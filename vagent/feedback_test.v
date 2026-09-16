module vagent

import x.json2

// a stand-in adherence report, so this module is testable without a model
fn fake_report(rows [][]int, names []string) AdherenceReport {
	mut rep := AdherenceReport{}
	for i, row in rows {
		followed := row[0]
		n := row[1]
		mut score := ClauseScore{
			clause: names[i]
		}
		for j in 0 .. n {
			score.probes << Probe{
				clause:  names[i]
				verdict: if j < followed { verdict_followed } else { verdict_broken }
			}
		}
		rep.scores << score
	}
	return rep
}

fn test_with_no_measurement_nothing_is_weighted() {
	mut f := new_feedback(new_event_log(tmp_log_path('fb1'), 'main', 'test'))
	assert f.weights().len == 0
	assert f.weight('ANY') == 1.0
	assert f.report().contains('no measurement yet')
}

fn test_a_measurement_moves_the_weights_in_the_stated_direction() {
	mut f := new_feedback(new_event_log(tmp_log_path('fb2'), 'main', 'test'))
	rep := fake_report([[1, 3], [3, 3]], ['OUT', 'SQL'])
	assert f.observe(&rep) == 2
	w := f.weights()
	// missed -> boosted, held -> eased
	assert w['OUT'] > 1.0, '${w}'
	assert w['SQL'] < 1.0, '${w}'
	assert w['SQL'] >= feedback_floor
	assert w['OUT'] <= feedback_ceiling

	// the mapping is the stated one, not an opaque curve
	assert math_abs(f.rates()['SQL'] - 1.0) < 1e-9
	assert math_abs(w['SQL'] - feedback_floor) < 1e-9

	mut z := new_feedback(new_event_log(tmp_log_path('fb2z'), 'main', 'test'))
	zero := fake_report([[0, 3]], ['ZERO'])
	z.observe(&zero)
	assert math_abs(z.weight('ZERO') - feedback_ceiling) < 1e-9
}

fn test_it_is_bounded_and_never_suppresses() {
	mut z := new_feedback(new_event_log(tmp_log_path('fb3'), 'main', 'test'))
	zero := fake_report([[0, 3]], ['ZERO'])
	for _ in 0 .. 20 {
		z.observe(&zero)
	}
	assert z.weight('ZERO') <= feedback_ceiling

	mut f := new_feedback(new_event_log(tmp_log_path('fb3b'), 'main', 'test'))
	perfect := fake_report([[3, 3]], ['SQL'])
	for _ in 0 .. 20 {
		f.observe(&perfect)
	}
	assert f.weight('SQL') >= feedback_floor
	assert feedback_floor > 0
}

fn test_too_few_probes_is_not_evidence() {
	mut f := new_feedback(new_event_log(tmp_log_path('fb4'), 'main', 'test'))
	thin := fake_report([[0, 1]], ['THIN'])
	assert f.observe(&thin) == 0
	assert f.weight('THIN') == 1.0
	// an unscorable clause never reaches observe at all
	assert 'PROSE' !in f.weights()
}

fn test_a_fix_last_week_outweighs_a_failure_last_month() {
	mut log := new_event_log(tmp_log_path('fb5'), 'main', 'test')
	mut f := new_feedback(log)
	now := now_ts()
	log.append('feedback.observed', {
		'clause':   json2.Any('X')
		'followed': json2.Any(0)
		'probes':   json2.Any(3)
		'at':       json2.Any(now - 30.0 * 86_400.0)
	}, AppendOpts{ actor: 'kernel' })
	log.append('feedback.observed', {
		'clause':   json2.Any('X')
		'followed': json2.Any(3)
		'probes':   json2.Any(3)
		'at':       json2.Any(now)
	}, AppendOpts{ actor: 'kernel' })
	assert f.rates()['X'] > 0.8, '${f.rates()}'
	assert feedback_decay(0.0) == 1.0
	assert math_abs(feedback_decay(feedback_half_life) - 0.5) < 1e-9
}

fn test_a_reset_discards_past_influence_and_the_fold_survives_a_restart() {
	path := tmp_log_path('fb6')
	mut log := new_event_log(path, 'main', 'test')
	mut f := new_feedback(log)
	failing := fake_report([[0, 3]], ['X'])
	f.observe(&failing)
	assert f.weight('X') > 1.0

	f.reset()
	assert f.weights().len == 0
	f.observe(&failing)
	assert f.weight('X') > 1.0

	// it is a fold, so a fresh reader of the same log agrees
	mut again := new_feedback(new_event_log(path, 'main', 'test'))
	assert again.weights() == f.weights()
}

fn test_the_report_says_which_way_each_clause_moved() {
	mut f := new_feedback(new_event_log(tmp_log_path('fb7'), 'main', 'test'))
	rep := fake_report([[1, 3], [3, 3]], ['OUT', 'SQL'])
	f.observe(&rep)
	text := f.report()
	assert text.contains('boosted')
	assert text.contains('eased')
	assert text.contains('delivered whole and unedited')
	assert text.contains('half-life 7d')
	// the weakest clause is listed first
	assert text.index('OUT') or { 999 } < text.index('SQL') or { 0 }
}
