module vagent

import os
import x.json2

fn goal_fixture(name string) (string, &EventLog, GoalContract) {
	dir := os.join_path(os.temp_dir(), 'vagent-goal-${os.getpid()}', name)
	os.rmdir_all(dir) or {}
	os.mkdir_all(dir) or { panic(err) }
	mut log := new_event_log(tmp_log_path('${name}.jsonl'), 'main', '')
	mut j := &Judge{
		log: log
	}
	return dir, log, new_goal_contract(log, j)
}

fn proof(typ string, path string) Rec {
	return Rec({
		'type': json2.Any(typ)
		'path': json2.Any(path)
	})
}

fn test_validation_rejects_unprovable_contracts() {
	_, mut log, mut gc := goal_fixture('validate')
	defer {
		log.close()
	}
	// §37.2: a clause with no machine-checkable predicate
	if _ := gc.set_goal('bad', [Rec({
		'id':   json2.Any('C1')
		'text': json2.Any('vague clause')
	})], SetGoalOpts{}) {
		assert false, 'a clause without a proof was accepted'
	} else {
		assert err.msg().contains('C1'), err.msg()
	}

	// model_judgement can never be the only evidence
	if _ := gc.set_goal('bad', [Rec({
		'id':    json2.Any('C1')
		'text':  json2.Any('x')
		'proof': json2.Any({
			'type': json2.Any('model_judgement')
		})
	})], SetGoalOpts{}) {
		assert false, 'a model_judgement-only clause was accepted'
	}

	// an unknown clause kind
	if _ := gc.set_goal('bad', [Rec({
		'id':    json2.Any('C1')
		'text':  json2.Any('x')
		'kind':  json2.Any('NOPE')
		'proof': json2.Any(proof('file_exists', '/tmp'))
	})], SetGoalOpts{}) {
		assert false, 'an unknown clause kind was accepted'
	}

	// duplicate ids would make one twin unprovable
	if _ := gc.set_goal('bad', [
		Rec({
			'id':    json2.Any('C1')
			'text':  json2.Any('a')
			'proof': json2.Any(proof('file_exists', '/tmp'))
		}),
		Rec({
			'id':    json2.Any('c1')
			'text':  json2.Any('b')
			'proof': json2.Any(proof('file_exists', '/tmp'))
		}),
	], SetGoalOpts{}) {
		assert false, 'duplicate clause ids were accepted'
	}

	// an empty contract
	if _ := gc.set_goal('bad', []Rec{}, SetGoalOpts{}) {
		assert false, 'an empty contract was accepted'
	}
}

fn test_advisory_clauses_need_no_proof() {
	dir, mut log, mut gc := goal_fixture('advisory')
	defer {
		log.close()
	}
	sample := os.join_path(dir, 'src.py')
	os.write_file(sample, 'x = 1\n') or { panic(err) }
	gc.set_goal('mixed', [
		Rec({
			'id':    json2.Any('C1')
			'text':  json2.Any('file exists')
			'proof': json2.Any(proof('file_exists', sample))
		}),
		Rec({
			'id':       json2.Any('C2')
			'text':     json2.Any('code reads nicely')
			'advisory': json2.Any(true)
		}),
	], SetGoalOpts{}) or { panic(err) }
	st := gc.status()
	assert st.active && st.clauses.len == 2
	assert st.clauses[1].advisory
}

fn test_full_contract_lifecycle() {
	dir, mut log, mut gc := goal_fixture('lifecycle')
	defer {
		log.close()
	}
	sample := os.join_path(dir, 'src.py')
	os.write_file(sample, 'def verify_token(leeway=0):\n    return True\n') or { panic(err) }

	contract := gc.set_goal('make verify_token configurable', [
		Rec({
			'id':     json2.Any('C1')
			'text':   json2.Any('src.py exists')
			'kind':   json2.Any('ARTIFACT')
			'weight': json2.Any(0.5)
			'proof':  json2.Any(proof('file_exists', sample))
		}),
		Rec({
			'id':     json2.Any('C2')
			'text':   json2.Any('leeway parameter exists')
			'kind':   json2.Any('OUTCOME')
			'weight': json2.Any(0.5)
			'proof':  json2.Any({
				'type':          json2.Any('ast_assert')
				'path':          json2.Any(sample)
				'symbol':        json2.Any('verify_token')
				'has_parameter': json2.Any('leeway')
			})
		}),
	], SetGoalOpts{
		anti:       [Rec({
			'id':    json2.Any('A1')
			'text':  json2.Any('src.py must not be deleted')
			'check': json2.Any(proof('file_exists', sample))
		})]
		invariants: [Rec({
			'id':    json2.Any('I1')
			'text':  json2.Any('src.py stays readable')
			'check': json2.Any(proof('file_exists', sample))
		})]
	}) or { panic(err) }

	assert jstr(contract, 'id') != ''
	// weights auto-normalised to 1.0
	mut total := 0.0
	for c in jarr(contract, 'clauses') {
		total += jf64(c as map[string]json2.Any, 'weight')
	}
	assert math_abs(total - 1.0) < 1e-9, '${total}'

	mut st := gc.status()
	assert st.active && st.clauses.len == 2
	assert math_abs(st.distance - 1.0) < 1e-9 // nothing proven yet

	// proving via each clause's OWN predicate
	ok1, d1 := gc.prove_by_predicate('C1')
	assert ok1, d1
	ok2, d2 := gc.prove_by_predicate('C2')
	assert ok2, d2

	st = gc.status()
	assert st.complete
	// §39.1: distance = 1 - (0.5*0.70 + 0.5*0.85) = 0.225 exactly
	assert math_abs(st.distance - 0.225) < 1e-9, '${st.distance}'
	c1 := st.clause('C1') or { panic('C1 vanished') }
	assert c1.state == 'PROVEN'
	assert math_abs(c1.confidence - 0.70) < 1e-9

	// closure: C1's file_exists proof is only 0.70 confident, so ACHIEVED
	// is withheld — existence is not correctness
	result := gc.close(true)
	assert result.state == st_partial, result.state
	mut weak := false
	for r in result.reasons {
		if r.contains('weak proof') {
			weak = true
		}
	}
	assert weak, '${result.reasons}'
	assert result.bundle.contains('contract')

	// a human waiver of the weak clause upgrades closure to ACHIEVED
	assert gc.waive('C1', 'human verified the file by eye')
	result2 := gc.close(false)
	assert result2.state == st_achieved, result2.state
}

fn test_anti_clause_violation_is_detected() {
	dir, mut log, mut gc := goal_fixture('anti')
	defer {
		log.close()
	}
	f := os.join_path(dir, 'keep.txt')
	os.write_file(f, 'keep me') or { panic(err) }
	gc.set_goal('work near keep.txt', [Rec({
		'id':     json2.Any('C1')
		'text':   json2.Any('work done')
		'weight': json2.Any(1.0)
		'proof':  json2.Any(proof('file_exists', f))
	})], SetGoalOpts{
		anti: [Rec({
			'id':    json2.Any('A1')
			'text':  json2.Any('keep.txt must survive')
			'check': json2.Any(proof('file_exists', f))
		})]
	}) or { panic(err) }

	gc.prove_by_predicate('C1')
	assert gc.check_anti_clauses().len == 0

	os.rm(f) or { panic(err) } // the forbidden thing happens
	violations := gc.check_anti_clauses()
	assert violations.len == 1
	assert jstr(violations[0], 'clause') == 'A1'

	// an anti-clause regression must NOT reopen the ordinary clause
	st := gc.status()
	c1 := st.clause('C1') or { panic('C1 vanished') }
	assert c1.state == 'PROVEN', c1.state
}

fn test_regression_reopens_a_proven_clause() {
	dir, mut log, mut gc := goal_fixture('regress')
	defer {
		log.close()
	}
	f := os.join_path(dir, 'x.txt')
	os.write_file(f, 'here') or { panic(err) }
	gc.set_goal('one', [Rec({
		'id':     json2.Any('C1')
		'text':   json2.Any('x exists')
		'weight': json2.Any(1.0)
		'proof':  json2.Any(proof('file_exists', f))
	})], SetGoalOpts{}) or { panic(err) }

	gc.prove_by_predicate('C1')
	assert gc.status().clause('C1') or { panic('') }.state == 'PROVEN'

	os.rm(f) or { panic(err) }
	// re-running the predicate now fails, which reopens the clause
	passed, _ := gc.prove_by_predicate('C1')
	assert !passed
	assert gc.status().clause('C1') or { panic('') }.state == 'REGRESSED'
	assert math_abs(gc.status().distance - 1.0) < 1e-9
}

fn test_gravity_focuses_the_heaviest_open_clause() {
	dir, mut log, mut gc := goal_fixture('gravity')
	defer {
		log.close()
	}
	sample := os.join_path(dir, 's.py')
	os.write_file(sample, 'x = 1\n') or { panic(err) }
	gc.set_goal('two clauses', [
		Rec({
			'id':     json2.Any('C1')
			'text':   json2.Any('small')
			'weight': json2.Any(0.2)
			'proof':  json2.Any(proof('file_exists', sample))
		}),
		Rec({
			'id':     json2.Any('C2')
			'text':   json2.Any('big')
			'weight': json2.Any(0.8)
			'proof':  json2.Any(proof('file_exists', sample))
		}),
	], SetGoalOpts{}) or { panic(err) }

	focus := gc.reaim('gravity') or { panic('no focus chosen') }
	assert focus == 'C2', focus // higher weight wins
	st := gc.status()
	assert st.focus == 'C2'
	assert st.focus_history == ['C2']

	// a proven clause exerts no pull
	gc.prove_by_predicate('C2')
	assert gc.gravity()['C2'] == 0.0
	next := gc.reaim('gravity') or { panic('no focus chosen') }
	assert next == 'C1'
}

fn test_amendments_are_proposed_not_applied() {
	_, mut log, mut gc := goal_fixture('amend')
	defer {
		log.close()
	}
	id := gc.propose_amendment('EXTEND_BUDGET', 'task is larger than expected',
		'+\$1') or { panic(err) }
	assert id.len == 10
	assert gc.resolve_amendment(id, 'rejected')

	mut found := false
	for a in fold(mut log, '').amendments {
		if jstr(a, 'verdict') == 'rejected' {
			found = true
		}
	}
	assert found

	// an unknown amendment kind is refused
	if _ := gc.propose_amendment('NOPE', 'why', '') {
		assert false, 'an unknown amendment kind was accepted'
	}
	// an unknown verdict resolves nothing
	assert !gc.resolve_amendment(id, 'maybe')
}

fn test_measure_seals_distance_and_velocity() {
	dir, mut log, mut gc := goal_fixture('measure')
	defer {
		log.close()
	}
	f := os.join_path(dir, 'm.txt')
	os.write_file(f, 'x') or { panic(err) }
	gc.set_goal('measured', [Rec({
		'id':     json2.Any('C1')
		'text':   json2.Any('m exists')
		'weight': json2.Any(1.0)
		'proof':  json2.Any(proof('file_exists', f))
	})], SetGoalOpts{}) or { panic(err) }

	first := gc.measure()
	assert 'distance' in first && 'velocity' in first
	assert jf64(first, 'distance') == 1.0

	gc.prove_by_predicate('C1')
	second := gc.measure()
	// distance fell, so velocity is positive
	assert jf64(second, 'distance') < 1.0
	assert jf64(second, 'velocity') > 0.0
}

fn test_a_closed_contract_stops_demanding_attribution() {
	dir, mut log, mut gc := goal_fixture('closed')
	defer {
		log.close()
	}
	f := os.join_path(dir, 'done.txt')
	os.write_file(f, 'done') or { panic(err) }
	gc.set_goal('single clause', [Rec({
		'id':     json2.Any('C1')
		'text':   json2.Any('done.txt exists')
		'weight': json2.Any(1.0)
		'proof':  json2.Any(proof('file_exists', f))
	})], SetGoalOpts{}) or { panic(err) }

	ok, detail := gc.prove_by_predicate('C1')
	assert ok, detail
	mut st := gc.status()
	assert st.complete
	assert st.closed_state == '' // open until sealed

	result := gc.close(true)
	st = gc.status()
	assert st.closed_state == result.state
	assert st.closed_state in terminal_states
	assert fold(mut log, '').goal_closed != none

	// a fresh contract reopens the world: the stale close must not leak
	gc.set_goal('next job', [Rec({
		'id':     json2.Any('C1')
		'text':   json2.Any('done.txt exists')
		'weight': json2.Any(1.0)
		'proof':  json2.Any(proof('file_exists', f))
	})], SetGoalOpts{}) or { panic(err) }
	st = gc.status()
	assert st.closed_state == '', st.closed_state
	assert fold(mut log, '').goal_closed == none
}

fn test_proofs_do_not_leak_across_contracts() {
	dir, mut log, mut gc := goal_fixture('scope')
	defer {
		log.close()
	}
	f := os.join_path(dir, 'a.txt')
	os.write_file(f, 'a') or { panic(err) }
	clause := [Rec({
		'id':     json2.Any('C1')
		'text':   json2.Any('a exists')
		'weight': json2.Any(1.0)
		'proof':  json2.Any(proof('file_exists', f))
	})]
	gc.set_goal('first', clause, SetGoalOpts{}) or { panic(err) }
	gc.prove_by_predicate('C1')
	assert gc.status().clause('C1') or { panic('') }.state == 'PROVEN'

	// the SAME clause id under a new contract starts unproven
	gc.set_goal('second', clause, SetGoalOpts{}) or { panic(err) }
	assert gc.status().clause('C1') or { panic('') }.state == 'OPEN'
	assert math_abs(gc.status().distance - 1.0) < 1e-9
}

fn test_clear_deactivates_the_goal() {
	dir, mut log, mut gc := goal_fixture('clear')
	defer {
		log.close()
	}
	f := os.join_path(dir, 'c.txt')
	os.write_file(f, 'c') or { panic(err) }
	gc.set_goal('temp', [Rec({
		'id':     json2.Any('C1')
		'text':   json2.Any('c exists')
		'weight': json2.Any(1.0)
		'proof':  json2.Any(proof('file_exists', f))
	})], SetGoalOpts{}) or { panic(err) }
	assert gc.status().active
	assert gc.format().starts_with('GOAL "temp"')

	gc.clear()
	assert !gc.status().active
	assert gc.format() == 'GOAL: none'
	assert gc.evidence_bundle() == 'no active contract'

	closed := gc.close(false)
	assert closed.state == st_abandoned
}

fn test_format_renders_the_compass() {
	dir, mut log, mut gc := goal_fixture('format')
	defer {
		log.close()
	}
	f := os.join_path(dir, 'f.txt')
	os.write_file(f, 'f') or { panic(err) }
	gc.set_goal('ship it', [Rec({
		'id':     json2.Any('C1')
		'text':   json2.Any('f exists')
		'weight': json2.Any(1.0)
		'proof':  json2.Any(proof('file_exists', f))
	})], SetGoalOpts{}) or { panic(err) }

	empty := gc.format()
	assert empty.contains('distance 1.00')
	assert empty.contains('░'), empty
	assert empty.contains('0% proven')

	gc.prove_by_predicate('C1')
	filled := gc.format()
	assert filled.contains('█'), filled
	assert filled.contains('PROVEN')

	bundle := gc.evidence_bundle()
	assert bundle.contains('GOAL ')
	assert bundle.contains('C1')
	assert bundle.contains('conf 0.70')
}
