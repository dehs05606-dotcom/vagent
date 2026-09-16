module vagent

import os
import time
import x.json2

// agent_tools.v — the tools the agent registers on top of the base kit.
//
// The base registry in tools.v is the irreducible set: read, write, search,
// run, fetch. Everything here is a capability one of the subsystems already
// has, exposed to the model so it can reach for it directly instead of
// waiting to be told.
//
// Every handler is a closure over the agent. They are installed AFTER the
// covenant armed the base registry, and the container arms on insertion too,
// so a tool added here arrives bound to the boundary rather than needing to
// be armed again.

// declare is the shape every registration below shares: a name, a sentence
// the model reads, the argument schema, and the handler.
fn (mut a Agent) declare(name string, description string, properties map[string]json2.Any, required []string, risk string, handler ToolHandler) {
	a.tools[name] = a.covenant.arm_one(name, Tool{
		name:        name
		description: description
		parameters:  {
			'type':       json2.Any('object')
			'properties': json2.Any(properties)
			'required':   json2.Any(strs_to_any(required))
		}
		risk:        risk
		handler:     handler
	})
	// the schema cache is keyed on the registry size, so a registration
	// invalidates it by construction
	a.schemas_tool_count = -1
}

fn str_prop() json2.Any {
	return json2.Any({
		'type': json2.Any('string')
	})
}

fn int_prop() json2.Any {
	return json2.Any({
		'type': json2.Any('integer')
	})
}

fn bool_prop() json2.Any {
	return json2.Any({
		'type': json2.Any('boolean')
	})
}

pub fn (mut a Agent) register_all_tools() {
	a.register_code_tools()
	a.register_v4_tools()
	a.register_crew_tools()
	a.register_advanced_tools()
}

// -- the deterministic code tools ------------------------------------------------

fn (mut a Agent) register_code_tools() {
	a.declare('code_symbols', 'List or find code symbols (functions/classes) via AST — precise ' + 'and cheaper than grep. Args: name (optional), path.', {
		'name': str_prop()
		'path': str_prop()
	}, [], risk_safe, ToolHandler(fn [mut a] (args map[string]json2.Any, sink OutputSink) string {
		unsafe {
			return a.tool_code_symbols(args)
		}
	}))

	a.declare('code_impact', 'Impact analysis: if I change this symbol, what breaks? Callers, ' + 'tests, public API, risk score. Args: name, path.', {
		'name': str_prop()
		'path': str_prop()
	}, ['name'], risk_safe, ToolHandler(fn [mut a] (args map[string]json2.Any, sink OutputSink) string {
		unsafe {
			return a.tool_code_impact(args)
		}
	}))
}

fn (mut a Agent) tool_code_symbols(args map[string]json2.Any) string {
	path := arg_or(args, 'path', '.')
	a.nexus.index(path, 0)
	name := jstr(args, 'name')
	if name != '' {
		syms := a.nexus.find_symbol(name)
		if syms.len == 0 {
			return "no symbol named '${name}' under ${path}"
		}
		return syms.map('${it.kind} ${it.name}  ${it.path}:${it.lineno} ' + 'params=(' + it.params.join(', ') + ')').join('\n')
	}
	mut lines := []string{}
	for _, s in a.nexus.idx.symbols {
		lines << '${s.kind} ${s.name}  ${s.path}:${s.lineno}'
		if lines.len >= 200 {
			break
		}
	}
	return if lines.len > 0 { lines.join('\n') } else { 'no symbols found' }
}

fn (mut a Agent) tool_code_impact(args map[string]json2.Any) string {
	path := arg_or(args, 'path', '.')
	a.nexus.index(path, 0)
	return a.nexus.format_impact(jstr(args, 'name'))
}

fn arg_or(args map[string]json2.Any, key string, fallback string) string {
	v := jstr(args, key).trim_space()
	return if v != '' { v } else { fallback }
}

fn int_arg_or(args map[string]json2.Any, key string, fallback int) int {
	if key !in args {
		return fallback
	}
	v := jint(args, key)
	return if v != 0 { v } else { fallback }
}

// -- the engineering tools ---------------------------------------------------------

fn (mut a Agent) register_v4_tools() {
	a.declare('analyze_code', 'Static analysis of a file or tree: taint flows (source→sink), ' + 'cyclomatic complexity hotspots, import cycles. Deterministic AST ' + 'analysis. Args: path, glob_filter, max_files.', {
		'path':        str_prop()
		'glob_filter': str_prop()
		'max_files':   int_prop()
	}, [], risk_safe, ToolHandler(fn [mut a] (args map[string]json2.Any, sink OutputSink) string {
		unsafe {
			return a.tool_analyze_code(args)
		}
	}))

	a.declare('graph_index', 'Build the knowledge graph (entities + typed relations) from ' + 'Python sources under path, plus the session log. Args: path.', {
		'path': str_prop()
	}, [], risk_safe, ToolHandler(fn [mut a] (args map[string]json2.Any, sink OutputSink) string {
		unsafe {
			return a.tool_graph_index(args)
		}
	}))

	a.declare('graph_query', 'Query the knowledge graph: find entities by name and show their ' + 'relations. Args: name, kind (optional).', {
		'name': str_prop()
		'kind': str_prop()
	}, ['name'], risk_safe, ToolHandler(fn [mut a] (args map[string]json2.Any, sink OutputSink) string {
		unsafe {
			return a.tool_graph_query(args)
		}
	}))

	a.declare('graph_impact', 'Impact analysis over the knowledge graph: everything that ' + "depends on this entity ('what breaks if I change X?'). Args: name.", {
		'name': str_prop()
	}, ['name'], risk_safe, ToolHandler(fn [mut a] (args map[string]json2.Any, sink OutputSink) string {
		unsafe {
			return a.tool_graph_impact(args)
		}
	}))

	a.declare('measure_coverage', 'Real line coverage of a Python file while a subject snippet ' + 'runs. Args: path (the file under test), command (Python code run ' + 'with the module bound as `mod`).', {
		'path':    str_prop()
		'command': str_prop()
	}, ['path', 'command'], risk_confirm, ToolHandler(fn [mut a] (args map[string]json2.Any, sink OutputSink) string {
		unsafe {
			return a.tool_measure_coverage(args)
		}
	}))

	a.declare('fuzz_target', 'Property-based fuzzing of a function: generated, boundary and ' + 'mutated inputs, with crash shrinking to a minimal reproducer. ' + 'Args: path, function, iterations, nargs.', {
		'path':       str_prop()
		'function':   str_prop()
		'iterations': int_prop()
		'nargs':      int_prop()
	}, ['path', 'function'], risk_confirm, ToolHandler(fn [mut a] (args map[string]json2.Any, sink OutputSink) string {
		unsafe {
			return a.tool_fuzz_target(args)
		}
	}))
}

fn (mut a Agent) tool_analyze_code(args map[string]json2.Any) string {
	path := os.expand_tilde_to_home(arg_or(args, 'path', '.'))
	if os.is_file(path) {
		result := a.static.analyze_file(path)
		return a.static.format_report(&result)
	}
	result := a.static.analyze_tree(path, arg_or(args, 'glob_filter', '*.py'), int_arg_or(args, 'max_files', 50))
	return a.static.format_report(&result)
}

fn (mut a Agent) tool_graph_index(args map[string]json2.Any) string {
	path := os.expand_tilde_to_home(arg_or(args, 'path', '.'))
	mut sources := map[string]string{}
	mut files := []string{}
	if os.is_file(path) {
		files << path
	} else {
		files = glob_paths(path, '**/*.py')
		files.sort()
		if files.len > 200 {
			files = files[..200].clone()
		}
	}
	for f in files {
		text := os.read_file(f) or { continue }
		sources[os.file_name(f).all_before_last('.')] = text
	}
	a.kgraph.index_code(sources) or { return 'ERROR: ${err.msg()}' }
	a.kgraph.index_log()
	return a.kgraph.format_status()
}

fn (mut a Agent) tool_graph_query(args map[string]json2.Any) string {
	name := jstr(args, 'name')
	hits := a.kgraph.find(name, jstr(args, 'kind'))
	if hits.len == 0 {
		return "no entity matching '${name}' — run graph_index first"
	}
	mut lines := []string{}
	for i, e in hits {
		if i >= 20 {
			break
		}
		lines << '${e.kind} ${e.id}  (${e.name})'
		for j, r in a.kgraph.out_of(e.id, '') {
			if j >= 8 {
				break
			}
			lines << '    --${r.rel}--> ${r.dst}'
		}
		for j, r in a.kgraph.into(e.id, '') {
			if j >= 8 {
				break
			}
			lines << '    <--${r.rel}-- ${r.src}'
		}
	}
	return lines.join('\n')
}

fn (mut a Agent) tool_graph_impact(args map[string]json2.Any) string {
	name := jstr(args, 'name')
	hits := a.kgraph.find(name, '')
	if hits.len == 0 {
		return "no entity matching '${name}' — run graph_index first"
	}
	mut lines := []string{}
	for i, e in hits {
		if i >= 5 {
			break
		}
		dep := a.kgraph.impact(e.id)
		lines << '${e.id}: ${dep.len} dependent(s)'
		for j, d in dep {
			if j >= 20 {
				break
			}
			lines << '    ${d}'
		}
	}
	return lines.join('\n')
}

fn (mut a Agent) tool_measure_coverage(args map[string]json2.Any) string {
	path := os.expand_tilde_to_home(jstr(args, 'path'))
	if !os.is_file(path) {
		return 'ERROR: not a file: ${path}'
	}
	res := a.coverage.measure(path, jstr(args, 'command'))
	mut missed := res.missed.map(it.str())
	if missed.len > 30 {
		missed = missed[..30].clone()
	}
	return 'coverage ${res.percent:.0f}%  (${res.hit}/${res.total} lines)\n' + 'missed: ' + missed.join(', ')
}

fn (mut a Agent) tool_fuzz_target(args map[string]json2.Any) string {
	path := os.expand_tilde_to_home(jstr(args, 'path'))
	if !os.is_file(path) {
		return 'ERROR: not a file: ${path}'
	}
	function := jstr(args, 'function')
	probe := call_python_function(path, function, [json2.Any('')])
	if !probe.ok && probe.error.starts_with('import failed') {
		return 'ERROR: ${probe.error}'
	}
	if !probe.ok && probe.error.starts_with('no callable') {
		return 'ERROR: ${probe.error}'
	}

	// The target is the Python function, reached through the harness. The
	// generation, the boundary bias and the shrinking stay in V, which is
	// where the value of a fuzzer actually lives.
	target := FuzzTarget(fn [path, function] (call_args []FuzzValue) !FuzzValue {
		res := call_python_function(path, function, call_args.map(fuzz_value_to_json(it)))
		if !res.ok {
			return error(res.error)
		}
		return FuzzValue(res.result)
	})
	stem := os.file_name(path).all_before_last('.')
	report := a.fuzzer.fuzz(target, FuzzOpts{
		iterations: int_arg_or(args, 'iterations', 200)
		nargs:      int_arg_or(args, 'nargs', 1)
		name:       '${stem}.${function}'
	})
	mut lines := [
		'fuzz ${report.target}: ${report.iterations} runs, ${report.crashes} crash(es), ' + '${report.invariant_failures} invariant failure(s)',
	]
	if c := report.first_crash {
		lines << '  first crash: ${c.error}'
		lines << '    args: ' + clip(args_repr(c.args), 120)
		lines << '    shrunk: ' + clip(args_repr(c.shrunk_args), 120) + ' → ${c.shrunk_error}'
	}
	return lines.join('\n')
}

// -- the crew tools --------------------------------------------------------------
//
// Persistent subagents: spawn, send, wait, close, resume. They run in the
// background and keep their full conversation, so a follow-up never starts
// from zero.

fn (mut a Agent) register_crew_tools() {
	a.declare('spawn_agent', 'Spawn ONE persistent background subagent. Returns IMMEDIATELY ' + 'with the agent id while it runs serially in the background queue — ' + 'you stay responsive. Agents run ONE AT A TIME, never in parallel. ' + 'Roles: coder, researcher, tester, reviewer, analyst. The agent keeps ' + 'its full conversation: follow up with send_to_agent, collect with ' + 'wait_for_agents. Use it for independent workstreams you want to ' + 'iterate on, not for fire-and-forget batches.', {
		'task':      str_prop()
		'role':      str_prop()
		'name':      json2.Any({
			'type':        json2.Any('string')
			'description': json2.Any('optional nickname')
		})
		'read_only': bool_prop()
		'model':     json2.Any({
			'type':        json2.Any('string')
			'description': json2.Any('optional model id override for this subagent only')
		})
	}, ['task'], risk_safe, ToolHandler(fn [mut a] (args map[string]json2.Any, sink OutputSink) string {
		unsafe {
			return a.tool_spawn_agent(args)
		}
	}))

	a.declare('send_to_agent', "Send a follow-up message into a living subagent's context (its " + 'full history is preserved). Works on done, blocked and errored ' + 'agents immediately; queues for a running one. Use it to iterate on a ' + "subagent's output instead of re-spawning.", {
		'id':        str_prop()
		'message':   str_prop()
		'interrupt': bool_prop()
	}, ['id', 'message'], risk_safe, ToolHandler(fn [mut a] (args map[string]json2.Any, sink OutputSink) string {
		unsafe {
			return a.tool_send_to_agent(args)
		}
	}))

	a.declare('wait_for_agents', 'Block until the named subagents finish (or all of them, if no ' + 'ids) and return their full reports. Call this when you need the ' + 'results of spawned background agents.', {
		'ids':     json2.Any({
			'type':        json2.Any('array')
			'items':       str_prop()
			'description': json2.Any('agent ids; omit for all')
		})
		'timeout': json2.Any({
			'type': json2.Any('number')
		})
	}, [], risk_safe, ToolHandler(fn [mut a] (args map[string]json2.Any, sink OutputSink) string {
		unsafe {
			return a.tool_wait_for_agents(args)
		}
	}))

	a.declare('close_agent', 'Retire a subagent. It keeps its history, and resume_agent can ' + 'bring it back. Close the agents you are done with.', {
		'id': str_prop()
	}, ['id'], risk_safe, ToolHandler(fn [mut a] (args map[string]json2.Any, sink OutputSink) string {
		unsafe {
			return a.tool_close_agent(args)
		}
	}))

	a.declare('resume_agent', 'Bring a closed subagent back so it can receive follow-up messages ' + 'again.', {
		'id': str_prop()
	}, ['id'], risk_safe, ToolHandler(fn [mut a] (args map[string]json2.Any, sink OutputSink) string {
		unsafe {
			return a.tool_resume_agent(args)
		}
	}))

	a.declare('crew_status', 'Show all crew subagents and their states (running, done, error, ' + 'closed).', map[string]json2.Any{}, [], risk_safe, ToolHandler(fn [mut a] (args map[string]json2.Any, sink OutputSink) string {
		unsafe {
			return a.crew.format_status()
		}
	}))
}

fn (mut a Agent) tool_spawn_agent(args map[string]json2.Any) string {
	task := jstr(args, 'task').trim_space()
	if task == '' {
		return 'ERROR: task must be a non-empty string'
	}
	agent := a.crew.spawn(task, SpawnOpts{
		role:      arg_or(args, 'role', 'coder')
		name:      jstr(args, 'name')
		context:   a.scout_context(4000)
		read_only: jbool(args, 'read_only') || a.read_only_default()
		model_id:  jstr(args, 'model')
	}) or { return 'ERROR: ${err.msg()}' }
	model_note := if agent.model_id != '' { " on model '${agent.model_id}'" } else { '' }
	a.push_status('⚡ crew · ${agent.nickname} (${agent.role}) launched')
	return "✓ subagent [${agent.id}] '${agent.nickname}' (${agent.role})${model_note} " + 'is RUNNING in the background.\n' + 'Collect with wait_for_agents, iterate with send_to_agent, retire ' + 'with close_agent.\n' + a.crew.format_status()
}

fn (mut a Agent) tool_send_to_agent(args map[string]json2.Any) string {
	agent := a.crew.send(jstr(args, 'id'), jstr(args, 'message'), jbool(args, 'interrupt')) or {
		return 'ERROR: ${err.msg()}'
	}
	return "✓ message delivered to [${agent.id}] '${agent.nickname}' — state: " + '${agent.state}. wait_for_agents collects the reply.'
}

fn (mut a Agent) tool_wait_for_agents(args map[string]json2.Any) string {
	mut timeout := jf64_or(args, 'timeout', 120.0)
	if timeout <= 0 {
		timeout = 120.0
	}
	timeout = max_f64(1.0, min_f64(timeout, 600.0))

	mut ids := []string{}
	for v in jarr(args, 'ids') {
		text := if v is string { v } else { v.str() }
		if text.trim_space() != '' {
			ids << text.trim_space()
		}
	}
	mut targets := []&CrewAgent{}
	if ids.len > 0 {
		for id in ids {
			if agent := a.crew.get(id) {
				targets << agent
			}
		}
	} else {
		targets = a.crew.list()
	}
	if targets.len == 0 {
		return 'ERROR: no matching subagents — spawn one first'
	}

	deadline := now_ts() + timeout
	for now_ts() < deadline {
		running := targets.filter(it.state == 'running').len
		if running == 0 {
			break
		}
		a.push_status('⚡ crew waiting · ${running}/${targets.len} running')
		time.sleep(400 * time.millisecond)
	}

	mut states := map[string]string{}
	mut still := []string{}
	for agent in targets {
		states[agent.id] = agent.state
		if agent.state == 'running' {
			still << agent.id
		}
	}
	mut lines := ['crew states: ${states}']
	if still.len > 0 {
		lines << 'still running after ${timeout:.0f}s: ' + still.join(', ') + ' — wait again or proceed without them'
	}
	lines << a.crew.format(targets)
	return lines.join('\n')
}

fn (mut a Agent) tool_close_agent(args map[string]json2.Any) string {
	agent := a.crew.close(jstr(args, 'id')) or { return 'ERROR: ${err.msg()}' }
	return "✓ [${agent.id}] '${agent.nickname}' closed. resume_agent brings it " + 'back with full context.'
}

fn (mut a Agent) tool_resume_agent(args map[string]json2.Any) string {
	agent := a.crew.resume(jstr(args, 'id')) or { return 'ERROR: ${err.msg()}' }
	return "✓ [${agent.id}] '${agent.nickname}' resumed (state: ${agent.state}) — " + 'send_to_agent works again.'
}

// -- the advanced tools ------------------------------------------------------------
//
// Each of these is a subsystem the agent already runs, handed to the model
// directly: intent compilation, debate, the task market, cognitive recall,
// causal self-inspection, formal verification, strategy search, synthesis.

fn (mut a Agent) register_advanced_tools() {
	a.declare('compile_and_run', 'COMPILE the goal through the intent compiler: it is drafted into ' + 'typed work items, then deterministic optimizer passes (dedupe, ' + 'dead-dependency pruning, topological layering, write-lock ' + 'scheduling) build ordered waves, and each wave executes as REAL ' + 'serial workers. Best for multi-step goals where order matters.', {
		'goal':      str_prop()
		'read_only': bool_prop()
	}, ['goal'], risk_safe, ToolHandler(fn [mut a] (args map[string]json2.Any, sink OutputSink) string {
		unsafe {
			return a.tool_compile_and_run(args)
		}
	}))

	a.declare('run_debate', 'Run a MULTI-MODEL debate tournament on a hard question: blind ' + 'proposals, mutual critique, revision, then calibrated cluster ' + 'fusion produces the verdict, with the dissent attached. Better than ' + 'any single model on contested questions.', {
		'question': str_prop()
		'rounds':   int_prop()
	}, ['question'], risk_safe, ToolHandler(fn [mut a] (args map[string]json2.Any, sink OutputSink) string {
		unsafe {
			return a.tool_run_debate(args)
		}
	}))

	a.declare('run_market', 'Put tasks on the AGENT TASK MARKET: every specialist role bids ' + '(capability × trust ÷ pace), the auctioneer awards each contract to ' + 'the best bidder, and the winner executes it as a real worker. Trust ' + 'updates from every outcome — the market learns which roles deliver.', {
		'tasks': json2.Any({
			'type':  json2.Any('array')
			'items': str_prop()
		})
	}, ['tasks'], risk_safe, ToolHandler(fn [mut a] (args map[string]json2.Any, sink OutputSink) string {
		unsafe {
			return a.tool_run_market(args)
		}
	}))

	a.declare('brain_recall', 'Recall knowledge from the cognitive memory — the four-store brain ' + 'with a forgetting curve ranks what is still alive and relevant. Use ' + 'it before re-researching anything; it may already be known. With an ' + 'empty query it returns the brain stats.', {
		'query': str_prop()
	}, ['query'], risk_safe, ToolHandler(fn [mut a] (args map[string]json2.Any, sink OutputSink) string {
		unsafe {
			return a.tool_brain_recall(args)
		}
	}))

	a.declare('inspect_why', 'Causal self-inspection: pass an event seq (shown in tool results ' + 'and the event log) and get the full WHY chain — which user message, ' + 'goal clause or prior tool call caused it. Use it to explain or ' + "audit the agent's own behaviour.", {
		'seq': int_prop()
	}, ['seq'], risk_safe, ToolHandler(fn [mut a] (args map[string]json2.Any, sink OutputSink) string {
		unsafe {
			return a.tool_inspect_why(args)
		}
	}))

	a.declare('verify_plan', 'FORMALLY VERIFY a plan: compile the goal, then model-check every ' + 'execution the plan permits against temporal safety properties ' + '(snapshot-before-write, write serialisation, verification after a ' + 'write). A violated plan is REJECTED with a counterexample — use it ' + 'before executing a risky plan.', {
		'goal': str_prop()
	}, ['goal'], risk_safe, ToolHandler(fn [mut a] (args map[string]json2.Any, sink OutputSink) string {
		unsafe {
			return a.tool_verify_plan(args)
		}
	}))

	a.declare('mcts_solve', 'Monte Carlo tree search over strategies: split a goal by semicolons ' + 'into work items and search which approach (coder, architect, ' + 'debugger, tester, or custom strategy ids) should handle each — UCB1 ' + 'exploration, rollout scoring, best assignment returned.', {
		'goal':       json2.Any({
			'type':        json2.Any('string')
			'description': json2.Any('items separated by ;')
		})
		'strategies': json2.Any({
			'type':  json2.Any('array')
			'items': str_prop()
		})
	}, ['goal'], risk_safe, ToolHandler(fn [mut a] (args map[string]json2.Any, sink OutputSink) string {
		unsafe {
			return a.tool_mcts_solve(args)
		}
	}))

	a.declare('synthesize_tool', 'WRITE A NEW TOOL: given a snake_case name, a description and ' + 'example cases ({"args": {...}, "want": expected}), a pure ' + 'deterministic function is drafted, AST-validated, example-tested ' + 'and registered as a REAL callable tool. Use it when no existing ' + 'tool fits.', {
		'name':        str_prop()
		'description': str_prop()
		'examples':    json2.Any({
			'type':  json2.Any('array')
			'items': json2.Any({
				'type': json2.Any('object')
			})
		})
	}, ['name', 'description', 'examples'], risk_safe, ToolHandler(fn [mut a] (args map[string]json2.Any, sink OutputSink) string {
		unsafe {
			return a.tool_synthesize_tool(args)
		}
	}))

	a.declare('predict_impact', 'Predict what breaks if a file changes: learned dependency edges ' + 'times historical breakage rates, ranked by probability. Use it ' + 'BEFORE a risky edit to see the blast radius.', {
		'path': str_prop()
	}, ['path'], risk_safe, ToolHandler(fn [mut a] (args map[string]json2.Any, sink OutputSink) string {
		unsafe {
			return a.tool_predict_impact(args)
		}
	}))

	a.declare('race_strategies', 'RACE three strategy universes one at a time on one task (direct, ' + 'careful, split); the first verified result WINS and the rest are ' + 'skipped. Use it for hard problems where you are unsure which ' + 'approach works.', {
		'task': str_prop()
	}, ['task'], risk_safe, ToolHandler(fn [mut a] (args map[string]json2.Any, sink OutputSink) string {
		unsafe {
			return a.tool_race_strategies(args)
		}
	}))

	a.declare('knowledge_ask', 'Query the bitemporal knowledge graph — facts with validity ' + "windows. Ask for the live truth, or 'as of' any past time ('at' is " + 'a unix timestamp). Use it to remember project facts that change ' + 'over time.', {
		'subject':   str_prop()
		'predicate': str_prop()
		'at':        json2.Any({
			'type': json2.Any('number')
		})
	}, ['subject', 'predicate'], risk_safe, ToolHandler(fn [mut a] (args map[string]json2.Any, sink OutputSink) string {
		unsafe {
			return a.tool_knowledge_ask(args)
		}
	}))
}

fn (mut a Agent) tool_compile_and_run(args map[string]json2.Any) string {
	goal := jstr(args, 'goal').trim_space()
	if goal == '' {
		return 'ERROR: goal must be a non-empty string'
	}
	plan := a.compiler.compile(goal)
	mut out := [a.compiler.format(&plan)]
	if plan.waves.len == 0 {
		out << 'ERROR: compilation produced no work items — rephrase the goal'
		return out.join('\n')
	}
	result := a.compiler.execute(&plan) or { return out.join('\n') + '\nERROR: ${err.msg()}' }
	out << '\nEXECUTED: ${jint(result, 'items')} items in ${jint(result, 'waves')} waves · ' + '${jint(result, 'done')} done · ${jint(result, 'blocked')} blocked · ' + '${jint(result, 'error')} error'
	return out.join('\n')
}

fn (mut a Agent) tool_run_debate(args map[string]json2.Any) string {
	question := jstr(args, 'question').trim_space()
	if question == '' {
		return 'ERROR: question must be a non-empty string'
	}
	mut rounds := int_arg_or(args, 'rounds', 3)
	rounds = if rounds < 1 {
		1
	} else if rounds > 3 { 3 } else { rounds }
	a.push_status('⚔ debate · ${a.debate.models.len} models, ${rounds} rounds')
	result := a.debate.run(question, rounds)
	return a.debate.format(&result)
}

fn (mut a Agent) tool_run_market(args map[string]json2.Any) string {
	mut clean := []string{}
	for t in jarr(args, 'tasks') {
		text := if t is string { t } else { t.str() }
		if text.trim_space() != '' {
			clean << text.trim_space()
		}
	}
	if clean.len == 0 {
		return 'ERROR: tasks must be a non-empty list of strings'
	}
	a.push_status('💰 market · ${clean.len} contract(s) up for auction')
	contracts := a.market.run(clean)
	return a.market.format(contracts)
}

fn (mut a Agent) tool_brain_recall(args map[string]json2.Any) string {
	query := jstr(args, 'query').trim_space()
	if query == '' {
		return a.brain.format_stats()
	}
	block := a.brain.context_block(query, 5)
	return if block != '' { block } else { 'no live memories match that query' }
}

fn (mut a Agent) tool_inspect_why(args map[string]json2.Any) string {
	if 'seq' !in args {
		return 'ERROR: seq must be an integer'
	}
	return a.theater.why(jint(args, 'seq'))
}

fn (mut a Agent) tool_verify_plan(args map[string]json2.Any) string {
	goal := jstr(args, 'goal').trim_space()
	if goal == '' {
		return 'ERROR: goal must be a non-empty string'
	}
	plan := a.compiler.compile(goal)
	r := a.formal.verify_plan(plan.waves)
	verdict := if r.ok { 'PASS ✓' } else { 'REJECTED ✗' }
	mut lines := [
		'FORMAL VERIFICATION — ${verdict} (${r.checked} trace(s) checked)',
		a.compiler.format(&plan),
	]
	for v in r.violations {
		lines << '  ⚠ ${v.property}: ${v.why}'
	}
	return lines.join('\n')
}

fn (mut a Agent) tool_mcts_solve(args map[string]json2.Any) string {
	goal := jstr(args, 'goal').trim_space()
	if goal == '' {
		return 'ERROR: goal must be a non-empty string'
	}
	mut items := []string{}
	for part in goal.split(';') {
		if part.trim_space() != '' {
			items << part.trim_space()
		}
	}
	mut strategies := []string{}
	for s in jarr(args, 'strategies') {
		text := if s is string { s } else { s.str() }
		if text.trim_space() != '' {
			strategies << text.trim_space()
		}
	}
	if strategies.len == 0 {
		strategies = ['coder', 'architect', 'debugger', 'tester']
	}
	// the evaluator scores against these items, so they are set before the
	// search rather than read out of whatever the last call left behind
	a.mcts_items = items.clone()
	report := a.mcts.search(items, strategies, 120, 20.0)
	mut lines := [
		'MCTS — best score ${report.best_score:.2f} in ${report.iterations} iterations ' + '(${report.nodes} nodes)',
	]
	for i, item in items {
		pick := report.best_assignment[i] or { '?' }
		lines << '  [${pick}] ' + clip_plain(item, 70)
	}
	return lines.join('\n')
}

fn (mut a Agent) tool_synthesize_tool(args map[string]json2.Any) string {
	raw := jarr(args, 'examples')
	if raw.len == 0 {
		return 'ERROR: examples must be a non-empty list of {"args": {...}, "want": ...}'
	}
	mut examples := []SynthExample{}
	for e in raw {
		if e !is map[string]json2.Any {
			continue
		}
		row := e.as_map()
		examples << SynthExample{
			args: jmap(row, 'args')
			want: jget(row, 'want')
		}
	}
	result := a.synth.synthesize(SynthSpec{
		name:        jstr(args, 'name')
		description: jstr(args, 'description')
		examples:    examples
	})
	if !result.ok {
		return 'ERROR: ' + result.reason
	}
	// a synthesized tool lands in its own registry; move it into the live
	// one so the model can actually call what it just wrote
	if tool := a.synth.registry[result.name] {
		a.tools[result.name] = a.covenant.arm_one(result.name, tool)
		a.schemas_tool_count = -1
	}
	return '✓ ' + result.reason
}

fn (mut a Agent) tool_predict_impact(args map[string]json2.Any) string {
	impact := a.world.predict_impact(jstr(args, 'path'))
	return impact.format()
}

fn (mut a Agent) tool_race_strategies(args map[string]json2.Any) string {
	task := jstr(args, 'task').trim_space()
	if task == '' {
		return 'ERROR: task must be a non-empty string'
	}
	a.push_status('⚡ race · 3 universes queued')
	result := a.racer.race(task, 420.0)
	return a.racer.format(&result)
}

fn (mut a Agent) tool_knowledge_ask(args map[string]json2.Any) string {
	subject := jstr(args, 'subject')
	predicate := jstr(args, 'predicate')
	at := jf64_or(args, 'at', 0.0)
	hits := if at > 0 {
		a.fabric.query(subject, predicate, at)
	} else {
		a.fabric.query_now(subject, predicate)
	}
	if hits.len == 0 {
		return 'no live fact for ${subject} ${predicate}'
	}
	return hits.map(json2.encode(json2.Any(it.to_json()))).join('\n')
}

// -- the forged skills ---------------------------------------------------------------

// register_persisted_skills loads previously forged skills from disk and
// exposes them as tools. Only a skill that re-passes every gate is loaded, so
// the file on disk is evidence rather than authority.
pub fn (mut a Agent) register_persisted_skills() {
	a.skill_forge.load_persisted()
	mut names := a.skill_forge.registry.keys()
	names.sort()
	for name in names {
		if name in a.tools {
			continue
		}
		skill := a.skill_forge.registry[name] or { continue }
		a.expose_skill(name, skill)
	}
}

// expose_skill wraps a validated skill as a live tool.
fn (mut a Agent) expose_skill(name string, skill Skill) {
	mut properties := map[string]json2.Any{}
	for key, value in skill.parameters {
		properties[key] = if value is map[string]json2.Any {
			value
		} else {
			str_prop()
		}
	}
	entry := if skill.entry != '' { skill.entry } else { name }
	source := skill.source
	description := if skill.description != '' { skill.description } else { name }
	a.declare(name, description, properties, [], risk_safe, ToolHandler(fn [entry, source] (args map[string]json2.Any, sink OutputSink) string {
		return call_synthesized(entry, source, args)
	}))
}
