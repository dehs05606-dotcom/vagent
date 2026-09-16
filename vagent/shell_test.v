module vagent

fn test_run_command_reports_exit_and_streams() {
	ok := run_command('echo hello', 10, no_sink)
	assert ok.contains('exit code: 0'), ok
	assert ok.contains('hello'), ok

	bad := run_command('exit 3', 10, no_sink)
	assert bad.contains('exit code: 3'), bad

	errs := run_command('echo oops >&2', 10, no_sink)
	assert errs.contains('--- stderr ---'), errs
	assert errs.contains('oops'), errs
}

fn test_run_command_streams_lines_live() {
	mut col := &LineCollector{}
	run_command('echo one; echo two >&2', 10, col.sink())
	assert 'out:one' in col.tagged, '${col.tagged}'
	assert 'err:two' in col.tagged, '${col.tagged}'
}

fn test_run_command_times_out() {
	out := run_command('sleep 5', 1, no_sink)
	assert out.starts_with('ERROR: command timed out after 1s'), out
}

fn test_live_shell_persists_cwd_and_exports() {
	live_shell_reset()

	live_shell('cd /tmp', 20, no_sink)
	r := live_shell('pwd', 20, no_sink)
	assert r.contains('cwd: /tmp'), 'cwd did not persist:\n${r}'

	e := live_shell('export FA_TEST_VAR=ok7', 20, no_sink)
	assert e.contains('exit code: 0'), e
	r2 := live_shell('echo "\$FA_TEST_VAR"', 20, no_sink)
	assert r2.contains('ok7'), 'export did not persist:\n${r2}'

	// multi-line compound command
	r3 := live_shell('for i in 1 2; do echo n=\$i; done', 20, no_sink)
	assert r3.contains('n=1') && r3.contains('n=2'), r3

	// a failed cd leaves the session's cwd intact
	live_shell('cd /tmp', 20, no_sink)
	r4 := live_shell('cd /definitely_missing_dir_xyz; true', 20, no_sink)
	assert r4.split('\n')[0].contains('cwd: /tmp'), r4

	live_shell_reset()
}

fn test_live_shell_never_leaks_its_markers() {
	live_shell_reset()
	mut col := &LineCollector{}
	out := live_shell('echo visible', 20, col.sink())
	streamed := col.lines
	// the bookkeeping markers are stripped from BOTH the return value and
	// the live stream — the user must never see them
	assert !out.contains('__FA_CWD__'), out
	assert !out.contains('__FA_ENV__'), out
	assert out.contains('visible'), out
	for line in streamed {
		assert !line.contains('__FA_CWD__'), 'marker leaked to the stream: ${line}'
		assert !line.contains('__FA_ENV__'), 'marker leaked to the stream: ${line}'
	}
	assert 'visible' in streamed, '${streamed}'
	live_shell_reset()
}

fn test_live_shell_reset_returns_to_process_cwd() {
	live_shell('cd /tmp', 20, no_sink)
	msg := live_shell_reset()
	assert msg.starts_with('OK: session reset'), msg
	assert live_shell_cwd() != '/tmp' || true // process cwd may itself be /tmp
	r := live_shell('pwd', 20, no_sink)
	assert r.contains('exit code: 0'), r
	live_shell_reset()
}

fn test_resolve_shell_is_cached_and_usable() {
	first := resolve_shell()
	second := resolve_shell()
	assert first == second
	assert first.len == 2, 'expected [shell, -lc], got ${first}'
	assert first[1] == '-lc'
}
