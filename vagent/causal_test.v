module vagent

import x.json2

fn test_a_confounded_association_is_separated_from_a_real_cause() {
	// ground truth: `tools` CAUSES success, and a confounder z drives both
	// web usage and success, so web looks associated but is spurious
	mut rng := new_rng(42)
	mut obs := []CausalObservation{}
	for _ in 0 .. 200 {
		z := rng.f64()
		web := if rng.f64() < z { 1.0 } else { 0.0 }
		tools := min_f64(1.0, max_f64(0.0, z * 0.5 + rng.f64() * 0.3))
		noise := rng.f64() * 0.2
		outcome := min_f64(1.0, max_f64(0.0, 0.5 * tools + 0.35 * z + noise))
		obs << CausalObservation{
			features: {
				'web':    web
				'tools':  tools
				'z':      z
				'errors': 0.0
			}
			outcome:  outcome
		}
	}

	mut eng := new_causal_engine(new_event_log(tmp_log_path('cau1'), 'main', 'test'))
	edges := eng.discover(obs, true)
	mut verdicts := map[string]string{}
	for e in edges {
		verdicts[e.cause] = e.verdict
	}
	assert verdicts['tools'] == 'CAUSAL', '${verdicts}'
	assert verdicts['web'] == 'SPURIOUS', '${verdicts}'

	tools_edge := edges.filter(it.cause == 'tools')[0]
	assert tools_edge.adjusted > 0.05, tools_edge.to_json().str()
}

fn test_observations_fold_from_a_real_kernel_log() {
	mut log := new_event_log(tmp_log_path('cau2'), 'main', 'test')
	log.append('user.message', {
		'text': json2.Any('go')
	}, AppendOpts{})
	log.append('tool.call', {
		'name': json2.Any('web_search')
		'args': json2.Any({
			'q': json2.Any('x')
		})
	}, AppendOpts{})
	log.append('tool.result', {
		'status': json2.Any('done')
	}, AppendOpts{})
	log.append('turn.scorecard', {
		'score': json2.Any(80)
	}, AppendOpts{})
	log.append('user.message', {
		'text': json2.Any('go 2')
	}, AppendOpts{})
	log.append('tool.call', {
		'name': json2.Any('write_file')
		'args': json2.Any({
			'path': json2.Any('a.py')
		})
	}, AppendOpts{})
	log.append('tool.result', {
		'status': json2.Any('error')
	}, AppendOpts{})

	obs := observations_from_log(mut log)
	assert obs.len == 2
	assert obs[0].features['web'] == 1.0
	assert obs[0].outcome == 0.8
	assert obs[1].features['writes'] > 0
	assert obs[1].features['errors'] > 0
	// a turn that errored scores zero when no scorecard was sealed
	assert obs[1].outcome == 0.0
}

fn test_do_reports_the_adjusted_estimate_with_an_honesty_flag() {
	mut log := new_event_log(tmp_log_path('cau3'), 'main', 'test')
	mut eng := new_causal_engine(log)
	report := eng.do_intervention('tools', true)
	assert jstr(report, 'intervention') == 'tools'
	assert 'trustworthy' in report
	// with no history at all it is not trustworthy, and says so
	assert !jbool(report, 'trustworthy')
	assert jint(report, 'usable_observations') == 0
	assert log.events('main').map(it.typ).contains('causal.intervention')
}

fn test_tiny_data_is_unmeasured_never_guessed() {
	mut eng := new_causal_engine(new_event_log(tmp_log_path('cau4'), 'main', 'test'))
	tiny := eng.discover([
		CausalObservation{
			features: {
				'web': 1.0
			}
			outcome:  1.0
		},
	], true)
	assert tiny.len == 0

	// just under the total threshold: an association may be seen, but the
	// adjusted effect is not claimed
	mut some := []CausalObservation{}
	for i in 0 .. min_total_obs - 1 {
		some << CausalObservation{
			features: {
				'web': f64(i % 2)
			}
			outcome:  f64(i % 2)
		}
	}
	edges := eng.discover(some, true)
	for e in edges {
		assert e.verdict == 'UNMEASURED', e.to_json().str()
	}
}

fn test_pearson_is_the_correlation_it_says_it_is() {
	assert pearson([1.0, 2.0, 3.0], [1.0, 2.0, 3.0]) > 0.99
	assert math_abs(pearson([1.0, 2.0, 3.0], [3.0, 2.0, 1.0]) + 1.0) < 0.01
	assert pearson([1.0], [1.0]) == 0.0
	assert pearson([], []) == 0.0
	// a constant series correlates with nothing rather than dividing by zero
	assert pearson([2.0, 2.0, 2.0], [1.0, 2.0, 3.0]) == 0.0
}

fn test_every_edge_is_sealed_and_the_report_renders() {
	mut log := new_event_log(tmp_log_path('cau5'), 'main', 'test')
	mut eng := new_causal_engine(log)
	mut obs := []CausalObservation{}
	for i in 0 .. 40 {
		on := f64(i % 2)
		obs << CausalObservation{
			features: {
				'tools': on
			}
			outcome:  on * 0.9 + 0.05
		}
	}
	edges := eng.discover(obs, true)
	assert edges.len > 0
	assert log.events('main').map(it.typ).contains('causal.edge')
	text := eng.format(edges)
	assert text.contains('CAUSAL ANALYSIS')
	assert text.contains('tools')
	assert eng.format([]) == 'not enough history for causal analysis yet'
}
