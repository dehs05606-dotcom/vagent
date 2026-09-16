module vagent

__global (
	healer_fixed bool
)

fn marking_fixer(diagnosis &Diagnosis, context string) !string {
	healer_fixed = true
	return 'applied: ${diagnosis.suggestion}'
}

fn state_recheck() !(bool, string) {
	if healer_fixed {
		return true, ''
	}
	return false, 'still broken'
}

fn futile_fixer(diagnosis &Diagnosis, context string) !string {
	return 'tried something'
}

fn failing_recheck() !(bool, string) {
	return false, 'still failing'
}

fn exploding_fixer(diagnosis &Diagnosis, context string) !string {
	return error('the fixer itself broke')
}

fn exploding_recheck() !(bool, string) {
	return error('the check could not run')
}

fn test_the_taxonomy_recognises_the_failures_it_was_written_for() {
	assert classify_error("ModuleNotFoundError: No module named 'requests'").root_cause == 'missing_module'
	assert classify_error('bash: foobar: command not found').root_cause == 'missing_binary'
	assert classify_error('ConnectionError: connection refused by host').root_cause == 'network_unreachable'
	assert classify_error('PermissionError: [Errno 13] /etc/shadow').root_cause == 'permission_denied'
	assert classify_error('HTTP 429 too many requests').root_cause == 'rate_limited'
	assert classify_error('ZeroDivisionError: division by zero').root_cause == 'division_by_zero'
}

fn test_an_unrecognised_error_is_unknown_not_the_nearest_guess() {
	d := classify_error('a totally novel failure mode xyz')
	assert d.root_cause == 'unknown'
	assert d.matched == ''
	assert d.suggestion.contains('inspect the error manually')
	// the evidence is still the error itself, so a human has something to read
	assert d.evidence.contains('novel failure mode')
	// an empty error is unknown too, rather than matching an empty pattern
	assert classify_error('').root_cause == 'unknown'
}

fn test_the_diagnosis_carries_the_excerpt_it_was_read_from() {
	long := 'x'.repeat(200) + 'ZeroDivisionError: division by zero' + 'y'.repeat(200)
	d := classify_error(long)
	assert d.root_cause == 'division_by_zero'
	// a window around the match, not the whole log
	assert d.evidence.len < long.len
	assert d.evidence.contains('ZeroDivisionError')
	assert d.matched != ''
}

fn test_a_fix_that_passes_the_recheck_is_sealed_as_healed() {
	healer_fixed = false
	mut log := new_event_log(tmp_log_path('hea1'), 'main', 'test')
	mut h := new_healer(log, marking_fixer, state_recheck)

	rep := h.heal("ModuleNotFoundError: No module named 'yaml'", 'importing config loader')
	assert rep.diagnosis.root_cause == 'missing_module'
	assert rep.fix_applied
	assert rep.retried
	assert rep.healed
	assert rep.lesson.contains('auto-healed'), rep.lesson

	// and the lesson makes the same cause instantly recognisable
	assert h.known_cause("ModuleNotFoundError: No module named 'toml'")
	assert !h.known_cause('KeyError: something else entirely')
}

fn test_a_fix_that_does_not_pass_the_recheck_is_reported_unhealed() {
	mut log := new_event_log(tmp_log_path('hea2'), 'main', 'test')
	mut h := new_healer(log, futile_fixer, failing_recheck)
	rep := h.heal("KeyError: 'user'", '')
	assert rep.fix_applied
	assert rep.retried
	assert !rep.healed
	assert rep.lesson.contains('still fails'), rep.lesson
	// proof, not promise: an unproven fix never claims the cure
	assert !h.known_cause("KeyError: 'other'")
}

fn test_a_healer_with_no_fixer_classifies_and_stops() {
	mut log := new_event_log(tmp_log_path('hea3'), 'main', 'test')
	mut h := new_observing_healer(log)
	rep := h.heal('PermissionError: [Errno 13] /etc/shadow', '')
	assert rep.diagnosis.root_cause == 'permission_denied'
	assert !rep.fix_applied
	assert !rep.retried
	assert !rep.healed
	// the lesson is the suggestion itself — the most it can honestly say
	assert rep.lesson == 'permission_denied: check file permissions / run with appropriate access'
	assert 'heal.patch' !in log.events('main').map(it.typ)
}

fn test_an_unknown_cause_is_never_fixed_even_with_a_fixer_present() {
	healer_fixed = false
	mut log := new_event_log(tmp_log_path('hea4'), 'main', 'test')
	mut h := new_healer(log, marking_fixer, state_recheck)
	rep := h.heal('a totally novel failure mode xyz', '')
	assert !rep.fix_applied
	assert !rep.healed
	// acting on a guess is the one thing the engine refuses to do
	assert !healer_fixed
}

fn test_a_fixer_that_breaks_is_recorded_rather_than_propagated() {
	mut log := new_event_log(tmp_log_path('hea5'), 'main', 'test')
	mut h := new_healer(log, exploding_fixer, failing_recheck)
	rep := h.heal('SyntaxError: invalid syntax', '')
	assert rep.fix_applied
	assert rep.fix_result.starts_with('ERROR:'), rep.fix_result
	assert !rep.healed
}

fn test_a_recheck_that_cannot_run_counts_as_not_healed() {
	mut log := new_event_log(tmp_log_path('hea6'), 'main', 'test')
	mut h := new_healer(log, futile_fixer, exploding_recheck)
	rep := h.heal('TypeError: bad argument', '')
	assert rep.retried
	assert !rep.healed
	retries := log.events('main').filter(it.typ == 'heal.retry')
	assert retries.len == 1
	assert jstr(retries[0].data, 'error').contains('could not run')
}

fn test_every_stage_is_sealed_and_counted() {
	healer_fixed = false
	mut log := new_event_log(tmp_log_path('hea7'), 'main', 'test')
	mut h := new_healer(log, marking_fixer, state_recheck)
	h.heal("ModuleNotFoundError: No module named 'yaml'", '')
	h.heal("ModuleNotFoundError: No module named 'toml'", '')
	h.heal('a totally novel failure mode xyz', '')

	st := fold(mut log, 'main')
	mut types := map[string]bool{}
	for e in st.heal_events {
		types[jstr(e, 'type')] = true
	}
	for want in ['heal.captured', 'heal.hypothesis', 'heal.patch', 'heal.retry', 'heal.lesson'] {
		assert types[want], want
	}

	s := h.stats()
	assert s.captured == 3
	assert s.healed == 2
	assert s.by_cause['missing_module'] == 2
	assert s.by_cause['unknown'] == 1

	status := h.format_status()
	assert status.contains('HEALER')
	assert status.contains('captured 3   healed 2')
	// the most frequent cause is listed first
	lines := status.split('\n')
	assert lines[2].contains('missing_module'), status
	assert lines[2].contains('×2'), status
}
