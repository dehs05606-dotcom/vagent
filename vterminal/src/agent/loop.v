module agent

import src.config
import src.context
import src.memory
import src.model
import src.tools
import src.tui
import src.utils

// Agent is the runtime: it owns the conversation and drives the
// observe → plan → act → verify → reflect cycle.
//
// The cycle is not a set of separate model calls. It is one loop in which the
// model proposes tool calls, this code executes them under policy, and the
// results are fed back as observations. Verification is a first-class step
// because the model's claim that something works is not evidence that it does.
@[heap]
pub struct Agent {
pub mut:
	state     State
	snapshot  context.Snapshot
	pmem      memory.ProjectMemory
	session   memory.Session
	ctxman    context.Manager
	cfg       config.AgentConfig
	perm_mode string
mut:
	gateway  &model.Gateway  = unsafe { nil }
	registry &tools.Registry = unsafe { nil }
	ui       &tui.Renderer   = unsafe { nil }
	log      &utils.Logger   = unsafe { nil }
}

pub struct AgentOpts {
pub:
	cfg       config.AgentConfig
	perm_mode string
	snapshot  context.Snapshot
	pmem      memory.ProjectMemory
	session   memory.Session
	limit     int
}

pub fn new_agent(opts AgentOpts, mut gw model.Gateway, mut reg tools.Registry, mut ui tui.Renderer, mut log utils.Logger) &Agent {
	return &Agent{
		cfg:       opts.cfg
		perm_mode: opts.perm_mode
		snapshot:  opts.snapshot
		pmem:      opts.pmem
		session:   opts.session
		ctxman:    context.Manager{
			limit: opts.limit
		}
		gateway:   unsafe { &gw }
		registry:  unsafe { &reg }
		ui:        unsafe { &ui }
		log:       unsafe { &log }
	}
}

pub fn (mut a Agent) set_mode(m tui.Mode) {
	a.state.mode = m
}

pub fn (a &Agent) mode() tui.Mode {
	return a.state.mode
}

pub fn (a &Agent) plan() []tools.PlanStep {
	return a.registry.ctx.plan
}

pub fn (a &Agent) context_tokens() int {
	return a.ctxman.estimate(a.state.messages)
}

// prime installs the system prompt before the first turn.
pub fn (mut a Agent) prime() {
	a.refresh_system()
}

// refresh_system rebuilds the system prompt for the current mode and project
// state. Cheap enough to do every turn, and it keeps a long session from
// drifting on a stale snapshot.
fn (mut a Agent) refresh_system() {
	prompt := build_system(a.state.mode, &a.snapshot, &a.pmem, a.registry.specs(),
		a.cfg.system_prompt_extra, a.perm_mode)
	a.state.set_system(prompt)
}

// run_turn processes one user request to completion: it keeps calling the
// model and executing the tools it asks for until the model answers without
// requesting another tool, or until a budget runs out.
pub fn (mut a Agent) run_turn(input string) ! {
	a.state.task = input
	a.state.turn++
	a.state.interrupted = false
	a.refresh_system()
	a.state.push(model.user_msg(input))

	plan_before := a.plan().len
	mut iterations := 0
	for {
		if iterations >= a.cfg.max_iterations {
			a.ui.warn('stopped after ${iterations} iterations (agent.max_iterations). The task may be incomplete; re-run to continue.')
			a.state.push(model.user_msg('[iteration budget reached; summarise what is done, what is left, and stop calling tools]'))
			a.finish_with_summary()!
			break
		}
		iterations++
		a.state.iterations++

		a.compact_if_needed()

		resp := a.one_model_turn()!
		a.record_assistant(resp)

		if resp.tool_calls.len == 0 {
			break
		}
		a.execute_calls(resp.tool_calls)
	}

	a.ui.end_turn()
	if a.plan().len > 0 && a.plan().len != plan_before {
		a.ui.plan(a.plan())
	}
	a.session.turns++
	a.session.save(a.state.messages)
}

// one_model_turn performs a single request, streaming into the renderer.
fn (mut a Agent) one_model_turn() !model.Response {
	mut ui := a.ui
	mut printed_prefix := false
	mut sink := model.Sink{}
	if a.gateway.streaming() {
		sink.on_text = fn [mut ui, mut printed_prefix] (chunk string) {
			if !printed_prefix {
				printed_prefix = true
				ui.assistant_prefix()
			}
			ui.stream_text(chunk)
		}
		sink.on_reasoning = fn [mut ui] (chunk string) {
			ui.thinking(chunk)
		}
	}
	req := model.Request{
		messages: a.state.messages
		tools:    if a.state.mode == .chat { [] } else { a.registry.schema() }
		stream:   a.gateway.streaming()
	}
	resp := a.gateway.chat(req, mut sink) or {
		a.ui.break_stream()
		return err
	}
	if !a.gateway.streaming() && resp.content.trim_space() != '' {
		a.ui.assistant_prefix()
		a.ui.assistant_text(resp.content)
	}
	a.ui.break_stream()
	return resp
}

fn (mut a Agent) record_assistant(resp model.Response) {
	a.state.push(model.Message{
		role:       .assistant
		content:    resp.content
		tool_calls: resp.tool_calls
	})
	if a.log != unsafe { nil } {
		a.log.debug('assistant turn: ${resp.content.len} chars, ${resp.tool_calls.len} tool call(s), finish=${resp.finish_reason}')
	}
}

// execute_calls runs every tool the model asked for, in order, and appends one
// tool message per call. Every call must produce a reply message: a missing
// tool result is a protocol error that breaks the next request.
fn (mut a Agent) execute_calls(calls []model.ToolCall) {
	for call in calls {
		summary := a.call_summary(call)
		a.ui.tool_start(call.name, summary)
		res := a.registry.execute(call.name, call.arguments)
		a.state.tool_calls++
		a.ui.tool_result(res)

		mut payload := if res.ok { res.output } else { res.output }
		if !res.ok {
			fingerprint := '${call.name}:${call.arguments}'
			repeats := a.state.note_failure(fingerprint)
			if repeats >= a.cfg.max_tool_retries + 1 {
				payload += '\n\n[This identical call has now failed ${repeats} times. Stop retrying it. Either investigate why it fails with a different tool, or explain the blocker to the user.]'
			}
		} else {
			a.state.note_success()
		}
		a.state.push(model.tool_msg(call.id, call.name, payload))
	}
	// The plan lives in the tool context; re-render it as soon as it changes.
	if a.plan().len > 0 {
		a.ui.plan(a.plan())
	}
}

fn (a &Agent) call_summary(call model.ToolCall) string {
	t := a.registry.get(call.name) or { return utils.truncate(call.arguments, 100) }
	args := utils.parse_object(call.arguments) or { return utils.truncate(call.arguments, 100) }
	return tools.summarize(t.spec(), args)
}

// finish_with_summary asks for a closing statement with tools disabled, so a
// budget-exhausted turn still ends with something useful rather than silence.
fn (mut a Agent) finish_with_summary() ! {
	mut sink := model.Sink{}
	mut ui := a.ui
	if a.gateway.streaming() {
		sink.on_text = fn [mut ui] (chunk string) {
			ui.stream_text(chunk)
		}
	}
	a.ui.assistant_prefix()
	req := model.Request{
		messages: a.state.messages
		tools:    []
		stream:   a.gateway.streaming()
	}
	resp := a.gateway.chat(req, mut sink) or { return }
	if !a.gateway.streaming() {
		a.ui.assistant_text(resp.content)
	}
	a.state.push(model.Message{
		role:    .assistant
		content: resp.content
	})
}

// compact_if_needed keeps the conversation inside the context window without
// asking the user. It reports what it did, because silently losing history
// would make the agent's later behaviour inexplicable.
fn (mut a Agent) compact_if_needed() {
	if !a.ctxman.over_budget(a.state.messages) {
		return
	}
	messages, report := a.ctxman.compact(a.state.messages)
	a.state.messages = messages
	a.ui.info('  context compacted: ${utils.human_count(report.before_tokens)} -> ${utils.human_count(report.after_tokens)} tokens (${report.trimmed} trimmed, ${report.dropped} dropped)')
	if a.log != unsafe { nil } {
		a.log.info('auto-compaction ${report.before_tokens} -> ${report.after_tokens}')
	}
}

// compact_now is /compact: the same machinery, invoked deliberately.
pub fn (mut a Agent) compact_now() context.CompactionReport {
	messages, report := a.ctxman.compact(a.state.messages)
	a.state.messages = messages
	return report
}

// clear resets the conversation and the visible plan.
pub fn (mut a Agent) clear() {
	a.state.reset()
	a.registry.ctx.plan = []
	a.registry.ctx.read_files.clear()
}
