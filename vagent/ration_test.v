module vagent

const ration_spec = '§30 A turn costs at most two dollars
@ration per turn max cost_usd 2.00

§31 No single request sends more than 120k tokens
@ration per call max tokens_in 120000

§32 A session costs at most twenty-five dollars
@ration per session max cost_usd 25.00
'

fn test_the_spec_parses_into_exactly_its_budgets() {
	limits, errors := parse_ration_limits(ration_spec)
	assert limits.len == 3
	assert errors.len == 0
	assert limits[0].window == window_turn && limits[0].measure == 'cost_usd'
	assert limits[0].limit == 2.0
	assert limits[1].window == window_call && limits[1].limit == 120000.0
}

fn test_a_budget_is_refused_on_the_projection_not_after_the_fact() {
	mut r := new_ration(new_event_log(tmp_log_path('rat1'), 'main', 'test'), ration_spec)
	r.open_turn()

	// well under: allowed
	assert r.gate(Estimate{ cost_usd: 0.50 }) == ''
	r.spend(0.50, 1000, 500, 1.0)
	assert r.gate(Estimate{ cost_usd: 0.50 }) == ''
	r.spend(0.50, 1000, 500, 1.0)
	assert r.gate(Estimate{ cost_usd: 0.50 }) == ''
	r.spend(0.50, 1000, 500, 1.0)

	// the fourth would reach $2.50, past the $2.00 turn cap
	blocked := r.gate(Estimate{ cost_usd: 1.00 })
	assert blocked != ''
	assert blocked.contains('30'), blocked
	assert blocked.contains('\$2.00'), blocked
	assert blocked.contains('would reach'), blocked

	// and the budget was never actually crossed
	assert r.totals(window_turn)['cost_usd'] == 1.50
	assert r.blocked == 1
}

fn test_the_call_window_starts_empty_every_time() {
	mut r := new_ration(new_event_log(tmp_log_path('rat2'), 'main', 'test'), ration_spec)
	// a single oversized request is refused
	assert r.gate(Estimate{ tokens_in: 150_000 }) != ''
	// but a normal one is not, however many came before it
	for _ in 0 .. 5 {
		r.spend(0.0, 100_000, 0, 0.0)
	}
	assert r.gate(Estimate{ tokens_in: 100_000 }) == ''
	assert r.totals(window_call)['tokens_in'] == 0.0
}

fn test_a_new_turn_resets_the_turn_budget_but_not_the_session() {
	mut r := new_ration(new_event_log(tmp_log_path('rat3'), 'main', 'test'), ration_spec)
	r.open_turn()
	r.spend(1.80, 0, 0, 0.0)
	assert r.gate(Estimate{ cost_usd: 0.50 }) != ''
	r.open_turn()
	assert r.totals(window_turn)['cost_usd'] == 0.0
	assert r.gate(Estimate{ cost_usd: 0.50 }) == ''
	// the session total kept counting
	assert r.totals(window_session)['cost_usd'] == 1.80
}

fn test_elapsed_time_is_read_from_the_clock_not_accumulated() {
	mut r := new_ration(new_event_log(tmp_log_path('rat4'), 'main', 'test'), '§32 A turn takes at most ten minutes\n@ration per turn max seconds 600\n')
	r.open_turn()
	// a turn that sat waiting has still used its ten minutes
	r.turn_started = now_ts() - 599.0
	assert r.gate(Estimate{ seconds: 0.5 }) == ''
	r.turn_started = now_ts() - 601.0
	assert r.gate(Estimate{}) != ''
}

fn test_the_spend_survives_a_restart() {
	path := tmp_log_path('rat5')
	mut r := new_ration(new_event_log(path, 'main', 'test'), ration_spec)
	r.spend(3.25, 1000, 500, 2.0)
	mut reopened := new_ration(new_event_log(path, 'main', 'test'), ration_spec)
	assert reopened.totals(window_session)['cost_usd'] == 3.25
	assert reopened.totals(window_session)['tokens_total'] == 1500.0
	assert reopened.totals(window_session)['calls'] == 1.0
}

fn test_no_budgets_means_no_interference() {
	mut r := new_ration(new_event_log(tmp_log_path('rat6'), 'main', 'test'), '')
	assert r.gate(Estimate{
		cost_usd:  1000.0
		tokens_in: 10_000_000
	}) == ''
	assert r.report().contains('no @ration budgets')
}

fn test_malformed_budgets_are_reported_never_guessed_at() {
	r := new_ration(new_event_log(tmp_log_path('rat7'), 'main', 'test'), '§33 x\n@ration per turn max\n' +
		'§34 y\n@ration per turn max sideways 4\n' + '§35 z\n@ration per turn max cost_usd 0\n' +
		'§36 w\n@ration per fortnight max cost_usd 4\n')
	assert r.errors.len == 4, '${r.errors}'
	assert r.limits.len == 0
	assert r.errors[1].contains('unknown measure')
	assert r.errors[2].contains('forbids all work')
}

fn test_the_report_shows_each_budget_against_its_spend() {
	mut r := new_ration(new_event_log(tmp_log_path('rat8'), 'main', 'test'), ration_spec)
	r.open_turn()
	r.spend(1.00, 0, 0, 0.0)
	text := r.report()
	assert text.contains('3 budget(s)')
	assert text.contains('\$1.00/\$2.00')
	assert text.contains('(50%) per turn')
	assert text.contains('○ 30')
}

fn test_every_refusal_is_sealed() {
	mut log := new_event_log(tmp_log_path('rat9'), 'main', 'test')
	mut r := new_ration(log, ration_spec)
	r.open_turn()
	r.spend(1.90, 0, 0, 0.0)
	r.gate(Estimate{ cost_usd: 0.50 })
	kinds := log.events('main').map(it.typ)
	assert 'ration.turn' in kinds
	assert 'ration.spent' in kinds
	assert 'ration.blocked' in kinds
}
