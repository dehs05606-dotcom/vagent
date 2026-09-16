module vagent

__global (
	adherence_calls int
)

const adherence_spec = '[SQL] Queries go through the repository layer
Never write SQL inline in a handler.
@output forbid (?i)execute\\(\\s*["\\\']SELECT

[OUT] Test results are reported with the exit code
@output forbid (?i)tests? pass(?![^.]*exit)

[PROSE] Prefer composition over inheritance
This clause carries no machine-checkable rule at all.
'

fn ask_obedient(request string) !string {
	return 'pytest -q: exit 0. Used the repository.'
}

fn ask_half(request string) !string {
	if request.contains('exit code') {
		// breaks [OUT]
		return 'The tests pass.'
	}
	// obeys [SQL]
	return 'Used the repository layer.'
}

fn ask_flaky(request string) !string {
	adherence_calls++
	if adherence_calls == 1 {
		return error('provider timeout')
	}
	return 'pytest -q: exit 0. Used the repository.'
}

fn new_adherence_for(name string) &Adherence {
	return new_adherence(new_event_log(tmp_log_path(name), 'main', 'test'), adherence_spec)
}

fn test_a_model_that_always_obeys_scores_a_hundred_percent() {
	mut a := new_adherence_for('adh1')
	rep := a.run(ask_obedient, [], default_probes)
	assert rep.overall() or { 0.0 } == 1.0, rep.describe()
	assert rep.measured().len == 2
}

fn test_a_broken_clause_is_localised_to_that_clause() {
	mut a := new_adherence_for('adh2')
	rep := a.run(ask_half, [], default_probes)
	mut by_id := map[string]ClauseScore{}
	for s in rep.measured() {
		by_id[s.clause] = s
	}
	assert by_id['SQL'].rate() or { -1.0 } == 1.0
	assert by_id['OUT'].rate() or { -1.0 } == 0.0
	overall := rep.overall() or { -1.0 }
	assert overall > 0.0 && overall < 1.0
	assert rep.weakest(1)[0].clause == 'OUT'
	assert rep.describe().contains('<- weakest')
}

fn test_a_clause_with_no_checkable_rule_is_not_counted_as_passing() {
	mut a := new_adherence_for('adh3')
	rep := a.run(ask_half, [], default_probes)
	assert 'PROSE' in rep.unscorable
	assert !rep.measured().any(it.clause == 'PROSE')
	assert rep.describe().contains('NOT counted as passing')
}

fn test_probes_come_from_the_authors_text_not_from_here() {
	mut a := new_adherence_for('adh4')
	mut sql_clause := Clause{}
	for c in a.covenant.clauses {
		if c.id == 'SQL' {
			sql_clause = c
		}
	}
	ps := probes_for(&sql_clause, default_probes)
	assert ps.len == default_probes
	for p in ps {
		assert p.request.contains('repository layer'), p.request
		// the @output line is never part of the probe text
		assert !p.request.contains('@output')
	}

	// a clause whose only text is a directive produces no probe at all
	bare := Clause{
		id:    'X'
		title: ''
		body:  '@output forbid x\n'
	}
	assert probes_for(&bare, 3).len == 0
}

fn test_the_measurement_is_deterministic() {
	mut a := new_adherence_for('adh5')
	r1 := a.run(ask_half, [], default_probes)
	r2 := a.run(ask_half, [], default_probes)
	assert r1.measured().map(it.to_json().str()) == r2.measured().map(it.to_json().str())
}

fn test_one_failing_probe_does_not_take_down_the_run() {
	adherence_calls = 0
	mut a := new_adherence_for('adh6')
	rep := a.run(ask_flaky, [], default_probes)
	assert rep.errors == 1
	assert rep.measured().len > 0
	assert rep.describe().contains('probe error')
	// an errored probe is not scorable either way
	mut errored := []Probe{}
	for sc in rep.scores {
		for p in sc.probes {
			if p.verdict == verdict_errored {
				errored << p
			}
		}
	}
	assert errored.len == 1
	assert errored[0].detail.contains('provider timeout')
}

fn test_a_single_clause_can_be_measured_on_its_own() {
	mut a := new_adherence_for('adh7')
	one := a.run(ask_half, ['OUT'], default_probes)
	assert one.measured().map(it.clause) == ['OUT']
}

fn test_an_empty_specification_measures_nothing_and_says_so() {
	mut a := new_adherence(new_event_log(tmp_log_path('adh8'), 'main', 'test'), '')
	rep := a.run(ask_obedient, [], default_probes)
	assert rep.overall() == none
	assert rep.describe().contains('nothing to measure')
}

fn test_every_run_is_sealed() {
	mut log := new_event_log(tmp_log_path('adh9'), 'main', 'test')
	mut a := new_adherence(log, adherence_spec)
	a.run(ask_half, [], default_probes)
	kinds := log.events('main').map(it.typ)
	assert 'adherence.clause' in kinds
	assert 'adherence.run' in kinds
}
