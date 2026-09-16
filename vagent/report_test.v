module vagent

import x.json2

fn seeded_report_log(name string) &EventLog {
	mut log := new_event_log(tmp_log_path(name), 'main', 'test')
	log.append('user.message', {
		'text': json2.Any('build the thing')
	}, AppendOpts{})
	log.append('tool.call', {
		'name': json2.Any('write_file')
		'args': json2.Any({
			'path': json2.Any('x.py')
		})
	}, AppendOpts{})
	log.append('tool.result', {
		'name':   json2.Any('write_file')
		'status': json2.Any('done')
	}, AppendOpts{})
	log.append('tool.call', {
		'name': json2.Any('run_command')
		'args': json2.Any({
			'command': json2.Any('pytest')
		})
	}, AppendOpts{})
	log.append('tool.result', {
		'name':   json2.Any('run_command')
		'status': json2.Any('error')
	}, AppendOpts{})
	log.append('judge.verdict', {
		'passed': json2.Any(true)
		'kind':   json2.Any('exit_code')
		'detail': json2.Any('ok')
	}, AppendOpts{})
	log.append('cost.incurred', {
		'usd':        json2.Any(0.0)
		'tokens_in':  json2.Any(500)
		'tokens_out': json2.Any(120)
		'model':      json2.Any('test-model')
	}, AppendOpts{})
	log.append('assistant.message', {
		'text': json2.Any('done')
	}, AppendOpts{})
	return log
}

fn test_the_markdown_export_reports_what_the_fold_holds() {
	mut log := seeded_report_log('rep1')
	md := export_markdown(mut log, 'FullAgent session report')
	assert md.contains('# FullAgent session report')
	assert md.contains('write_file')
	assert md.contains('run_command')
	assert md.contains('500')
	assert md.contains('PASS exit_code')
	assert md.contains('judge verdicts**: 1 passed / 0 failed')
	assert md.contains('errors: 1')
	assert md.contains('## Model usage')
	assert md.contains('test-model')
	assert md.contains('## Timeline (key events)')
}

fn test_the_export_never_writes_to_the_log() {
	mut log := seeded_report_log('rep2')
	before := log.head('main')
	export_markdown(mut log, 'x')
	export_html(mut log, 'x')
	forecast(mut log)
	assert log.head('main') == before
}

fn test_a_pipe_in_a_message_stays_inside_its_cell() {
	mut log := new_event_log(tmp_log_path('rep3'), 'main', 'test')
	log.append('user.message', {
		'text': json2.Any('run a | b | c')
	}, AppendOpts{})
	md := export_markdown(mut log, 'x')
	// escaped, not stripped: the row is still one cell and still says
	// what the user said
	assert md.contains('run a \\| b \\| c'), md

	page := export_html(mut log, 'x')
	assert page.contains('run a | b | c'), page
	// and the escaped pipe did not become a column boundary
	assert !page.contains('<td>run a </td>')
}

fn test_the_html_export_is_self_contained() {
	mut log := seeded_report_log('rep4')
	page := export_html(mut log, 'FullAgent session report')
	assert page.starts_with('<!DOCTYPE html>')
	assert page.contains('<table>')
	assert page.contains('</table>')
	assert page.contains('write_file')
	assert page.contains('<title>FullAgent session report</title>')
	// a compliance artefact that needs the network to render is not one
	assert !page.contains('http://')
	assert !page.contains('https://')
	assert !page.contains('<script')
	// the verdict cell is classed so it reads at a glance
	assert page.contains('class="pass"')
}

fn test_the_html_export_escapes_what_it_renders() {
	mut log := new_event_log(tmp_log_path('rep5'), 'main', 'test')
	log.append('user.message', {
		'text': json2.Any('<script>alert(1)</script>')
	}, AppendOpts{})
	page := export_html(mut log, '<b>title</b>')
	assert page.contains('&lt;script&gt;')
	assert !page.contains('<script>alert')
	assert page.contains('<title>&lt;b&gt;title&lt;/b&gt;</title>')
}

fn test_a_separator_row_never_becomes_a_table_row() {
	assert is_export_separator_row(['---', ':---:'])
	assert !is_export_separator_row(['tool', 'count'])
	assert !is_export_separator_row([])

	cells := split_export_row('| a | b \\| c | d |')
	assert cells == ['a', 'b | c', 'd'], cells.str()
}

fn test_the_forecast_divides_measured_totals_by_measured_turns() {
	mut log := seeded_report_log('rep6')
	f := forecast(mut log)
	assert f.turns == 1
	assert f.tokens_in == 500
	assert f.tokens_out == 120
	assert (f.tokens_in_per_turn or { 0 }) == 500
	assert (f.tokens_out_per_turn or { 0 }) == 120
	text := format_forecast(&f)
	assert text.contains('measured, not guessed')
	assert text.contains('turns so far      : 1')
	assert text.contains('500 in / 120 out')
}

fn test_an_empty_log_forecasts_nothing_rather_than_dividing_by_zero() {
	mut log := new_event_log(tmp_log_path('rep7'), 'main', 'test')
	f := forecast(mut log)
	assert f.turns == 0
	assert f.tokens_in_per_turn == none
	assert f.cost_per_turn_usd == none
	assert f.goal_distance == none
	text := format_forecast(&f)
	assert text.contains('turns so far      : 0')
	assert !text.contains('per turn')
}

fn test_goal_velocity_projects_only_from_real_measurements() {
	mut log := new_event_log(tmp_log_path('rep8'), 'main', 'test')
	log.append('user.message', {
		'text': json2.Any('ship it')
	}, AppendOpts{})
	log.append('goal.set', {
		'statement': json2.Any('ship the parser')
		'clauses':   json2.Any([
			json2.Any({
				'id': json2.Any('C1')
			}),
		])
	}, AppendOpts{})
	// one measurement is not a velocity
	log.append('goal.distance', {
		'distance': json2.Any(0.8)
	}, AppendOpts{})
	one := forecast(mut log)
	assert one.est_ticks_remaining == none
	assert one.velocity_per_tick == none

	// three measurements closing steadily give a real projection
	log.append('goal.distance', {
		'distance': json2.Any(0.6)
	}, AppendOpts{})
	log.append('goal.distance', {
		'distance': json2.Any(0.4)
	}, AppendOpts{})
	f := forecast(mut log)
	assert (f.goal_distance or { -1.0 }) == 0.4
	assert (f.velocity_per_tick or { 0.0 }) > 0.19
	assert (f.est_ticks_remaining or { 0 }) == 2
	text := format_forecast(&f)
	assert text.contains('goal progress     : 60%')
	assert text.contains('~2 goal-tick(s)')
}

fn test_a_stalled_goal_says_so_rather_than_extrapolating() {
	mut log := new_event_log(tmp_log_path('rep9'), 'main', 'test')
	log.append('goal.set', {
		'statement': json2.Any('ship it')
		'clauses':   json2.Any([
			json2.Any({
				'id': json2.Any('C1')
			}),
		])
	}, AppendOpts{})
	for _ in 0 .. 4 {
		log.append('goal.distance', {
			'distance': json2.Any(0.7)
		}, AppendOpts{})
	}
	f := forecast(mut log)
	assert (f.goal_distance or { -1.0 }) == 0.7
	assert (f.velocity_per_tick or { -1.0 }) == 0.0
	// the distance is not moving, so no honest number of ticks exists
	assert f.est_ticks_remaining == none
	text := format_forecast(&f)
	assert text.contains('no measurable velocity')
}

fn test_the_forecast_serialises_only_what_it_measured() {
	mut log := new_event_log(tmp_log_path('rep10'), 'main', 'test')
	f := forecast(mut log)
	d := f.to_json()
	assert 'turns' in d
	// an absent measurement is absent, not zero — a zero here would read
	// as a measurement of no progress
	assert 'tokens_in_per_turn' !in d
	assert 'goal_distance' !in d
	assert 'est_ticks_remaining' !in d
}
