module vagent

import x.json2

fn test_an_empty_chain_says_so_rather_than_looking_clean() {
	w := new_witness(new_event_log(tmp_log_path('wit1'), 'main', 'test'))
	assert w.verify([], false).describe().contains('has not run')
	assert w.head() == witness_genesis
	// an empty chain is intact by definition: there is nothing to have edited
	assert w.verify([], false).ok()
	assert w.verify([], false).length == 0
}

fn test_decisions_chain_together() {
	mut w := new_witness(new_event_log(tmp_log_path('wit2'), 'main', 'test'))
	w.allow('read_file')
	w.refuse('write_file', ['1'])
	w.allow('run_command')
	w.refuse('delete_path', ['3', '5'])

	a := w.verify([], false)
	assert a.ok()
	assert a.length == 4
	assert a.allowed == 2
	assert a.refused == 2
	assert a.describe().contains('chain intact')

	// each link commits to the one before it
	assert w.chain[0].prev == witness_genesis
	for i in 1 .. w.chain.len {
		assert w.chain[i].prev == w.chain[i - 1].digest
	}

	// the head changes with every decision
	before := w.head()
	w.allow('read_file')
	assert w.head() != before
}

fn test_a_call_nobody_judged_is_a_gap() {
	mut w := new_witness(new_event_log(tmp_log_path('wit3'), 'main', 'test'))
	w.allow('read_file')
	w.refuse('write_file', ['1'])
	w.allow('run_command')
	w.refuse('delete_path', ['3'])

	gated := ['read_file', 'write_file', 'run_command', 'delete_path', 'apply_patch']
	a := w.verify(gated, true)
	assert !a.ok()
	assert a.gaps == ['apply_patch'], '${a.gaps}'
	assert a.describe().contains('no decision witnessed for: apply_patch')
	// with the full set accounted for it is clean again
	assert w.verify(gated[..gated.len - 1], true).ok()
}

fn test_a_flipped_verdict_breaks_the_chain() {
	mut w := new_witness(new_event_log(tmp_log_path('wit4'), 'main', 'test'))
	w.allow('read_file')
	w.refuse('write_file', ['1'])
	w.allow('run_command')

	exported := w.export()
	assert witness_check(exported).ok()

	mut tampered := exported.clone()
	// hide the refusal
	tampered[1]['verdict'] = json2.Any(verdict_allowed)
	broken := witness_check(tampered)
	assert !broken.intact
	assert broken.broken_at == 1, '${broken.broken_at}'
}

fn test_a_deleted_decision_breaks_it_even_after_renumbering() {
	mut w := new_witness(new_event_log(tmp_log_path('wit5'), 'main', 'test'))
	w.allow('a')
	w.refuse('b', ['1'])
	w.allow('c')
	w.allow('d')
	exported := w.export()

	mut dropped := exported.clone()
	dropped.delete(2)
	for i, _ in dropped {
		dropped[i]['index'] = json2.Any(i)
	}
	assert !witness_check(dropped).intact
}

fn test_an_appended_but_unlinked_record_is_caught() {
	mut w := new_witness(new_event_log(tmp_log_path('wit6'), 'main', 'test'))
	w.allow('a')
	w.refuse('b', ['1'])
	mut forged := w.export()
	forged << {
		'index':   json2.Any(forged.len)
		'prev':    json2.Any(witness_genesis)
		'tool':    json2.Any('write_file')
		'verdict': json2.Any(verdict_allowed)
		'clauses': json2.Any([]json2.Any{})
		'ts':      json2.Any(0.0)
		'digest':  json2.Any('0'.repeat(64))
	}
	assert !witness_check(forged).intact
}

fn test_verification_needs_nothing_from_this_process() {
	mut w := new_witness(new_event_log(tmp_log_path('wit7'), 'main', 'test'))
	w.allow('read_file')
	w.refuse('write_file', ['1'])
	// round-trip the export through plain JSON, as an outside checker would
	text := json2.encode(json2.Any(w.export().map(json2.Any(it))))
	parsed := json2.decode[json2.Any](text) or { panic(err) }
	mut rows := []map[string]json2.Any{}
	for row in parsed.as_array() {
		rows << row.as_map()
	}
	assert witness_check(rows).ok()
	assert witness_check(rows).length == 2
}

fn test_the_chain_survives_a_restart() {
	path := tmp_log_path('wit8')
	mut w := new_witness(new_event_log(path, 'main', 'test'))
	w.allow('read_file')
	w.refuse('write_file', ['1'])
	w.allow('run_command')

	mut reopened := new_witness(new_event_log(path, 'main', 'test'))
	assert reopened.rebuild() == w.chain.len
	assert reopened.verify([], false).ok()
	assert reopened.head() == w.head(), 'the head did not survive a reload'
}

fn test_an_unknown_verdict_is_a_problem_not_a_silent_pass() {
	mut w := new_witness(new_event_log(tmp_log_path('wit9'), 'main', 'test'))
	w.record('write_file', 'maybe', [])
	a := w.verify([], false)
	assert !a.ok()
	assert a.problems.len == 1
	assert a.problems[0].contains('unknown verdict')
}

fn test_the_report_carries_the_anchorable_head() {
	mut w := new_witness(new_event_log(tmp_log_path('wit10'), 'main', 'test'))
	w.allow('read_file')
	text := w.report([], false)
	assert text.contains('head: ')
	assert text.contains(w.head()[..16])
}
