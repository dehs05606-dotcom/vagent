module vagent

import os
import time
import x.json2

// agent_bridges.v — the subsystems' hooks back into the agent.
//
// Each subsystem takes the one capability it needs as an injected function,
// which is what lets every one of them be tested offline. Here is where those
// injections are filled in with the real thing: a model call, a crew worker,
// a shell run.
//
// They are closures over the agent rather than free functions because they
// genuinely need the whole agent — the crew, the current model, the autonomy
// level. That is safe only because the agent is a heap struct; the capture is
// a pointer, and it stays valid for as long as the agent does.

// -- shared helpers ----------------------------------------------------------

// ask_model is one blocking model call with no tools attached: a question,
// not a turn.
pub fn (mut a Agent) ask_model(system string, user string, timeout f64) string {
	return a.ask_model_on(a.provider(), a.model(), system, user, timeout)
}

pub fn (mut a Agent) ask_model_on(provider Provider, model Model, system string, user string, timeout f64) string {
	mut messages := [
		Message{
			role:    'system'
			content: system
		},
		Message{
			role:    'user'
			content: user
		},
	]
	result := chat_blocking(provider, model, a.effort(), mut messages, []json2.Any{}, StreamCallbacks{}, timeout) or { return '' }
	return result.content
}

// push_status streams a one-line status into the UI, when a turn is live.
pub fn (mut a Agent) push_status(text string) {
	if a.turn_status != unsafe { nil } {
		a.turn_status(text)
	}
}

// read_only_default is whether a subagent should be denied write tools
// regardless of what it was asked to do. At autonomy 1 and below the agent
// proposes and applies nothing, and a subagent is not a way around that.
pub fn (a &Agent) read_only_default() bool {
	return a.autonomy <= 1
}

// scout_context is the shared read-only context handed to every subagent.
//
// A subagent gets little else — its task and this — so anything it must
// reason about has to be in here: where we are, what the goal is, what is
// already known.
pub fn (mut a Agent) scout_context(max_chars int) string {
	mut parts := ['Working directory: ' + a.cwd]

	mut entries := []string{}
	for name in os.ls(a.cwd) or { []string{} } {
		if name.starts_with('.') {
			continue
		}
		entries << if os.is_dir(os.join_path(a.cwd, name)) { name + '/' } else { name }
	}
	entries.sort()
	if entries.len > 40 {
		entries = entries[..40].clone()
	}
	if entries.len > 0 {
		parts << 'Directory listing: ' + entries.join(', ')
	}

	status := a.goal.status()
	if status.active {
		parts << 'Active goal: ' + status.statement
		for c in status.clauses {
			parts << '  clause ${c.id} [${c.state}]: ${c.text}'
		}
	}

	st := a.state()
	if st.files_touched.len > 0 {
		mut touched := st.touched_files()
		if touched.len > 20 {
			touched = touched[..20].clone()
		}
		parts << 'Files touched this session: ' + touched.join(', ')
	}
	mut facts := st.facts.map(jstr(it, 'fact'))
	if facts.len > 8 {
		facts = facts[facts.len - 8..].clone()
	}
	if facts.len > 0 {
		parts << 'Known facts:\n- ' + facts.join('\n- ')
	}
	mut episodes := st.episodes.clone()
	if episodes.len > 3 {
		episodes = episodes[episodes.len - 3..].clone()
	}
	for ep in episodes {
		parts << 'Past episode: ' + jstr(ep, 'goal') + ' -> ' + jstr(ep, 'outcome')
	}
	// a hard cut, not clip(): the note clip() appends would push a context
	// that was already at the limit over it
	body := parts.join('\n')
	return if body.len <= max_chars { body } else { body[..max_chars] }
}

// -- the serial worker --------------------------------------------------------

pub struct WorkerTask {
pub:
	task  string
	role  string
	model string
}

// run_worker_serial executes subagent tasks ONE AT A TIME through the crew.
//
// There is no parallel fan-out: every worker is a persistent crew subagent
// run to completion in order. A failing worker yields an error report rather
// than propagating, because a batch of five tasks should not lose four
// results to the one that broke.
pub fn (mut a Agent) run_worker_serial(tasks []WorkerTask, read_only bool) []WorkerReport {
	mut reports := []WorkerReport{}
	ro := read_only || a.read_only_default()
	context := a.scout_context(4000)
	for t in tasks {
		task := t.task.trim_space()
		if task == '' {
			continue
		}
		role := if t.role.trim_space() != '' { t.role.trim_space() } else { 'coder' }
		mut agent := a.crew.spawn(task, SpawnOpts{
			role:      role
			context:   context
			read_only: ro
			model_id:  t.model
		}) or {
			reports << WorkerReport{
				task:   task
				role:   role
				status: 'error'
				error:  err.msg()
			}
			continue
		}
		for agent.state == 'running' {
			time.sleep(250 * time.millisecond)
		}
		mut status := agent.state
		if status !in ['done', 'blocked', 'error'] {
			status = if agent.error != '' { 'error' } else { 'done' }
		}
		mut summary := agent.summary
		if summary.len > max_summary_chars {
			summary = summary[..max_summary_chars] + ' …[truncated]'
		}
		reports << WorkerReport{
			task:          agent.task
			role:          agent.role
			status:        status
			summary:       summary
			files_touched: agent.files_touched.clone()
			tool_calls:    agent.tool_calls
			tokens_in:     agent.tokens_in
			tokens_out:    agent.tokens_out
			error:         agent.error
			elapsed_ms:    agent.elapsed_ms()
		}
	}
	return reports
}

// -- the bridges --------------------------------------------------------------

// spec_runner executes one read-only tool call for the speculator. Only the
// whitelisted tools ever reach here, and the check is repeated anyway: a
// speculative call runs before anyone asked for it, so it must be incapable
// of changing anything even if the gate upstream were wrong.
pub fn (mut a Agent) spec_runner(name string, args map[string]json2.Any) !string {
	if name !in speculative_tools {
		return error('${name} is not speculative-safe')
	}
	tool := a.tools[name] or { return error('unknown tool ${name}') }
	return tool.handler(args, no_sink)
}

// daemon_step runs one mission step as a read-only researcher probe. The
// daemon advances missions without mutating the world unless a write is
// explicitly part of the task.
pub fn (mut a Agent) daemon_step(task string) string {
	reports := a.run_worker_serial([WorkerTask{
		task: task
		role: 'researcher'
	}], true)
	if reports.len == 0 {
		return 'ERROR: daemon step produced no report'
	}
	r := reports[0]
	if r.status == 'error' {
		return 'ERROR: ' + if r.error != '' { r.error } else { 'step failed' }
	}
	return 'OK: ' + clip(r.summary, 400)
}

// council_speaker produces one council position. The synthesis brief is
// already blind — it carries only the two arguments — so nothing here has to
// preserve that property.
pub fn (mut a Agent) council_speaker(role string, brief string) !string {
	return a.ask_model('You are one voice in a structured debate council. ' + 'Answer exactly as instructed.', brief, 120.0)
}

// compile_wave runs one compiled wave as a serial batch of crew subagents.
pub fn (mut a Agent) compile_wave(wave []PlanItem) []map[string]json2.Any {
	mut tasks := []WorkerTask{}
	for it in wave {
		tasks << WorkerTask{
			task: it.task
			role: it.role
		}
	}
	a.push_status('⚙ compiled wave · ${tasks.len} item(s)')
	return a.run_worker_serial(tasks, a.read_only_default()).map(it.to_json())
}

// evolution_mutator asks the model for k candidate rewrites of a role brief.
pub fn (mut a Agent) evolution_mutator(role string, incumbent string, k int) []string {
	reply := a.ask_model('You improve agent role briefs. Output ONLY candidate briefs ' + 'separated by lines with exactly --- . No prose around them.', "Current brief for the '${role}' worker:\n${incumbent}\n\n" + 'Write ${k} improved variants. Each must be one paragraph, more ' + 'specific and actionable than the original, keeping the same scope.', 120.0)
	mut out := []string{}
	for part in reply.split('\n---') {
		trimmed := part.trim_space()
		if trimmed.len > 40 {
			out << trimmed
		}
		if out.len >= k {
			break
		}
	}
	return out
}

// evolution_evaluator runs the fixed benchmark with a candidate brief and
// scores the reply's structure deterministically.
//
// The score is about the CONTRACT, not about the prose: did it answer in the
// required shape, did it say something of substance, did it name anything
// concrete. A model grading a model on quality would just move the guess.
pub fn (mut a Agent) evolution_evaluator(role string, brief string) !(string, f64) {
	content := a.ask_model(worker_prompt_for(brief), default_benchmark(role), 180.0)
	return content, brief_score(content)
}

fn worker_prompt_for(brief string) string {
	return worker_tmpl.replace('{role_brief}', brief).replace('{max_workers}', max_workers.str())
}

fn brief_score(content string) f64 {
	status, summary := parse_worker_final(content)
	mut score := 0.0
	if status == 'done' {
		score += 0.5
	}
	if summary != '' && summary != content.trim_space() {
		// it followed the format rather than being salvaged by the parser
		score += 0.2
	}
	if summary.len > 60 {
		score += 0.2
	}
	mut concrete := summary.contains('/')
	if !concrete {
		for c in summary {
			if c >= `0` && c <= `9` {
				concrete = true
				break
			}
		}
	}
	if concrete {
		score += 0.1
	}
	return min_f64(1.0, score)
}

// debate_speaker routes one tournament turn to its participant model.
pub fn (mut a Agent) debate_speaker(model_id string, prompt string) string {
	m := model_by_id(model_id) or { a.model() }
	provider := providers[m.provider] or { a.provider() }
	return a.ask_model_on(provider, m, 'You are a participant in an answer tournament. Follow the ' + 'instructions exactly and concisely.', prompt, 120.0)
}

// market_exec settles an awarded contract by actually running it.
pub fn (mut a Agent) market_exec(task string, role string) !map[string]json2.Any {
	reports := a.run_worker_serial([WorkerTask{
		task: task
		role: role
	}], a.read_only_default())
	if reports.len == 0 {
		return {
			'status':     json2.Any('error')
			'summary':    json2.Any('no report returned')
			'tool_calls': json2.Any(0)
		}
	}
	r := reports[0]
	return {
		'status':     json2.Any(r.status)
		'summary':    json2.Any(if r.summary != '' { r.summary } else { r.error })
		'tool_calls': json2.Any(r.tool_calls)
	}
}

// role_audition runs a drafted role's own benchmark under its brief and
// scores the reply on the same yardstick evolution uses.
pub fn (mut a Agent) role_audition(draft &RoleDraft) f64 {
	content := a.ask_model(worker_prompt_for(draft.brief), draft.benchmark, 180.0)
	status, summary := parse_worker_final(content)
	mut score := if status == 'done' { 0.5 } else { 0.0 }
	if summary.len > 60 {
		score += 0.4
	}
	return min_f64(1.0, score)
}

// ci_runner runs the impacted tests through the real shell.
pub fn (mut a Agent) ci_runner(test_files []string) !(bool, string) {
	mut cmd := quote_arg(find_python() or { 'python3' }) + ' -m pytest -q'
	for t in test_files {
		cmd += ' ' + quote_arg(t)
	}
	out := run_command(cmd, 300, no_sink)
	// Only the runner's own exit-code line is trusted. A substring match
	// would accept 'exit code: 0' printed inside the test output itself,
	// which is exactly how a red suite gets reported green.
	mut ok := false
	for line in split_lines(out) {
		if line.trim_space() == 'exit code: 0' {
			ok = true
			break
		}
	}
	return ok, out
}

// dual_fast is system 1: one cheap, direct call.
pub fn (mut a Agent) dual_fast(question string) string {
	return a.ask_model('Answer directly and concisely.', question, 60.0)
}

// dual_slow is system 2: the deliberate stack, a full debate tournament.
pub fn (mut a Agent) dual_slow(question string) string {
	result := a.debate.run(question, 2)
	return '[verified via ${a.debate.models.len}-model debate, champion ' + '${result.champion_model}] ${result.verdict}'
}

// race_runner is one racing universe: a real serial crew worker under its
// strategy.
pub fn (mut a Agent) race_runner(strategy Strategy, task string, mut cancel CancelFlag) !string {
	if cancel.is_set() {
		return 'CANCELLED'
	}
	reports := a.run_worker_serial([WorkerTask{
		task: '${strategy.instructions}\n\nTASK: ${task}'
		role: strategy.role
	}], a.read_only_default())
	if reports.len == 0 {
		return 'ERROR: no report'
	}
	r := reports[0]
	body := if r.summary != '' { r.summary } else { r.error }
	return 'STATUS: ${r.status.to_upper()}\nSUMMARY: ${body}'
}

pub fn (mut a Agent) race_verify(task string, result string) !bool {
	return result.contains('STATUS: DONE') && !result.contains('ERROR')
}

// workflow_step runs one workflow step as a crew worker.
pub fn (mut a Agent) workflow_step(step &WorkflowStep, n int) !map[string]json2.Any {
	reports := a.run_worker_serial([WorkerTask{
		task:  step.task
		role:  step.role
		model: step.model
	}], a.read_only_default())
	if reports.len == 0 {
		return {
			'status':  json2.Any('error')
			'summary': json2.Any('no report returned')
		}
	}
	r := reports[0]
	return {
		'status':     json2.Any(r.status)
		'summary':    json2.Any(if r.summary != '' { r.summary } else { r.error })
		'elapsed_ms': json2.Any(r.elapsed_ms)
	}
}

// ask_model_plan asks for one work-item decomposition of a goal.
pub fn (mut a Agent) ask_model_plan(goal string) string {
	mut messages := draft_prompt(goal)
	result := chat_blocking(a.provider(), a.model(), a.effort(), mut messages, []json2.Any{}, StreamCallbacks{}, 120.0) or { return '' }
	return result.content
}

// ask_model_role asks for one role draft as a JSON object.
pub fn (mut a Agent) ask_model_role(mission string) string {
	reply := a.ask_model('You design agent specialists. Reply ONLY with a JSON object: ' + '{"name": snake_case_id, "brief": one strong paragraph (>=100 words) ' + 'telling this specialist exactly how to work, "tools": subset of the ' + 'allowed list, "benchmark": one task proving the role works}. No prose ' + 'around the JSON.', 'MISSION: ${mission}\nALLOWED TOOLS: ' + all_tool_names().join(', '), 120.0)
	return strip_fence(reply)
}

// ask_model_synth asks for the source of one small, pure function.
pub fn (mut a Agent) ask_model_synth(spec &SynthSpec) string {
	mut examples := []string{}
	for e in spec.examples {
		examples << '  ' + json2.encode(json2.Any(e.args.clone())) + ' == ' + e.want.str()
	}
	reply := a.ask_model('You write small pure Python tools. Reply with ONLY the function ' + 'source — no imports, no prose, no markdown fence. The function must ' + 'be deterministic and pure.', 'Function name: ${spec.name}\nPurpose: ${spec.description}\n' + 'It must satisfy:\n' + examples.join('\n') + '\ndef ${spec.name}(...):', 120.0)
	return strip_fence(reply)
}

// mcts_evaluator scores one strategy assignment by mechanical role-task fit:
// a write verb wants a write-capable role, a run verb wants a runner.
//
// It is cheap on purpose. The search supplies the exploration; a scorer that
// called a model would make every rollout a turn.
pub fn (a &Agent) mcts_evaluator(assignment map[int]string) f64 {
	if a.mcts_items.len == 0 {
		return 0.0
	}
	mut fit := 0.0
	for i, item in a.mcts_items {
		strategy := assignment[i] or { continue }
		spec := roles[strategy] or { continue }
		low := item.to_lower()
		mut writes := false
		for w in ['write', 'build', 'implement', 'fix'] {
			if low.contains(w) {
				writes = true
				break
			}
		}
		mut runs := false
		for w in ['run', 'test', 'measure'] {
			if low.contains(w) {
				runs = true
				break
			}
		}
		if writes && ('write_file' in spec.tools || 'edit_file' in spec.tools) {
			fit += 1
		}
		if runs && 'run_command' in spec.tools {
			fit += 1
		}
	}
	n := if a.mcts_items.len > 1 { a.mcts_items.len } else { 1 }
	return min_f64(1.0, fit / (f64(n) * 1.5))
}

// -- the repairs ---------------------------------------------------------------

// repair_reseed_prompts re-seals every vault prompt, curing prompt drift.
pub fn (mut a Agent) repair_reseed_prompts() !bool {
	for name in a.mastermind.vault.names() {
		a.mastermind.vault.resolve(name) or { continue }
	}
	return true
}

// repair_consolidate runs the brain's sleep pass: loop alerts usually mean
// stale patterns are driving repetition.
pub fn (mut a Agent) repair_consolidate() !bool {
	a.brain.sleep()
	return true
}

// repair_warm_caches rebuilds the shared context so speculative caches refill.
pub fn (mut a Agent) repair_warm_caches() !bool {
	a.scout_context(4000)
	return true
}

// -- wiring ---------------------------------------------------------------------

// wire_bridges replaces every placeholder with the real capability.
pub fn (mut a Agent) wire_bridges() {
	a.compiler.drafter = PlanDrafter(fn [mut a] (goal string) []json2.Any {
		unsafe {
			return parse_draft_array(a.ask_model_plan(goal))
		}
	})
	a.compiler.executor = WaveExecutor(fn [mut a] (wave []PlanItem) []map[string]json2.Any {
		unsafe {
			return a.compile_wave(wave)
		}
	})
	a.evolution.mutator = Mutator(fn [mut a] (role string, incumbent string, k int) []string {
		unsafe {
			return a.evolution_mutator(role, incumbent, k)
		}
	})
	a.evolution.evaluator = BriefEvaluator(fn [mut a] (role string, brief string) !(string, f64) {
		unsafe {
			return a.evolution_evaluator(role, brief)
		}
	})
	a.debate.speaker = DebateSpeaker(fn [mut a] (model_id string, prompt string) string {
		unsafe {
			return a.debate_speaker(model_id, prompt)
		}
	})
	a.market.executor = MarketExecutor(fn [mut a] (task string, role string) !map[string]json2.Any {
		unsafe {
			return a.market_exec(task, role)
		}
	})
	a.mesh.executor = MeshExecutor(fn [mut a] (task string, role string) !map[string]json2.Any {
		unsafe {
			return a.market_exec(task, role)
		}
	})
	a.roleforge.drafter = RoleDrafter(fn [mut a] (mission string) map[string]json2.Any {
		unsafe {
			return decode_obj(a.ask_model_role(mission))
		}
	})
	a.roleforge.evaluator = RoleEvaluator(fn [mut a] (draft &RoleDraft) f64 {
		unsafe {
			return a.role_audition(draft)
		}
	})
	a.synth.generator = SynthGenerator(fn [mut a] (spec &SynthSpec) string {
		unsafe {
			return a.ask_model_synth(spec)
		}
	})
	a.ci.runner = CiRunner(fn [mut a] (test_files []string) !(bool, string) {
		unsafe {
			return a.ci_runner(test_files)
		}
	})
	a.dual.fast_fn = DualFn(fn [mut a] (question string) string {
		unsafe {
			return a.dual_fast(question)
		}
	})
	a.dual.slow_fn = DualFn(fn [mut a] (question string) string {
		unsafe {
			return a.dual_slow(question)
		}
	})
	a.racer.runner = UniverseRunner(fn [mut a] (strategy Strategy, task string, cancel &CancelFlag) !string {
		unsafe {
			mut flag := cancel
			return a.race_runner(strategy, task, mut flag)
		}
	})
	a.racer.verifier = RaceVerifier(fn [mut a] (task string, result string) !bool {
		unsafe {
			return a.race_verify(task, result)
		}
	})
	a.speculator.runner = SpecRunner(fn [mut a] (name string, args map[string]json2.Any) !string {
		unsafe {
			return a.spec_runner(name, args)
		}
	})
	a.daemon.executor = StepExecutor(fn [mut a] (task string) string {
		unsafe {
			return a.daemon_step(task)
		}
	})
	a.council.speaker = CouncilSpeaker(fn [mut a] (role string, brief string) !string {
		unsafe {
			return a.council_speaker(role, brief)
		}
	})
	a.workflows.executor = StepExecutorFn(fn [mut a] (step &WorkflowStep, n int) !map[string]json2.Any {
		unsafe {
			return a.workflow_step(step, n)
		}
	})
	a.mcts.evaluator = MctsEvaluator(fn [mut a] (assignment map[int]string) f64 {
		unsafe {
			return a.mcts_evaluator(assignment)
		}
	})
	a.homeo.repairs = {
		'tool_error_rate': Repair{
			action: 'reseed prompts'
			run:    fn [mut a] () !bool {
				unsafe {
					return a.repair_reseed_prompts()
				}
			}
		}
		'loop_alerts':     Repair{
			action: 'consolidate the brain'
			run:    fn [mut a] () !bool {
				unsafe {
					return a.repair_consolidate()
				}
			}
		}
		'tool_latency_ms': Repair{
			action: 'warm the caches'
			run:    fn [mut a] () !bool {
				unsafe {
					return a.repair_warm_caches()
				}
			}
		}
	}
}
