module vagent

import crypto.blake2b
import x.json2

// provenance.v — where the bytes being written came from.
//
// Guards judge WHAT is written and WHERE. Neither question reaches the one
// that matters for a whole class of clauses: what is the ORIGIN of this
// content?
//
//     "code fetched from the web is never committed unreviewed"
//     "nothing from a tool's error output ends up in a source file"
//     "a credential read from the environment never lands on disk"
//
// Each of these is invisible to a content rule, because the bytes are
// unremarkable. `def parse(s): ...` is fine; the same line copied verbatim
// out of a web_fetch five turns ago may not be. The difference is not in the
// text — it is in where the text came from, which only the log knows.
//
// So every tool result is recorded as a SOURCE with a kind (web, file,
// command, env), its content is shingled into rolling fingerprints, and a
// pending write is matched against those shingles:
//
//     §14 Web content is never written to source unreviewed.
//     @origin forbid web -> src/**
//
// Matching is by SHINGLE OVERLAP rather than equality, because content is
// rarely copied byte for byte: it is reindented, renamed, trimmed. A rule
// that only caught exact copies would catch nothing real. The threshold is
// explicit and reported, so a near miss is a number you can see rather than
// a silent pass.
//
// WHAT THIS IS NOT. Not information-flow analysis, and it claims no
// soundness. It detects reuse of recorded content above a threshold.
// Content that is heavily rewritten, or that passed through a
// transformation this module never saw, is not detected — and report() says
// so rather than implying coverage it does not have.

pub const origin_web = 'web'
pub const origin_file = 'file'
pub const origin_command = 'command'
pub const origin_env = 'env'
pub const origin_kinds = [origin_web, origin_file, origin_command, origin_env]

// The window size is the sensitivity dial. Measured against a 700-character
// sample: 48/16 yields 13 fingerprints and misses a rename-plus-reindent at
// 0.23, while 32/8 yields 27 and catches it at 0.30, with unrelated content
// still at 0.00. Going finer does not improve the rename case and starts
// matching on common code idioms, so 32/8 is the floor worth taking.
const shingle_size = 32
const shingle_stride = 8
// a source too short to fingerprint usefully
const min_source_chars = 120
const default_origin_threshold = 0.25

// which tools produce which kind of source
fn source_kind_of(tool string) ?string {
	return match tool {
		'web_fetch', 'web_search' { origin_web }
		'read_file', 'search_files', 'list_dir' { origin_file }
		'run_command', 'live_shell', 'bg_shell' { origin_command }
		else { none }
	}
}

// normalise_content collapses whitespace so reindentation does not defeat
// matching.
pub fn normalise_content(text string) string {
	mut out := []u8{}
	mut in_space := false
	for c in text.trim_space() {
		if c == ` ` || c == `\t` || c == `\n` || c == `\r` {
			if !in_space {
				out << ` `
				in_space = true
			}
			continue
		}
		in_space = false
		out << c
	}
	return out.bytestr().to_lower()
}

// shingles are the rolling content fingerprints.
//
// The original used blake2b truncated to eight bytes. V's blake2b has no
// 64-bit variant, so this takes the first eight bytes of the 160-bit sum —
// the same width of fingerprint. The values differ from Python's, which is
// harmless: shingles are never persisted or compared across processes.
pub fn shingles(text string) map[string]bool {
	norm := normalise_content(text)
	mut out := map[string]bool{}
	if norm.len < shingle_size {
		return out
	}
	for i := 0; i <= norm.len - shingle_size; i += shingle_stride {
		window := norm[i..i + shingle_size]
		digest := blake2b.sum160(window.bytes())
		out[digest[..8].hex()] = true
	}
	return out
}

pub struct OriginRule {
pub:
	clause    string
	kind      string
	glob      string
	threshold f64 = default_origin_threshold
}

pub fn (r &OriginRule) to_json() map[string]json2.Any {
	return {
		'clause':    json2.Any(r.clause)
		'kind':      json2.Any(r.kind)
		'glob':      json2.Any(r.glob)
		'threshold': json2.Any(r.threshold)
	}
}

// Source is one recorded origin of content.
pub struct Source {
pub:
	kind string
	// a url, a path, or a command
	label string
	marks map[string]bool
}

pub struct Taint {
pub:
	clause    string
	kind      string
	path      string
	label     string
	overlap   f64
	threshold f64
}

pub fn (t &Taint) to_json() map[string]json2.Any {
	return {
		'clause':    json2.Any(t.clause)
		'kind':      json2.Any(t.kind)
		'path':      json2.Any(t.path)
		'label':     json2.Any(t.label)
		'overlap':   json2.Any(round_to(t.overlap, 3))
		'threshold': json2.Any(t.threshold)
	}
}

pub fn (t &Taint) describe() string {
	return "${t.clause}: '${t.path}' reuses ${t.overlap * 100.0:.0f}% of content from " +
		"${t.kind} source '${t.label}' (threshold ${t.threshold * 100.0:.0f}%)"
}

pub fn parse_origin_rules(spec string) ([]OriginRule, []string) {
	mut rules := []OriginRule{}
	mut errors := []string{}
	mut clause := 'preamble'

	section_re := compile_regex(r'^\s{0,3}§\s*([\d.]+[a-z]?)') or { return rules, errors }
	tag_re := compile_regex(r'^\s{0,3}\[([A-Za-z0-9_.\-]+)\]') or { return rules, errors }
	head_re := compile_regex(r'(?i)^\s*@origin\b') or { return rules, errors }
	origin_re := compile_regex(r'(?i)^\s*@origin\s+forbid\s+(web|file|command|env)\s*->\s*(\S+)(?:\s+over\s+([0-9.]+))?\s*$') or {
		return rules, errors
	}

	for line in split_lines(spec) {
		if m := section_re.search(line) {
			clause = group_text(line, &m, 1)
			continue
		}
		if m := tag_re.search(line) {
			clause = group_text(line, &m, 1)
			continue
		}
		if _ := head_re.search(line) {
		} else {
			continue
		}
		m := origin_re.search(line) or {
			errors << "${clause}: malformed @origin — expected '@origin forbid web -> src/**' (optionally 'over 0.3')"
			continue
		}
		raw := group_text(line, &m, 3)
		mut threshold := default_origin_threshold
		if raw != '' {
			if !is_number_text(raw) {
				errors << "${clause}: threshold '${raw}' is not a number"
				continue
			}
			threshold = raw.f64()
		}
		if threshold <= 0 || threshold > 1 {
			errors << '${clause}: threshold must be between 0 and 1'
			continue
		}
		rules << OriginRule{
			clause:    clause
			kind:      group_text(line, &m, 1).to_lower()
			glob:      group_text(line, &m, 2)
			threshold: threshold
		}
	}
	return rules, errors
}

fn is_number_text(s string) bool {
	if s == '' {
		return false
	}
	mut dots := 0
	for c in s {
		if c == `.` {
			dots++
			if dots > 1 {
				return false
			}
			continue
		}
		if c < `0` || c > `9` {
			return false
		}
	}
	return s != '.'
}

@[heap]
pub struct Lineage {
pub mut:
	log     &EventLog
	rules   []OriginRule
	errors  []string
	sources []Source
	blocked int
}

pub fn new_lineage(log &EventLog, spec string) &Lineage {
	mut l := &Lineage{
		log: unsafe { log }
	}
	l.bind(spec)
	return l
}

pub fn (mut l Lineage) bind(spec string) {
	l.rules, l.errors = parse_origin_rules(spec)
}

// -- recording ---------------------------------------------------------------

// observe records a tool result as a source of content.
pub fn (mut l Lineage) observe(tool string, args map[string]json2.Any, result string) ?Source {
	kind := source_kind_of(tool) or { return none }
	if result.len < min_source_chars {
		return none
	}
	mut label := jstr(args, 'url')
	for key in ['path', 'command', 'query'] {
		if label != '' {
			break
		}
		label = jstr(args, key)
	}
	if label == '' {
		label = tool
	}
	marks := shingles(result)
	if marks.len == 0 {
		return none
	}
	src := Source{
		kind:  kind
		label: label
		marks: marks.clone()
	}
	l.sources << src
	l.log.append('provenance.source', {
		'kind':  json2.Any(kind)
		'label': json2.Any(clip_plain(label, 200))
		'marks': json2.Any(marks.len)
	}, AppendOpts{ actor: 'kernel' })
	return src
}

// -- the boundary ------------------------------------------------------------

// check is the origin clauses this pending write would break.
pub fn (mut l Lineage) check(tool string, args map[string]json2.Any) []Taint {
	if l.rules.len == 0 || l.sources.len == 0 {
		return []
	}
	mut out := []Taint{}
	for e in derive(tool, args) {
		if e.kind != effect_write || e.content == '' || e.path == '' {
			continue
		}
		marks := shingles(e.content)
		if marks.len == 0 {
			continue
		}
		for rule in l.rules {
			if !seq_glob(e.path, rule.glob) {
				continue
			}
			for src in l.sources {
				if src.kind != rule.kind {
					continue
				}
				mut overlap_count := 0
				for m, _ in marks {
					if m in src.marks {
						overlap_count++
					}
				}
				if overlap_count == 0 {
					continue
				}
				overlap := f64(overlap_count) / f64(marks.len)
				if overlap >= rule.threshold {
					out << Taint{
						clause:    rule.clause
						kind:      rule.kind
						path:      e.path
						label:     src.label
						overlap:   overlap
						threshold: rule.threshold
					}
					break
				}
			}
		}
	}
	return out
}

pub fn (mut l Lineage) gate(tool string, args map[string]json2.Any) string {
	taints := l.check(tool, args)
	if taints.len == 0 {
		return ''
	}
	l.blocked++
	l.log.append('provenance.blocked', {
		'tool':   json2.Any(tool)
		'taints': json2.Any(taints.map(json2.Any(it.to_json())))
	}, AppendOpts{ actor: 'kernel' })
	plural := if taints.len > 1 { 's' } else { '' }
	mut lines := [
		'OriginRefused: this write reuses content from a source ${taints.len} clause${plural} forbid as an origin.',
	]
	for t in taints {
		lines << '  ${t.describe()}'
	}
	return lines.join('\n')
}

pub fn (l &Lineage) report() string {
	if l.rules.len == 0 {
		return 'provenance: no @origin rules — content lineage is untracked'
	}
	mut by_kind := map[string]int{}
	for s in l.sources {
		by_kind[s.kind] = by_kind[s.kind] + 1
	}
	mut keys := by_kind.keys()
	keys.sort()
	parts := keys.map('${it}:${by_kind[it]}')
	breakdown := if parts.len > 0 { parts.join(', ') } else { 'none' }
	mut lines := [
		'provenance: ${l.rules.len} rule(s) · ${l.sources.len} source(s) recorded (${breakdown}) · ${l.blocked} refused',
	]
	for r in l.rules {
		lines << '  ' + pad_width(r.clause, 10) + ' no ' + pad_width(r.kind, 8) +
			' content in ${r.glob} (over ${r.threshold * 100.0:.0f}%)'
	}
	lines << '  detects reuse above the threshold; heavily rewritten content is not detected'
	for e in l.errors {
		lines << '  !! ${e}'
	}
	return lines.join('\n')
}
