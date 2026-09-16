module vagent

import time

// three lanes of different speeds: fast-but-wrong, slow-but-right, far too slow
fn race_runner(s Strategy, task string, cancel &CancelFlag) !string {
	mut c := unsafe { cancel }
	if s.id == 'direct' {
		time.sleep(60 * time.millisecond)
		return '42 is probably the answer, maybe'
	}
	if s.id == 'careful' {
		time.sleep(150 * time.millisecond)
		if c.is_set() {
			return 'CANCELLED before finishing'
		}
		return 'VERIFIED: the answer is 42 with proof'
	}
	time.sleep(900 * time.millisecond)
	if c.is_set() {
		return 'CANCELLED'
	}
	return 'late answer'
}

fn race_verifier(task string, result string) !bool {
	return result.contains('VERIFIED:')
}

fn race_never_passes(task string, result string) !bool {
	return false
}

fn race_boom(s Strategy, task string, cancel &CancelFlag) !string {
	if s.id == 'direct' {
		return error('universe exploded')
	}
	time.sleep(20 * time.millisecond)
	return 'VERIFIED: fine'
}

fn race_raising_verifier(task string, result string) !bool {
	return error('verifier blew up')
}

fn outcomes_by_id(r &RaceResult) map[string]UniverseOutcome {
	mut out := map[string]UniverseOutcome{}
	for o in r.outcomes {
		out[o.strategy] = o
	}
	return out
}

fn test_the_verified_lane_wins_and_the_rest_are_cancelled() {
	mut r := new_racing_universes(new_event_log(tmp_log_path('race1'), 'main', 'test'),
		race_runner, race_verifier, [])
	res := r.race('meaning of life', 10.0)
	by_id := outcomes_by_id(&res)

	// the fast lane ran first and lost: speed is not a verdict
	assert 'direct' in by_id
	assert !by_id['direct'].passed
	assert by_id['direct'].result.contains('42 is probably')

	assert res.winner == 'careful', res.winner
	assert res.answer.contains('42')

	// the slow lane never ran at all
	assert by_id['split'].cancelled
	assert by_id['split'].result == ''
	assert res.elapsed_ms < 800, '${res.elapsed_ms}'
}

fn test_when_nothing_passes_the_best_failure_surfaces_with_its_evidence() {
	mut r := new_racing_universes(new_event_log(tmp_log_path('race2'), 'main', 'test'),
		race_runner, race_never_passes, default_strategies[..2].clone())
	res := r.race('impossible', 5.0)
	assert res.winner == ''
	assert res.answer != ''
	// the quickest lane that actually ran is the evidence shown
	assert res.answer.contains('42 is probably')
}

fn test_a_crashing_universe_loses_without_ending_the_race() {
	mut r := new_racing_universes(new_event_log(tmp_log_path('race3'), 'main', 'test'),
		race_boom, race_verifier, [])
	res := r.race('survive', 5.0)
	assert res.winner == 'careful', res.winner
	by_id := outcomes_by_id(&res)
	assert by_id['direct'].result.contains('exploded')
	assert !by_id['direct'].passed
}

fn test_a_raising_verifier_fails_the_lane_not_the_race() {
	mut r := new_racing_universes(new_event_log(tmp_log_path('race4'), 'main', 'test'),
		race_runner, race_raising_verifier, default_strategies[..1].clone())
	res := r.race('check', 5.0)
	assert res.winner == ''
	assert res.outcomes[0].result.contains('VERIFIER ERROR')
	assert res.outcomes[0].result.contains('verifier blew up')
	assert !res.outcomes[0].passed
}

fn test_the_deadline_stops_the_race_and_cancels_what_is_left() {
	mut r := new_racing_universes(new_event_log(tmp_log_path('race5'), 'main', 'test'),
		race_runner, race_never_passes, [])
	res := r.race('too slow', 0.2)
	// the deadline fires during the second lane, so the third never starts
	by_id := outcomes_by_id(&res)
	assert by_id['split'].cancelled
	assert res.elapsed_ms < 800, '${res.elapsed_ms}'
}

fn test_an_empty_task_or_no_strategies_is_clean() {
	mut r := new_racing_universes(new_event_log(tmp_log_path('race6'), 'main', 'test'),
		race_runner, race_verifier, [])
	empty := r.race('   ', 5.0)
	assert empty.winner == ''
	assert empty.outcomes.len == 0
	assert empty.elapsed_ms == 0
}

fn test_both_outcomes_are_sealed_and_the_report_renders() {
	mut log := new_event_log(tmp_log_path('race7'), 'main', 'test')
	mut r := new_racing_universes(log, race_runner, race_verifier, [])
	won := r.race('meaning of life', 10.0)
	mut r2 := new_racing_universes(log, race_runner, race_never_passes, default_strategies[..1].clone())
	r2.race('impossible', 5.0)
	kinds := log.events('main').map(it.typ)
	assert 'race.start' in kinds
	assert 'race.winner' in kinds
	assert 'race.cancel' in kinds

	text := r.format(&won)
	assert text.contains('RACE — meaning of life')
	assert text.contains('winner: careful')
	assert text.contains('✓ [careful]')
	assert text.contains('✗ [direct]')
	assert text.contains('⊘ [split]')
	assert text.contains('ANSWER: VERIFIED')
}
