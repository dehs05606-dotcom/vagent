module vagent

import os
import x.json2

fn exec_agent(name string) (&Agent, string) {
	root := os.join_path(os.temp_dir(), 'vagent-exec-${name}-${os.getpid()}')
	os.rmdir_all(root) or {}
	os.mkdir_all(os.join_path(root, 'work')) or { panic(err) }
	mut cfg := Config{}
	cfg.auto_approve = true
	return new_agent_in(cfg, AgentOpts{
		home: os.join_path(root, 'home')
		cwd:  os.join_path(root, 'work')
	}), root
}

fn always_deny(tool &Tool, args map[string]json2.Any) bool {
	return false
}

fn always_allow(tool &Tool, args map[string]json2.Any) bool {
	return true
}

fn test_an_unknown_tool_names_what_is_available() {
	mut a, root := exec_agent('unknown')
	defer {
		os.rmdir_all(root) or {}
	}
	mut ev := ToolEvent{
		name: 'no_such_tool'
	}
	a.execute_tool(mut ev, ExecOpts{})
	assert ev.status == 'error'
	assert ev.result.contains("unknown tool 'no_such_tool'")
	assert ev.result.contains('read_file')
}

fn test_a_read_only_autonomy_refuses_every_mutation() {
	mut a, root := exec_agent('readonly')
	defer {
		os.rmdir_all(root) or {}
	}
	a.autonomy = 1
	target := os.join_path(a.cwd, 'x.txt')
	mut ev := ToolEvent{
		name: 'write_file'
		args: {
			'path':    json2.Any(target)
			'content': json2.Any('hello')
		}
	}
	a.execute_tool(mut ev, ExecOpts{})
	assert ev.status == 'blocked'
	assert ev.result.contains('read-only')
	// refused means it did not happen
	assert !os.exists(target)
	assert 'tool.blocked' in a.log.events('main').map(it.typ)
}

fn test_a_write_takes_a_snapshot_before_it_runs() {
	mut a, root := exec_agent('snapshot')
	defer {
		os.rmdir_all(root) or {}
	}
	a.autonomy = 5
	target := os.join_path(a.cwd, 'x.txt')
	os.write_file(target, 'before') or { panic(err) }

	mut ev := ToolEvent{
		name: 'write_file'
		args: {
			'path':    json2.Any(target)
			'content': json2.Any('after')
		}
	}
	a.execute_tool(mut ev, ExecOpts{})
	assert ev.status == 'done', ev.result
	assert os.read_file(target) or { '' } == 'after'

	// the recovery path was committed BEFORE the write, not after
	events := a.log.events('main')
	mut snap_seq := -1
	mut call_seq := -1
	for e in events {
		if e.typ == 'snapshot.taken' && snap_seq < 0 {
			snap_seq = e.seq
		}
		if e.typ == 'tool.call' && call_seq < 0 {
			call_seq = e.seq
		}
	}
	assert snap_seq >= 0, 'no snapshot was taken'
	assert call_seq >= 0
	assert snap_seq < call_seq, 'the snapshot must precede the call'
}

fn test_a_denied_action_does_not_run() {
	mut a, root := exec_agent('denied')
	defer {
		os.rmdir_all(root) or {}
	}
	a.autonomy = 2
	a.cfg.auto_approve = false
	target := os.join_path(a.cwd, 'x.txt')
	mut ev := ToolEvent{
		name: 'write_file'
		args: {
			'path':    json2.Any(target)
			'content': json2.Any('hello')
		}
	}
	a.execute_tool(mut ev, ExecOpts{ approve: always_deny })
	assert ev.status == 'denied'
	assert !os.exists(target)
}

fn test_with_nobody_to_ask_the_answer_is_no() {
	mut a, root := exec_agent('noask')
	defer {
		os.rmdir_all(root) or {}
	}
	a.autonomy = 2
	a.cfg.auto_approve = false
	target := os.join_path(a.cwd, 'x.txt')
	mut ev := ToolEvent{
		name: 'write_file'
		args: {
			'path':    json2.Any(target)
			'content': json2.Any('hello')
		}
	}
	// treating an absent human as a yes is how an unattended session does
	// the one thing it was supposed to ask about
	a.execute_tool(mut ev, ExecOpts{})
	assert ev.status == 'denied'
	assert !os.exists(target)
}

fn test_approval_lets_the_same_action_through() {
	mut a, root := exec_agent('approved')
	defer {
		os.rmdir_all(root) or {}
	}
	a.autonomy = 2
	a.cfg.auto_approve = false
	target := os.join_path(a.cwd, 'x.txt')
	mut ev := ToolEvent{
		name: 'write_file'
		args: {
			'path':    json2.Any(target)
			'content': json2.Any('hello')
		}
	}
	a.execute_tool(mut ev, ExecOpts{ approve: always_allow })
	assert ev.status == 'done', ev.result
	assert os.read_file(target) or { '' } == 'hello'
}

fn test_a_failure_twice_becomes_a_dead_end() {
	mut a, root := exec_agent('deadend')
	defer {
		os.rmdir_all(root) or {}
	}
	a.autonomy = 5
	missing := os.join_path(a.cwd, 'nope.txt')
	args := {
		'path': json2.Any(missing)
	}
	for _ in 0 .. 2 {
		mut ev := ToolEvent{
			name: 'read_file'
			args: args.clone()
		}
		a.execute_tool(mut ev, ExecOpts{})
		assert ev.status == 'error', ev.result
	}
	// the third attempt is refused by the ledger rather than re-run
	mut third := ToolEvent{
		name: 'read_file'
		args: args.clone()
	}
	a.execute_tool(mut third, ExecOpts{})
	assert third.status == 'blocked'
	assert third.result.contains('dead-end ledger')

	// and the healer classified the failure rather than only counting it
	assert a.healer.lessons().len > 0
}

fn test_a_failing_tool_is_reported_not_raised() {
	mut a, root := exec_agent('failing')
	defer {
		os.rmdir_all(root) or {}
	}
	a.autonomy = 5
	mut ev := ToolEvent{
		name: 'read_file'
		args: {
			'path': json2.Any(os.join_path(a.cwd, 'absent.txt'))
		}
	}
	a.execute_tool(mut ev, ExecOpts{})
	// a handler that reports 'ERROR: …' is an error, or the dead-end
	// ledger would never see the failures that actually happen
	assert ev.status == 'error'
	assert ev.result.starts_with('ERROR:')
	assert ev.duration >= 0
}

fn test_attribution_is_absent_without_a_goal() {
	mut a, root := exec_agent('attr')
	defer {
		os.rmdir_all(root) or {}
	}
	attribution := a.attribute('read_file')
	assert attribution.clause_id == ''
	assert attribution.orphan == ''
}

fn test_a_command_snapshots_the_tree_it_could_touch() {
	mut a, root := exec_agent('cmdsnap')
	defer {
		os.rmdir_all(root) or {}
	}
	for i in 0 .. 3 {
		os.write_file(os.join_path(a.cwd, 'f${i}.txt'), 'x') or { panic(err) }
	}
	paths := a.snapshot_paths('run_command', {
		'command': json2.Any('rm -f f0.txt')
	})
	// a command can touch anything, so its targets cannot be read off the
	// arguments the way a write's can
	assert paths.len == 3, paths.str()
	assert a.snapshot_paths('write_file', {
		'path': json2.Any('a.txt')
	}) == ['a.txt']
	assert a.snapshot_paths('copy_path', {
		'src': json2.Any('a')
		'dst': json2.Any('b')
	}) == ['a', 'b']
	assert a.snapshot_paths('read_file', {
		'path': json2.Any('a.txt')
	}) == []
}

fn test_a_delete_is_always_asked_about_at_pilot_level() {
	mut a, root := exec_agent('delete')
	defer {
		os.rmdir_all(root) or {}
	}
	a.autonomy = 4
	target := os.join_path(a.cwd, 'doomed.txt')
	os.write_file(target, 'x') or { panic(err) }
	// autonomy 4 auto-approves everything except a delete
	assert a.gate(&Tool{
		name:    'write_file'
		handler: inert_handler
	}, map[string]json2.Any{}) == ''
	assert a.gate(&Tool{
		name:    'delete_path'
		handler: inert_handler
	}, map[string]json2.Any{}) == 'ASK'
}

fn inert_handler(args map[string]json2.Any, sink OutputSink) string {
	return ''
}
