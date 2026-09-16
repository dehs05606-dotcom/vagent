module vagent

import os
import x.json2

fn test_oracle_analyze_and_report() {
	base := os.join_path(os.temp_dir(), 'vagent-oracle-${os.getpid()}')
	os.rmdir_all(base) or {}
	mut log := new_event_log(tmp_log_path('oracle.jsonl'), 'main', '')
	defer {
		log.close()
	}
	mut oracle := new_oracle(log, os.join_path(base, 'memory'))

	log.append('tool.call', {
		'name': json2.Any('read_file')
		'args': json2.Any({
			'path': json2.Any('a')
		})
	}, AppendOpts{})
	log.append('tool.result', {
		'name':   json2.Any('read_file')
		'status': json2.Any('error')
	}, AppendOpts{})
	log.append('tool.result', {
		'name':   json2.Any('read_file')
		'status': json2.Any('done')
	}, AppendOpts{})
	log.append('cost.incurred', {
		'usd': json2.Any(0.10)
	}, AppendOpts{ correlation_id: 'C1' })
	log.append('cost.incurred', {
		'usd': json2.Any(0.05)
	}, AppendOpts{ correlation_id: 'C2' })
	log.append('deadend.recorded', {
		'signature': json2.Any('abc')
		'reason':    json2.Any('x')
	}, AppendOpts{})

	a := oracle.analyze()
	assert a.tool_calls >= 1
	assert a.wasted_steps == 1
	assert a.dead_ends_hit == 1
	assert math_abs(a.cost_usd - 0.15) < 1e-9
	assert math_abs((a.cost_by_clause['C1'] or { 0 }) - 0.10) < 1e-9

	report := oracle.format_report()
	assert report.contains('ORACLE')
	assert report.contains('cost by clause')
}

fn test_unattributed_cost_stays_visible() {
	mut log := new_event_log(tmp_log_path('oracle-unattr.jsonl'), 'main', '')
	defer {
		log.close()
	}
	mut oracle := new_oracle(log, '')
	log.append('cost.incurred', {
		'usd': json2.Any(0.25)
	}, AppendOpts{}) // no correlation_id
	a := oracle.analyze()
	// the report must not claim cost_usd equals the sum of the attributed
	// clauses when part of the spend served no clause
	assert '__unattributed__' in a.cost_by_clause
	assert math_abs((a.cost_by_clause['__unattributed__'] or { 0 }) - 0.25) < 1e-9
	mut summed := 0.0
	for _, v in a.cost_by_clause {
		summed += v
	}
	assert math_abs(summed - a.cost_usd) < 1e-9
}

fn test_calibration_tracks_prediction_error() {
	mut log := new_event_log(tmp_log_path('oracle-cal.jsonl'), 'main', '')
	defer {
		log.close()
	}
	mut oracle := new_oracle(log, '')
	assert oracle.calibrate().n == 0

	oracle.record_calibration('WRITE', 3.0, 5.0)
	oracle.record_calibration('WRITE', 4.0, 4.0)
	cal := oracle.calibrate()
	assert cal.n == 2
	assert math_abs(cal.mean_abs_error - 1.0) < 1e-9
	assert math_abs((cal.by_kind['WRITE'] or { 0 }) - 1.0) < 1e-9
}

fn test_facts_are_written_human_readable() {
	base := os.join_path(os.temp_dir(), 'vagent-oracle-facts-${os.getpid()}')
	os.rmdir_all(base) or {}
	mut log := new_event_log(tmp_log_path('oracle-facts.jsonl'), 'main', '')
	defer {
		log.close()
	}
	mut oracle := new_oracle(log, os.join_path(base, 'memory'))
	oracle.learn_fact('tests live in tests/', 'project')
	oracle.learn_fact('FLAKE: test_x is intermittent', 'flake')

	path := oracle.write_facts_md()
	assert path != ''
	content := os.read_file(path)!
	assert content.contains('tests live in tests/')
	assert content.contains('[flake]')
}

fn test_constitution_is_never_auto_modified() {
	base := os.join_path(os.temp_dir(), 'vagent-oracle-const-${os.getpid()}')
	os.rmdir_all(base) or {}
	mut log := new_event_log(tmp_log_path('oracle-const.jsonl'), 'main', '')
	defer {
		log.close()
	}
	mut oracle := new_oracle(log, os.join_path(base, 'memory'))
	assert oracle.read_constitution() == ''

	result := oracle.propose_constitution_amendment('always run make check')
	assert result.contains('pending human')
	// the file is still untouched — only a human may accept
	assert oracle.read_constitution() == ''
	assert !os.exists(oracle.constitution_path())

	mut saw := false
	for a in fold(mut log, '').amendments {
		if jstr(a, 'kind') == 'CONSTITUTION' {
			saw = true
		}
	}
	assert saw
}

// -- autopilot ---------------------------------------------------------------

fn test_autopilot_goal_mode() {
	mut log := new_event_log(tmp_log_path('autopilot.jsonl'), 'main', '')
	defer {
		log.close()
	}
	mut ap := new_autopilot(log, true)

	d := ap.route('fix the login bug in auth.py', false, 3)
	assert d.suggest_goal
	assert d.goal_clauses.len > 0
	assert jstr(d.goal_clauses[0], 'id') == 'C1'
	assert d.summary().contains('goal mode')

	// questions never trigger goal mode
	q := ap.route('what is the best way to fix a login bug?', false, 3)
	assert !q.suggest_goal

	// an active goal suppresses auto-drafting
	active := ap.route('implement the new parser now', true, 3)
	assert !active.suggest_goal
}

fn test_autopilot_web_mode() {
	mut log := new_event_log(tmp_log_path('autopilot-web.jsonl'), 'main', '')
	defer {
		log.close()
	}
	mut ap := new_autopilot(log, true)

	assert ap.route('what is the latest news about AI today?', false, 3).use_web
	assert ap.route('tell me the current bitcoin price', false, 3).use_web
	// plain chat enables nothing
	assert !ap.route('hello, how are you', false, 3).active()
}

fn test_triggers_respect_word_boundaries() {
	mut log := new_event_log(tmp_log_path('autopilot-bounds.jsonl'), 'main', '')
	defer {
		log.close()
	}
	mut ap := new_autopilot(log, true)
	// "rate" must not fire inside "generate", nor "fix" inside "suffix"
	d := ap.route('generate a suffix for the address field', false, 3)
	assert !d.use_web, '${d.reasons}'
	assert !d.suggest_goal, '${d.reasons}'
	// but the whole words still do
	assert ap.route('what is the rate today?', false, 3).use_web
}

fn test_autopilot_can_be_disabled_and_seals_its_routes() {
	mut log := new_event_log(tmp_log_path('autopilot-off.jsonl'), 'main', '')
	defer {
		log.close()
	}
	mut ap := new_autopilot(log, true)
	ap.route('build the parser module', false, 3)
	mut routed := 0
	for e in log.events('') {
		if e.typ == 'autopilot.route' {
			routed++
		}
	}
	assert routed >= 1

	ap.enabled = false
	off := ap.route('fix everything and also test everything please', false, 3)
	assert !off.active()
}

fn test_drafted_clauses_are_machine_checkable_when_possible() {
	mut log := new_event_log(tmp_log_path('autopilot-draft.jsonl'), 'main', '')
	defer {
		log.close()
	}
	mut ap := new_autopilot(log, true)

	// an explicit path becomes a file_exists predicate
	d := ap.route('create ./out/report.md for the team', false, 3)
	assert d.suggest_goal
	mut has_predicate := false
	for c in d.goal_clauses {
		if jstr(jmap(c, 'proof'), 'type') == 'file_exists' {
			has_predicate = true
		}
	}
	assert has_predicate, '${d.goal_clauses}'

	// with nothing checkable to derive, the clause is advisory rather than
	// a goal that cannot be failed pretending to be one
	vague := ap.route('make it nicer', false, 3)
	assert vague.suggest_goal
	assert jbool(vague.goal_clauses[0], 'advisory')
}
