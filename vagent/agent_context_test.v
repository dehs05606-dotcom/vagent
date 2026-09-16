module vagent

import os
import x.json2

fn ctx_agent(name string) (&Agent, string) {
	dir := os.join_path(os.temp_dir(), 'vagent-ctx-${name}-${os.getpid()}')
	os.rmdir_all(dir) or {}
	os.mkdir_all(dir) or { panic(err) }
	return new_agent_in(Config{}, AgentOpts{ home: dir, cwd: os.getwd() }), dir
}

fn user_msg(text string) Message {
	return Message{
		role:    'user'
		content: text
	}
}

fn assistant_msg(text string) Message {
	return Message{
		role:    'assistant'
		content: text
	}
}

fn tool_msg(id string, content string) Message {
	return Message{
		role:         'tool'
		tool_call_id: id
		content:      content
	}
}

fn calling_msg(name string, arguments string) Message {
	return Message{
		role:       'assistant'
		content:    ''
		tool_calls: [
			ToolCall{
				id:       'tc1'
				function: ToolCallFunction{
					name:      name
					arguments: arguments
				}
			},
		]
	}
}

fn test_a_giant_paste_is_capped_but_still_says_what_happened() {
	mut a, dir := ctx_agent('cap')
	defer {
		os.rmdir_all(dir) or {}
	}
	small := 'fix the parser'
	assert a.cap_user_message(small) == small

	huge := 'x'.repeat(a.fit_budget() * 2)
	capped := a.cap_user_message(huge)
	assert capped.len < huge.len
	// the model is told the text was cut and where the rest lives
	assert capped.contains('the kernel truncated this message')
	assert capped.contains('read_file/search_files')
	// and the cap is sealed, so the full length is on the record
	sealed := a.log.events('main').filter(it.typ == 'user.message.capped')
	assert sealed.len == 1
	assert jint(sealed[0].data, 'chars') == huge.len
}

fn test_nothing_is_compacted_while_it_all_fits() {
	mut a, dir := ctx_agent('fits')
	defer {
		os.rmdir_all(dir) or {}
	}
	a.messages << user_msg('hello')
	a.messages << assistant_msg('hi')
	before := a.messages.len
	a.maybe_compact()
	assert a.messages.len == before
	assert 'context.compacted' !in a.log.events('main').map(it.typ)
}

fn test_stale_tool_output_is_summarised_newest_first_kept() {
	mut a, dir := ctx_agent('tools')
	defer {
		os.rmdir_all(dir) or {}
	}
	// the agent already carries its seated system prompt, so the tools
	// start after it
	base := a.messages.len
	a.messages << user_msg('go')
	for i in 0 .. 4 {
		a.messages << tool_msg('t${i}', 'y'.repeat(2000))
	}
	first_tool := base + 1
	shortened := a.compact_old_tools(2)
	assert shortened == 2, shortened.str()
	// the two oldest were summarised, the two newest kept verbatim
	assert a.messages[first_tool].text().contains('truncated by the kernel')
	assert a.messages[first_tool + 1].text().contains('truncated by the kernel')
	assert a.messages[first_tool + 2].text().len == 2000
	assert a.messages[first_tool + 3].text().len == 2000
	// and a short output is left alone: summarising it would cost more
	// characters than it saves
	a.messages << tool_msg('t9', 'ok')
	assert a.compact_old_tools(0) == 2
	assert a.messages[first_tool + 4].text() == 'ok'
}

fn test_a_turn_is_dropped_whole_so_tool_pairing_survives() {
	mut a, dir := ctx_agent('drop')
	defer {
		os.rmdir_all(dir) or {}
	}
	a.messages = [
		Message{
			role:    'system'
			content: 'sys'
		},
		user_msg('first'),
		calling_msg('write_file', '{"path":"a.py"}'),
		tool_msg('tc1', 'OK: wrote 10 chars to a.py'),
		assistant_msg('done first'),
		user_msg('second'),
		assistant_msg('done second'),
	]
	assert a.drop_oldest_turn()
	// not `roles`: that is a module const, and V 0.5.2 generates broken C
	// for a local that shadows one
	msg_roles := a.messages.map(it.role)
	assert msg_roles == ['system', 'user', 'assistant'], msg_roles.str()
	assert a.messages[1].text() == 'second'
	// an orphaned tool response would make the next request fail outright
	assert a.messages.filter(it.role == 'tool').len == 0

	// the knowledge left a note behind
	assert a.compact_digests.len == 1
	assert a.compact_digests[0].contains('tools: write_file')
	assert a.compact_digests[0].contains('wrote: a.py')

	// with only one turn left there is nothing to drop
	assert !a.drop_oldest_turn()
}

fn test_the_digest_records_tools_writes_and_failures() {
	mut a, dir := ctx_agent('digest')
	defer {
		os.rmdir_all(dir) or {}
	}
	digest := a.digest_messages([
		calling_msg('edit_file', '{}'),
		tool_msg('tc1', 'OK: replaced foo in src/parser.py'),
		tool_msg('tc2', 'ERROR: file not found: missing.py'),
	])
	assert digest.contains('tools: edit_file')
	assert digest.contains('wrote: src/parser.py')
	// the original slices the text after 'ERROR:' without stripping, so
	// the space it leaves is part of the note
	assert digest.contains('hit:  file not found'), digest
	// a turn with nothing notable leaves no note rather than an empty one
	assert a.digest_messages([user_msg('hi'), assistant_msg('hello')]) == ''
}

fn test_the_oldest_assistant_message_is_trimmed_not_deleted() {
	mut a, dir := ctx_agent('trim')
	defer {
		os.rmdir_all(dir) or {}
	}
	a.messages = [
		Message{
			role:    'system'
			content: 'sys'
		},
		assistant_msg('z'.repeat(5000)),
		user_msg('next'),
		assistant_msg('short'),
	]
	a.trim_oldest_assistant(10)
	assert a.messages[1].text().len < 5000
	assert a.messages[1].text().contains('trimmed by the kernel')
	// the message survives as a stub: deleting it would orphan whatever
	// referred to it
	assert a.messages.len == 4
	assert a.messages[3].text() == 'short'
}

fn test_the_compaction_gate_skips_the_estimate_until_growth() {
	mut a, dir := ctx_agent('gate')
	defer {
		os.rmdir_all(dir) or {}
	}
	a.messages << user_msg('hello')
	a.maybe_compact()
	gate := a.compact_check_chars
	assert gate > 0
	// a tiny addition does not reset the gate, because re-estimating the
	// whole conversation for it would cost more than it saves
	a.messages << assistant_msg('ok')
	a.maybe_compact()
	assert a.compact_check_chars == gate
	// real growth does
	a.messages << assistant_msg('q'.repeat(gate * 2))
	a.maybe_compact()
	assert a.compact_check_chars > gate
}

fn test_an_overflow_shrink_reports_whether_anything_shrank() {
	mut a, dir := ctx_agent('overflow')
	defer {
		os.rmdir_all(dir) or {}
	}
	a.messages = [
		Message{
			role:    'system'
			content: 'sys'
		},
		user_msg('first'),
		tool_msg('tc1', 'w'.repeat(200000)),
		assistant_msg('one'),
		user_msg('second'),
		assistant_msg('two'),
	]
	assert a.overflow_shrink()
	// and once there is nothing left to give up it says so, rather than
	// letting the client retry forever
	mut tiny, dir2 := ctx_agent('overflow2')
	defer {
		os.rmdir_all(dir2) or {}
	}
	tiny.messages = [
		Message{
			role:    'system'
			content: 'sys'
		},
		user_msg('hi'),
	]
	assert !tiny.overflow_shrink()
}

fn test_the_fit_budget_leaves_room_for_a_reply() {
	mut a, dir := ctx_agent('budget')
	defer {
		os.rmdir_all(dir) or {}
	}
	budget := a.fit_budget()
	window := a.model().context_window
	assert budget > 0
	assert budget < window
	// the margin is the client's own: input plus the reservation must fit
	assert budget + 8192 + budget / 32 + 1024 <= window + 1
}

fn test_the_size_proxy_counts_what_the_model_will_be_sent() {
	mut a, dir := ctx_agent('proxy')
	defer {
		os.rmdir_all(dir) or {}
	}
	a.messages = [user_msg('abcde')]
	base := a.messages_chars()
	assert base == 5
	a.messages << calling_msg('write_file', '{"path":"a"}')
	// the tool call's name and arguments are part of what is sent
	assert a.messages_chars() == base + 'write_file'.len + '{"path":"a"}'.len
	a.messages << Message{
		role:      'assistant'
		content:   'x'
		reasoning: 'yy'
	}
	assert a.messages_chars() == base + 'write_file'.len + '{"path":"a"}'.len + 3
}

fn test_compaction_is_sealed_when_it_happens() {
	mut a, dir := ctx_agent('sealed')
	defer {
		os.rmdir_all(dir) or {}
	}
	a.messages = [Message{
		role:    'system'
		content: 'sys'
	}]
	// enough to genuinely exceed the window rather than merely look large
	bulk := 'p'.repeat(a.fit_budget() / 2)
	for i in 0 .. 12 {
		a.messages << user_msg('turn ${i}')
		a.messages << calling_msg('read_file', '{"path":"f${i}.py"}')
		a.messages << tool_msg('tc1', 'OK: wrote 10 chars to f${i}.py\n' + bulk)
		a.messages << assistant_msg('reply ${i}')
	}
	a.maybe_compact()
	sealed := a.log.events('main').filter(it.typ == 'context.compacted')
	assert sealed.len == 1, sealed.len.str()
	assert jint(sealed[0].data, 'units') > 0
	// truncating the stale tool outputs was enough here, so no turn was
	// dropped and no digest was needed — the passes escalate only as far
	// as they have to
	assert a.compact_digests.len == 0
	// the log still has everything: compaction is about the window only
	assert a.log.events('main').len > 0
}
