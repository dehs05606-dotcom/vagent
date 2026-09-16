module vagent

import x.json2

__global (
	homeo_fired []string
)

fn repair_reseed() !bool {
	homeo_fired << 'reseed'
	return true
}

fn repair_restart_daemon() !bool {
	homeo_fired << 'restart_daemon'
	return true
}

fn repair_warm_caches() !bool {
	homeo_fired << 'warm_caches'
	return true
}

fn repair_that_explodes() !bool {
	return error('cure exploded')
}

fn wired_repairs() map[string]Repair {
	return {
		'tool_error_rate': Repair{
			action: 'reseed'
			run:    repair_reseed
		}
		'loop_alerts':     Repair{
			action: 'restart_daemon'
			run:    repair_restart_daemon
		}
		'tool_latency_ms': Repair{
			action: 'warm_caches'
			run:    repair_warm_caches
		}
	}
}

fn test_a_healthy_system_seals_a_quiet_all_clear_and_touches_nothing() {
	homeo_fired = []
	mut log := new_event_log(tmp_log_path('homeo1'), 'main', 'test')
	log.append('user.message', {
		'text': json2.Any('hi')
	}, AppendOpts{})
	log.append('tool.result', {
		'name':     json2.Any('read_file')
		'status':   json2.Any('done')
		'duration': json2.Any(0.4)
	}, AppendOpts{})
	mut h := new_homeostasis(log, wired_repairs())
	report := h.check_and_repair()
	assert report.healthy()
	assert report.repairs.len == 0
	assert homeo_fired.len == 0
	assert report.format().contains('ALL VITALS NORMAL')
}

fn test_planted_symptoms_fire_exactly_their_own_cures() {
	homeo_fired = []
	mut log := new_event_log(tmp_log_path('homeo2'), 'main', 'test')
	for i in 0 .. 10 {
		log.append('tool.result', {
			'name':     json2.Any('run_command')
			'status':   json2.Any(if i < 5 { 'error' } else { 'done' })
			'duration': json2.Any(30.0)
		}, AppendOpts{})
	}
	for _ in 0 .. 5 {
		log.append('loop.alert', {
			'kind': json2.Any('exact_repeat')
		}, AppendOpts{})
	}
	mut h := new_homeostasis(log, wired_repairs())
	report := h.check_and_repair()

	mut symptoms := []string{}
	for v in report.vitals {
		if !v.healthy {
			symptoms << v.name
		}
	}
	assert 'tool_error_rate' in symptoms, '${symptoms}'
	assert 'loop_alerts' in symptoms, '${symptoms}'
	assert 'tool_latency_ms' in symptoms, '${symptoms}'

	mut fired := homeo_fired.clone()
	fired.sort()
	assert fired == ['reseed', 'restart_daemon', 'warm_caches'], '${fired}'
	assert report.repairs.len == 3

	// the re-measure is honest: the data did not change, so neither did the
	// vital, and the record says so
	rec := report.repairs.filter(it.symptom == 'tool_error_rate')[0]
	assert rec.before == rec.after
	assert !rec.helped
	assert report.format().contains('NO EFFECT')
	assert report.format().contains('SYMPTOM(S)')
}

fn test_an_unwired_symptom_is_reported_never_fabricated() {
	mut log := new_event_log(tmp_log_path('homeo3'), 'main', 'test')
	for _ in 0 .. 8 {
		log.append('tool.result', {
			'name':     json2.Any('x')
			'status':   json2.Any('error')
			'duration': json2.Any(0.1)
		}, AppendOpts{})
	}
	log.append('budget.event', {
		'kind': json2.Any('exceeded')
	}, AppendOpts{})
	mut h := new_homeostasis(log, map[string]Repair{})
	report := h.check_and_repair()
	assert !report.healthy()
	assert report.repairs.len == 0
}

fn test_a_crashing_repair_never_kills_the_check() {
	mut log := new_event_log(tmp_log_path('homeo4'), 'main', 'test')
	for _ in 0 .. 8 {
		log.append('tool.result', {
			'name':     json2.Any('x')
			'status':   json2.Any('error')
			'duration': json2.Any(0.1)
		}, AppendOpts{})
	}
	mut h := new_homeostasis(log, {
		'tool_error_rate': Repair{
			action: 'bad_repair'
			run:    repair_that_explodes
		}
	})
	report := h.check_and_repair()
	assert !report.healthy()
	assert report.repairs.len == 1
	assert !report.repairs[0].helped
	assert report.repairs[0].action == 'bad_repair'
}

fn test_the_window_is_a_sliding_one() {
	mut log := new_event_log(tmp_log_path('homeo5'), 'main', 'test')
	// a long-past run of failures
	for _ in 0 .. 20 {
		log.append('tool.result', {
			'status':   json2.Any('error')
			'duration': json2.Any(0.1)
		}, AppendOpts{})
	}
	// followed by a full window of clean work
	for _ in 0 .. homeo_window {
		log.append('tool.result', {
			'status':   json2.Any('done')
			'duration': json2.Any(0.1)
		}, AppendOpts{})
	}
	mut h := new_homeostasis(log, map[string]Repair{})
	assert h.check_and_repair().healthy()
}

fn test_both_events_are_sealed() {
	mut log := new_event_log(tmp_log_path('homeo6'), 'main', 'test')
	for _ in 0 .. 8 {
		log.append('tool.result', {
			'status':   json2.Any('error')
			'duration': json2.Any(0.1)
		}, AppendOpts{})
	}
	homeo_fired = []
	mut h := new_homeostasis(log, wired_repairs())
	h.check_and_repair()
	kinds := log.events('main').map(it.typ)
	assert 'homeo.check' in kinds
	assert 'homeo.repair' in kinds
	assert h.has_report
}
