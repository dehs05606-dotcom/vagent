module vagent

import x.json2
import os

// Building an agent creates its whole world on disk, so every test here
// builds it under a scratch home. Without that the suite would write into
// whatever event log the machine's own agent uses — and read it back.
fn sandboxed_agent(name string, cfg Config) (&Agent, string) {
	dir := os.join_path(os.temp_dir(), 'vagent-agent-${name}-${os.getpid()}')
	os.rmdir_all(dir) or {}
	os.mkdir_all(dir) or { panic(err) }
	return new_agent_in(cfg, AgentOpts{ home: dir, cwd: os.getwd() }), dir
}

fn test_the_composition_root_builds_every_subsystem() {
	mut a, dir := sandboxed_agent('build', Config{})
	defer {
		os.rmdir_all(dir) or {}
	}

	// the kernel and the boundary are live
	assert a.session_id.len == 8
	assert a.log.branch == 'main'
	assert a.covenant != unsafe { nil }
	assert a.horizon != unsafe { nil }
	assert a.integrity != unsafe { nil }

	// the session opened on the record
	types := a.log.events('main').map(it.typ)
	assert 'session.start' in types

	// the system prompt was seated through the gate rather than by hand
	assert a.messages.len >= 1
	assert a.messages[0].role == 'system'
	assert a.messages[0].text().len > 100
}

fn test_every_registered_tool_is_armed_by_the_boundary() {
	mut a, dir := sandboxed_agent('armed', Config{})
	defer {
		os.rmdir_all(dir) or {}
	}
	assert a.tools.len > 16, a.tools.len.str()
	// an executor holding an unguarded handler could act outside the
	// specification, so this is asserted rather than assumed
	for name, tool in a.tools {
		assert tool.guarded, '${name} is not armed'
		assert tool.name == name
	}
}

fn test_the_subsystem_tools_are_all_present() {
	mut a, dir := sandboxed_agent('tools', Config{})
	defer {
		os.rmdir_all(dir) or {}
	}
	for want in ['code_symbols', 'code_impact', 'analyze_code', 'graph_index', 'graph_query',
		'graph_impact', 'measure_coverage', 'fuzz_target', 'spawn_agent', 'send_to_agent',
		'wait_for_agents', 'close_agent', 'resume_agent', 'crew_status', 'compile_and_run',
		'run_debate', 'run_market', 'brain_recall', 'inspect_why', 'verify_plan', 'mcts_solve',
		'synthesize_tool', 'predict_impact', 'race_strategies', 'knowledge_ask'] {
		assert want in a.tools, want
	}
	// and the base kit survived the additions
	for want in ['read_file', 'write_file', 'edit_file', 'run_command', 'web_search'] {
		assert want in a.tools, want
	}
}

fn test_the_schema_cache_rebuilds_when_the_registry_changes() {
	mut a, dir := sandboxed_agent('schemas', Config{})
	defer {
		os.rmdir_all(dir) or {}
	}
	first := a.tool_schemas()
	assert first.len == a.tools.len
	// a second call is served from the cache and agrees
	assert a.tool_schemas().len == first.len

	a.declare('a_new_tool', 'x', map[string]json2.Any{}, [], risk_safe, ToolHandler(no_tool_handler))
	assert a.tool_schemas().len == first.len + 1
}

fn no_tool_handler(args map[string]json2.Any, sink OutputSink) string {
	return ''
}

fn test_a_model_that_cannot_act_gets_no_schemas() {
	mut cfg := Config{}
	// pick a model the config declares as unable to use tools, if there is
	// one; otherwise this assertion has nothing to say
	mut chosen := ''
	for m in models {
		if !m.supports_tools {
			chosen = m.id
			break
		}
	}
	if chosen == '' {
		return
	}
	cfg.model_id = chosen
	mut a, dir := sandboxed_agent('noschema', cfg)
	defer {
		os.rmdir_all(dir) or {}
	}
	assert a.tool_schemas().len == 0
}

fn test_the_context_sections_carry_only_what_exists() {
	mut a, dir := sandboxed_agent('sections', Config{})
	defer {
		os.rmdir_all(dir) or {}
	}
	sections := a.context_sections(none, 'read the parser and fix it')
	// with no goal set, there is no goal section to compose
	assert 'goal' !in sections
	// and nothing empty is ever composed: a heading with no body reads as
	// an assertion that the section is empty, which is a different claim
	for name, body in sections {
		assert body.trim_space() != '', name
	}

	with_web := a.context_sections(RouteDecision{ use_web: true }, 'latest release')
	assert 'web' in with_web
	assert with_web['web'].contains('web_search')
}

fn test_the_scout_context_is_bounded_and_says_where_we_are() {
	mut a, dir := sandboxed_agent('scout', Config{})
	defer {
		os.rmdir_all(dir) or {}
	}
	ctx := a.scout_context(4000)
	assert ctx.contains('Working directory:')
	assert ctx.len <= 4000
	// a subagent gets little else, so the cap must not silently drop the
	// part that says where it is
	assert a.scout_context(50).len <= 50
	assert a.scout_context(50).contains('Working dir')
}

fn test_reset_starts_a_new_session_on_the_same_log() {
	mut a, dir := sandboxed_agent('reset', Config{})
	defer {
		os.rmdir_all(dir) or {}
	}
	first := a.session_id
	a.turns << Turn{
		user_text: 'hello'
	}
	a.reset()
	assert a.session_id != first
	assert a.turns.len == 0
	// the prompt is re-seated, not dropped
	assert a.messages.len == 1
	assert a.messages[0].role == 'system'
	assert a.log.events('main').filter(it.typ == 'session.start').len == 2
}

fn test_the_read_only_default_follows_the_autonomy_ladder() {
	mut a, dir := sandboxed_agent('autonomy', Config{})
	defer {
		os.rmdir_all(dir) or {}
	}
	a.autonomy = 0
	assert a.read_only_default()
	a.autonomy = 1
	assert a.read_only_default()
	a.autonomy = 2
	assert !a.read_only_default()
	a.autonomy = 5
	assert !a.read_only_default()
}

fn test_a_speculative_call_cannot_reach_a_mutating_tool() {
	mut a, dir := sandboxed_agent('spec', Config{})
	defer {
		os.rmdir_all(dir) or {}
	}
	// the speculator gates on the whitelist before calling, and this
	// checks again: a speculative call runs before anyone asked for it
	for name in ['write_file', 'edit_file', 'delete_path', 'run_command'] {
		a.spec_runner(name, map[string]json2.Any{}) or {
			assert err.msg().contains('not speculative-safe'), err.msg()
			continue
		}
		assert false, '${name} was allowed to run speculatively'
	}
	assert 'read_file' in speculative_tools
}
