module vagent

import math
import x.json2

// dashboard.v — live observability over the temporal kernel.
//
// The whole system is already event-sourced, so the dashboard is simply the
// X-ray: a real-time projection of the ledger onto one screen — cost, tokens,
// goal progress, sub-agent activity, routing savings, speculation hit-rate,
// dead-ends, verdicts, loop alerts and the live event stream.
//
// Every panel is a pure fold over the event log. The dashboard keeps no state
// of its own, so it can never disagree with the kernel. render() returns plain
// text (the TUI colours it), snapshot() returns the raw record for
// programmatic consumers, and tail() streams the newest events since a cursor
// so the UI can poll cheaply without re-rendering everything.

// the panels, in display order
pub const dashboard_panels = ['cost', 'goal', 'agents', 'router', 'speculator', 'memory', 'health',
	'engineering', 'stream']

@[heap]
pub struct Dashboard {
pub mut:
	log &EventLog
}

pub fn new_dashboard(log &EventLog) &Dashboard {
	return &Dashboard{
		log: unsafe { log }
	}
}

// DashboardSnapshot is the raw projection. The two `?f64` fields are the
// point of the type: a coverage run that never happened is not 0%, and a
// mutation score that was never measured is not 0.0 — the difference has to
// survive all the way to the screen, where it renders as an em dash.
pub struct DashboardSnapshot {
pub mut:
	head_seq      int
	cost_usd      f64
	tokens_in     int
	tokens_out    int
	tool_calls    int
	tool_errors   int
	commands_run  int
	files_touched int

	goal_active    bool
	goal_statement string
	clauses_proven int
	clauses_total  int

	crew_done int
	councils  int

	routed      int
	routed_cost f64

	spec_prefetched int
	spec_hits       int
	spec_misses     int

	episodes  int
	dead_ends int
	facts     int
	heals     int
	skills    int

	verdicts        int
	verdicts_failed int
	loop_alerts     int
	budget_events   int

	taint_findings int
	graph_entities int
	cov_runs       int
	cov_last       ?f64
	fuzz_crashes   int
	mut_runs       int
	mut_last       ?f64
}

pub fn (s &DashboardSnapshot) to_json() map[string]json2.Any {
	mut d := {
		'head_seq':        json2.Any(s.head_seq)
		'cost_usd':        json2.Any(s.cost_usd)
		'tokens_in':       json2.Any(s.tokens_in)
		'tokens_out':      json2.Any(s.tokens_out)
		'tool_calls':      json2.Any(s.tool_calls)
		'tool_errors':     json2.Any(s.tool_errors)
		'commands_run':    json2.Any(s.commands_run)
		'files_touched':   json2.Any(s.files_touched)
		'goal_active':     json2.Any(s.goal_active)
		'goal_statement':  json2.Any(s.goal_statement)
		'clauses_proven':  json2.Any(s.clauses_proven)
		'clauses_total':   json2.Any(s.clauses_total)
		'crew_done':       json2.Any(s.crew_done)
		'routed':          json2.Any(s.routed)
		'routed_cost':     json2.Any(round_to(s.routed_cost, 4))
		'spec_prefetched': json2.Any(s.spec_prefetched)
		'spec_hits':       json2.Any(s.spec_hits)
		'spec_misses':     json2.Any(s.spec_misses)
		'episodes':        json2.Any(s.episodes)
		'dead_ends':       json2.Any(s.dead_ends)
		'facts':           json2.Any(s.facts)
		'verdicts':        json2.Any(s.verdicts)
		'verdicts_failed': json2.Any(s.verdicts_failed)
		'loop_alerts':     json2.Any(s.loop_alerts)
		'budget_events':   json2.Any(s.budget_events)
		'heals':           json2.Any(s.heals)
		'skills':          json2.Any(s.skills)
		'councils':        json2.Any(s.councils)
		'taint_findings':  json2.Any(s.taint_findings)
		'graph_entities':  json2.Any(s.graph_entities)
		'cov_runs':        json2.Any(s.cov_runs)
		'fuzz_crashes':    json2.Any(s.fuzz_crashes)
		'mut_runs':        json2.Any(s.mut_runs)
	}
	d['cov_last'] = if v := s.cov_last { json2.Any(v) } else { json2.Any(json2.null) }
	d['mut_last'] = if v := s.mut_last { json2.Any(v) } else { json2.Any(json2.null) }
	return d
}

// -- the snapshot -------------------------------------------------------------

pub fn (mut d Dashboard) snapshot() DashboardSnapshot {
	st := fold(mut d.log, d.log.branch)
	goal := st.goal or { Rec{} }

	mut s := DashboardSnapshot{
		head_seq:       st.head_seq
		cost_usd:       st.cost_usd
		tokens_in:      st.tokens_in
		tokens_out:     st.tokens_out
		tool_calls:     st.tool_calls
		tool_errors:    st.tool_errors
		commands_run:   st.commands_run
		files_touched:  st.files_touched.len
		goal_active:    jstr(goal, 'statement') != ''
		goal_statement: jstr(goal, 'statement')
		clauses_proven: st.goal_done.len
		clauses_total:  jarr(goal, 'clauses').len
		episodes:       st.episodes.len
		dead_ends:      st.dead_ends.len
		facts:          st.facts.len
		verdicts:       st.verdicts.len
		loop_alerts:    st.loop_alerts.len
		budget_events:  st.budget_events.len
	}

	// sub-agent activity comes from the crew roster's own seals
	for e in d.log.events(d.log.branch) {
		if e.typ == 'crew.done' {
			s.crew_done++
		}
	}

	// routing and speculation dividends
	s.routed = st.router_decisions.len
	for r in st.router_decisions {
		s.routed_cost += jf64(r, 'est_cost')
	}
	for e in st.spec_events {
		match jstr(e, 'type') {
			'spec.prefetch' { s.spec_prefetched++ }
			'spec.hit' { s.spec_hits++ }
			'spec.miss' { s.spec_misses++ }
			else {}
		}
	}

	s.verdicts_failed = st.verdicts.filter(!jbool(it, 'passed')).len
	s.heals = st.heal_events.filter(jstr(it, 'type') == 'heal.lesson').len
	s.skills = st.skill_events.filter(jstr(it, 'type') == 'skill.registered').len
	s.councils = st.council_events.filter(jstr(it, 'type') == 'council.verdict').len

	// the engineering subsystems
	for e in st.analysis_events {
		if jstr(e, 'type') == 'analysis.taint' {
			s.taint_findings += jarr(e, 'findings').len
		}
	}
	for e in st.graph_events {
		entities := jint(e, 'entities')
		if entities > s.graph_entities {
			s.graph_entities = entities
		}
	}
	cov_runs := st.coverage_events.filter(jstr(it, 'type') == 'coverage.result')
	s.cov_runs = cov_runs.len
	if cov_runs.len > 0 {
		s.cov_last = jf64(cov_runs[cov_runs.len - 1], 'percent')
	}
	s.fuzz_crashes = st.fuzz_events.filter(jstr(it, 'type') == 'fuzz.crash').len
	mut_reports := st.mutation_events.filter(jstr(it, 'type') == 'mutation.result')
	s.mut_runs = mut_reports.len
	if mut_reports.len > 0 {
		s.mut_last = jf64(mut_reports[mut_reports.len - 1], 'score')
	}
	return s
}

// -- the render ---------------------------------------------------------------

pub fn (mut d Dashboard) render(width int) string {
	s := d.snapshot()
	bar := '─'.repeat(width)
	mut lines := ['◆ FULLAGENT LIVE DASHBOARD', bar]

	lines << ' COST   \$${s.cost_usd:.4f}   ${s.tokens_in}→${s.tokens_out} tok   ' + 'tools ${s.tool_calls} (err ${s.tool_errors})   ' + 'cmds ${s.commands_run}   files ${s.files_touched}'

	if s.goal_active {
		pct := if s.clauses_total > 0 {
			f64(s.clauses_proven) / f64(s.clauses_total) * 100.0
		} else {
			0.0
		}
		filled := banker_round(pct / 100.0 * 20.0)
		gbar := '█'.repeat(filled) + '░'.repeat(20 - filled)
		lines << ' GOAL   [${gbar}] ${pct:.0f}%  ${s.clauses_proven}/${s.clauses_total} ' + 'clauses  "' + clip_plain(s.goal_statement, 34) + '"'
	} else {
		lines << ' GOAL   none active'
	}

	lines << ' AGENTS crew done ${s.crew_done}   councils ${s.councils}'
	lines << ' ROUTER ${s.routed} routed   est \$${s.routed_cost:.4f}'

	total_spec := s.spec_hits + s.spec_misses
	rate := if total_spec > 0 { f64(s.spec_hits) / f64(total_spec) } else { 0.0 }
	lines << ' SPEC   prefetched ${s.spec_prefetched}   hits ${s.spec_hits}   ' + 'misses ${s.spec_misses}   rate ${rate * 100.0:.0f}%'

	lines << ' MEMORY episodes ${s.episodes}   facts ${s.facts}   ' + 'dead-ends ${s.dead_ends}   heals ${s.heals}   skills ${s.skills}'

	lines << ' HEALTH verdicts ${s.verdicts} (failed ${s.verdicts_failed})   ' + 'loop alerts ${s.loop_alerts}   budget events ${s.budget_events}'

	// "never measured" renders as an em dash rather than a zero, because a
	// zero here would read as a real measurement of nothing working
	cov := if v := s.cov_last { '${v:.0f}%' } else { '—' }
	mutation := if v := s.mut_last { '${v * 100.0:.0f}%' } else { '—' }
	lines << ' ENGINE taint ${s.taint_findings}   graph ${s.graph_entities} ent   ' + 'cov ${cov} (${s.cov_runs} runs)   fuzz ⚠${s.fuzz_crashes}   ' + 'mut ${mutation} (${s.mut_runs} runs)'

	lines << bar
	return lines.join('\n')
}

// -- the event stream ---------------------------------------------------------

pub struct TickerRow {
pub:
	seq     int
	typ     string
	actor   string
	summary string
}

pub fn (r &TickerRow) to_json() map[string]json2.Any {
	return {
		'seq':     json2.Any(r.seq)
		'type':    json2.Any(r.typ)
		'actor':   json2.Any(r.actor)
		'summary': json2.Any(r.summary)
	}
}

// tail is the newest events with seq > since_seq, oldest first, for a live
// ticker.
//
// The UI polls this on every refresh tick. Materialising every event before
// slicing was O(N) per call — a 10k-event log at a 200ms refresh chewed CPU
// for nothing — so the walk runs in REVERSE and stops the moment the window
// is filled or the cursor horizon is crossed.
pub fn (mut d Dashboard) tail(since_seq int, limit int) []TickerRow {
	if limit <= 0 {
		return []
	}
	events := d.log.events(d.log.branch)
	mut out := []TickerRow{}
	for i := events.len - 1; i >= 0; i-- {
		ev := events[i]
		if ev.seq <= since_seq {
			break
		}
		out << TickerRow{
			seq:     ev.seq
			typ:     ev.typ
			actor:   ev.actor
			summary: summarise_event(ev.typ, ev.data)
		}
		if out.len >= limit {
			break
		}
	}
	out.reverse_in_place()
	return out
}

// summarise_event is the one-line human summary of an event for the ticker.
fn summarise_event(typ string, data map[string]json2.Any) string {
	match typ {
		'user.message', 'assistant.message' {
			return clip_plain(jstr(data, 'text'), 60)
		}
		'tool.call' {
			return name_or_unknown(data)
		}
		'tool.result' {
			status := if 'status' in data { jstr(data, 'status') } else { '?' }
			return '${name_or_unknown(data)} -> ${status}'
		}
		'cost.incurred' {
			return '\$${jf64(data, 'usd'):.4f}'
		}
		'router.decision' {
			model := if 'model' in data { jstr(data, 'model') } else { '?' }
			return '-> ${model}'
		}
		'spec.hit' {
			return 'cache hit ${name_or_unknown_key(data, 'tool')}'
		}
		'judge.verdict' {
			kind := if 'kind' in data { jstr(data, 'kind') } else { '?' }
			return (if jbool(data, 'passed') { 'PASS' } else { 'FAIL' }) + ' ${kind}'
		}
		'goal.distance' {
			return 'distance ${jf64_or(data, 'distance', 1.0):.2f}'
		}
		'heal.lesson', 'skill.registered', 'council.verdict' {
			return typ
		}
		'coverage.result' {
			return 'coverage ${jf64(data, 'percent'):.0f}% ${jstr(data, 'path')}'
		}
		'fuzz.crash' {
			return 'crash ' + clip_plain(jstr(data, 'error'), 40)
		}
		'mutation.result' {
			return 'mutation score ${jf64(data, 'score') * 100.0:.0f}%'
		}
		'analysis.taint' {
			return 'taint ${jarr(data, 'findings').len} finding(s)'
		}
		else {
			return ''
		}
	}
}

// banker_round is round-half-to-even, which is what the original's round()
// does. It matters exactly at a half: one clause proven of eight is 2.5 bar
// cells, and rounding that up would draw a fuller bar than the ledger says.
fn banker_round(x f64) int {
	floor := math.floor(x)
	diff := x - floor
	if diff > 0.5 {
		return int(floor) + 1
	}
	if diff < 0.5 {
		return int(floor)
	}
	// exactly a half — take the even neighbour
	n := i64(floor)
	return int(if n % 2 == 0 { n } else { n + 1 })
}

fn name_or_unknown(data map[string]json2.Any) string {
	return name_or_unknown_key(data, 'name')
}

fn name_or_unknown_key(data map[string]json2.Any, key string) string {
	return if key in data { jstr(data, key) } else { '?' }
}
