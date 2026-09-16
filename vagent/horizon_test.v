module vagent

import x.json2

const horizon_spec = '§12 A change touches at most 3 files
@horizon per turn max files_written 3

§13 A session deletes at most 2 files
@horizon per session max files_deleted 2

§14 At most 1 unanalysable command per turn
@horizon per turn max opaque_commands 1
'

fn hz_args(pairs map[string]string) map[string]json2.Any {
	mut out := map[string]json2.Any{}
	for k, v in pairs {
		out[k] = json2.Any(v)
	}
	return out
}

fn test_the_spec_parses_into_exactly_its_limits() {
	h := new_horizon(new_event_log(tmp_log_path('hz0'), 'main', 'test'), horizon_spec)
	assert h.limits.len == 3
	assert h.errors.len == 0
	assert h.limits[0].clause == '12'
	assert h.limits[0].window == window_turn
	assert h.limits[0].measure == 'files_written'
	assert h.limits[0].limit == 3
	assert h.limits[1].window == window_session
}

fn test_measurement_counts_effects_not_tools() {
	m := measure_call('write_file', hz_args({
		'path':    'a.py'
		'content': 'x\ny\n'
	}))
	assert m['files_written'] == 1
	assert m['lines_written'] == 3

	// a shell write weighs what the same write through write_file weighs
	assert measure_call('run_command', hz_args({
		'command': 'echo x > a.py'
	}))['files_written'] == 1
	assert measure_call('run_command', hz_args({
		'command': 'touch a && touch b'
	}))['files_written'] == 2
	// a path written twice in one call is one file
	assert measure_call('run_command', hz_args({
		'command': 'echo x > a; echo y > a'
	}))['files_written'] == 1
}

fn test_every_step_is_legal_but_the_sum_is_not() {
	mut h := new_horizon(new_event_log(tmp_log_path('hz1'), 'main', 'test'), horizon_spec)
	h.open_turn()
	for i in 0 .. 3 {
		args := hz_args({
			'path':    'f${i}.py'
			'content': 'x'
		})
		assert h.gate('write_file', args) == '', 'file ${i} refused too early'
		h.spend('write_file', args)
	}
	// the fourth is refused although it is identical to the first three
	blocked := h.gate('write_file', hz_args({
		'path':    'f3.py'
		'content': 'x'
	}))
	assert blocked != ''
	assert blocked.contains('12'), blocked
	assert blocked.contains('would reach 4'), blocked

	// and the limit was never actually crossed
	assert h.totals(window_turn)['files_written'] == 3
	assert h.blocked == 1
}

fn test_a_new_turn_resets_the_turn_window_but_not_the_session() {
	mut h := new_horizon(new_event_log(tmp_log_path('hz2'), 'main', 'test'), horizon_spec)
	h.open_turn()
	for i in 0 .. 3 {
		h.spend('write_file', hz_args({
			'path':    'f${i}.py'
			'content': 'x'
		}))
	}
	h.open_turn()
	assert h.totals(window_turn)['files_written'] == 0
	assert h.gate('write_file', hz_args({
		'path':    'f4.py'
		'content': 'x'
	})) == ''

	h.spend('delete_path', hz_args({
		'path': 'a.py'
	}))
	h.spend('run_command', hz_args({
		'command': 'rm b.py'
	}))
	assert h.totals(window_session)['files_deleted'] == 2
	h.open_turn()
	assert h.totals(window_session)['files_deleted'] == 2, 'the session window reset'
	blocked := h.gate('delete_path', hz_args({
		'path': 'c.py'
	}))
	assert blocked.contains('13'), blocked
}

fn test_one_call_that_alone_crosses_a_limit_is_refused_whole() {
	mut h := new_horizon(new_event_log(tmp_log_path('hz3'), 'main', 'test'), horizon_spec)
	h.open_turn()
	assert h.gate('run_command', hz_args({
		'command': 'touch a && touch b && touch c && touch d'
	})) != '', 'a four-file call passed a three-file cap'
}

fn test_opaque_commands_are_their_own_measure() {
	mut h := new_horizon(new_event_log(tmp_log_path('hz4'), 'main', 'test'), horizon_spec)
	h.open_turn()
	opaque := hz_args({
		'command': 'eval "\$CMD"'
	})
	assert h.gate('run_command', opaque) == ''
	h.spend('run_command', opaque)
	assert h.gate('run_command', opaque) != '', 'a second opaque command passed a cap of 1'
}

fn test_totals_are_a_fold_and_survive_a_reload() {
	path := tmp_log_path('hz5')
	mut h := new_horizon(new_event_log(path, 'main', 'test'), horizon_spec)
	h.spend('delete_path', hz_args({
		'path': 'a.py'
	}))
	h.spend('run_command', hz_args({
		'command': 'rm b.py'
	}))
	mut reopened := new_horizon(new_event_log(path, 'main', 'test'), horizon_spec)
	assert reopened.totals(window_session)['files_deleted'] == 2, 'the session total did not survive a reload'
}

fn test_no_limits_means_no_interference() {
	mut h := new_horizon(new_event_log(tmp_log_path('hz6'), 'main', 'test'), '')
	assert h.gate('run_command', hz_args({
		'command': 'rm -rf everything'
	})) == ''
	assert h.report().contains('no @horizon limits')
}

fn test_malformed_limits_are_reported_never_guessed_at() {
	mut h := new_horizon(new_event_log(tmp_log_path('hz7'), 'main', 'test'), '§20 x\n@horizon per turn max\n' +
		'§21 y\n@horizon per turn max sideways 4\n' +
		'§22 z\n@horizon per fortnight max files_written 4\n')
	assert h.errors.len == 3, '${h.errors}'
	assert h.limits.len == 0
	assert h.errors[1].contains('unknown measure')
}

fn test_the_report_shows_each_limit_against_its_current_total() {
	mut h := new_horizon(new_event_log(tmp_log_path('hz8'), 'main', 'test'), horizon_spec)
	h.open_turn()
	for i in 0 .. 3 {
		h.spend('write_file', hz_args({
			'path':    'f${i}.py'
			'content': 'x'
		}))
	}
	text := h.report()
	assert text.contains('3 limit(s)')
	assert text.contains('● 12'), text
	assert text.contains('3/3 per turn')
	assert text.contains('○ 13'), text
	assert text.contains('0/2 per session')
}
