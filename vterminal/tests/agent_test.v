module main

import os
import src.agent
import src.config
import src.context
import src.memory
import src.model
import src.security
import src.tools
import src.tui
import src.utils

// Script is the mutable half of the fake provider. The Provider interface takes
// an immutable receiver, so the recorded state lives behind a pointer.
@[heap]
struct Script {
mut:
	turns []model.Response
	calls int
	// seen records the request each turn received, so the test can assert on
	// what the loop actually sent back to the model.
	seen []model.Request
}

// ScriptedProvider replays a fixed list of model turns. It makes the agent loop
// testable end to end — tool dispatch, message threading, budget enforcement —
// without touching the network.
struct ScriptedProvider {
	state &Script
}

fn (p &ScriptedProvider) name() string {
	return 'scripted'
}

fn (p &ScriptedProvider) model_id() string {
	return 'scripted-1'
}

fn (p &ScriptedProvider) context_limit() int {
	return 128000
}

fn (p &ScriptedProvider) chat(req model.Request, mut sink model.Sink) !model.Response {
	mut st := unsafe { p.state }
	st.seen << req
	idx := if st.calls < st.turns.len { st.calls } else { st.turns.len - 1 }
	st.calls++
	return st.turns[idx]
}

fn text_turn(content string) model.Response {
	return model.Response{
		content:       content
		finish_reason: 'stop'
	}
}

fn tool_turn(id string, name string, args string) model.Response {
	return model.Response{
		content:       ''
		finish_reason: 'tool_calls'
		tool_calls:    [
			model.ToolCall{
				id:        id
				name:      name
				arguments: args
			},
		]
	}
}

struct Harness {
mut:
	root   string
	ag     &agent.Agent
	script &Script
}

fn harness(name string, turns []model.Response, max_iterations int) Harness {
	root := os.join_path(os.temp_dir(), 'vagent_agent_${name}_${os.getpid()}')
	os.rmdir_all(root) or {}
	os.mkdir_all(root) or { panic(err) }

	mut log := utils.discard_logger()
	mut perms := security.new_engine(config.PermissionConfig{
		mode: 'allow'
	}, root, mut log)
	mut tctx := tools.Context{
		root:    root
		workdir: root
		log:     &log
	}
	tctx.probe_environment()
	mut reg := tools.new_registry(tctx, mut perms)
	reg.register_builtins()

	mut gw := model.new_gateway(config.ProviderConfig{
		name:      'scripted'
		base_url:  'https://scripted.invalid/v1'
		model:     'scripted-1'
		api_key:   'x'
		streaming: false
	}, mut log) or { panic(err) }
	script := &Script{
		turns: turns
	}
	gw.set_provider(ScriptedProvider{
		state: script
	})

	mut ui := tui.new_renderer(false, false, true, false)
	ui.interactive = false
	mut ag := agent.new_agent(agent.AgentOpts{
		cfg:       config.AgentConfig{
			max_iterations: max_iterations
		}
		perm_mode: 'allow'
		snapshot:  context.collect(root, root)
		pmem:      memory.load_project_memory(root)
		session:   memory.Session{
			id:   'test'
			root: root
			dir:  os.join_path(root, '.sessions')
		}
		limit:     128000
	}, mut gw, mut reg, mut ui, mut log)
	return Harness{
		root:   root
		ag:     ag
		script: script
	}
}

fn (mut h Harness) cleanup() {
	os.rmdir_all(h.root) or {}
}

fn test_loop_executes_a_tool_then_answers() {
	mut h := harness('basic', [
		tool_turn('c1', 'write_file', '{"path":"out.txt","content":"written by the agent"}'),
		text_turn('Done — created out.txt.'),
	], 10)
	defer { h.cleanup() }

	h.ag.run_turn('create out.txt') or { panic(err) }

	assert os.exists(os.join_path(h.root, 'out.txt'))
	assert os.read_file(os.join_path(h.root, 'out.txt')) or { '' } == 'written by the agent'
	// Two model turns: the tool request, then the answer.
	assert h.script.calls == 2
	assert h.ag.state.tool_calls == 1
}

fn test_tool_result_is_threaded_back_to_the_model() {
	mut h := harness('thread', [
		tool_turn('call-7', 'write_file', '{"path":"x.txt","content":"hi"}'),
		text_turn('done'),
	], 10)
	defer { h.cleanup() }
	h.ag.run_turn('write x.txt') or { panic(err) }

	// The second request must carry: system, user, assistant(tool_calls), tool.
	second := h.script.seen[1]
	last := second.messages[second.messages.len - 1]
	assert last.role == .tool
	assert last.tool_call_id == 'call-7'
	assert last.name == 'write_file'
	assert last.content.contains('created x.txt')

	prev := second.messages[second.messages.len - 2]
	assert prev.role == .assistant
	assert prev.tool_calls.len == 1
	assert prev.tool_calls[0].id == 'call-7'
}

fn test_failed_tool_result_is_reported_not_fatal() {
	mut h := harness('toolfail', [
		tool_turn('c1', 'read_file', '{"path":"missing.txt"}'),
		text_turn('That file does not exist.'),
	], 10)
	defer { h.cleanup() }
	h.ag.run_turn('read missing.txt') or { panic(err) }

	second := h.script.seen[1]
	last := second.messages[second.messages.len - 1]
	assert last.role == .tool
	assert last.content.contains('file not found')
	assert h.ag.state.failures == 1
}

fn test_repeated_identical_failure_gets_a_stop_instruction() {
	// The same bad call three times: the loop must tell the model to stop
	// rather than let it burn the whole iteration budget.
	mut h := harness('repeat', [
		tool_turn('c1', 'read_file', '{"path":"nope.txt"}'),
		tool_turn('c2', 'read_file', '{"path":"nope.txt"}'),
		tool_turn('c3', 'read_file', '{"path":"nope.txt"}'),
		text_turn('giving up'),
	], 10)
	defer { h.cleanup() }
	h.ag.run_turn('read nope.txt') or { panic(err) }

	mut found := false
	for m in h.ag.state.messages {
		if m.role == .tool && m.content.contains('Stop retrying it') {
			found = true
		}
	}
	assert found, 'the loop should inject a stop-retrying instruction'
}

fn test_iteration_budget_stops_a_runaway_loop() {
	// A provider that only ever asks for another tool call.
	mut h := harness('runaway', [
		tool_turn('c', 'list_directory', '{"path":"."}'),
	], 3)
	defer { h.cleanup() }
	h.ag.run_turn('loop forever') or { panic(err) }

	// 3 iterations, plus the final tool-free summary request.
	assert h.script.calls == 4
	assert h.ag.state.iterations == 3
	last_req := h.script.seen[h.script.seen.len - 1]
	assert last_req.tools.len == 0, 'the closing summary request must disable tools'
}

fn test_chat_mode_sends_no_tools() {
	mut h := harness('chatmode', [text_turn('just talking')], 5)
	defer { h.cleanup() }
	h.ag.set_mode(.chat)
	h.ag.run_turn('hello') or { panic(err) }

	assert h.script.seen[0].tools.len == 0
	// The system prompt still has to say why the tools are absent.
	assert h.script.seen[0].messages[0].role == .system
	assert h.script.seen[0].messages[0].content.contains('Mode: CHAT')
}

fn test_agent_mode_sends_the_tool_schema() {
	mut h := harness('agentmode', [text_turn('ok')], 5)
	defer { h.cleanup() }
	h.ag.run_turn('hello') or { panic(err) }
	assert h.script.seen[0].tools.len > 5
	assert h.script.seen[0].messages[0].content.contains('Mode: AGENT')
}

fn test_update_plan_becomes_visible_state() {
	mut h := harness('planstate', [
		tool_turn('c1', 'update_plan', '{"steps":["read","patch","test"],"active":2}'),
		text_turn('working on it'),
	], 10)
	defer { h.cleanup() }
	h.ag.run_turn('do a three step task') or { panic(err) }

	plan := h.ag.plan()
	assert plan.len == 3
	assert plan[1].title == 'patch'
	assert plan[1].status == 'active'
}

fn test_clear_resets_the_conversation_and_plan() {
	mut h := harness('clear', [
		tool_turn('c1', 'update_plan', '{"steps":["a","b"],"active":1}'),
		text_turn('done'),
	], 10)
	defer { h.cleanup() }
	h.ag.run_turn('go') or { panic(err) }
	assert h.ag.plan().len == 2
	assert h.ag.state.user_visible_messages() > 0

	h.ag.clear()
	assert h.ag.plan().len == 0
	assert h.ag.state.user_visible_messages() == 0
}
