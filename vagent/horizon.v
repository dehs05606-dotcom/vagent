module vagent

import x.json2

// horizon.v — the clauses no single action can break.
//
// Every guard so far judges one call in isolation. That is the right unit
// for "never write outside src/", because each write either lands inside or
// does not. It is the wrong unit — structurally, not by oversight — for a
// whole class of real constraints:
//
//     "a change touches at most 20 files"
//     "no more than 400 lines are rewritten without review"
//     "delete at most 5 files in a session"
//
// None of these can be violated by one action. Each individual step is
// perfectly legal and would be waved through by any per-call check; the
// breach exists only in the SUM. An agent that hits such a limit does not do
// it by making one bad decision — it does it by making forty reasonable ones.
//
// So a horizon clause is evaluated against an accumulating window:
//
//     §12 A change touches at most 20 files.
//     @horizon per turn max files_written 20
//
// The window is the unit the limit is about: `turn` resets when the agent
// takes a new instruction, `session` never resets. Counters are FOLDED from
// the sealed record rather than tallied in a variable, so they survive a
// restart and cannot drift from what actually happened.
//
// What makes this enforceable rather than merely observable is WHERE it is
// checked: the projected total. Before a call runs, its effects are added to
// the window's current total, and the call is refused if that projection
// crosses the limit. The limit is therefore never exceeded — not detected
// afterwards, when twenty-one files are already written.

pub const window_turn = 'turn'
pub const window_session = 'session'

pub const horizon_measures = ['files_written', 'files_deleted', 'lines_written',
	'commands_run', 'opaque_commands', 'bytes_written']

pub struct Limit {
pub:
	clause  string
	window  string
	measure string
	limit   int
}

pub fn (l &Limit) to_json() map[string]json2.Any {
	return {
		'clause':  json2.Any(l.clause)
		'window':  json2.Any(l.window)
		'measure': json2.Any(l.measure)
		'limit':   json2.Any(l.limit)
	}
}

pub struct Breach {
pub:
	clause    string
	measure   string
	window    string
	limit     int
	projected int
	current   int
}

pub fn (b &Breach) to_json() map[string]json2.Any {
	return {
		'clause':    json2.Any(b.clause)
		'measure':   json2.Any(b.measure)
		'window':    json2.Any(b.window)
		'limit':     json2.Any(b.limit)
		'projected': json2.Any(b.projected)
		'current':   json2.Any(b.current)
	}
}

pub fn (b &Breach) describe() string {
	return '${b.clause}: ${b.measure} per ${b.window} is capped at ${b.limit}; ' +
		'this call would reach ${b.projected} (currently ${b.current})'
}

pub fn parse_limits(spec string) ([]Limit, []string) {
	mut limits := []Limit{}
	mut errors := []string{}
	mut clause := 'preamble'

	section_re := compile_regex(r'^\s{0,3}§\s*([\d.]+[a-z]?)') or { return limits, errors }
	tag_re := compile_regex(r'^\s{0,3}\[([A-Za-z0-9_.\-]+)\]') or { return limits, errors }
	head_re := compile_regex(r'(?i)^\s*@horizon\b') or { return limits, errors }
	line_re := compile_regex(r'(?i)^\s*@horizon\s+per\s+(turn|session)\s+max\s+(\w+)\s+(\d+)\s*$') or {
		return limits, errors
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
		m := line_re.search(line) or {
			errors << "${clause}: malformed @horizon — expected '@horizon per turn max files_written 20'"
			continue
		}
		measure := group_text(line, &m, 2).to_lower()
		if measure !in horizon_measures {
			errors << "${clause}: unknown measure '${measure}' — known: ${horizon_measures.join(", ")}"
			continue
		}
		limits << Limit{
			clause:  clause
			window:  group_text(line, &m, 1).to_lower()
			measure: measure
			limit:   group_text(line, &m, 3).int()
		}
	}
	return limits, errors
}

// measure_call is what one call contributes to each measure.
//
// It counts from EFFECTS, so a shell write weighs exactly what the same
// write through write_file weighs. Paths are counted once per call: a
// command that writes one file twice is one file.
pub fn measure_call(tool string, args map[string]json2.Any) map[string]int {
	effects := derive(tool, args)
	mut written := map[string]bool{}
	mut deleted := map[string]bool{}
	mut content := []string{}
	mut commands := 0
	mut opaque := 0
	for e in effects {
		match e.kind {
			effect_write {
				if e.path != '' {
					written[e.path] = true
				}
				if e.content != '' {
					content << e.content
				}
			}
			effect_delete {
				if e.path != '' {
					deleted[e.path] = true
				}
			}
			effect_exec {
				commands++
			}
			effect_opaque {
				opaque++
			}
			else {}
		}
	}
	mut lines := 0
	mut bytes := 0
	for c in content {
		lines += c.count('\n') + 1
		bytes += c.len
	}
	return {
		'files_written':   written.len
		'files_deleted':   deleted.len
		'lines_written':   lines
		'bytes_written':   bytes
		'commands_run':    commands
		'opaque_commands': opaque
	}
}

@[heap]
pub struct Horizon {
pub mut:
	log     &EventLog
	limits  []Limit
	errors  []string
	blocked int
}

pub fn new_horizon(log &EventLog, spec string) &Horizon {
	mut h := &Horizon{
		log: unsafe { log }
	}
	h.bind(spec)
	return h
}

pub fn (mut h Horizon) bind(spec string) {
	h.limits, h.errors = parse_limits(spec)
}

// -- the fold ----------------------------------------------------------------

fn zero_totals() map[string]int {
	mut t := map[string]int{}
	for m in horizon_measures {
		t[m] = 0
	}
	return t
}

// totals are the current counts, folded from the sealed record.
//
// A counter kept in memory would reset on restart and drift whenever an
// event was written that it did not see. Folding costs a pass over the log
// and is always exactly what happened.
pub fn (mut h Horizon) totals(window string) map[string]int {
	mut totals := zero_totals()
	for ev in h.log.events(h.log.branch) {
		match ev.typ {
			'horizon.spent' {
				if window == window_turn && jbool(ev.data, 'turn_boundary') {
					totals = zero_totals()
					continue
				}
				for k in horizon_measures {
					totals[k] = totals[k] + jint(ev.data, k)
				}
			}
			'horizon.turn' {
				if window == window_turn {
					totals = zero_totals()
				}
			}
			else {}
		}
	}
	return totals
}

// open_turn starts a new turn window. It is sealed, so the reset is part of
// the record rather than an in-memory fact the log cannot show.
pub fn (mut h Horizon) open_turn() {
	h.log.append('horizon.turn', map[string]json2.Any{}, AppendOpts{ actor: 'kernel' })
}

// spend seals what a completed call consumed.
pub fn (mut h Horizon) spend(tool string, args map[string]json2.Any) map[string]int {
	spent := measure_call(tool, args)
	mut any_spent := false
	for _, v in spent {
		if v != 0 {
			any_spent = true
			break
		}
	}
	if any_spent {
		mut payload := map[string]json2.Any{}
		for k, v in spent {
			payload[k] = json2.Any(v)
		}
		payload['tool'] = json2.Any(tool)
		h.log.append('horizon.spent', payload, AppendOpts{ actor: 'kernel' })
	}
	return spent
}

// -- the boundary ------------------------------------------------------------

// project is the breaches this call WOULD cause if it ran.
pub fn (mut h Horizon) project(tool string, args map[string]json2.Any) []Breach {
	if h.limits.len == 0 {
		return []
	}
	spent := measure_call(tool, args)
	mut cache := map[string]map[string]int{}
	mut out := []Breach{}
	for lim in h.limits {
		if lim.window !in cache {
			cache[lim.window] = h.totals(lim.window).clone()
		}
		current := cache[lim.window][lim.measure]
		projected := current + spent[lim.measure]
		if projected > lim.limit {
			out << Breach{
				clause:    lim.clause
				measure:   lim.measure
				window:    lim.window
				limit:     lim.limit
				projected: projected
				current:   current
			}
		}
	}
	return out
}

// gate is the block reason, or '' to allow. It refuses on the PROJECTED
// total, so the limit is never crossed rather than noticed once it has been.
pub fn (mut h Horizon) gate(tool string, args map[string]json2.Any) string {
	breaches := h.project(tool, args)
	if breaches.len == 0 {
		return ''
	}
	h.blocked++
	h.log.append('horizon.blocked', {
		'tool':     json2.Any(tool)
		'breaches': json2.Any(breaches.map(json2.Any(it.to_json())))
	}, AppendOpts{ actor: 'kernel' })
	plural := if breaches.len > 1 { 's' } else { '' }
	mut lines := ['HorizonExceeded: this call would cross ${breaches.len} limit${plural} in the specification.']
	for b in breaches {
		lines << '  ${b.describe()}'
	}
	return lines.join('\n')
}

pub fn (mut h Horizon) report() string {
	if h.limits.len == 0 {
		return 'horizon: no @horizon limits in the specification'
	}
	mut lines := ['horizon: ${h.limits.len} limit(s) · ${h.blocked} call(s) refused']
	mut cache := map[string]map[string]int{}
	for lim in h.limits {
		if lim.window !in cache {
			cache[lim.window] = h.totals(lim.window).clone()
		}
		now := cache[lim.window][lim.measure]
		bar := if now >= lim.limit { '●' } else { '○' }
		lines << '  ${bar} ' + pad_width(lim.clause, 8) + ' ' + pad_width(lim.measure, 16) +
			' ${now}/${lim.limit} per ${lim.window}'
	}
	for e in h.errors {
		lines << '  !! ${e}'
	}
	return lines.join('\n')
}
