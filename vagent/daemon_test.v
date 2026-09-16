module vagent

import x.json2

__global (
	daemon_results map[string]string
)

fn scripted_step(task string) string {
	if out := daemon_results[task] {
		return out
	}
	return 'OK: ${task}'
}

fn always_fails(task string) string {
	return 'ERROR: permanent'
}

fn test_a_mission_advances_one_step_per_tick() {
	daemon_results = {
		'step two': 'ERROR: transient failure'
	}
	mut log := new_event_log(tmp_log_path('dae1'), 'main', 'test')
	mut d := new_daemon(log, scripted_step, 1)

	m := d.start('ship the parser', ['step one', 'step two', 'step three'])
	assert m.mission_id != ''
	assert m.steps.len == 3

	r1 := d.tick(m.mission_id)
	assert jstr(r1, 'state') == 'RUNNING', r1.str()
	assert jstr(r1, 'step') == 'M1', r1.str()

	// a transient failure does not block: the step returns to PENDING and
	// the mission stays RUNNING for the retry
	r2 := d.tick(m.mission_id)
	assert jstr(r2, 'result').starts_with('ERROR:'), r2.str()
	assert jstr(r2, 'step') == 'M2'
	mid := d.resume(m.mission_id) or { panic('mission vanished') }
	assert mid.state == 'RUNNING'

	daemon_results['step two'] = 'OK: recovered'
	r3 := d.tick(m.mission_id)
	assert jstr(r3, 'step') == 'M2'
	assert !jstr(r3, 'result').starts_with('ERROR:')

	r4 := d.tick(m.mission_id)
	assert jstr(r4, 'state') == 'DONE', r4.str()
	assert jf64(r4, 'progress') == 1.0
}

fn test_a_finished_mission_rebuilds_from_the_fold_alone() {
	daemon_results = map[string]string{}
	mut log := new_event_log(tmp_log_path('dae2'), 'main', 'test')
	mut d := new_daemon(log, scripted_step, 1)
	m := d.start('ship it', ['a', 'b'])
	d.tick(m.mission_id)
	d.tick(m.mission_id)

	// a second daemon over the same log knows nothing but the events
	mut fresh := new_daemon(log, scripted_step, 1)
	rebuilt := fresh.resume(m.mission_id) or { panic('mission vanished') }
	assert rebuilt.state == 'DONE'
	assert rebuilt.progress() == 1.0
	assert rebuilt.steps.len == 2
	for s in rebuilt.steps {
		assert s.state == 'DONE', s.state
	}
	assert rebuilt.statement == 'ship it'
	assert rebuilt.ticks == 2
}

fn test_a_step_that_never_succeeds_blocks_the_mission_visibly() {
	mut log := new_event_log(tmp_log_path('dae3'), 'main', 'test')
	mut d := new_daemon(log, always_fails, 1)
	m := d.start('doomed', ['only step'])

	d.tick(m.mission_id) // attempt 1 fails → retry
	r := d.tick(m.mission_id) // attempt 2 fails → BLOCKED
	assert jstr(r, 'state') == 'BLOCKED', r.str()
	assert jstr(r, 'step') == 'M1'

	blocked := d.resume(m.mission_id) or { panic('mission vanished') }
	assert blocked.state == 'BLOCKED'
	// the step is never skipped — it stays FAILED, naming where it stopped
	assert blocked.steps[0].state == 'FAILED'
	assert blocked.steps[0].attempts == 2

	// a blocked mission refuses further ticks rather than pretending
	again := d.tick(m.mission_id)
	assert jstr(again, 'error').contains('not RUNNING'), again.str()

	assert d.abandon(m.mission_id, 'giving up')
	abandoned := d.resume(m.mission_id) or { panic('mission vanished') }
	assert abandoned.state == 'ABANDONED'
	// abandoning twice is not an error, it is simply not a change
	assert d.abandon(m.mission_id, 'again')
}

fn test_a_mission_with_no_executor_fails_honestly() {
	mut log := new_event_log(tmp_log_path('dae4'), 'main', 'test')
	mut d := &Daemon{
		log:         log
		max_retries: 0
	}
	m := d.start('nobody home', ['a'])
	r := d.tick(m.mission_id)
	assert jstr(r, 'state') == 'BLOCKED', r.str()
	assert jstr(r, 'result').contains('no executor attached')
}

fn test_an_unknown_mission_is_reported_not_invented() {
	mut log := new_event_log(tmp_log_path('dae5'), 'main', 'test')
	mut d := new_daemon(log, scripted_step, 1)
	r := d.tick('mission-404')
	assert jstr(r, 'error') == 'no such mission'
	if _ := d.resume('mission-404') {
		assert false, 'an unknown mission must not resume'
	}
}

fn test_wake_conditions_report_what_holds_right_now() {
	daemon_results = map[string]string{}
	mut log := new_event_log(tmp_log_path('dae6'), 'main', 'test')
	mut d := new_daemon(log, scripted_step, 1)
	assert !d.due()
	assert d.wake_conditions().len == 0

	m := d.start('long mission', ['a', 'b'])
	assert d.due()
	mut hit := false
	for w in d.wake_conditions() {
		if w.contains('RUNNING') {
			hit = true
		}
	}
	assert hit, d.wake_conditions().str()

	// a failed verdict is its own reason to wake
	log.append('judge.verdict', {
		'passed': json2.Any(false)
	}, AppendOpts{ actor: 'test' })
	mut reasons := d.wake_conditions()
	assert reasons.filter(it.contains('failed verdict')).len == 1, reasons.str()

	rows := d.missions()
	assert rows.len == 1
	assert jstr(rows[0], 'mission_id') == m.mission_id
	assert jint(rows[0], 'steps') == 2

	status := d.format_status()
	assert status.contains('DAEMON')
	assert status.contains(m.mission_id)
	assert status.contains('wake:')
}

fn test_missions_are_listed_newest_first() {
	daemon_results = map[string]string{}
	mut log := new_event_log(tmp_log_path('dae7'), 'main', 'test')
	mut d := new_daemon(log, scripted_step, 1)
	first := d.start('first', ['a'])
	second := d.start('second', ['a'])
	rows := d.missions()
	assert rows.len == 2
	assert jstr(rows[0], 'mission_id') == second.mission_id
	assert jstr(rows[1], 'mission_id') == first.mission_id
	// ids come from the log head, so two missions started back to back
	// cannot collide the way a millisecond clock would
	assert first.mission_id != second.mission_id
}

fn test_everything_is_sealed_in_the_ledger() {
	daemon_results = map[string]string{}
	mut log := new_event_log(tmp_log_path('dae8'), 'main', 'test')
	mut d := new_daemon(log, scripted_step, 1)
	m := d.start('ship it', ['a'])
	d.tick(m.mission_id)

	st := fold(mut log, 'main')
	mut types := map[string]bool{}
	for e in st.daemon_events {
		types[jstr(e, 'type')] = true
	}
	for want in ['daemon.mission', 'daemon.checkpoint', 'daemon.tick', 'daemon.done'] {
		assert types[want], want
	}
}

fn test_an_empty_mission_is_complete_on_its_first_tick() {
	mut log := new_event_log(tmp_log_path('dae9'), 'main', 'test')
	mut d := new_daemon(log, scripted_step, 1)
	m := d.start('nothing to do', [])
	assert m.progress() == 1.0
	r := d.tick(m.mission_id)
	assert jstr(r, 'state') == 'DONE'
	assert jf64(r, 'progress') == 1.0
}
