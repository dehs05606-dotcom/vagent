module vagent

import x.json2

// adherence.v — which of your rules does the model actually follow?
//
// "The model does not follow the system prompt" is the complaint that starts
// every attempt to fix this, and it is not actionable, because it is not a
// measurement. It does not say which rules, how often, or whether the last
// change helped.
//
// A 150k specification is not one instruction. It is several hundred, and
// they do not fail together. Some hold reliably, some never, and the
// difference is invisible while the only instrument is a feeling about the
// last few replies.
//
// So this is the instrument. For each clause it builds a probe — a request
// that clause governs — runs it, and scores the reply against that clause's
// own checkable rules:
//
//     clause   probes   followed   rate
//     [SQL]         3          3   100%
//     [OUT]         3          1    33%   <- this is the one to fix
//
// HOW A CLAUSE IS SCORED. Only against its own machine-checkable rules.
// A clause with no checkable rule cannot be scored and is reported as
// UNSCORABLE rather than counted as passing — silence is not compliance.
//
// WHAT IT IS NOT. Not a benchmark, and the numbers are not comparable
// between specifications: the probes are derived from the author's own
// clause text, so a vague clause produces a vague probe. It measures this
// model against this specification the same way every run, which is what
// makes two runs comparable with each other.
//
// The model is injected, never constructed here. An experiment that built
// its own subject could not be run against a different one.

pub const verdict_followed = 'followed'
pub const verdict_broken = 'broken'
pub const verdict_unscorable = 'unscorable'
pub const verdict_errored = 'errored'

pub const default_probes = 3

// probe_forms turn a rule into a request that would break it if the rule is
// not followed. Fixed and deterministic: a generated probe set would make
// two runs incomparable, which is the one thing this must not be.
const probe_forms = [
	'{title}. Do the work this describes and report what you did.',
	'I need help with this: {title}. Walk me through it and summarise.',
	'Handle this task: {title}. Then tell me the outcome.',
]

pub struct Probe {
pub mut:
	clause  string
	request string
	reply   string
	verdict string = verdict_unscorable
	detail  string
}

pub fn (p &Probe) to_json() map[string]json2.Any {
	return {
		'clause':  json2.Any(p.clause)
		'request': json2.Any(clip_plain(p.request, 200))
		'verdict': json2.Any(p.verdict)
		'detail':  json2.Any(p.detail)
	}
}

pub struct ClauseScore {
pub mut:
	clause string
	title  string
	probes []Probe
}

// scorable is the probes that produced a verdict either way. An errored
// probe is neither.
pub fn (s &ClauseScore) scorable() []Probe {
	return s.probes.filter(it.verdict == verdict_followed || it.verdict == verdict_broken)
}

pub fn (s &ClauseScore) followed() int {
	return s.probes.filter(it.verdict == verdict_followed).len
}

// rate is none when nothing was scorable — which is not the same as zero.
pub fn (s &ClauseScore) rate() ?f64 {
	n := s.scorable().len
	if n == 0 {
		return none
	}
	return f64(s.followed()) / f64(n)
}

pub fn (s &ClauseScore) to_json() map[string]json2.Any {
	return {
		'clause':   json2.Any(s.clause)
		'title':    json2.Any(s.title)
		'probes':   json2.Any(s.probes.map(json2.Any(it.to_json())))
		'followed': json2.Any(s.followed())
		'scorable': json2.Any(s.scorable().len)
		'rate':     if r := s.rate() { json2.Any(r) } else { json2.null }
	}
}

pub struct AdherenceReport {
pub mut:
	scores     []ClauseScore
	unscorable []string
	errors     int
}

pub fn (r &AdherenceReport) measured() []ClauseScore {
	return r.scores.filter(it.rate() != none)
}

pub fn (r &AdherenceReport) overall() ?f64 {
	measured := r.measured()
	if measured.len == 0 {
		return none
	}
	mut followed := 0
	mut total := 0
	for s in measured {
		followed += s.followed()
		total += s.scorable().len
	}
	if total == 0 {
		return none
	}
	return f64(followed) / f64(total)
}

fn (r &AdherenceReport) ranked() []ClauseScore {
	mut m := r.measured()
	m.sort_with_compare(fn (a &ClauseScore, b &ClauseScore) int {
		ra := a.rate() or { 0.0 }
		rb := b.rate() or { 0.0 }
		if ra < rb {
			return -1
		}
		if ra > rb {
			return 1
		}
		return compare_strings(a.clause, b.clause)
	})
	return m
}

pub fn (r &AdherenceReport) weakest(n int) []ClauseScore {
	m := r.ranked()
	return m[..min_int(n, m.len)].clone()
}

pub fn (r &AdherenceReport) describe() string {
	if r.scores.len == 0 && r.unscorable.len == 0 {
		return 'adherence: nothing to measure — no clauses are bound'
	}
	measured := r.measured()
	mut head := 'adherence: ${measured.len} clause(s) measured'
	if o := r.overall() {
		head += ' · ${o * 100.0:.0f}% overall'
	}
	if r.errors > 0 {
		head += ' · ${r.errors} probe error(s)'
	}
	mut lines := [
		head,
		'',
		'  ' + pad_width('clause', 14) + pad_left('probes', 7) + pad_left('followed', 10) +
			pad_left('rate', 7),
	]
	for s in r.ranked() {
		rate := s.rate() or { 0.0 }
		weak := if rate < 0.5 { '   <- weakest' } else { '' }
		lines << '  ' + pad_width(s.clause, 14) + pad_left(s.scorable().len.str(), 7) +
			pad_left(s.followed().str(), 10) + pad_left('${rate * 100.0:.0f}%', 7) + weak
	}
	if r.unscorable.len > 0 {
		lines << ''
		lines << '  ${r.unscorable.len} clause(s) carry no checkable rule and were NOT counted as passing:'
		head_list := r.unscorable[..min_int(12, r.unscorable.len)]
		more := if r.unscorable.len > 12 { ' …' } else { '' }
		lines << '    ' + head_list.join(', ') + more
		lines << '    give them an @output or @enforce rule to bring them into the measurement'
	}
	return lines.join('\n')
}

// probes_for are requests that exercise one clause. They are derived from
// the author's text, never invented: a probe this module wrote would measure
// the model against this module's idea of the rule.
pub fn probes_for(clause &Clause, count int) []Probe {
	mut subject := clause.title.trim_space()
	if subject == '' {
		for line in split_lines(clause.body) {
			if line.trim_space() != '' {
				subject = line.trim_space()
				break
			}
		}
	}
	// a directive line is not a description of the rule
	if re := compile_regex(r'^@\w+.*$') {
		if _ := re.search(subject) {
			subject = ''
		}
	}
	subject = subject.trim_space()
	if subject == '' {
		return []
	}
	n := min_int(max_int(1, count), probe_forms.len)
	mut out := []Probe{}
	for form in probe_forms[..n] {
		out << Probe{
			clause:  clause.id
			request: form.replace('{title}', subject)
		}
	}
	return out
}

// AskFn runs one probe. The agent passes one that runs a real turn.
pub type AskFn = fn (request string) !string

@[heap]
pub struct Adherence {
pub mut:
	log      &EventLog
	spec     string
	covenant &Covenant
}

pub fn new_adherence(log &EventLog, spec string) &Adherence {
	return &Adherence{
		log:      unsafe { log }
		spec:     spec
		covenant: new_covenant(log, spec)
	}
}

fn (a &Adherence) rules_for(clause_id string) []Rule {
	rules, _ := parse_rules(a.spec)
	return rules.filter(it.clause == clause_id)
}

// run probes each clause and scores every reply.
pub fn (mut a Adherence) run(ask AskFn, clauses []string, count int) AdherenceReport {
	mut report := AdherenceReport{}
	wanted := clauses.clone()

	for c in a.covenant.clauses {
		if wanted.len > 0 && c.id !in wanted {
			continue
		}
		out_rules := a.rules_for(c.id)
		if out_rules.len == 0 {
			// no checkable rule: not scorable, and explicitly NOT a pass
			if c.id != 'preamble' {
				report.unscorable << c.id
			}
			continue
		}
		mut score := ClauseScore{
			clause: c.id
			title:  c.title
		}
		for mut probe in probes_for(&c, count) {
			reply := ask(probe.request) or {
				// one probe failed, not the run
				probe.verdict = verdict_errored
				probe.detail = err.msg()
				report.errors++
				score.probes << probe
				continue
			}
			probe.reply = reply
			unmet := check_rules(out_rules, probe.reply)
			if unmet.len > 0 {
				probe.verdict = verdict_broken
				probe.detail = unmet[0].detail
			} else {
				probe.verdict = verdict_followed
			}
			score.probes << probe
		}
		a.log.append('adherence.clause', score.to_json(), AppendOpts{ actor: 'kernel' })
		report.scores << score
	}

	a.log.append('adherence.run', {
		'measured':   json2.Any(report.measured().len)
		'unscorable': json2.Any(report.unscorable.len)
		'overall':    if o := report.overall() { json2.Any(o) } else { json2.null }
		'errors':     json2.Any(report.errors)
	}, AppendOpts{ actor: 'kernel' })
	return report
}
