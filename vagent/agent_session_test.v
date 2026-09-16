module vagent

import os
import x.json2

fn session_agent(name string) (&Agent, string) {
	root := os.join_path(os.temp_dir(), 'vagent-sess-${name}-${os.getpid()}')
	os.rmdir_all(root) or {}
	os.mkdir_all(os.join_path(root, 'work')) or { panic(err) }
	mut cfg := Config{}
	cfg.auto_approve = true
	mut a := new_agent_in(cfg, AgentOpts{
		home: os.join_path(root, 'home')
		cwd:  os.join_path(root, 'work')
	})
	a.autonomy = 5
	return a, root
}

fn test_the_autonomy_ladder_clamps_at_both_ends() {
	mut a, root := session_agent('autonomy')
	defer {
		os.rmdir_all(root) or {}
	}
	assert a.set_autonomy(3).contains('Collaborator')
	assert a.autonomy == 3
	a.set_autonomy(-4)
	assert a.autonomy == 0
	a.set_autonomy(99)
	assert a.autonomy == 5
	assert a.log.events('main').filter(it.typ == 'autonomy.changed').len == 3
}

fn test_focus_stops_when_the_turn_failed() {
	mut a, root := session_agent('focusfail')
	defer {
		os.rmdir_all(root) or {}
	}
	failed := Turn{
		user_text: 'x'
		error:     'PAUSED — budget exceeded'
	}
	if _ := a.focus_continue(&failed, 5) {
		assert false, 'focus must not continue past a failed turn'
	}
	stops := a.log.events('main').filter(it.typ == 'focus.stop')
	assert stops.len == 1
	assert jstr(stops[0].data, 'reason').contains('budget exceeded')
}

fn test_focus_stops_when_the_agent_says_it_is_done_twice() {
	mut a, root := session_agent('focusdone')
	defer {
		os.rmdir_all(root) or {}
	}
	answered := Turn{
		user_text: 'x'
	}
	// one answer with no tool work is not a verdict; two in a row is the
	// agent saying it believes itself finished
	first := a.focus_continue(&answered, 5) or { '' }
	assert first.contains('CONTINUE — deep-work mode (5 turns left)')
	if _ := a.focus_continue(&answered, 4) {
		assert false, 'two idle answers must stop the loop'
	}
	assert a.log.events('main').filter(it.typ == 'focus.stop').len == 1
	// and the history is cleared, so a later focus run starts fresh
	assert a.focus_history.len == 0
}

fn test_focus_keeps_going_while_tools_are_still_running() {
	mut a, root := session_agent('focuswork')
	defer {
		os.rmdir_all(root) or {}
	}
	worked := Turn{
		user_text: 'x'
		tools:     [
			ToolEvent{
				name:   'read_file'
				status: 'done'
			},
		]
	}
	for i in 0 .. 4 {
		prompt := a.focus_continue(&worked, 10 - i) or {
			assert false, 'work in progress must not stop the loop'
			''
		}
		assert prompt.contains('CONTINUE')
	}
	assert a.log.events('main').filter(it.typ == 'focus.tick').len == 4
}

fn test_a_session_catalog_lists_every_branch_newest_first() {
	mut a, root := session_agent('catalog')
	defer {
		os.rmdir_all(root) or {}
	}
	first := a.sessions_catalog()
	assert first.len == 1
	assert first[0].branch == 'main'
	assert first[0].session_id == a.session_id
	assert first[0].events > 0

	branch := a.fork_timeline('side')
	catalog := a.sessions_catalog()
	assert catalog.len == 2
	assert catalog.map(it.branch).contains(branch)
	// the newest session sorts first
	assert catalog[0].started >= catalog[1].started
}

fn test_resuming_a_branch_rebuilds_only_the_visible_conversation() {
	mut a, root := session_agent('resume')
	defer {
		os.rmdir_all(root) or {}
	}
	a.log.append('user.message', {
		'text': json2.Any('hello')
	}, AppendOpts{ actor: 'human' })
	a.log.append('assistant.message', {
		'text': json2.Any('hi there')
	}, AppendOpts{ actor: 'sovereign' })
	a.log.append('tool.call', {
		'name': json2.Any('read_file')
	}, AppendOpts{})

	kept := a.resume_session('main') or { panic(err) }
	assert kept == 2, kept.str()
	// the system prompt is re-seated ahead of the rebuilt conversation
	assert a.messages[0].role == 'system'
	assert a.messages[1].text() == 'hello'
	assert a.messages[2].text() == 'hi there'
	// the full history is still in the log — only the window was rebuilt
	assert 'tool.call' in a.log.events('main').map(it.typ)
	assert 'session.resumed' in a.log.events('main').map(it.typ)

	a.resume_session('no-such-branch') or {
		assert err.msg().contains('unknown branch')
		return
	}
	assert false, 'an unknown branch must be refused'
}

fn test_rewind_returns_the_files_and_the_state() {
	mut a, root := session_agent('rewind')
	defer {
		os.rmdir_all(root) or {}
	}
	target := os.join_path(a.cwd, 'x.txt')
	os.write_file(target, 'original') or { panic(err) }

	mut ev := ToolEvent{
		name: 'write_file'
		args: {
			'path':    json2.Any(target)
			'content': json2.Any('changed')
		}
	}
	a.execute_tool(mut ev, ExecOpts{})
	assert ev.status == 'done', ev.result
	assert os.read_file(target) or { '' } == 'changed'
	after_write := a.log.head('main')

	new_head, kept := a.rewind_to(after_write - 2)
	// the file came back
	assert os.read_file(target) or { '' } == 'original'
	// rewinding is itself an event, so the head advances rather than
	// shrinking: history is never destroyed, only re-pointed
	assert 'kernel.rewind' in a.log.events('main').map(it.typ)
	assert new_head >= 0
	assert kept >= 0
	// and the branch still verifies after the surgery
	ok, msg := a.log.verify('main')
	assert ok, msg
}

fn test_revert_returns_the_files_and_keeps_the_memory() {
	mut a, root := session_agent('revert')
	defer {
		os.rmdir_all(root) or {}
	}
	target := os.join_path(a.cwd, 'x.txt')
	os.write_file(target, 'original') or { panic(err) }
	mut ev := ToolEvent{
		name: 'write_file'
		args: {
			'path':    json2.Any(target)
			'content': json2.Any('changed')
		}
	}
	a.execute_tool(mut ev, ExecOpts{})
	head_before := a.log.head('main')

	result := a.revert_files_to(head_before - 2)
	assert jstr(result, 'error') == '', result.str()
	assert os.read_file(target) or { '' } == 'original'
	// the files went back; the history did not
	assert a.log.head('main') > head_before
	assert 'kernel.revert' in a.log.events('main').map(it.typ)
	assert 'tool.call' in a.log.events('main').map(it.typ)

	// a seq with no snapshot before it says so rather than pretending
	missing := a.revert_files_to(-1)
	assert jstr(missing, 'error').contains('no snapshot')
}

fn test_a_session_is_saved_atomically_and_reread() {
	mut a, root := session_agent('save')
	defer {
		os.rmdir_all(root) or {}
	}
	a.messages << Message{
		role:    'user'
		content: 'remember this'
	}
	path := a.save_session() or { panic('the session was not saved') }
	assert os.is_file(path)
	saved := decode_obj(os.read_file(path) or { '' })
	assert jstr(saved, 'session_id') == a.session_id
	assert jarr(saved, 'messages').len == a.messages.len
	// no torn temp file was left behind
	assert !os.exists(path + '.tmp')
}

fn test_a_report_is_written_where_the_work_is() {
	mut a, root := session_agent('report')
	defer {
		os.rmdir_all(root) or {}
	}
	md := a.export_report('md') or { panic(err) }
	assert md.starts_with(a.cwd)
	assert md.ends_with('.md')
	assert (os.read_file(md) or { '' }).contains('FullAgent session ${a.session_id}')

	html := a.export_report('html') or { panic(err) }
	assert html.ends_with('.html')
	assert (os.read_file(html) or { '' }).starts_with('<!DOCTYPE html>')
	assert a.log.events('main').filter(it.typ == 'report.exported').len == 2

	assert a.get_forecast().contains('measured, not guessed')
}
