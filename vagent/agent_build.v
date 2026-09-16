module vagent

import os
import x.json2

// agent_build.v — the composition root.
//
// Every subsystem is constructed here, in one place, and then the bridges
// that need the agent itself are wired in a second pass. The two passes are
// unavoidable rather than stylistic: a subsystem like the intent compiler
// takes its executor at construction, and that executor needs a fully built
// agent to run a crew wave through.
//
// The bridges are closures over the agent, which V allows only because the
// agent is a heap struct; a value agent would hand each closure a pointer
// into a stack frame that stops existing the moment the constructor returns.

// the placeholder bridges. They exist so a subsystem is never constructed
// holding a nil function pointer — a nil there is a segfault waiting for the
// first caller, whereas these are merely useless until wire_bridges runs.
fn unwired_plan_drafter(goal string) []json2.Any {
	return []
}

fn unwired_wave_executor(wave []PlanItem) []map[string]json2.Any {
	return []
}

fn unwired_mutator(role string, incumbent string, k int) []string {
	return []
}

fn unwired_brief_evaluator(role string, brief string) !(string, f64) {
	return '', 0.0
}

fn unwired_debate_speaker(model_id string, prompt string) string {
	return ''
}

fn unwired_market_executor(task string, role string) !map[string]json2.Any {
	return error('the market executor is not wired')
}

fn unwired_mcts_evaluator(assignment map[int]string) f64 {
	return 0.0
}

fn unwired_mesh_executor(task string, role string) !map[string]json2.Any {
	return error('the mesh executor is not wired')
}

fn unwired_role_drafter(mission string) map[string]json2.Any {
	return map[string]json2.Any{}
}

fn unwired_role_evaluator(draft &RoleDraft) f64 {
	return 0.0
}

fn unwired_synth_generator(spec &SynthSpec) string {
	return ''
}

fn unwired_ci_runner(test_files []string) !(bool, string) {
	return false, 'the CI runner is not wired'
}

fn unwired_dual(question string) string {
	return ''
}

fn unwired_universe_runner(strategy Strategy, task string, cancel &CancelFlag) !string {
	return error('the racer is not wired')
}

fn unwired_race_verifier(task string, result string) !bool {
	return false
}

fn unwired_spec_runner(name string, args map[string]json2.Any) !string {
	return error('the speculator is not wired')
}

fn unwired_step_executor(task string) string {
	return 'ERROR: the daemon executor is not wired'
}

fn unwired_council_speaker(role string, brief string) !string {
	return error('the council speaker is not wired')
}

fn unwired_workflow_step(step &WorkflowStep, n int) !map[string]json2.Any {
	return error('the workflow executor is not wired')
}

fn unwired_repair() !bool {
	return false
}

// AgentOpts is where this agent's world lives.
//
// It exists because an agent that can only be built against the user's real
// home directory is an agent whose construction cannot be tested without
// writing into their event log. Both fields default to the shared locations.
pub struct AgentOpts {
pub:
	home string
	cwd  string
}

// new_agent builds the whole system over the shared event log.
pub fn new_agent(cfg Config) &Agent {
	return new_agent_in(cfg, AgentOpts{})
}

// new_agent_in builds the whole system with its state under `home`.
pub fn new_agent_in(cfg Config, opts AgentOpts) &Agent {
	home := if opts.home != '' { opts.home } else { app_dir }
	cwd := if opts.cwd != '' { opts.cwd } else { os.getwd() }
	if home == app_dir {
		ensure_dirs()
	} else {
		for sub in ['', 'store', 'skills', 'workflows', 'memory', 'sessions'] {
			os.mkdir_all(os.join_path(home, sub)) or {}
		}
	}
	session_id := new_session_id()
	mut log := new_event_log(os.join_path(home, 'eventlog.jsonl'), 'main', session_id)

	// The mastermind is built before the messages, so the very first system
	// prompt is sealed and dispatched through the gate rather than being
	// assembled by hand.
	mut mastermind := new_mastermind(log)
	mut judge := new_judge(log)

	mut a := &Agent{
		cfg:        cfg
		tools:      build_registry()
		session_id: session_id
		log:        log
		mastermind: mastermind
		store:      new_snapshot_store(os.join_path(home, 'store'))
		memory:     new_hippocampus(log)
		judge:      judge
		goal:       new_goal_contract(log, judge)

		brain:     new_brain(log, os.join_path(home, 'brain.json'))
		compiler:  new_intent_compiler(log, unwired_plan_drafter)
		evolution: new_evolution_engine(log, unwired_mutator, unwired_brief_evaluator)
		merger:    new_timeline_merger(log)
		theater:   new_theater(log)
		debate:    new_debate_tournament(log, unwired_debate_speaker, debate_participants())
		market:    new_task_market(log, unwired_market_executor)
		tower:     new_tower(log)

		formal:    new_constitutional_checker(log)
		mcts:      new_tree_search(log, unwired_mcts_evaluator, 0)
		causal:    new_causal_engine(log)
		bandit:    new_bandit_router(log, bandit_arms(), 0)
		mesh:      new_mesh_node(log, session_id, unwired_mesh_executor)
		roleforge: new_role_forge(log, unwired_role_drafter, unwired_role_evaluator, 0.6)
		synth:     new_program_synthesizer(log, unwired_synth_generator)
		ci:        new_ci_pilot(log, cwd, unwired_ci_runner, 0.0)
		tuner:     new_parzen_tuner(log, agent_tuner_space(), 0, unsafe { nil })
		dual:      unsafe { nil }
		world:     new_world_model(log, cwd)
		racer:     new_racing_universes(log, unwired_universe_runner, unwired_race_verifier, [])
		homeo:     unsafe { nil }
		attention: new_attention_economy(log, 0)

		charter:     unsafe { nil }
		covenant:    unsafe { nil }
		horizon:     unsafe { nil }
		obligations: unsafe { nil }
		integrity:   unsafe { nil }
		sentinel:    unsafe { nil }

		fabric:     new_knowledge_fabric(log)
		crew:       unsafe { nil }
		autopilot:  new_autopilot(log, true)
		nexus:      new_nexus()
		forge:      new_forge(log, cwd)
		oracle:     new_oracle(log, os.join_path(home, 'memory'))
		budget_gov: new_budget_governor(log, Budget{})
		loop_det:   new_loop_detector(log, 0, 0)

		router:      new_router(log, map[string]ModelSpec{})
		semantic:    new_semantic_memory(log)
		speculator:  new_speculator(log, unwired_spec_runner)
		dashboard:   new_dashboard(log)
		daemon:      new_daemon(log, unwired_step_executor, 2)
		healer:      new_observing_healer(log)
		skill_forge: new_skill_forge(log, os.join_path(home, 'skills'))
		council:     new_council(log, unwired_council_speaker)

		kgraph:   new_knowledge_graph(log)
		static:   new_static_analyzer(log)
		coverage: new_coverage_engine(log)
		fuzzer:   new_fuzzer(log, 0)

		workflows: unsafe { nil }
		notifier:  new_notifier(log)
	}

	// the dual process needs the brain, so it is built after it
	a.dual = new_dual_process(log, unwired_dual, unwired_dual, a.brain, 0.0)

	// The specification bound to the action boundary. It contributes no
	// prompt text: it only refuses calls that collide with a clause.
	a.charter = new_charter(log, CharterOpts{
		spec:        master_spec
		spec_source: master_spec
		package_dir: os.dir(@FILE)
		store:       a.store
		root:        cwd
	})
	// the names the UI and the callers already use
	a.covenant = a.charter.covenant
	a.horizon = a.charter.horizon
	a.obligations = a.charter.obligations
	a.integrity = a.charter.integrity
	if a.charter.has_sentinel {
		a.sentinel = a.charter.sentinel
	}

	// Arm the registry. After this there is no unguarded handler left to
	// call, so every executor passes the boundary whether or not it
	// remembers to ask the gate.
	a.tools = a.covenant.arm(a.tools)

	mut crew := new_crew(log, a.provider(), a.model(), a.effort())
	crew.mastermind = mastermind
	crew.covenant = a.covenant
	crew.arm()
	a.crew = crew

	a.workflows = new_workflow_engine(log, os.join_path(home, 'workflows'), unwired_workflow_step, judge)
	a.homeo = new_homeostasis(log, map[string]Repair{})
	a.notify_seq = log.head('main')

	a.reseat_system_prompt(map[string]string{}, false)
	a.wire_bridges()
	a.register_all_tools()
	a.register_persisted_skills()
	a.attach_cassette()

	log.append('session.start', {
		'session_id': json2.Any(session_id)
		'model':      json2.Any(cfg.model_id)
		'effort':     json2.Any(cfg.effort)
	}, AppendOpts{ actor: 'system' })
	// PERCEIVE: stamp the environment
	a.forge.probe()
	a.home = home
	a.cwd = cwd
	return a
}

// debate_participants is the tournament roster: the tool-capable models,
// capped so one debate does not become a survey.
fn debate_participants() []string {
	mut out := []string{}
	for m in models {
		if m.supports_tools {
			out << m.id
		}
		if out.len >= 4 {
			break
		}
	}
	return out
}

fn bandit_arms() []string {
	mut out := []string{}
	for m in models {
		out << m.id
		if out.len >= 8 {
			break
		}
	}
	return out
}

fn agent_tuner_space() map[string][]string {
	mut keys := []string{}
	for e in efforts {
		keys << e.key
	}
	return {
		'effort':       keys
		'worker_steps': ['low', 'medium', 'high']
	}
}

// attach_cassette binds the record/replay tape when the environment asks for
// one. A cassette that cannot be opened is reported and skipped rather than
// silently recording nothing.
fn (mut a Agent) attach_cassette() {
	path := os.getenv('FULLAGENT_CASSETTE')
	if path == '' {
		return
	}
	mut mode := os.getenv('FULLAGENT_CASSETTE_MODE')
	if mode == '' {
		mode = 'off'
	}
	a.cassette = new_cassette(path, mode) or {
		a.log.append('cassette.error', {
			'path':  json2.Any(path)
			'error': json2.Any(err.msg())
		}, AppendOpts{ actor: 'system' })
		unsafe { nil }
	}
}
