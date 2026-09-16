module vagent

import os
import x.json2

// A cassette is how the original runs a turn with no network, and it is how
// these tests do it too: the request is keyed by its exact content, so the
// recorded reply is served only if the whole request matched.
fn taped_agent(name string) (&Agent, string) {
	root := os.join_path(os.temp_dir(), 'vagent-turn-${name}-${os.getpid()}')
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

// tape_reply records one reply against the agent's CURRENT request shape, so
// the following turn replays it.
fn tape_reply(mut a Agent, root string, response map[string]json2.Any) {
	path := os.join_path(root, 'tape.jsonl')
	mut recorder := new_cassette(path, 'record') or { panic(err) }
	recorder.record(a.model().id, a.messages, a.tool_schemas(), response, a.effort().key)
	a.cassette = new_cassette(path, 'replay') or { panic(err) }
}

fn plain_reply(text string) map[string]json2.Any {
	return {
		'content':    json2.Any(text)
		'reasoning':  json2.Any('')
		'tool_calls': json2.Any([]json2.Any{})
		'usage':      json2.Any({
			'prompt_tokens':     json2.Any(120)
			'completion_tokens': json2.Any(30)
		})
	}
}

fn tool_reply(name string, arguments string) map[string]json2.Any {
	return {
		'content':    json2.Any('')
		'reasoning':  json2.Any('')
		'tool_calls': json2.Any([
			json2.Any({
				'id':       json2.Any('call-1')
				'type':     json2.Any('function')
				'function': json2.Any({
					'name':      json2.Any(name)
					'arguments': json2.Any(arguments)
				})
			}),
		])
		'usage':      json2.Any({
			'prompt_tokens':     json2.Any(80)
			'completion_tokens': json2.Any(12)
		})
	}
}

// run_taped seats the prompt exactly as run_turn will, tapes the reply
// against that request, and then runs the turn.
fn run_taped(mut a Agent, root string, user_text string, response map[string]json2.Any) Turn {
	// mirror run_turn's own preparation so the recorded key matches
	route := a.autopilot.route(user_text, a.goal.status().active, a.autonomy)
	a.reseat_system_prompt(a.context_sections(route, user_text), true)
	mut probe := a.messages.clone()
	probe << Message{
		role:    'user'
		content: a.cap_user_message(user_text)
	}
	path := os.join_path(root, 'tape.jsonl')
	mut recorder := new_cassette(path, 'record') or { panic(err) }
	recorder.record(a.model().id, probe, a.tool_schemas(), response, a.effort().key)
	a.cassette = new_cassette(path, 'replay') or { panic(err) }
	return a.run_turn(user_text, TurnCallbacks{})
}

fn test_a_plain_reply_completes_a_turn_and_is_sealed() {
	mut a, root := taped_agent('plain')
	defer {
		os.rmdir_all(root) or {}
	}
	turn := run_taped(mut a, root, 'say hello', plain_reply('hello there'))

	assert turn.error == '', turn.error
	assert turn.assistant_text.contains('hello there'), turn.assistant_text
	assert turn.tools.len == 0
	assert turn.duration >= 0
	assert a.turns.len == 1

	types := a.log.events('main').map(it.typ)
	assert 'user.message' in types
	assert 'assistant.message' in types
	assert 'cost.incurred' in types
	assert 'turn.scorecard' in types

	// the spend was recorded from the reply, not guessed
	cost := a.log.events('main').filter(it.typ == 'cost.incurred')
	assert jint(cost[0].data, 'tokens_in') == 120
	assert jint(cost[0].data, 'tokens_out') == 30
}

fn test_the_whole_user_text_reaches_the_log() {
	mut a, root := taped_agent('fulltext')
	defer {
		os.rmdir_all(root) or {}
	}
	// long enough to be a real paste, short enough that the test is about
	// the logging rather than about the cap (which agent_context_test
	// covers directly)
	long := 'the parser fails on nested quotes. '.repeat(400)
	run_taped(mut a, root, long, plain_reply('got it'))

	sealed := a.log.events('main').filter(it.typ == 'user.message')
	assert sealed.len == 1
	// the log keeps everything; only the window was ever the constraint
	assert jstr(sealed[0].data, 'text').len == long.len
}

fn test_a_tool_call_runs_and_its_result_goes_back_to_the_model() {
	mut a, root := taped_agent('tool')
	defer {
		os.rmdir_all(root) or {}
	}
	target := os.join_path(a.cwd, 'note.txt')
	os.write_file(target, 'on disk') or { panic(err) }

	// the first request gets a tool call; the second — with the tool
	// result appended — gets the final answer
	route := a.autopilot.route('read the note', a.goal.status().active, a.autonomy)
	a.reseat_system_prompt(a.context_sections(route, 'read the note'), true)
	mut probe := a.messages.clone()
	probe << Message{
		role:    'user'
		content: 'read the note'
	}
	path := os.join_path(root, 'tape.jsonl')
	mut recorder := new_cassette(path, 'record') or { panic(err) }
	args := '{"path": ' + json2.Any(target).json_str() + '}'
	recorder.record(a.model().id, probe, a.tool_schemas(), tool_reply('read_file', args), a.effort().key)

	// build the follow-up request exactly as the loop will
	mut after := probe.clone()
	after << assistant_message('', [
		ToolCall{
			id:       'call-1'
			function: ToolCallFunction{
				name:      'read_file'
				arguments: args
			}
		},
	], '')
	tool_out := read_file_tool_output(mut a, target)
	after << Message{
		role:         'tool'
		tool_call_id: 'call-1'
		content:      tool_out
	}
	recorder.record(a.model().id, after, a.tool_schemas(), plain_reply('the note says: on disk'), a.effort().key)
	a.cassette = new_cassette(path, 'replay') or { panic(err) }

	turn := a.run_turn('read the note', TurnCallbacks{})
	assert turn.error == '', turn.error
	assert turn.tools.len == 1
	assert turn.tools[0].name == 'read_file'
	assert turn.tools[0].status == 'done', turn.tools[0].result
	assert turn.assistant_text.contains('the note says'), turn.assistant_text

	types := a.log.events('main').map(it.typ)
	assert 'tool.call' in types
	assert 'tool.result' in types
	// the scorecard counted the call
	assert jint(turn.scorecard, 'tool_calls') == 1
	assert jint(turn.scorecard, 'errors') == 0
	assert jint(turn.scorecard, 'score') == 100
}

fn read_file_tool_output(mut a Agent, path string) string {
	tool := a.tools['read_file'] or { panic('no read_file tool') }
	return tool.handler({
		'path': json2.Any(path)
	}, no_sink)
}

fn test_a_replay_miss_is_a_hard_error_not_a_live_call() {
	mut a, root := taped_agent('miss')
	defer {
		os.rmdir_all(root) or {}
	}
	path := os.join_path(root, 'tape.jsonl')
	os.write_file(path, '') or { panic(err) }
	a.cassette = new_cassette(path, 'replay') or { panic(err) }

	turn := a.run_turn('anything at all', TurnCallbacks{})
	// falling back to the network here would make the replay
	// non-deterministic, which is the whole point of a cassette
	assert turn.error.contains('cassette replay miss'), turn.error
	assert 'turn.error' in a.log.events('main').map(it.typ)
	// the unanswered user message was taken back off the conversation
	assert a.messages.filter(it.role == 'user').len == 0
}

fn test_a_cancelled_turn_keeps_what_was_already_said() {
	mut a, root := taped_agent('cancel')
	defer {
		os.rmdir_all(root) or {}
	}
	turn := a.run_turn('do something long', TurnCallbacks{ should_cancel: always_cancel })
	assert turn.error == 'cancelled'
	assert 'turn.cancelled' in a.log.events('main').map(it.typ)
	// the conversation ends on an assistant message rather than a dangling
	// user one
	assert a.messages[a.messages.len - 1].role == 'assistant'
	assert a.messages[a.messages.len - 1].text() == '(cancelled by user)'
}

fn always_cancel() bool {
	return true
}

fn test_the_scorecard_measures_rather_than_judges() {
	mut a, root := taped_agent('score')
	defer {
		os.rmdir_all(root) or {}
	}
	mut turn := Turn{
		user_text: 'x'
		duration:  1.5
		tools:     [
			ToolEvent{
				name:   'write_file'
				args:   {
					'path': json2.Any('a.py')
				}
				status: 'done'
			},
			ToolEvent{
				name:   'write_file'
				args:   {
					'path': json2.Any('a.py')
				}
				status: 'done'
			},
			ToolEvent{
				name:   'read_file'
				status: 'error'
			},
		]
	}
	card := a.score_turn(mut turn)
	assert jint(card, 'tool_calls') == 3
	assert jint(card, 'errors') == 1
	// the same file written twice in one turn is rework
	assert jint(card, 'rework_files') == 1
	assert jint(card, 'score') == 70
	assert jf64(card, 'duration') == 1.5
	assert turn.scorecard.len > 0
}

fn test_the_notifier_cursor_moves_even_with_no_sink() {
	mut a, root := taped_agent('notify')
	defer {
		os.rmdir_all(root) or {}
	}
	a.log.append('goal.closed', {
		'state': json2.Any('ACHIEVED')
	}, AppendOpts{})
	a.flush_notifications()
	// switching a sink on later must not replay the whole session at it
	assert a.notify_seq == a.log.head('main')
}

fn test_a_failover_is_refused_when_the_error_is_not_an_outage() {
	mut a, root := taped_agent('failover')
	defer {
		os.rmdir_all(root) or {}
	}
	// a 401 is a bad key, not a provider outage; cycling models would only
	// spend the budget proving it
	if _ := a.failover_candidate(401) {
		assert false, 'a 401 must not trigger a failover'
	}
	// a 503 is
	if _ := a.failover_candidate(503) {
	} else {
		assert false, 'a 503 should offer a candidate'
	}
	// and only once per turn
	a.failed_over = true
	if _ := a.failover_candidate(503) {
		assert false, 'at most one failover per turn'
	}
}
