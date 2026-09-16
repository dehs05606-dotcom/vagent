module vagent

import rand
import x.json2

// agent.v — the agent loop: model against tools, event-sourced on the kernel.
//
// Every user message, tool call, tool result, assistant reply and cost is an
// immutable event in the append-only log. Conversation state, cost, goal
// distance, dead-ends and verdicts are projections folded from that log —
// the agent holds no authoritative state of its own.
//
// What is wired here is enforced mechanically, never as prompt advice:
//
//   * Total attribution — with an active goal, every tool call is bound to
//     the focus clause. An action with no open clause to serve is refused.
//   * Snapshot-before-write — no mutating tool runs without a committed
//     recovery path already in the snapshot store.
//   * Anti-clauses are re-checked after EVERY successful write.
//   * A budget breach pauses the turn rather than killing it silently.
//   * Exact repeats are sealed and interrupted.
//   * The goal kernel ticks: distance measured, focus re-aimed.
//   * Time travel: rewind restores files and state, revert only files.
//
// The struct is one composition root, which is the honest shape for it: the
// subsystems are genuinely all live at once, and hiding that behind lazy
// accessors would only make the wiring harder to read.

// The autonomy ladder's rungs are named in ui_complete.v, where the
// completer offers them; this module is what enforces them.

pub const mutating_tool_names = ['write_file', 'edit_file', 'create_directory', 'copy_path',
	'move_path', 'delete_path', 'run_command']

// a delete is never auto-approved, at any autonomy level
pub const always_ask_tools = ['delete_path']

// which argument names hold the paths a tool touches, for snapshotting
pub const path_arg_tools = {
	'write_file':       ['path']
	'edit_file':        ['path']
	'create_directory': ['path']
	'delete_path':      ['path']
	'copy_path':        ['src', 'dst']
	'move_path':        ['src', 'dst']
}

// provider errors that justify an automatic model failover
pub const failover_statuses = [408, 429, 500, 502, 503, 504]

@[heap]
pub struct Agent {
pub mut:
	cfg        Config
	tools      map[string]Tool
	session_id string
	turns      []Turn
	messages   []Message
	autonomy   int = 3

	log        &EventLog
	mastermind &Mastermind
	store      SnapshotStore
	memory     Hippocampus
	judge      &Judge
	goal       GoalContract

	brain     &Brain
	compiler  &IntentCompiler
	evolution &EvolutionEngine
	merger    &TimelineMerger
	theater   &Theater
	debate    &DebateTournament
	market    &TaskMarket
	tower     &Tower

	formal    &ModelChecker
	mcts      &TreeSearch
	causal    &CausalEngine
	bandit    &BanditRouter
	mesh      &MeshNode
	roleforge &RoleForge
	synth     &ProgramSynthesizer
	ci        &CIPilot
	tuner     &ParzenTuner
	dual      &DualProcess
	world     &WorldModel
	racer     &RacingUniverses
	homeo     &Homeostasis
	attention &AttentionEconomy

	charter     &Charter
	covenant    &Covenant
	horizon     &Horizon
	obligations &Ledger
	integrity   &Integrity
	sentinel    &Sentinel

	fabric     &KnowledgeFabric
	crew       &Crew
	autopilot  AutoPilot
	nexus      &Nexus
	forge      Forge
	oracle     Oracle
	budget_gov BudgetGovernor
	loop_det   LoopDetector

	router      &Router
	semantic    &SemanticMemory
	speculator  &Speculator
	dashboard   &Dashboard
	daemon      &Daemon
	healer      &Healer
	skill_forge &SkillForge
	council     &Council

	kgraph   &KnowledgeGraph
	static   &StaticAnalyzer
	coverage &CoverageEngine
	fuzzer   &Fuzzer
	// a mutation tester needs a suite command, so it is bound on demand
	mutator &MutationTester = unsafe { nil }

	workflows &WorkflowEngine
	notifier  &Notifier
	cassette  &Cassette = unsafe { nil }

	// -- per-turn and per-session bookkeeping --------------------------
	//
	// None of this is authoritative: it is caching and plumbing, and every
	// question that matters is answered by folding the log instead.
	should_cancel CancelCheck = unsafe { nil }
	turn_status   StatusSink  = unsafe { nil }
	// distance history, for the focus mode's stall detection
	focus_history []f64
	notify_seq    int
	model_errors  map[string]int
	failovers     int
	// at most one failover per turn
	failed_over    bool
	turn_start_seq int
	// knowledge kept when history is compacted away
	compact_digests []string
	error_counts    map[string]int
	// per-file content history, for oscillation detection
	file_hashes map[string][]string
	// the tool schemas are rebuilt only when the registry changes; they
	// used to be re-serialised before every model call inside a turn
	schemas_cache      []json2.Any
	schemas_tool_count int = -1
	// the full token re-estimate runs only after real conversation growth
	compact_check_chars int
	// the work items the strategy search is currently scoring against
	mcts_items []string
	// where this agent's state lives, and the project it is working on
	home string
	cwd  string
}

// CancelCheck reports whether the current turn has been cancelled.
pub type CancelCheck = fn () bool

// StatusSink streams a one-line status into the UI during a long turn.
pub type StatusSink = fn (text string)

// -- model, provider, effort ---------------------------------------------------

pub fn (a &Agent) model() Model {
	return model_by_id(a.cfg.model_id) or { models[0] }
}

pub fn (a &Agent) provider() Provider {
	m := a.model()
	return providers[m.provider] or { Provider{} }
}

pub fn (a &Agent) effort() Effort {
	return effort_by_key(a.cfg.effort) or { efforts[0] }
}

// -- prompts and context -------------------------------------------------------

// base_prompt is this session's system prompt, served from the sealed vault.
// It falls back to the module source if the vault somehow lacks the name, so
// the model is never promptless.
pub fn (mut a Agent) base_prompt() string {
	return a.mastermind.vault.get(a.cfg.prompt) or { prompt_get(a.cfg.prompt) }
}

// salient_section is the clauses this request implicates, rendered for the
// END of the context.
//
// The specification still ships whole in the system prompt. This is the same
// text again, in the position a long prompt loses: with hundreds of clauses
// the few that govern a turn sit in the middle, which is where recall is
// weakest.
pub fn (mut a Agent) salient_section(request string) string {
	mut names := a.tools.keys()
	names.sort()
	return a.charter.salient(request, names)
}

// reseat_system_prompt routes the conversation's system prompt through the
// gate — the single door to the model. It guarantees messages[0] carries the
// sealed prompt, composes any live sections beneath it, and seals the
// dispatch lineage.
pub fn (mut a Agent) reseat_system_prompt(sections map[string]string, compose bool) {
	a.mastermind.gate.dispatch(a.cfg.prompt, mut a.messages, sections, compose) or {}
}

// state is the live projection of the event log.
pub fn (mut a Agent) state() State {
	return fold(mut a.log, a.log.branch)
}

// -- the conversation ------------------------------------------------------------

pub fn (mut a Agent) reset() {
	a.messages = []
	a.reseat_system_prompt(map[string]string{}, false)
	a.turns = []
	a.session_id = new_session_id()
	a.log.session = a.session_id
	a.log.append('session.start', {
		'session_id': json2.Any(a.session_id)
		'model':      json2.Any(a.cfg.model_id)
		'effort':     json2.Any(a.cfg.effort)
	}, AppendOpts{ actor: 'system' })
}

fn new_session_id() string {
	return rand.uuid_v4().replace('-', '')[..8]
}

// context_sections are the live sections composed beneath the sealed prompt.
// The framing is the composer's job — the bodies here are plain content.
pub fn (mut a Agent) context_sections(route ?RouteDecision, query string) map[string]string {
	mut sections := map[string]string{}

	block := a.salient_section(query)
	if block != '' {
		sections['salient'] = block
	}
	constitution := a.oracle.read_constitution().trim_space()
	if constitution != '' {
		sections['constitution'] = constitution
	}
	status := a.goal.status()
	if status.active {
		sections['goal'] = a.goal.format() + "\nEvery action must serve an open clause. When a clause's " + "predicate genuinely passes, say 'PROVEN: <clause id>' — the " + 'kernel verifies it, never trust self-declared success.'
	}
	if r := route {
		if r.use_web {
			sections['web'] = 'This request needs live, up-to-the-minute data. Use ' + 'web_search (and web_fetch for details) to get CURRENT facts — ' + 'never answer from stale knowledge. Quote the retrieval time ' + 'and sources.'
		}
	}

	mut mem := a.memory.context_block(3)
	if query != '' {
		// meaning-based recall: the episodes and facts most SIMILAR to
		// this request, not merely the most recent ones
		recall := a.semantic.recall_block(query, 3)
		if recall != '' {
			mem = if mem != '' { mem + '\n\n' + recall } else { recall }
		}
		// and what survived the forgetting curve
		brain_block := a.brain.context_block(query, 3)
		if brain_block != '' {
			mem = if mem != '' { mem + '\n\n' + brain_block } else { brain_block }
		}
	}
	if mem != '' {
		sections['memory'] = mem
	}
	if a.compact_digests.len > 0 {
		mut tail := a.compact_digests.clone()
		if tail.len > 12 {
			tail = tail[tail.len - 12..].clone()
		}
		sections['compacted'] = 'COMPACTED HISTORY — knowledge preserved from turns that ' + 'were compressed to fit the context window:\n- ' + tail.join('\n- ')
	}
	return sections
}

// tool_schemas is the schema list sent with a model call, or none for a
// model that cannot act.
pub fn (mut a Agent) tool_schemas() []json2.Any {
	if !a.model().supports_tools {
		return []
	}
	n := a.tools.len
	if a.schemas_tool_count == n && a.schemas_cache.len > 0 {
		return a.schemas_cache.clone()
	}
	mut names := a.tools.keys()
	names.sort()
	mut schemas := []json2.Any{}
	for name in names {
		if t := a.tools[name] {
			schemas << json2.Any(t.openai_schema())
		}
	}
	a.schemas_cache = schemas.clone()
	a.schemas_tool_count = n
	return schemas
}
