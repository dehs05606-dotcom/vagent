module vagent

import x.json2

fn at_call(mut log EventLog, name string, args map[string]json2.Any) {
	log.append('tool.call', {
		'name': json2.Any(name)
		'args': json2.Any(args.clone())
	}, AppendOpts{})
}

fn at_result(mut log EventLog, result string) {
	log.append('tool.result', {
		'result': json2.Any(result)
	}, AppendOpts{})
}

fn at_args(pairs map[string]string) map[string]json2.Any {
	mut out := map[string]json2.Any{}
	for k, v in pairs {
		out[k] = json2.Any(v)
	}
	return out
}

fn verdicts_for(a &Attestation, kind string) []string {
	return a.claims.filter(it.kind == kind).map(it.verdict)
}

fn test_a_passing_claim_is_supported_by_a_passing_run() {
	mut log := new_event_log(tmp_log_path('at1'), 'main', 'test')
	at_call(mut log, 'run_command', at_args({
		'command': 'pytest -q'
	}))
	at_result(mut log, 'exit code: 0\n--- stdout ---\n41 passed')
	a := attest('I ran the suite and the tests pass.', mut log)
	assert verdicts_for(&a, 'tests_pass') == [claim_supported], a.report()
	assert a.clean()
}

fn test_a_passing_claim_over_a_failing_run_is_contradicted() {
	mut log := new_event_log(tmp_log_path('at2'), 'main', 'test')
	at_call(mut log, 'run_command', at_args({
		'command': 'pytest -q'
	}))
	at_result(mut log, 'exit code: 1\n--- stdout ---\n2 failed, 39 passed')
	a := attest('The tests pass now.', mut log)
	assert claim_contradicted in verdicts_for(&a, 'tests_pass')
	assert !a.clean()
	assert a.report().contains('✗')
}

fn test_a_passing_claim_with_no_run_at_all_is_unsupported() {
	mut log := new_event_log(tmp_log_path('at3'), 'main', 'test')
	a := attest('All the tests pass.', mut log)
	assert verdicts_for(&a, 'tests_pass') == [claim_unsupported]
	assert a.claims[0].evidence.contains('no test command')
	// unsupported is not the same failure as contradicted
	assert a.contradicted().len == 0
	assert a.unsupported().len == 1
}

fn test_a_wrong_count_is_contradicted_even_when_the_run_passed() {
	mut log := new_event_log(tmp_log_path('at4'), 'main', 'test')
	at_call(mut log, 'run_command', at_args({
		'command': 'pytest -q'
	}))
	at_result(mut log, 'exit code: 0\n12 passed')
	wrong := attest('All 40 tests pass.', mut log)
	assert claim_contradicted in verdicts_for(&wrong, 'tests_pass')
	assert wrong.claims[0].evidence.contains('12 passing, not 40')

	right := attest('All 12 tests pass.', mut log)
	assert verdicts_for(&right, 'tests_pass') == [claim_supported]
}

fn test_a_failure_claim_over_a_passing_run_is_contradicted_too() {
	mut log := new_event_log(tmp_log_path('at5'), 'main', 'test')
	at_call(mut log, 'run_command', at_args({
		'command': 'pytest -q'
	}))
	at_result(mut log, 'exit code: 0\n41 passed')
	a := attest('The tests failed.', mut log)
	assert a.contradicted().len > 0
	assert a.claims.any(it.evidence == 'the recorded run passed')
}

fn test_a_run_with_no_recorded_outcome_is_unsupported() {
	mut log := new_event_log(tmp_log_path('at6'), 'main', 'test')
	at_call(mut log, 'run_command', at_args({
		'command': 'pytest -q'
	}))
	at_result(mut log, 'something happened')
	a := attest('The tests pass.', mut log)
	assert verdicts_for(&a, 'tests_pass') == [claim_unsupported]
	assert a.claims[0].evidence.contains('records no outcome')
}

fn test_a_backticked_command_claim_is_checked_against_the_log() {
	mut log := new_event_log(tmp_log_path('at7'), 'main', 'test')
	at_call(mut log, 'run_command', at_args({
		'command': 'ruff check src/'
	}))
	at_result(mut log, 'exit code: 0')
	good := attest('I ran `ruff check src/` and it was clean.', mut log)
	assert verdicts_for(&good, 'ran_command') == [claim_supported]

	bad := attest('I ran `mypy src/` afterwards.', mut log)
	assert verdicts_for(&bad, 'ran_command') == [claim_contradicted]
	assert bad.claims[0].evidence.contains('no such command')
}

fn test_ordinary_english_is_not_read_as_a_command_claim() {
	mut log := new_event_log(tmp_log_path('at8'), 'main', 'test')
	at_call(mut log, 'run_command', at_args({
		'command': 'pytest -q'
	}))
	at_result(mut log, 'exit code: 0\n1 passed')
	// "I ran the tests" must not become a claim about a program named 'the'
	a := attest('I ran the tests and they pass.', mut log)
	assert verdicts_for(&a, 'ran_command').len == 0, a.report()
	assert verdicts_for(&a, 'tests_pass') == [claim_supported]
}

fn test_a_file_claim_is_checked_against_the_effects() {
	mut log := new_event_log(tmp_log_path('at9'), 'main', 'test')
	at_call(mut log, 'write_file', at_args({
		'path':    '/home/u/proj/src/a.py'
		'content': 'x = 1'
	}))
	at_result(mut log, 'OK')

	// the tail matches without pretending to resolve either path
	good := attest('I created src/a.py with the parser.', mut log)
	assert verdicts_for(&good, 'file_written') == [claim_supported]

	never := attest('I updated src/b.py too.', mut log)
	assert verdicts_for(&never, 'file_written') == [claim_contradicted]
	assert never.claims[0].evidence.contains('no write or delete')

	// claiming a delete where a write is recorded names the opposite
	opposite := attest('I deleted src/a.py.', mut log)
	assert verdicts_for(&opposite, 'file_deleted') == [claim_contradicted]
	assert opposite.claims[0].evidence.contains('opposite effect')
}

fn test_a_shell_write_counts_as_a_write() {
	mut log := new_event_log(tmp_log_path('at10'), 'main', 'test')
	at_call(mut log, 'run_command', at_args({
		'command': 'echo x > src/gen.py'
	}))
	at_result(mut log, 'exit code: 0')
	a := attest('I created src/gen.py.', mut log)
	assert verdicts_for(&a, 'file_written') == [claim_supported]
}

fn test_a_reply_with_no_checkable_claim_says_so() {
	mut log := new_event_log(tmp_log_path('at11'), 'main', 'test')
	a := attest('Here is what I think about the architecture.', mut log)
	assert a.claims.len == 0
	assert a.clean()
	assert a.report() == 'attest: the reply made no checkable claim'
}

fn test_the_verdict_is_always_sealed_including_a_clean_one() {
	mut log := new_event_log(tmp_log_path('at12'), 'main', 'test')
	clean := attest('Nothing checkable here.', mut log)
	seal_attestation(mut log, &clean)
	events := log.events('main').filter(it.typ == 'attest.verdict')
	assert events.len == 1
	assert jint(events[0].data, 'contradicted') == 0
	assert jint(events[0].data, 'unsupported') == 0
}
