module vagent

import x.json2

__global (
	evolution_eval_calls []string
)

fn variant_mutator(role string, incumbent string, k int) []string {
	mut out := []string{}
	for i in 0 .. k {
		out << '${incumbent} [evolved variant ${i}]'
	}
	return out
}

fn magic_word_evaluator(role string, brief string) !(string, f64) {
	evolution_eval_calls << brief
	score := if brief.contains('[evolved variant') { 0.95 } else { 0.60 }
	return 'STATUS: DONE\nSUMMARY: ran with ' + clip_plain(brief, 30), score
}

fn weak_mutator(role string, incumbent string, k int) []string {
	mut out := []string{}
	for _ in 0 .. k {
		out << 'slightly different but not better'
	}
	return out
}

fn flat_evaluator(role string, brief string) !(string, f64) {
	// beats the 0.60 incumbent, but not by the 0.10 margin
	return 'STATUS: DONE', 0.62
}

fn exploding_evaluator(role string, brief string) !(string, f64) {
	if brief.contains('[evolved variant') {
		return error('the candidate crashed the worker')
	}
	return 'STATUS: DONE', 0.60
}

fn seed_crew_history(mut log EventLog) {
	// coder failed three of its four recent runs, tester passed all four
	for i in 0 .. 4 {
		log.append('crew.done', {
			'role':  json2.Any('coder')
			'state': json2.Any(if i < 3 { 'error' } else { 'done' })
			'task':  json2.Any('t${i}')
		}, AppendOpts{})
	}
	for i in 0 .. 4 {
		log.append('crew.done', {
			'role':  json2.Any('tester')
			'state': json2.Any('done')
			'task':  json2.Any('t${i}')
		}, AppendOpts{})
	}
}

fn restore_brief(role string) {
	mut reg := role_registry
	reg.set_brief(role, role_briefs[role] or { '' })
}

fn test_fitness_ranks_the_roles_by_their_recent_record() {
	mut log := new_event_log(tmp_log_path('evo1'), 'main', 'test')
	seed_crew_history(mut log)
	mut e := new_evolution_engine(log, variant_mutator, magic_word_evaluator)

	fit := e.fitness()
	assert fit['coder'] < fit['tester'], fit.str()
	assert fit['tester'] == 1.0
	assert e.weakest_role() or { '' } == 'coder'
}

fn test_a_non_evolvable_role_cannot_push_history_out_of_the_window() {
	mut log := new_event_log(tmp_log_path('evo2'), 'main', 'test')
	seed_crew_history(mut log)
	// the sovereign roles are chatty; filtering them out AFTER the window
	// was cut would have hidden the coder's failures behind this noise
	for i in 0 .. 200 {
		log.append('crew.done', {
			'role':  json2.Any('main')
			'state': json2.Any('done')
			'task':  json2.Any('noise${i}')
		}, AppendOpts{})
	}
	mut e := new_evolution_engine(log, variant_mutator, magic_word_evaluator)
	fit := e.fitness()
	assert 'main' !in fit
	assert fit['coder'] < fit['tester'], fit.str()
	assert e.weakest_role() or { '' } == 'coder'
}

fn test_a_better_candidate_deploys_and_the_old_text_survives() {
	restore_brief('coder')
	evolution_eval_calls = []string{}
	mut log := new_event_log(tmp_log_path('evo3'), 'main', 'test')
	seed_crew_history(mut log)
	mut e := new_evolution_engine(log, variant_mutator, magic_word_evaluator)

	mut reg := role_registry
	original := reg.brief('coder') or { '' }
	gen := e.evolve('')
	assert gen.role == 'coder', gen.to_json().str()
	assert gen.deployed, gen.reason
	assert gen.champion_score == 0.95
	assert gen.incumbent_score == 0.60
	// the incumbent is measured once and every candidate once
	assert evolution_eval_calls.len == 4, evolution_eval_calls.len.str()

	live := reg.brief('coder') or { '' }
	assert live != original
	assert live.contains('evolved variant')

	types := log.events('main').map(it.typ)
	assert 'evolution.deployed' in types
	assert 'evolution.generation' in types

	// the deployed event carries the old text, so rollback is one command
	msg := e.rollback('coder')
	assert msg.contains('rolled back')
	assert (reg.brief('coder') or { '' }) == original
	assert e.rollback('tester').starts_with('no deployed')
	restore_brief('coder')
}

fn test_a_candidate_that_misses_the_margin_never_deploys() {
	restore_brief('coder')
	mut log := new_event_log(tmp_log_path('evo4'), 'main', 'test')
	seed_crew_history(mut log)
	mut reg := role_registry
	original := reg.brief('coder') or { '' }

	mut e := new_evolution_engine(log, weak_mutator, flat_evaluator)
	gen := e.evolve('coder')
	assert !gen.deployed
	assert gen.reason.contains('margin'), gen.reason
	// a tie or a near miss keeps the incumbent: drift without evidence is
	// not improvement
	assert (reg.brief('coder') or { '' }) == original
	assert 'evolution.deployed' !in log.events('main').map(it.typ)
}

fn test_a_candidate_that_crashes_the_worker_is_skipped_not_fatal() {
	restore_brief('coder')
	mut log := new_event_log(tmp_log_path('evo5'), 'main', 'test')
	seed_crew_history(mut log)
	mut e := new_evolution_engine(log, variant_mutator, exploding_evaluator)
	gen := e.evolve('coder')
	// every candidate failed, so nothing beat the incumbent — and the
	// generation still completed and sealed its reason
	assert !gen.deployed
	assert gen.reason.contains('incumbent kept'), gen.reason
	assert 'evolution.generation' in log.events('main').map(it.typ)
}

fn test_the_generation_cap_stops_runaway_evolution() {
	mut log := new_event_log(tmp_log_path('evo6'), 'main', 'test')
	seed_crew_history(mut log)
	mut e := new_evolution_engine(log, variant_mutator, magic_word_evaluator)
	e.generations = max_generations_per_session
	gen := e.evolve('')
	assert !gen.deployed
	assert gen.reason.contains('cap'), gen.reason
	// a capped generation seals nothing: it never ran
	assert log.events('main').filter(it.typ.starts_with('evolution.')).len == 0
}

fn test_no_history_means_no_evolution_target() {
	mut log := new_event_log(tmp_log_path('evo7'), 'main', 'test')
	mut e := new_evolution_engine(log, variant_mutator, magic_word_evaluator)
	if _ := e.weakest_role() {
		assert false, 'an empty log has no weakest role'
	}
	gen := e.evolve('')
	assert gen.reason.contains('no role history'), gen.reason
	assert !gen.deployed
}

fn test_only_worker_briefs_are_evolvable() {
	mut log := new_event_log(tmp_log_path('evo8'), 'main', 'test')
	seed_crew_history(mut log)
	mut e := new_evolution_engine(log, variant_mutator, magic_word_evaluator)
	// the sovereign prompts are never a target, even when named directly
	gen := e.evolve('main')
	assert !gen.deployed
	assert gen.reason.contains('no role history'), gen.reason
	for role in evolvable_roles() {
		assert is_evolvable(role)
	}
	assert !is_evolvable('main')
	assert !is_evolvable('master')
}

fn test_the_lineage_is_sealed_and_foldable() {
	restore_brief('coder')
	evolution_eval_calls = []string{}
	mut log := new_event_log(tmp_log_path('evo9'), 'main', 'test')
	seed_crew_history(mut log)
	mut e := new_evolution_engine(log, variant_mutator, magic_word_evaluator)
	gen := e.evolve('')
	assert gen.deployed

	st := fold(mut log, 'main')
	assert st.advanced_events.filter(jstr(it, 'type') == 'evolution.deployed').len == 1

	hist := e.history()
	assert hist.len == 2
	text := e.format(&gen)
	assert text.contains('GENERATION 1')
	assert text.contains('DEPLOYED ✓')
	assert text.contains('incumbent 0.60 · champion 0.95')

	e.rollback('coder')
	assert e.history().len == 3
	restore_brief('coder')
}

fn test_the_benchmark_is_the_same_yardstick_every_generation() {
	first := default_benchmark('coder')
	second := default_benchmark('coder')
	assert first == second
	assert first.contains('EVOLUTION BENCHMARK [coder]')
	assert first.contains('STATUS: DONE')
	assert default_benchmark('tester') != first
}
