module vagent

import sync
import time
import x.json2

// crew.v — persistent, addressable subagents with a real lifecycle.
//
// The crew is the ONLY way to execute a subagent, and it manages them the
// way a lead engineer manages a roster of specialists:
//
//     spawn(task, role)   queue a subagent; returns immediately
//     send(id, message)   a follow-up into a living subagent's context
//     wait(ids, timeout)  block until the named subagents reach a verdict
//     close(id)           retire a subagent
//     resume(id)          bring a closed subagent back with its full context
//
// Each agent is a REAL agent: its own role brief, its own tool whitelist, its
// own multi-step tool loop, and its own message history that SURVIVES
// follow-up messages — so you iterate on a subagent instead of re-spawning
// from scratch. Context is the dividend of persistence.
//
// The hard rules are mechanical, the same discipline as the rest of the
// system:
//
//   * ONE serial execution queue. Subagents NEVER run concurrently; each
//     finishes before the next starts. Writes additionally pass through the
//     same global write lock as every other subsystem.
//   * Every lifecycle transition is sealed: crew.spawn, crew.progress,
//     crew.message, crew.done, crew.closed, crew.resumed. The whole crew
//     history is replayable.
//   * A failing subagent never kills the crew. It lands as an error report
//     and can still be sent a follow-up or closed.

pub const max_agents = max_workers // roster ceiling (queued + active)
pub const max_send_steps = 40 // tool-loop budget per follow-up message
const wait_poll = 50 * time.millisecond

// callsigns for the roster — an agent you can name is an agent you can talk
// about
const callsigns = ['nova', 'atlas', 'echo', 'lyra', 'orion', 'vega', 'iris', 'argo', 'sable', 'kepler',
	'juno', 'helix', 'drift', 'onyx', 'piper', 'quill']

pub const agent_states = ['running', 'done', 'blocked', 'error', 'closed']

const role_icon = {
	'researcher': '🔎'
	'coder':      '👨‍💻'
	'tester':     '🧪'
	'reviewer':   '🧐'
	'analyst':    '📊'
	'architect':  '🏛️'
	'debugger':   '🐞'
	'optimizer':  '⚡'
	'refactorer': '🧹'
	'documenter': '📝'
	'devops':     '🛠️'
	'integrator': '🔗'
	'planner':    '🗺️'
}

// the write tools — the ones that contend for the global write lock, and the
// ones a read-only subagent never gets
const crew_write_tools = ['write_file', 'edit_file', 'create_directory', 'run_command']

// CrewError marks an invalid lifecycle operation: an unknown id, a spawn at
// capacity, a send to a closed agent. It is distinct from a subagent's own
// failure, which is a report rather than an error.
pub struct CrewError {
	Error
pub:
	message string
}

pub fn (e CrewError) msg() string {
	return e.message
}

fn crew_error(message string) IError {
	return CrewError{
		message: message
	}
}

// -- one subagent -------------------------------------------------------------

// CrewAgent is one persistent subagent. The message history is the point: it
// survives follow-ups, so iteration never starts from zero.
@[heap]
pub struct CrewAgent {
pub mut:
	// Per-agent mutex.
	//
	// The crew's queue serialises the worker passes, but the SOVEREIGN
	// thread (the TUI, a workflow executor, the council) can call send,
	// close or resume while the worker sits between two loop steps.
	// Without this lock the worker reads state == 'running' and the
	// sovereign flips it to 'closed' a microsecond later: the worker then
	// enqueues a follow-up run for an already-retired agent, and the user
	// watches it ignore close() for one more iteration. Worse, the pending
	// message list is shared, so a pop from the worker interleaves with an
	// append from the sovereign and a follow-up is silently lost.
	mu               sync.Mutex
	id               string
	nickname         string
	role             string
	task             string
	state            string = 'running'
	summary          string
	error            string
	messages         []Message
	files_touched    []string
	tool_calls       int
	tokens_in        int
	tokens_out       int
	spawned_at       f64
	finished_at      f64
	pending_messages []string
	// a per-agent model override; empty means the crew default
	model_id string
	// the tool restriction survives follow-ups and resumes
	read_only bool
}

pub fn (a &CrewAgent) icon() string {
	return role_icon[a.role] or { '◆' }
}

pub fn (a &CrewAgent) elapsed_ms() int {
	end := if a.finished_at != 0 { a.finished_at } else { now_ts() }
	return int((end - a.spawned_at) * 1000.0)
}

pub fn (a &CrewAgent) to_json() map[string]json2.Any {
	mut files := a.files_touched.clone()
	if files.len > 12 {
		files = files[..12].clone()
	}
	return {
		'id':            json2.Any(a.id)
		'nickname':      json2.Any(a.nickname)
		'role':          json2.Any(a.role)
		'task':          json2.Any(a.task)
		'state':         json2.Any(a.state)
		'model':         json2.Any(a.model_id)
		'summary':       json2.Any(clip_plain(a.summary, 600))
		'error':         json2.Any(clip_plain(a.error, 300))
		'files_touched': json2.Any(strs_to_any(files))
		'tool_calls':    json2.Any(a.tool_calls)
		'tokens_in':     json2.Any(a.tokens_in)
		'tokens_out':    json2.Any(a.tokens_out)
		'elapsed_ms':    json2.Any(a.elapsed_ms())
	}
}

// -- the crew -----------------------------------------------------------------

// CrewChat is the model call, injectable so the tests run offline.
pub type CrewChat = fn (provider Provider, model Model, effort Effort, mut messages []Message, schemas []json2.Any, timeout f64) !StreamResult

struct CrewJob {
	agent     &CrewAgent
	read_only bool
	max_steps int
}

@[heap]
pub struct Crew {
pub mut:
	log        &EventLog
	provider   Provider
	model      Model
	effort     Effort
	mastermind &Mastermind = unsafe { nil }
	covenant   &Covenant   = unsafe { nil }
	max_agents int         = max_agents
	chat       CrewChat    = chat_with_retry
mut:
	// protects the roster
	mu       sync.Mutex
	agents   map[string]&CrewAgent
	order    []string
	name_idx int
	counter  int
	toolsets map[string]map[string]Tool
	jobs     chan CrewJob
	started  bool
}

pub fn new_crew(log &EventLog, provider Provider, model Model, effort Effort) &Crew {
	mut c := &Crew{
		log:      unsafe { log }
		provider: provider
		model:    model
		effort:   effort
		jobs:     chan CrewJob{ cap: 256 }
	}
	c.arm()
	return c
}

// arm carves the per-role tool whitelists out of the main registry.
//
// The registry is armed by the covenant BEFORE it is carved, because a
// subagent is bound by exactly the same specification as the sovereign agent.
// A worker must never be the way around a clause.
pub fn (mut c Crew) arm() {
	mut registry := build_registry()
	if c.covenant != unsafe { nil } {
		registry = c.covenant.arm(registry)
	}
	c.toolsets = map[string]map[string]Tool{}
	for role, spec in roles {
		mut set := map[string]Tool{}
		for name in spec.tools {
			if tool := registry[name] {
				set[name] = tool
			}
		}
		c.toolsets[role] = set.clone()
	}
	if !c.started {
		c.started = true
		spawn c.serve_queue()
	}
}

// serve_queue is the ONE serial executor: a single FIFO channel served by one
// thread, so subagents never overlap.
fn (mut c Crew) serve_queue() {
	for {
		job := <-c.jobs or { return }
		mut agent := job.agent
		if agent.state == 'closed' {
			// retired while still queued — never run it
			continue
		}
		c.run_loop(mut agent, job.read_only, job.max_steps)
	}
}

fn (mut c Crew) enqueue(agent &CrewAgent, read_only bool, max_steps int) {
	c.jobs <- CrewJob{
		agent:     unsafe { agent }
		read_only: read_only
		max_steps: max_steps
	}
}

// -- lifecycle ----------------------------------------------------------------

pub struct SpawnOpts {
pub:
	role      string = default_role
	name      string
	context   string
	read_only bool
	model_id  string
}

// spawn queues a subagent for serial execution and returns IMMEDIATELY.
//
// Agents run ONE AT A TIME in queue order; wait() collects each verdict when
// its turn comes. model_id optionally overrides the model THIS subagent uses
// — a cheap fast model for grunt work, the strongest model for the hard
// piece. An unknown id falls back to the crew default.
pub fn (mut c Crew) spawn(raw_task string, opts SpawnOpts) !&CrewAgent {
	task := raw_task.trim_space()
	if task == '' {
		return crew_error('cannot spawn a subagent without a task')
	}
	mut role := opts.role
	if !role_registry.has(role) {
		role = default_role
	}

	c.mu.lock()
	mut live := 0
	for _, a in c.agents {
		if a.state == 'running' {
			live++
		}
	}
	if live >= c.max_agents {
		c.mu.unlock()
		return crew_error('crew is at capacity (${c.max_agents} agents queued/running) — ' + 'wait for one to finish or close one')
	}
	c.counter++
	agent_id := 'crew-${c.counter}'
	mut nickname := opts.name.trim_space()
	if nickname == '' {
		nickname = callsigns[c.name_idx % callsigns.len]
		c.name_idx++
	}
	for {
		mut taken := false
		for _, a in c.agents {
			if a.nickname == nickname {
				taken = true
				break
			}
		}
		if !taken {
			break
		}
		nickname = '${nickname}-${c.counter}'
	}
	mut agent := &CrewAgent{
		id:         agent_id
		nickname:   nickname
		role:       role
		task:       task
		read_only:  opts.read_only
		spawned_at: now_ts()
	}
	if opts.model_id != '' {
		if override := model_by_id(opts.model_id) {
			agent.model_id = override.id
		}
	}
	c.agents[agent_id] = agent
	c.order << agent_id
	c.mu.unlock()

	user := if opts.context != '' {
		'Shared context:\n${opts.context}\n\nYOUR TASK: ${task}'
	} else {
		'YOUR TASK: ${task}'
	}
	if c.mastermind != unsafe { nil } {
		c.mastermind.gate.dispatch('worker:${role}', mut agent.messages, map[string]string{}, false) or {}
	} else {
		agent.messages = with_system(mut agent.messages, prompt_worker(role, c.max_agents))
	}
	agent.messages << Message{
		role:    'user'
		content: user
	}

	c.log.append('crew.spawn', {
		'id':        json2.Any(agent.id)
		'nickname':  json2.Any(agent.nickname)
		'role':      json2.Any(role)
		'task':      json2.Any(clip_plain(task, 300))
		'read_only': json2.Any(opts.read_only)
		'model':     json2.Any(if agent.model_id != '' { agent.model_id } else { c.model.id })
	}, AppendOpts{ actor: 'sovereign' })
	c.enqueue(agent, opts.read_only, max_worker_steps)
	return agent
}

// send is a follow-up into a subagent's LIVING context.
//
// A done, blocked or errored agent starts a new loop iteration with the
// message appended and its full history preserved. A running agent has the
// message queued and delivered the moment the current loop finishes;
// `interrupt` clears the pending summary so the follow-up takes priority in
// the next reply.
pub fn (mut c Crew) send(agent_id string, raw_message string, interrupt bool) !&CrewAgent {
	mut agent := c.require(agent_id)!
	message := raw_message.trim_space()
	if message == '' {
		return crew_error('cannot send an empty message')
	}
	// The whole critical section runs under the agent's mutex: the lock
	// keeps the worker from observing a half-written state (messages
	// appended before the state flips to running), and it serialises this
	// append with the worker's eventual pop.
	agent.mu.lock()
	defer {
		agent.mu.unlock()
	}
	if agent.state == 'closed' {
		return crew_error('agent ${agent_id} is closed — resume it first')
	}
	c.log.append('crew.message', {
		'id':        json2.Any(agent_id)
		'chars':     json2.Any(message.len)
		'interrupt': json2.Any(interrupt)
	}, AppendOpts{ actor: 'sovereign' })
	if agent.state == 'running' {
		agent.pending_messages << message
		return agent
	}
	if interrupt {
		agent.summary = ''
	}
	agent.messages << Message{
		role:    'user'
		content: 'FOLLOW-UP: ${message}'
	}
	agent.state = 'running'
	agent.error = ''
	// the spawn-time tool restriction is kept: a read-only subagent must
	// never gain write tools through a follow-up
	c.enqueue(agent, agent.read_only, max_send_steps)
	return agent
}

// wait blocks until the named subagents (all of them by default) leave the
// running state, or the timeout lands. It returns {id: state}.
pub fn (mut c Crew) wait(ids []string, timeout f64) !map[string]string {
	mut targets := []&CrewAgent{}
	if ids.len > 0 {
		for id in ids {
			targets << c.require(id)!
		}
	} else {
		for id in c.order {
			if a := c.agents[id] {
				targets << a
			}
		}
	}
	deadline := now_ts() + max_f64(0.0, timeout)
	for now_ts() < deadline {
		mut all_settled := true
		for a in targets {
			if a.state == 'running' {
				all_settled = false
				break
			}
		}
		if all_settled {
			break
		}
		time.sleep(wait_poll)
	}
	mut out := map[string]string{}
	for a in targets {
		out[a.id] = a.state
	}
	return out
}

// close retires a subagent. It keeps its history — resume() brings it back —
// but refuses sends while closed. It frees no slot, because only running
// agents occupy one.
pub fn (mut c Crew) close(agent_id string) !&CrewAgent {
	mut agent := c.require(agent_id)!
	if agent.state == 'closed' {
		return agent
	}
	prev := agent.state
	agent.state = 'closed'
	c.log.append('crew.closed', {
		'id':         json2.Any(agent_id)
		'prev_state': json2.Any(prev)
	}, AppendOpts{ actor: 'sovereign' })
	return agent
}

// resume brings a closed subagent back with its full context, so it can
// receive follow-ups again.
pub fn (mut c Crew) resume(agent_id string) !&CrewAgent {
	mut agent := c.require(agent_id)!
	if agent.state != 'closed' {
		return agent
	}
	agent.state = if agent.error == '' { 'done' } else { 'error' }
	c.log.append('crew.resumed', {
		'id': json2.Any(agent_id)
	}, AppendOpts{ actor: 'sovereign' })
	return agent
}

// -- queries ------------------------------------------------------------------

pub fn (mut c Crew) get(agent_id string) ?&CrewAgent {
	return c.agents[agent_id] or { return none }
}

pub fn (mut c Crew) list() []&CrewAgent {
	mut out := []&CrewAgent{}
	for id in c.order {
		if a := c.agents[id] {
			out << a
		}
	}
	return out
}

pub fn (mut c Crew) running() []&CrewAgent {
	return c.list().filter(it.state == 'running')
}

fn (mut c Crew) require(agent_id string) !&CrewAgent {
	if a := c.agents[agent_id] {
		return a
	}
	known := if c.order.len > 0 { c.order.join(', ') } else { 'none' }
	return crew_error("unknown subagent '${agent_id}' (known: ${known})")
}

pub fn (mut c Crew) status() map[string]json2.Any {
	agents := c.list()
	mut counts := map[string]int{}
	for state in agent_states {
		counts[state] = 0
	}
	mut tool_calls := 0
	mut tokens_in := 0
	mut tokens_out := 0
	for a in agents {
		counts[a.state] = counts[a.state] + 1
		tool_calls += a.tool_calls
		tokens_in += a.tokens_in
		tokens_out += a.tokens_out
	}
	return {
		'total':      json2.Any(agents.len)
		'running':    json2.Any(counts['running'])
		'done':       json2.Any(counts['done'])
		'blocked':    json2.Any(counts['blocked'])
		'error':      json2.Any(counts['error'])
		'closed':     json2.Any(counts['closed'])
		'tool_calls': json2.Any(tool_calls)
		'tokens_in':  json2.Any(tokens_in)
		'tokens_out': json2.Any(tokens_out)
	}
}

fn state_glyph(state string) string {
	return match state {
		'done' { '✓' }
		'blocked' { '◐' }
		'error' { '✗' }
		'closed' { '⊘' }
		'running' { '…' }
		else { '?' }
	}
}

// format is the compact multi-line report — the shape handed back to the
// model.
pub fn (mut c Crew) format(agents []&CrewAgent) string {
	if agents.len == 0 {
		return 'crew is empty — spawn a subagent first'
	}
	mut lines := []string{}
	for a in agents {
		model_tag := if a.model_id != '' && a.model_id != c.model.id {
			' · ${a.model_id}'
		} else {
			''
		}
		lines << '${a.icon()} [${a.id}] ${a.nickname} (${a.role}) ${state_glyph(a.state)} ' + '${a.state} · ${a.tool_calls} tools${model_tag} · ${a.elapsed_ms()}ms'
		lines << '  task: ${clip_plain(a.task, 200)}'
		if a.files_touched.len > 0 {
			mut head := a.files_touched.clone()
			if head.len > 8 {
				head = head[..8].clone()
			}
			lines << '  files: ' + head.join(', ')
		}
		if a.error != '' {
			lines << '  error: ${clip_plain(a.error, 200)}'
		}
		if a.summary != '' {
			lines << '  ' + clip_plain(a.summary.replace('\n', '\n  '), 1200)
		}
	}
	return lines.join('\n')
}

pub fn (mut c Crew) format_all() string {
	return c.format(c.list())
}

pub fn (mut c Crew) format_status() string {
	s := c.status()
	mut lines := [
		'CREW — ${jint(s, 'total')} subagent(s): ${jint(s, 'running')} running · ' + '${jint(s, 'done')} done · ${jint(s, 'error')} error · ${jint(s, 'closed')} closed',
	]
	for a in c.list() {
		lines << '  ${a.icon()} [${a.id}] ${a.nickname} (${a.role}) — ' + '${a.state}: ${clip_plain(a.task, 70)}'
	}
	return lines.join('\n')
}

// -- the worker loop ----------------------------------------------------------

// run_loop is one subagent's bounded tool loop. It never fails outward: every
// failure lands in the agent's own report and is sealed as crew.done.
fn (mut c Crew) run_loop(mut agent CrewAgent, read_only bool, max_steps int) {
	if agent.state == 'closed' {
		return
	}
	spec := role_spec(agent.role)
	mut tools := (c.toolsets[agent.role] or { map[string]Tool{} }).clone()
	if read_only {
		for name in crew_write_tools {
			tools.delete(name)
		}
	}
	// A per-agent model override resolves its own provider: the schemas must
	// follow the model that will actually serve this agent rather than the
	// crew default, because tool support differs between models.
	mut model := c.model
	if agent.model_id != '' {
		if override := model_by_id(agent.model_id) {
			model = override
		}
	}
	provider := providers[model.provider] or { c.provider }
	mut schemas := []json2.Any{}
	if model.supports_tools {
		mut names := tools.keys()
		names.sort()
		for name in names {
			if t := tools[name] {
				schemas << json2.Any(t.openai_schema())
			}
		}
	}

	mut final := ''
	mut failure := ''
	for step in 0 .. max_steps {
		result := c.chat(provider, model, c.effort, mut agent.messages, schemas, 120.0) or {
			failure = err.msg()
			break
		}
		if result.has_usage {
			agent.tokens_in += jint(result.usage, 'prompt_tokens')
			agent.tokens_out += jint(result.usage, 'completion_tokens')
		}
		final = result.content
		if result.tool_calls.len == 0 {
			break
		}
		agent.messages << assistant_message(result.content, result.tool_calls, result.reasoning)
		mut tool_names := []string{}
		for tc in result.tool_calls {
			name := tc.function.name
			args := parse_tool_arguments(tc.function.arguments)
			agent.tool_calls++
			tool_names << name
			mut out := ''
			if tool := tools[name] {
				// writes serialise across ALL workers, crew and team alike
				locked := spec.writes && name in crew_write_tools
				if locked {
					acquire_write_lock()
				}
				out = tool.handler(args, no_sink)
				if locked {
					release_write_lock()
				}
				if name in ['write_file', 'edit_file'] && out.starts_with('OK') {
					p := jstr(args, 'path')
					if p != '' && p !in agent.files_touched {
						agent.files_touched << p
					}
				}
			} else {
				mut available := tools.keys()
				available.sort()
				out = "ERROR: tool '${name}' is not available to a ${agent.role} subagent. " + 'Available: ' + available.join(', ')
			}
			agent.messages << Message{
				role:         'tool'
				tool_call_id: tc.id
				content:      clip(out, 6000)
			}
		}
		if step % 2 == 0 {
			mut head := tool_names.clone()
			if head.len > 6 {
				head = head[..6].clone()
			}
			c.log.append('crew.progress', {
				'id':    json2.Any(agent.id)
				'step':  json2.Any(step + 1)
				'tools': json2.Any(strs_to_any(head))
			}, AppendOpts{ actor: 'crew:${agent.id}' })
		}
	}

	if agent.state == 'closed' {
		// retired mid-loop — keep the closed state, never resurrect it
		return
	}
	if failure != '' {
		// a failing subagent never kills the crew
		agent.state = 'error'
		agent.error = failure
	} else {
		state, summary := parse_worker_final(final)
		agent.summary = clip_plain(summary, max_summary_chars)
		agent.state = if state in ['done', 'blocked'] { state } else { 'done' }
		if final.trim_space() == '' {
			agent.error = 'subagent returned an empty reply'
			agent.state = 'error'
		}
	}
	agent.finished_at = now_ts()

	// deliver a follow-up that arrived mid-loop — to the back of the SAME
	// serial queue, so nothing ever overlaps
	agent.mu.lock()
	if agent.pending_messages.len > 0 && agent.state != 'closed' {
		queued := agent.pending_messages[0]
		agent.pending_messages.delete(0)
		agent.messages << Message{
			role:    'user'
			content: 'FOLLOW-UP: ${queued}'
		}
		agent.state = 'running'
		agent.finished_at = 0.0
		agent.mu.unlock()
		c.enqueue(agent, read_only, max_send_steps)
		return
	}
	agent.mu.unlock()
	c.log.append('crew.done', agent.to_json(), AppendOpts{ actor: 'crew:${agent.id}' })
}
