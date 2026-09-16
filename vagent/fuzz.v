module vagent

import x.json2

// fuzz.v — property-based fuzzing with shrinking.
//
// Feeds a function a stream of generated inputs — random, boundary and
// mutated — and watches for crashes and invariant violations. When something
// breaks, the engine SHRINKS the failing input to a minimal reproducer, which
// is the difference between "it crashed somewhere" and "here is the exact
// smallest input that breaks it".
//
//   * Generators produce typed values with a bias toward boundaries: zero,
//     minus one, empty, huge, unicode, the shapes that break parsers.
//   * A target under test crashes by returning an error. An optional
//     invariant checks post-conditions; returning false, or failing, counts.
//   * Shrinking repeatedly tries simpler variants — shorter strings, smaller
//     numbers, dropped elements — and keeps the smallest one that still
//     fails.
//   * Runs are sealed as fuzz.run, fuzz.crash and fuzz.shrunk.
//
// Under one seed the whole run is deterministic, so a crash found in CI can
// be reproduced exactly. The generator is this package's own splitmix64
// rather than the original's Mersenne Twister, so the two implementations
// explore different streams — each is reproducible on its own terms, and
// neither claims to replay the other's sequence.

const max_shrink_steps = 60

// -- the values under test ----------------------------------------------------

// FuzzValue is the dynamic value a fuzzed function receives. The original
// fuzzed Python's own values; this is the same set, made explicit.
pub type FuzzValue = FuzzBlob
	| []FuzzValue
	| bool
	| f64
	| i64
	| map[string]FuzzValue
	| string
	| FuzzNone

// FuzzNone is the absent value — the one that finds every missing null check.
pub struct FuzzNone {}

// FuzzBlob is a byte string, kept distinct from text because the bugs they
// find are different ones.
pub struct FuzzBlob {
pub:
	data []u8
}

pub fn (v FuzzValue) repr() string {
	match v {
		FuzzNone { return 'none' }
		bool { return v.str() }
		i64 { return v.str() }
		f64 { return v.str() }
		string { return "'${v}'" }
		FuzzBlob { return 'bytes(${v.data.len})' }
		[]FuzzValue { return '[' + v.map(it.repr()).join(', ') + ']' }
		map[string]FuzzValue { return fuzz_map_repr(v) }
	}
}

fn fuzz_map_repr(m map[string]FuzzValue) string {
	mut keys := m.keys()
	keys.sort()
	mut parts := []string{}
	for k in keys {
		if val := m[k] {
			parts << "'${k}': ${val.repr()}"
		}
	}
	return '{' + parts.join(', ') + '}'
}

pub fn args_repr(args []FuzzValue) string {
	return '(' + args.map(it.repr()).join(', ') + ')'
}

// -- input generation ---------------------------------------------------------

// The boundary values carry most of the yield. Random inputs find the bugs
// nobody thought about; these find the ones everybody thought about and got
// slightly wrong.
const boundary_ints = [i64(0), 1, -1, 2, -2, 128, -128, 32768, 2147483648, -2147483648, max_i64,
	min_i64]

const boundary_strs = ['', ' ', '\n', '\t', '\x00', 'a', 'abc', 'A'.repeat(64), 'é', '😀', '\x27"\\',
	'<script>', '../../../etc/passwd', '%s%s%s', '{0}', '\$(rm -rf /)', 'SELECT * FROM t;--']

const printable_alphabet = 'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789' + '!"#\$%&\x27()*+,-./:;<=>?@[\\]^_`{|}~ \t\n\r'

pub struct FuzzGenerator {
pub mut:
	rng Rng
}

pub fn new_fuzz_generator(seed u64) FuzzGenerator {
	return FuzzGenerator{
		rng: new_rng(seed)
	}
}

pub fn (mut g FuzzGenerator) integer() i64 {
	if g.rng.f64() < 0.35 {
		return boundary_ints[g.rng.below(boundary_ints.len)]
	}
	return i64(g.rng.below(2000001)) - 1000000
}

pub fn (mut g FuzzGenerator) text() string {
	if g.rng.f64() < 0.35 {
		return boundary_strs[g.rng.below(boundary_strs.len)]
	}
	n := g.rng.below(41)
	mut out := []u8{}
	for _ in 0 .. n {
		out << printable_alphabet[g.rng.below(printable_alphabet.len)]
	}
	return out.bytestr()
}

pub fn (mut g FuzzGenerator) blob() FuzzBlob {
	if g.rng.f64() < 0.3 {
		return FuzzBlob{}
	}
	n := 1 + g.rng.below(32)
	mut out := []u8{}
	for _ in 0 .. n {
		out << u8(g.rng.below(256))
	}
	return FuzzBlob{
		data: out
	}
}

pub fn (mut g FuzzGenerator) list() []FuzzValue {
	n := g.rng.below(9)
	mut out := []FuzzValue{}
	for _ in 0 .. n {
		out << g.any(1)
	}
	return out
}

pub fn (mut g FuzzGenerator) dict() map[string]FuzzValue {
	n := g.rng.below(6)
	mut out := map[string]FuzzValue{}
	for _ in 0 .. n {
		key := clip(g.text(), 8)
		out[key] = g.any(1)
	}
	return out
}

// any is one value of any shape. Past depth two it flattens to an integer, so
// a generated value cannot recurse without bound.
pub fn (mut g FuzzGenerator) any(depth int) FuzzValue {
	if depth > 2 {
		return FuzzValue(g.integer())
	}
	choice := g.rng.f64()
	if choice < 0.25 {
		return FuzzValue(g.integer())
	}
	if choice < 0.5 {
		return FuzzValue(g.text())
	}
	if choice < 0.6 {
		return FuzzValue(FuzzNone{})
	}
	if choice < 0.7 {
		return FuzzValue(g.rng.f64())
	}
	if choice < 0.85 {
		return FuzzValue(g.list())
	}
	if choice < 0.92 {
		return FuzzValue(g.blob())
	}
	return FuzzValue(g.dict())
}

pub fn (mut g FuzzGenerator) args_for(nargs int) []FuzzValue {
	mut out := []FuzzValue{}
	for _ in 0 .. nargs {
		out << g.any(0)
	}
	return out
}

// -- shrinking ------------------------------------------------------------------

// simpler_variants are the smaller values to try in place of a failing one.
// The order matters: the emptiest candidate comes first, so the shrink
// converges on the smallest reproducer rather than a merely smaller one.
pub fn simpler_variants(v FuzzValue) []FuzzValue {
	mut out := []FuzzValue{}
	match v {
		string {
			if v.len > 0 {
				out << FuzzValue('')
				out << FuzzValue(v[..1])
				out << FuzzValue(v[..v.len / 2])
				out << FuzzValue(v[v.len / 2..])
				for i in 0 .. min_int(v.len, 8) {
					out << FuzzValue(v[..i] + v[i + 1..])
				}
			}
		}
		i64 {
			if v != 0 {
				out << FuzzValue(i64(0))
				out << FuzzValue(if v > 0 { i64(1) } else { i64(-1) })
				out << FuzzValue(v / 2)
			}
		}
		f64 {
			out << FuzzValue(0.0)
		}
		[]FuzzValue {
			if v.len > 0 {
				out << FuzzValue([]FuzzValue{})
				out << FuzzValue(v[..v.len / 2].clone())
				for i in 0 .. min_int(v.len, 6) {
					mut dropped := v[..i].clone()
					dropped << v[i + 1..]
					out << FuzzValue(dropped)
				}
			}
		}
		map[string]FuzzValue {
			if v.len > 0 {
				out << FuzzValue(map[string]FuzzValue{})
				mut keys := v.keys()
				keys.sort()
				for k in keys[..min_int(keys.len, 4)] {
					mut d := v.clone()
					d.delete(k)
					out << FuzzValue(d)
				}
			}
		}
		FuzzBlob {
			if v.data.len > 0 {
				out << FuzzValue(FuzzBlob{})
				out << FuzzValue(FuzzBlob{
					data: v.data[..v.data.len / 2].clone()
				})
			}
		}
		else {}
	}
	return out
}

// -- the engine -----------------------------------------------------------------

// FuzzTarget is the callable under test. An error is a crash.
pub type FuzzTarget = fn (args []FuzzValue) !FuzzValue

// FuzzInvariant is an optional post-condition. Returning false, or failing,
// counts as a violation.
pub type FuzzInvariant = fn (result FuzzValue, args []FuzzValue) !bool

pub struct Crash {
pub mut:
	args         []FuzzValue
	error        string
	shrunk_args  []FuzzValue
	shrunk_error string
	iterations   int
}

pub fn (c &Crash) to_json() map[string]json2.Any {
	return {
		'args':         json2.Any(clip_plain(args_repr(c.args), 200))
		'error':        json2.Any(clip_plain(c.error, 200))
		'shrunk_args':  json2.Any(clip_plain(args_repr(c.shrunk_args), 200))
		'shrunk_error': json2.Any(clip_plain(c.shrunk_error, 200))
	}
}

pub struct FuzzReport {
pub mut:
	target             string
	iterations         int
	crashes            int
	invariant_failures int
	first_crash        ?Crash
	ok                 bool = true
}

pub fn (r &FuzzReport) to_json() map[string]json2.Any {
	mut d := {
		'target':             json2.Any(r.target)
		'iterations':         json2.Any(r.iterations)
		'crashes':            json2.Any(r.crashes)
		'invariant_failures': json2.Any(r.invariant_failures)
		'ok':                 json2.Any(r.ok)
	}
	d['first_crash'] = if c := r.first_crash {
		json2.Any(c.to_json())
	} else {
		json2.Any(json2.null)
	}
	return d
}

@[heap]
pub struct Fuzzer {
pub mut:
	log &EventLog
	gen FuzzGenerator
}

pub fn new_fuzzer(log &EventLog, seed u64) &Fuzzer {
	return &Fuzzer{
		log: unsafe { log }
		gen: new_fuzz_generator(seed)
	}
}

pub struct FuzzOpts {
pub:
	iterations int = 200
	nargs      int = 1
	name       string
	invariant  FuzzInvariant = unsafe { nil }
}

// fuzz runs the target against generated inputs. It never fails outward: a
// crash is the finding, not an accident.
pub fn (mut f Fuzzer) fuzz(target FuzzTarget, opts FuzzOpts) FuzzReport {
	mut report := FuzzReport{
		target: if opts.name != '' { opts.name } else { 'target' }
	}
	f.log.append('fuzz.run', {
		'target':     json2.Any(report.target)
		'iterations': json2.Any(opts.iterations)
		'nargs':      json2.Any(opts.nargs)
	}, AppendOpts{ actor: 'fuzzer' })

	for i in 0 .. opts.iterations {
		report.iterations = i + 1
		args := f.gen.args_for(opts.nargs)
		result := target(args) or {
			report.crashes++
			mut crash := Crash{
				args:       args.clone()
				error:      err.msg()
				iterations: i + 1
			}
			f.shrink(mut crash, target)
			if report.first_crash == none {
				report.first_crash = crash
			}
			f.log.append('fuzz.crash', {
				'target': json2.Any(report.target)
				'args':   json2.Any(clip_plain(args_repr(args), 200))
				'error':  json2.Any(clip_plain(crash.error, 200))
			}, AppendOpts{ actor: 'fuzzer' })
			continue
		}
		if opts.invariant == unsafe { nil } {
			continue
		}
		held := opts.invariant(result, args) or {
			report.crashes++
			if report.first_crash == none {
				report.first_crash = Crash{
					args:       args.clone()
					error:      'invariant raised ${err.msg()}'
					iterations: i + 1
				}
			}
			continue
		}
		if !held {
			report.invariant_failures++
			if report.first_crash == none {
				report.first_crash = Crash{
					args:       args.clone()
					error:      'invariant returned False'
					iterations: i + 1
				}
			}
		}
	}
	report.ok = report.crashes == 0 && report.invariant_failures == 0
	return report
}

// shrink reduces the failing arguments to a minimal reproducer.
fn (mut f Fuzzer) shrink(mut crash Crash, target FuzzTarget) {
	mut current := crash.args.clone()
	for _ in 0 .. max_shrink_steps {
		mut improved := false
		for idx in 0 .. current.len {
			for simpler in simpler_variants(current[idx]) {
				mut candidate := current.clone()
				candidate[idx] = simpler
				target(candidate) or {
					// still fails, and on a smaller input
					current = candidate.clone()
					improved = true
					break
				}
			}
		}
		if !improved {
			break
		}
	}
	crash.shrunk_args = current.clone()
	target(current) or {
		crash.shrunk_error = err.msg()
		f.seal_shrunk(crash)
		return
	}
	// the shrink walked off the failing input entirely — say so rather than
	// reporting a reproducer that does not reproduce
	crash.shrunk_error = '(no longer reproduces)'
	f.seal_shrunk(crash)
}

fn (mut f Fuzzer) seal_shrunk(crash &Crash) {
	f.log.append('fuzz.shrunk', {
		'args':  json2.Any(clip_plain(args_repr(crash.shrunk_args), 200))
		'error': json2.Any(clip_plain(crash.shrunk_error, 200))
	}, AppendOpts{ actor: 'fuzzer' })
}

// -- projections ----------------------------------------------------------------

pub fn (mut f Fuzzer) runs() []Rec {
	st := fold(mut f.log, f.log.branch)
	return st.fuzz_events
}

pub fn (mut f Fuzzer) format_status() string {
	evs := f.runs()
	runs := evs.filter(jstr(it, 'type') == 'fuzz.run')
	crashes := evs.filter(jstr(it, 'type') == 'fuzz.crash')
	mut lines := ['FUZZ', '  runs ${runs.len}   crashes ${crashes.len}']
	mut tail := crashes.clone()
	if tail.len > 5 {
		tail = tail[tail.len - 5..].clone()
	}
	for c in tail {
		lines << '    ⚠ ' + clip_plain(jstr(c, 'error'), 60) + '  args ' + clip_plain(jstr(c, 'args'), 40)
	}
	return lines.join('\n')
}
