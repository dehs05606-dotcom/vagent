module vagent

import x.json2

fn seed_dashboard_log(mut log EventLog) {
	log.append('user.message', {
		'text': json2.Any('fix the parser')
	}, AppendOpts{ actor: 'human' })
	log.append('tool.call', {
		'name': json2.Any('read_file')
		'args': json2.Any({
			'path': json2.Any('p.py')
		})
	}, AppendOpts{})
	log.append('tool.result', {
		'name':   json2.Any('read_file')
		'status': json2.Any('done')
	}, AppendOpts{})
	log.append('tool.result', {
		'name':   json2.Any('edit_file')
		'status': json2.Any('error')
	}, AppendOpts{})
	log.append('cost.incurred', {
		'usd':        json2.Any(0.05)
		'tokens_in':  json2.Any(100)
		'tokens_out': json2.Any(40)
	}, AppendOpts{})
	log.append('goal.set', {
		'statement': json2.Any('fix parser')
		'clauses':   json2.Any([
			json2.Any({
				'id': json2.Any('C1')
			}),
			json2.Any({
				'id': json2.Any('C2')
			}),
		])
	}, AppendOpts{})
	log.append('goal.clause.done', {
		'clause': json2.Any('C1')
	}, AppendOpts{})
	log.append('router.decision', {
		'model':    json2.Any('agnes-2.5-flash')
		'est_cost': json2.Any(0.0)
	}, AppendOpts{})
	log.append('spec.prefetch', {
		'tool': json2.Any('read_file')
	}, AppendOpts{})
	log.append('spec.hit', {
		'tool': json2.Any('read_file')
	}, AppendOpts{})
	log.append('judge.verdict', {
		'passed': json2.Any(true)
		'kind':   json2.Any('exit_code')
	}, AppendOpts{})
	log.append('judge.verdict', {
		'passed': json2.Any(false)
		'kind':   json2.Any('file_exists')
	}, AppendOpts{})
	log.append('memory.episode', {
		'goal':    json2.Any('fix parser')
		'outcome': json2.Any('success')
	}, AppendOpts{})
	log.append('deadend.recorded', {
		'signature': json2.Any('x')
		'reason':    json2.Any('y')
	}, AppendOpts{})
	log.append('heal.lesson', {
		'root': json2.Any('missing import')
	}, AppendOpts{})
	log.append('skill.registered', {
		'name': json2.Any('csv_clean')
	}, AppendOpts{})
	log.append('council.verdict', {
		'decision': json2.Any('thesis')
	}, AppendOpts{})
	log.append('analysis.taint', {
		'path':     json2.Any('p.py')
		'findings': json2.Any([
			json2.Any({
				'sink': json2.Any('eval')
			}),
		])
	}, AppendOpts{})
	log.append('graph.entity', {
		'entities':  json2.Any(12)
		'relations': json2.Any(9)
	}, AppendOpts{})
	log.append('coverage.result', {
		'path':    json2.Any('p.py')
		'percent': json2.Any(83.0)
		'hit':     json2.Any(5)
		'total':   json2.Any(6)
	}, AppendOpts{})
	log.append('fuzz.run', {
		'target':     json2.Any('f')
		'iterations': json2.Any(30)
	}, AppendOpts{})
	log.append('fuzz.crash', {
		'target': json2.Any('f')
		'error':  json2.Any('TypeError')
	}, AppendOpts{})
	log.append('mutation.result', {
		'path':     json2.Any('p.py')
		'score':    json2.Any(0.29)
		'killed':   json2.Any(2)
		'survived': json2.Any(5)
	}, AppendOpts{})
}

fn test_an_empty_log_still_renders_every_panel() {
	mut log := new_event_log(tmp_log_path('dash1'), 'main', 'test')
	mut d := new_dashboard(log)
	text := d.render(62)
	assert text.contains('FULLAGENT LIVE DASHBOARD')
	assert text.contains('GOAL   none active')
	for panel in ['COST', 'AGENTS', 'ROUTER', 'SPEC', 'MEMORY', 'HEALTH', 'ENGINE'] {
		assert text.contains(panel), panel
	}
	// nothing measured is an em dash, not a zero: a zero would read as a
	// real measurement saying nothing works
	assert text.contains('cov — (0 runs)'), text
	assert text.contains('mut — (0 runs)'), text
}

fn test_the_snapshot_is_a_faithful_projection_of_the_ledger() {
	mut log := new_event_log(tmp_log_path('dash2'), 'main', 'test')
	seed_dashboard_log(mut log)
	mut d := new_dashboard(log)
	s := d.snapshot()

	assert s.cost_usd == 0.05
	assert s.tool_calls == 1
	assert s.tool_errors == 1
	assert s.goal_active
	assert s.clauses_proven == 1
	assert s.clauses_total == 2
	assert s.routed == 1
	assert s.spec_prefetched == 1
	assert s.spec_hits == 1
	assert s.spec_misses == 0
	assert s.verdicts == 2
	assert s.verdicts_failed == 1
	assert s.episodes == 1
	assert s.dead_ends == 1
	assert s.heals == 1
	assert s.skills == 1
	assert s.councils == 1
	assert s.taint_findings == 1
	assert s.graph_entities == 12
	assert s.cov_runs == 1
	assert (s.cov_last or { -1.0 }) == 83.0
	assert s.fuzz_crashes == 1
	assert s.mut_runs == 1
	assert (s.mut_last or { -1.0 }) == 0.29
}

fn test_the_render_shows_the_numbers_the_snapshot_holds() {
	mut log := new_event_log(tmp_log_path('dash3'), 'main', 'test')
	seed_dashboard_log(mut log)
	mut d := new_dashboard(log)
	text := d.render(62)
	assert text.contains('50%'), text
	assert text.contains('"fix parser"'), text
	assert text.contains('83%'), text
	assert text.contains('29%'), text
	assert text.contains('⚠1'), text
	assert text.contains('verdicts 2 (failed 1)'), text
	assert text.contains('rate 100%'), text
}

fn test_the_dashboard_never_writes() {
	mut log := new_event_log(tmp_log_path('dash4'), 'main', 'test')
	seed_dashboard_log(mut log)
	before := log.head('main')
	mut d := new_dashboard(log)
	d.snapshot()
	d.render(62)
	d.tail(-1, 5)
	assert log.head('main') == before
}

fn test_the_ticker_streams_only_what_is_newer_than_the_cursor() {
	mut log := new_event_log(tmp_log_path('dash5'), 'main', 'test')
	seed_dashboard_log(mut log)
	mut d := new_dashboard(log)

	tail := d.tail(-1, 5)
	assert tail.len == 5
	// oldest first inside the window, and the window is the NEWEST five
	for i in 1 .. tail.len {
		assert tail[i].seq > tail[i - 1].seq
	}
	head := log.head('main')
	assert tail[tail.len - 1].seq == head
	assert d.tail(head, 12).len == 0
	assert d.tail(-1, 0).len == 0
}

fn test_each_event_kind_summarises_into_one_line() {
	assert summarise_event('tool.result', {
		'name':   json2.Any('read_file')
		'status': json2.Any('done')
	}) == 'read_file -> done'
	assert summarise_event('cost.incurred', {
		'usd': json2.Any(0.05)
	}) == '\$0.0500'
	assert summarise_event('judge.verdict', {
		'passed': json2.Any(false)
		'kind':   json2.Any('file_exists')
	}) == 'FAIL file_exists'
	assert summarise_event('mutation.result', {
		'score': json2.Any(0.29)
	}) == 'mutation score 29%'
	assert summarise_event('analysis.taint', {
		'findings': json2.Any([json2.Any('a'), json2.Any('b')])
	}) == 'taint 2 finding(s)'
	// a missing name is a question mark rather than an empty gap
	assert summarise_event('tool.call', map[string]json2.Any{}) == '?'
	// an unknown event kind summarises to nothing rather than guessing
	assert summarise_event('some.new.event', map[string]json2.Any{}) == ''
}

fn test_the_goal_bar_rounds_to_even_at_an_exact_half() {
	// one clause of eight is 2.5 cells; rounding up would draw a fuller bar
	// than the ledger supports
	assert banker_round(2.5) == 2
	assert banker_round(3.5) == 4
	assert banker_round(2.4) == 2
	assert banker_round(2.6) == 3
	assert banker_round(0.0) == 0
	assert banker_round(20.0) == 20
}
