module vagent

// a multiplicative landscape with an interaction penalty: a naive per-knob
// greedy sweep gets stuck, so reaching the optimum means the search worked
fn tuner_objective(cfg map[string]string) f64 {
	effort := match cfg['effort'] {
		'low' { 0.2 }
		'medium' { 0.5 }
		'high' { 0.9 }
		else { 0.0 }
	}
	steps := match cfg['steps'] {
		'low' { 0.4 }
		'medium' { 0.8 }
		'high' { 0.5 }
		else { 0.0 }
	}
	compact := match cfg['compact'] {
		'loose' { 0.3 }
		'tight' { 0.7 }
		else { 0.0 }
	}
	mut base := effort * steps * compact
	mut penalty := 0.0
	if cfg['steps'] == 'high' && cfg['compact'] == 'tight' {
		penalty = 0.3
	}
	return base + 0.1 - penalty
}

fn tuner_space() map[string][]string {
	return {
		'effort':  ['low', 'medium', 'high']
		'steps':   ['low', 'medium', 'high']
		'compact': ['loose', 'tight']
	}
}

fn test_the_tuner_converges_without_exhausting_the_grid() {
	mut t := new_parzen_tuner(new_event_log(tmp_log_path('tuner1'), 'main', 'test'),
		tuner_space(), 21, tuner_objective)
	report := t.run(40) or { panic(err) }

	optimum := {
		'effort':  'high'
		'steps':   'medium'
		'compact': 'tight'
	}
	best_possible := tuner_objective(optimum)
	assert report.best_score >= best_possible * 0.999, '${report.best_score} vs ${best_possible}'
	assert report.best_config == optimum, '${report.best_config}'
	// 27 combinations exist, and it never had to try them all
	assert report.distinct <= 26, '${report.distinct}'
	assert report.trials == 40
}

fn test_the_same_seed_gives_the_same_search() {
	mut a := new_parzen_tuner(new_event_log(tmp_log_path('tuner2a'), 'main', 'test'),
		tuner_space(), 21, tuner_objective)
	mut b := new_parzen_tuner(new_event_log(tmp_log_path('tuner2b'), 'main', 'test'),
		tuner_space(), 21, tuner_objective)
	ra := a.run(40) or { panic(err) }
	rb := b.run(40) or { panic(err) }
	assert ra.best_config == rb.best_config
	assert ra.best_score == rb.best_score
	assert ra.distinct == rb.distinct
}

fn test_early_suggestions_space_fill_and_cover_every_knob() {
	mut t := new_parzen_tuner(new_event_log(tmp_log_path('tuner3'), 'main', 'test'),
		tuner_space(), 4, unsafe { nil })
	first := t.suggest()
	assert first.len == 3
	assert 'effort' in first && 'steps' in first && 'compact' in first
	assert first['effort'] in tuner_space()['effort']
}

fn test_the_density_ratio_prefers_what_the_good_set_contains() {
	mut t := new_parzen_tuner(new_event_log(tmp_log_path('tuner4'), 'main', 'test'),
		tuner_space(), 4, unsafe { nil })
	t.observe({
		'effort':  'high'
		'steps':   'low'
		'compact': 'loose'
	}, 0.9)
	t.observe({
		'effort':  'high'
		'steps':   'low'
		'compact': 'loose'
	}, 0.8)
	t.observe({
		'effort':  'low'
		'steps':   'high'
		'compact': 'tight'
	}, 0.1)
	mut high := 0
	mut low := 0
	for _ in 0 .. 60 {
		match t.suggest()['effort'] {
			'high' { high++ }
			'low' { low++ }
			else {}
		}
	}
	assert high > low, 'high=${high} low=${low}'

	// the smoothing floor means an unseen value is still reachable
	assert density('never-seen', ['a', 'b']) > 0.0
	assert density('a', []) == 1.0
	assert density('a', ['a', 'a']) > density('b', ['a', 'a'])
}

fn test_a_tuner_without_an_objective_fails_cleanly() {
	mut t := new_parzen_tuner(new_event_log(tmp_log_path('tuner5'), 'main', 'test'),
		tuner_space(), 1, unsafe { nil })
	t.step() or {
		assert err.msg().contains('no objective')
		assert t.best() == none
		assert t.format() == 'TUNER — 0 trials'
		return
	}
	assert false, 'a tuner with no objective must not pretend to step'
}

fn test_an_empty_knob_is_dropped_from_the_space() {
	mut t := new_parzen_tuner(new_event_log(tmp_log_path('tuner6'), 'main', 'test'),
		{
		'effort': ['low', 'high']
		'unused': []string{}
	}, 1, unsafe { nil })
	assert t.knobs == ['effort']
	assert t.suggest().len == 1
}

fn test_both_events_are_sealed_and_the_report_renders() {
	mut log := new_event_log(tmp_log_path('tuner7'), 'main', 'test')
	mut t := new_parzen_tuner(log, tuner_space(), 7, tuner_objective)
	t.run(5) or { panic(err) }
	kinds := log.events('main').map(it.typ)
	assert 'tuner.trial' in kinds
	assert 'tuner.best' in kinds
	text := t.format()
	assert text.contains('TUNER — 5 trials')
	assert text.contains('best score')
	assert text.contains('effort=')
}
