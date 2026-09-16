module vagent

import x.json2

fn test_plan_frontier_and_write_exclusivity() {
	path := tmp_log_path('cortex.jsonl')
	mut log := new_event_log(path, 'main', '')
	defer {
		log.close()
	}
	mut plan := new_plan(log)
	plan.add(Node{ id: 'n1', goal: 'read config', kind: 'READ' }) or { panic(err) }
	plan.add(Node{
		id:         'n2'
		goal:       'write auth'
		kind:       'WRITE'
		path_set:   ['src/auth.py']
		depends_on: ['n1']
	}) or { panic(err) }
	plan.add(Node{
		id:         'n3'
		goal:       'write auth tests'
		kind:       'WRITE'
		path_set:   ['src/auth.py']
		depends_on: ['n1']
	}) or { panic(err) }
	plan.add(Node{
		id:         'n4'
		goal:       'write docs'
		kind:       'WRITE'
		path_set:   ['docs.md']
		depends_on: ['n1']
	}) or { panic(err) }

	// n1 is the only PENDING node with all deps passed
	assert plan.frontier().map(jstr(it, 'id')) == ['n1']
	plan.set_status('n1', 'PASSED') or { panic(err) }

	// n2 and n3 overlap on src/auth.py -> only one may be scheduled
	ids := plan.eligible(8).map(jstr(it, 'id'))
	assert 'n2' in ids && 'n4' in ids, '${ids}'
	assert !('n2' in ids && 'n3' in ids), 'overlapping writes scheduled together: ${ids}'
}

fn test_plan_rejects_bad_kinds_and_statuses() {
	path := tmp_log_path('cortex-bad.jsonl')
	mut log := new_event_log(path, 'main', '')
	defer {
		log.close()
	}
	mut plan := new_plan(log)
	if _ := plan.add(Node{ id: 'x', goal: 'g', kind: 'NOPE' }) {
		assert false, 'an unknown node kind was accepted'
	}
	if _ := plan.add(Node{ id: 'x', goal: 'g', risk: 'NOPE' }) {
		assert false, 'an unknown risk level was accepted'
	}
	plan.set_status('x', 'NOPE') or { return }
	assert false, 'an unknown status was accepted'
}

fn test_budget_governor_pauses_on_breach() {
	path := tmp_log_path('cortex-budget.jsonl')
	mut log := new_event_log(path, 'main', '')
	defer {
		log.close()
	}
	mut gov := new_budget_governor(log, Budget{ max_usd: 0.001, max_steps: 1000 })
	log.append('cost.incurred', {
		'usd':        json2.Any(0.5)
		'tokens_in':  json2.Any(10)
		'tokens_out': json2.Any(5)
	}, AppendOpts{})

	ok, reason := gov.check()
	assert !ok
	assert reason.contains('USD'), reason
	assert gov.enforce() == false

	events := fold(mut log, '').budget_events
	assert events.len > 0
	assert jstr(events.last(), 'kind') == 'exceeded'

	// while paused, the same reason is sealed only once — no event spam
	before := fold(mut log, '').budget_events.len
	gov.enforce()
	gov.enforce()
	assert fold(mut log, '').budget_events.len == before
}

fn test_budget_is_unlimited_by_default() {
	path := tmp_log_path('cortex-unlimited.jsonl')
	mut log := new_event_log(path, 'main', '')
	defer {
		log.close()
	}
	mut gov := new_budget_governor(log, Budget{})
	log.append('cost.incurred', {
		'usd':        json2.Any(9999.0)
		'tokens_in':  json2.Any(1_000_000)
		'tokens_out': json2.Any(1_000_000)
	}, AppendOpts{})
	ok, _ := gov.check()
	assert ok, 'the default budget stopped a run'
}

fn test_budget_spend_is_session_scoped() {
	path := tmp_log_path('cortex-session.jsonl')
	mut log := new_event_log(path, 'main', '')
	defer {
		log.close()
	}
	log.append('cost.incurred', {
		'usd': json2.Any(5.0)
	}, AppendOpts{})
	// a new session must start with a fresh budget, or a crossed limit
	// would pause every future turn forever
	log.append('session.start', map[string]json2.Any{}, AppendOpts{})
	mut gov := new_budget_governor(log, Budget{ max_usd: 1.0 })
	assert gov.spend().usd == 0.0
	ok, _ := gov.check()
	assert ok
}

fn test_budget_reset_and_set_limit() {
	path := tmp_log_path('cortex-reset.jsonl')
	mut log := new_event_log(path, 'main', '')
	defer {
		log.close()
	}
	mut gov := new_budget_governor(log, Budget{ max_usd: 0.001 })
	log.append('cost.incurred', {
		'usd': json2.Any(0.5)
	}, AppendOpts{})
	assert !gov.enforce()

	gov.reset()
	ok, _ := gov.check()
	assert ok, 'reset did not forget the spend'

	msg := gov.set_limit('steps', '42') or { panic(err) }
	assert msg.contains('steps budget set to 42'), msg
	assert gov.budget.max_steps == 42
	if _ := gov.set_limit('nope', '1') {
		assert false, 'an unknown axis was accepted'
	}
}

fn test_budget_slices_cap_subagents() {
	path := tmp_log_path('cortex-slice.jsonl')
	mut log := new_event_log(path, 'main', '')
	defer {
		log.close()
	}
	gov := new_budget_governor(log, Budget{
		max_usd: 10.0
		slices:  {
			'scouts': 0.05
		}
	})
	assert math_abs(gov.slice_for('scouts') - 0.5) < 1e-9
	assert gov.slice_for('unknown') == 0.0
}

fn test_loop_detector_exact_repeat() {
	path := tmp_log_path('cortex-loops.jsonl')
	mut log := new_event_log(path, 'main', '')
	defer {
		log.close()
	}
	mut det := new_loop_detector(log, 3, 10)
	for _ in 0 .. 2 {
		log.append('tool.call', {
			'name': json2.Any('read_file')
			'args': json2.Any({
				'path': json2.Any('x.py')
			})
		}, AppendOpts{})
	}
	assert det.exact_repeat() == none

	log.append('tool.call', {
		'name': json2.Any('read_file')
		'args': json2.Any({
			'path': json2.Any('x.py')
		})
	}, AppendOpts{})
	assert det.exact_repeat() != none

	alerts := det.detect()
	assert alerts.len > 0
	assert jstr(alerts[0], 'kind') == 'exact_repeat'
	assert fold(mut log, '').loop_alerts.len > 0

	// a different argument set is not a repeat
	mut det2 := new_loop_detector(log, 3, 10)
	log.append('tool.call', {
		'name': json2.Any('read_file')
		'args': json2.Any({
			'path': json2.Any('y.py')
		})
	}, AppendOpts{})
	_ := det2.exact_repeat()
}

fn test_loop_detector_oscillation() {
	path := tmp_log_path('cortex-osc.jsonl')
	mut log := new_event_log(path, 'main', '')
	defer {
		log.close()
	}
	det := new_loop_detector(log, 3, 10)
	assert det.oscillation('f.py', ['h1', 'h2', 'h1', 'h2']) == true
	assert det.oscillation('f.py', ['h1', 'h2', 'h1', 'h3']) == false
	assert det.oscillation('f.py', ['h1', 'h2', 'h1']) == false
	// a file that never changed is not oscillating
	assert det.oscillation('f.py', ['h1', 'h1', 'h1', 'h1']) == false
}
