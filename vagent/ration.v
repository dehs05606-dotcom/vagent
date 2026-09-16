module vagent

import x.json2

// ration.v — the budgets a specification sets, enforced before they are spent.
//
// horizon.v counts effects: files written, commands run. Those are the units
// of what the agent DOES. They are not the units anyone runs out of. What
// runs out is money, context and time, and none of the three is visible to a
// rule about files:
//
//     "a turn costs at most $2"
//     "no single model call sends more than 120k tokens"
//     "a turn takes at most 10 minutes of wall clock"
//
// These are the constraints an operator cares about most and the ones a
// boundary usually cannot express at all, so they end up as a monitor that
// notices overspend after it happened. Noticing is not enforcing. Money spent
// is spent; a 200k-token request that the provider was going to reject is
// rejected whether or not a dashboard recorded it.
//
// So a ration is checked on the PROJECTION, like a horizon: the cost of the
// call about to be made is added to what the window has already spent, and
// the call is refused if the total would cross the line. The budget is
// therefore never exceeded rather than reported as exceeded.
//
// Three windows, because the three run out differently:
//
//     call      one model request — where a hard provider limit bites
//     turn      one instruction from the user
//     session   the whole run
//
// Spend is folded from sealed events, so it survives a restart and cannot
// drift from what was actually billed. A ration and a horizon are
// deliberately separate: one is about the size of the work, the other about
// what the work consumes, and collapsing them would make it impossible to
// say "any number of files, but only two dollars".

pub const window_call = 'call'
pub const ration_windows = [window_call, window_turn, window_session]

pub const ration_measures = ['cost_usd', 'tokens_in', 'tokens_out', 'tokens_total',
	'seconds', 'calls']

pub struct RationLimit {
pub:
	clause  string
	window  string
	measure string
	limit   f64
}

pub fn (l &RationLimit) to_json() map[string]json2.Any {
	return {
		'clause':  json2.Any(l.clause)
		'window':  json2.Any(l.window)
		'measure': json2.Any(l.measure)
		'limit':   json2.Any(l.limit)
	}
}

pub struct Overspend {
pub:
	clause    string
	window    string
	measure   string
	limit     f64
	spent     f64
	projected f64
}

pub fn (o &Overspend) to_json() map[string]json2.Any {
	return {
		'clause':    json2.Any(o.clause)
		'window':    json2.Any(o.window)
		'measure':   json2.Any(o.measure)
		'limit':     json2.Any(o.limit)
		'spent':     json2.Any(round_to(o.spent, 6))
		'projected': json2.Any(round_to(o.projected, 6))
	}
}

fn ration_fmt(measure string, v f64) string {
	return if measure == 'cost_usd' { '\$${v:.2f}' } else { '${v:.0f}' }
}

pub fn (o &Overspend) describe() string {
	return '${o.clause}: ${o.measure} per ${o.window} is capped at ${ration_fmt(o.measure,
		o.limit)}; this call would reach ${ration_fmt(o.measure, o.projected)} ' +
		'(spent ${ration_fmt(o.measure, o.spent)})'
}

pub fn parse_ration_limits(spec string) ([]RationLimit, []string) {
	mut limits := []RationLimit{}
	mut errors := []string{}
	mut clause := 'preamble'

	section_re := compile_regex(r'^\s{0,3}§\s*([\d.]+[a-z]?)') or { return limits, errors }
	tag_re := compile_regex(r'^\s{0,3}\[([A-Za-z0-9_.\-]+)\]') or { return limits, errors }
	head_re := compile_regex(r'(?i)^\s*@ration\b') or { return limits, errors }
	line_re := compile_regex(r'(?i)^\s*@ration\s+per\s+(call|turn|session)\s+max\s+(\w+)\s+([0-9]+(?:\.[0-9]+)?)\s*$') or {
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
			errors << "${clause}: malformed @ration — expected '@ration per turn max cost_usd 2.00'"
			continue
		}
		measure := group_text(line, &m, 2).to_lower()
		if measure !in ration_measures {
			errors << "${clause}: unknown measure '${measure}' — known: ${ration_measures.join(", ")}"
			continue
		}
		value := group_text(line, &m, 3).f64()
		if value <= 0 {
			errors << '${clause}: a limit of ${value} forbids all work'
			continue
		}
		limits << RationLimit{
			clause:  clause
			window:  group_text(line, &m, 1).to_lower()
			measure: measure
			limit:   value
		}
	}
	return limits, errors
}

// Estimate is what a call is expected to consume, before it is made.
pub struct Estimate {
pub:
	cost_usd   f64
	tokens_in  int
	tokens_out int
	seconds    f64
}

pub fn (e &Estimate) as_measures() map[string]f64 {
	return {
		'cost_usd':     e.cost_usd
		'tokens_in':    f64(e.tokens_in)
		'tokens_out':   f64(e.tokens_out)
		'tokens_total': f64(e.tokens_in + e.tokens_out)
		'seconds':      e.seconds
		'calls':        1.0
	}
}

@[heap]
pub struct Ration {
pub mut:
	log     &EventLog
	limits  []RationLimit
	errors  []string
	blocked int
mut:
	turn_started    f64
	session_started f64
}

pub fn new_ration(log &EventLog, spec string) &Ration {
	now := now_ts()
	mut r := &Ration{
		log:             unsafe { log }
		turn_started:    now
		session_started: now
	}
	r.bind(spec)
	return r
}

pub fn (mut r Ration) bind(spec string) {
	r.limits, r.errors = parse_ration_limits(spec)
}

// -- windows -----------------------------------------------------------------

pub fn (mut r Ration) open_turn() {
	r.turn_started = now_ts()
	r.log.append('ration.turn', map[string]json2.Any{}, AppendOpts{ actor: 'kernel' })
}

fn zero_ration_totals() map[string]f64 {
	mut t := map[string]f64{}
	for m in ration_measures {
		t[m] = 0.0
	}
	return t
}

// totals is the spend so far in this window, folded from the log.
pub fn (mut r Ration) totals(window string) map[string]f64 {
	mut totals := zero_ration_totals()
	if window == window_call {
		// a call window starts empty every time
		return totals
	}
	for ev in r.log.events(r.log.branch) {
		if ev.typ == 'ration.turn' && window == window_turn {
			totals = zero_ration_totals()
		} else if ev.typ == 'ration.spent' {
			for k in ration_measures {
				if k in ev.data {
					totals[k] = totals[k] + jf64(ev.data, k)
				}
			}
			totals['calls'] = totals['calls'] + 1.0
		}
	}
	// elapsed time is read from the clock rather than accumulated per call:
	// a turn that sat waiting has still used its ten minutes
	now := now_ts()
	if window == window_turn {
		totals['seconds'] = now - r.turn_started
	} else if window == window_session {
		totals['seconds'] = now - r.session_started
	}
	return totals
}

// spend seals what a completed call actually consumed.
pub fn (mut r Ration) spend(cost_usd f64, tokens_in int, tokens_out int, seconds f64) {
	r.log.append('ration.spent', {
		'cost_usd':     json2.Any(cost_usd)
		'tokens_in':    json2.Any(tokens_in)
		'tokens_out':   json2.Any(tokens_out)
		'tokens_total': json2.Any(tokens_in + tokens_out)
		'seconds':      json2.Any(seconds)
	}, AppendOpts{ actor: 'kernel' })
}

// -- the boundary ------------------------------------------------------------

pub fn (mut r Ration) project(estimate Estimate) []Overspend {
	if r.limits.len == 0 {
		return []
	}
	want := estimate.as_measures()
	mut cache := map[string]map[string]f64{}
	mut out := []Overspend{}
	for lim in r.limits {
		if lim.window !in cache {
			cache[lim.window] = r.totals(lim.window).clone()
		}
		spent := cache[lim.window][lim.measure]
		projected := spent + (want[lim.measure] or { 0.0 })
		if projected > lim.limit {
			out << Overspend{
				clause:    lim.clause
				window:    lim.window
				measure:   lim.measure
				limit:     lim.limit
				spent:     spent
				projected: projected
			}
		}
	}
	return out
}

// gate is the block reason, or ''. It refuses on the projection, so a budget
// is never exceeded rather than reported as exceeded.
pub fn (mut r Ration) gate(estimate Estimate) string {
	over := r.project(estimate)
	if over.len == 0 {
		return ''
	}
	r.blocked++
	r.log.append('ration.blocked', {
		'overspend': json2.Any(over.map(json2.Any(it.to_json())))
	}, AppendOpts{ actor: 'kernel' })
	plural := if over.len > 1 { 's' } else { '' }
	mut lines := ['RationExceeded: this call would cross ${over.len} budget${plural} in the specification.']
	for o in over {
		lines << '  ${o.describe()}'
	}
	return lines.join('\n')
}

pub fn (mut r Ration) report() string {
	if r.limits.len == 0 {
		return 'ration: no @ration budgets in the specification'
	}
	mut lines := ['ration: ${r.limits.len} budget(s) · ${r.blocked} call(s) refused']
	mut cache := map[string]map[string]f64{}
	for lim in r.limits {
		if lim.window !in cache {
			cache[lim.window] = r.totals(lim.window).clone()
		}
		now := cache[lim.window][lim.measure]
		pct := if lim.limit != 0 { int(100.0 * now / lim.limit) } else { 0 }
		bar := if now >= lim.limit { '●' } else { '○' }
		unit := if lim.measure == 'cost_usd' { '\$' } else { '' }
		lines << '  ${bar} ' + pad_width(lim.clause, 8) + ' ' + pad_width(lim.measure, 13) +
			' ${unit}${now:.2f}/${unit}${lim.limit:.2f} (${pct}%) per ${lim.window}'
	}
	for e in r.errors {
		lines << '  !! ${e}'
	}
	return lines.join('\n')
}
