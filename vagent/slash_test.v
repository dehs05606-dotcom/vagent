module vagent

import os
import x.json2

// slash_test.v — the command router.
//
// Several commands persist the config, and the config file's location is
// fixed at program start, so these tests save the real file and put it back
// afterwards rather than quietly rewriting whatever the machine's own agent
// is configured to do.

fn sandboxed_router(name string) (&Agent, string, string) {
	dir := os.join_path(os.temp_dir(), 'vagent-slash-${name}-${os.getpid()}')
	os.rmdir_all(dir) or {}
	os.mkdir_all(dir) or { panic(err) }
	saved := os.read_file(config_file) or { '' }
	return new_agent_in(Config{}, AgentOpts{ home: dir, cwd: os.getwd() }), dir, saved
}

fn restore_config(saved string) {
	if saved == '' {
		os.rm(config_file) or {}
		return
	}
	os.write_file(config_file, saved) or {}
}

// -- argument splitting --------------------------------------------------------

fn test_the_command_word_splits_once_and_keeps_the_sentence() {
	cmd, arg := split_command('/goal set ship the thing | tests pass @ exit_code:go test')
	assert cmd == '/goal'
	assert arg == 'set ship the thing | tests pass @ exit_code:go test'
}

fn test_the_command_word_is_lowercased_but_the_argument_is_not() {
	cmd, arg := split_command('  /Model  Deepseek-V4-PRO  ')
	assert cmd == '/model'
	assert arg == 'Deepseek-V4-PRO'
}

fn test_a_tab_separates_the_command_from_its_argument() {
	// Python's split(None, 1) splits on ANY whitespace run, not just spaces
	cmd, arg := split_command('/judge\t\texit_code  go build')
	assert cmd == '/judge'
	assert arg == 'exit_code  go build'
}

fn test_an_empty_line_routes_nowhere() {
	cmd, _ := split_command('   ')
	assert cmd == ''
}

// -- dispatch ------------------------------------------------------------------

fn test_an_unknown_command_is_an_error_not_a_crash() {
	mut a, dir, saved := sandboxed_router('unknown')
	defer {
		os.rmdir_all(dir) or {}
		restore_config(saved)
	}
	r := a.handle_slash('/nosuchthing please')
	assert r.lines.len == 1
	assert r.lines[0].kind == 'error'
	assert r.text().contains('unknown command: /nosuchthing')
	assert r.action == ''
}

fn test_an_empty_line_produces_nothing_at_all() {
	mut a, dir, saved := sandboxed_router('empty')
	defer {
		os.rmdir_all(dir) or {}
		restore_config(saved)
	}
	r := a.handle_slash('   ')
	assert r.lines.len == 0
	assert r.action == ''
	assert r.job == ''
}

fn test_exit_saves_the_session_before_asking_the_ui_to_quit() {
	mut a, dir, saved := sandboxed_router('exit')
	defer {
		os.rmdir_all(dir) or {}
		restore_config(saved)
	}
	r := a.handle_slash('/q')
	assert r.action == 'exit'
	assert r.text().contains('bye — session ${a.session_id} saved')
	// the save actually happened, rather than the message claiming it did
	assert os.exists(os.join_path(dir, 'sessions'))
}

fn test_clear_is_an_action_with_nothing_to_print() {
	mut a, dir, saved := sandboxed_router('clear')
	defer {
		os.rmdir_all(dir) or {}
		restore_config(saved)
	}
	r := a.handle_slash('/clear')
	assert r.action == 'clear'
	assert r.lines.len == 0
}

// -- the toggles ---------------------------------------------------------------

fn test_approve_toggles_the_gate_and_persists_it() {
	mut a, dir, saved := sandboxed_router('approve')
	defer {
		os.rmdir_all(dir) or {}
		restore_config(saved)
	}
	assert !a.cfg.auto_approve
	on := a.handle_slash('/approve')
	assert a.cfg.auto_approve
	assert on.text().contains('auto-approve: ON')
	off := a.handle_slash('/approve')
	assert !a.cfg.auto_approve
	assert off.text().contains('auto-approve: OFF')
	// it reached disk: the next session inherits the choice
	written := os.read_file(config_file) or { '' }
	assert written.contains('auto_approve')
}

fn test_render_accepts_on_off_and_a_bare_toggle() {
	mut a, dir, saved := sandboxed_router('render')
	defer {
		os.rmdir_all(dir) or {}
		restore_config(saved)
	}
	a.handle_slash('/render on')
	assert jbool(a.cfg.extra, 'render_markdown')
	a.handle_slash('/render')
	assert !jbool(a.cfg.extra, 'render_markdown')
	bad := a.handle_slash('/render maybe')
	assert bad.lines[0].kind == 'error'
	// a rejected argument must not have changed anything
	assert !jbool(a.cfg.extra, 'render_markdown')
}

// -- model and effort ----------------------------------------------------------

fn test_an_unknown_model_is_refused_and_the_config_is_untouched() {
	mut a, dir, saved := sandboxed_router('model')
	defer {
		os.rmdir_all(dir) or {}
		restore_config(saved)
	}
	before := a.cfg.model_id
	r := a.handle_slash('/model no-such-model')
	assert r.lines[0].kind == 'error'
	assert a.cfg.model_id == before
}

fn test_a_known_model_is_applied() {
	mut a, dir, saved := sandboxed_router('model-ok')
	defer {
		os.rmdir_all(dir) or {}
		restore_config(saved)
	}
	target := models[models.len - 1]
	r := a.handle_slash('/model ${target.id} and some trailing noise')
	assert a.cfg.model_id == target.id
	assert r.text().contains(target.label)
}

fn test_a_bare_model_command_opens_the_picker_on_the_current_model() {
	mut a, dir, saved := sandboxed_router('model-picker')
	defer {
		os.rmdir_all(dir) or {}
		restore_config(saved)
	}
	r := a.handle_slash('/model')
	assert r.overlay != unsafe { nil }
	assert r.overlay.kind == 'model'
	assert r.overlay.items.len == models.len
	assert r.overlay.items[r.overlay.index].meta == a.cfg.model_id
}

fn test_a_bad_effort_lists_the_real_levels() {
	mut a, dir, saved := sandboxed_router('effort')
	defer {
		os.rmdir_all(dir) or {}
		restore_config(saved)
	}
	r := a.handle_slash('/effort turbo')
	assert r.lines[0].kind == 'error'
	for e in efforts {
		assert r.text().contains(e.key)
	}
}

fn test_effort_is_matched_case_insensitively() {
	mut a, dir, saved := sandboxed_router('effort-ok')
	defer {
		os.rmdir_all(dir) or {}
		restore_config(saved)
	}
	a.handle_slash('/effort LOW')
	assert a.cfg.effort == 'low'
}

// -- overlays ------------------------------------------------------------------

fn test_history_flashes_rather_than_opening_an_empty_picker() {
	mut a, dir, saved := sandboxed_router('history-empty')
	defer {
		os.rmdir_all(dir) or {}
		restore_config(saved)
	}
	r := a.handle_slash('/history')
	assert r.overlay == unsafe { nil }
	assert r.flash == 'no history yet'
}

fn test_history_shows_the_most_recent_turns_with_the_newest_selected() {
	mut a, dir, saved := sandboxed_router('history')
	defer {
		os.rmdir_all(dir) or {}
		restore_config(saved)
	}
	for i in 0 .. 20 {
		a.turns << Turn{
			user_text: 'turn number ${i}'
		}
	}
	r := a.handle_slash('/history')
	assert r.overlay != unsafe { nil }
	// only the last 15, newest selected
	assert r.overlay.items.len == 15
	assert r.overlay.index == 14
	assert r.overlay.items[14].text.contains('turn number 19')
	assert r.overlay.items[0].text.contains('turn number 5')
}

fn test_help_lists_every_row_it_documents() {
	mut a, dir, saved := sandboxed_router('help')
	defer {
		os.rmdir_all(dir) or {}
		restore_config(saved)
	}
	r := a.handle_slash('/help')
	assert r.overlay != unsafe { nil }
	assert r.overlay.kind == 'help'
	assert r.overlay.items.len == help_rows.len
	assert r.overlay.footer == 'Esc close'
}

// -- numbers that must not be guessed ------------------------------------------

fn test_a_non_numeric_argument_is_refused_rather_than_read_as_zero() {
	// Python's int() raises; V's .int() answers 0. Reading "/rewind soon"
	// as "/rewind 0" would silently rewind the whole session.
	assert parse_int_strict('12') or { -1 } == 12
	assert parse_int_strict('-3') or { 999 } == -3
	assert parse_int_strict('soon') == none
	assert parse_int_strict('12x') == none
	assert parse_int_strict('') == none
	assert parse_int_strict('  7  ') or { -1 } == 7
}

fn test_rewind_and_revert_and_why_all_refuse_a_non_number() {
	mut a, dir, saved := sandboxed_router('seqs')
	defer {
		os.rmdir_all(dir) or {}
		restore_config(saved)
	}
	for line in ['/rewind soon', '/revert soon', '/why soon'] {
		r := a.handle_slash(line)
		assert r.lines[0].kind == 'error', line
		assert r.text().contains('usage:'), line
	}
}

fn test_autonomy_refuses_a_word_and_reports_the_levels() {
	mut a, dir, saved := sandboxed_router('autonomy')
	defer {
		os.rmdir_all(dir) or {}
		restore_config(saved)
	}
	before := a.autonomy
	bad := a.handle_slash('/autonomy yes')
	assert bad.lines[0].kind == 'error'
	assert a.autonomy == before

	listing := a.handle_slash('/autonomy')
	for i, desc in autonomy_levels {
		assert listing.text().contains('L${i}  ${desc}')
	}
}

// -- focus ---------------------------------------------------------------------

fn test_focus_arms_clamps_and_disarms() {
	mut a, dir, saved := sandboxed_router('focus')
	defer {
		os.rmdir_all(dir) or {}
		restore_config(saved)
	}
	a.focus_history << 0.5
	armed := a.handle_slash('/focus 99')
	assert a.focus_remaining == 20, 'clamped to the documented ceiling'
	assert a.focus_history.len == 0, 'a fresh arming forgets the old distances'
	assert armed.text().contains('up to 20 auto-turns')

	assert a.handle_slash('/focus 0').text().contains('up to 1 auto-turns')
	assert a.focus_remaining == 1

	status := a.handle_slash('/focus')
	assert status.text().contains('ARMED — 1 auto-turn(s) left')

	a.handle_slash('/focus off')
	assert a.focus_remaining == 0
	assert a.handle_slash('/focus status').text().contains('focus mode: off')

	bad := a.handle_slash('/focus soon')
	assert bad.lines[0].kind == 'error'
}

// -- the goal grammar ----------------------------------------------------------

fn test_every_proof_shorthand_parses_to_the_predicate_the_judge_expects() {
	exit_code, e1 := parse_proof('exit_code: go test ./…')
	assert e1 == ''
	assert jstr(exit_code, 'type') == 'exit_code'
	assert jstr(exit_code, 'command') == 'go test ./…'
	assert jint(exit_code, 'expect') == 0

	exists, e2 := parse_proof('file_exists:docs/readme.md')
	assert e2 == ''
	assert jstr(exists, 'path') == 'docs/readme.md'

	contains, e3 := parse_proof('file_contains:src/x.v:fn main')
	assert e3 == ''
	assert jstr(contains, 'path') == 'src/x.v'
	assert jstr(contains, 'text') == 'fn main'

	matches, e4 := parse_proof('file_matches:src/x.v:^fn .*')
	assert e4 == ''
	assert jstr(matches, 'pattern') == '^fn .*', 'file_matches names its needle a pattern'

	output, e5 := parse_proof('command_output_contains:go version:go1')
	assert e5 == ''
	assert jstr(output, 'command') == 'go version'
	assert jstr(output, 'text') == 'go1'

	ast, e6 := parse_proof('ast_assert:src/x.py:main')
	assert e6 == ''
	assert jstr(ast, 'symbol') == 'main'

	unchanged, e7 := parse_proof('file_unchanged:lock.json:abc123')
	assert e7 == ''
	assert jstr(unchanged, 'baseline_hash') == 'abc123'
}

fn test_a_malformed_proof_says_what_is_missing() {
	_, no_colon := parse_proof('exit_code')
	assert no_colon.contains("proof needs '<type>:<arg>'")

	_, no_needle := parse_proof('file_contains:src/x.v')
	assert no_needle.contains("file_contains needs '<path-or-cmd>:<text>'")

	_, unknown := parse_proof('vibes:good')
	assert unknown.contains('unknown proof type')
}

fn test_a_goal_needs_at_least_one_checkable_clause() {
	mut a, dir, saved := sandboxed_router('goal-empty')
	defer {
		os.rmdir_all(dir) or {}
		restore_config(saved)
	}
	bare := a.handle_slash('/goal set just a wish')
	assert bare.lines[0].kind == 'error'
	assert bare.text().contains('at least one clause')
	assert !a.goal.status().active

	unprovable := a.handle_slash('/goal set ship it | it feels right')
	assert unprovable.lines[0].kind == 'error'
	assert unprovable.text().contains('machine-checkable proof')
	assert !a.goal.status().active
}

fn test_the_goal_grammar_sorts_clauses_anti_clauses_and_invariants() {
	mut a, dir, saved := sandboxed_router('goal-set')
	defer {
		os.rmdir_all(dir) or {}
		restore_config(saved)
	}
	r := a.handle_slash('/goal set ship the parser | tests pass @ exit_code:go test | docs exist @ file_exists:docs.md | !no secrets leak @ file_contains:out.log:TOKEN | ~lockfile frozen @ file_unchanged:lock.json:abc')
	assert r.lines[0].kind == 'info', r.text()
	assert r.text().contains('2 clause(s), 1 anti, 1 invariant')

	st := a.goal.status()
	assert st.active
	assert st.statement == 'ship the parser'
	assert st.clauses.len == 2
	assert st.clauses[0].id == 'C1'
	assert st.clauses[1].text == 'docs exist'
	assert st.anti.len == 1
	assert st.invariants.len == 1

	// and the whole contract is on the log, not in a field
	types := a.log.events(a.log.branch).map(it.typ)
	assert 'goal.set' in types
}

fn test_a_goal_clause_may_be_raw_json_for_full_control() {
	mut a, dir, saved := sandboxed_router('goal-json')
	defer {
		os.rmdir_all(dir) or {}
		restore_config(saved)
	}
	r := a.handle_slash('/goal set ship it | {"id": "C9", "text": "advisory note", "weight": 1.0, "advisory": true}')
	assert r.lines[0].kind == 'info', r.text()
	st := a.goal.status()
	assert st.clauses.len == 1
	assert st.clauses[0].id == 'C9'
	assert st.clauses[0].advisory

	broken := a.handle_slash('/goal set again | {not json}')
	assert broken.lines[0].kind == 'error'
	assert broken.text().contains('clause 1: invalid JSON')
}

fn test_goal_waive_splits_on_the_reason_flag() {
	mut a, dir, saved := sandboxed_router('goal-waive')
	defer {
		os.rmdir_all(dir) or {}
		restore_config(saved)
	}
	a.handle_slash('/goal set ship it | docs exist @ file_exists:docs.md')
	ok := a.handle_slash('/goal waive C1 --reason the docs live in the wiki')
	assert ok.text().contains('clause C1 waived')
	assert a.goal.status().clauses[0].state == 'WAIVED'

	missing := a.handle_slash('/goal waive')
	assert missing.lines[0].kind == 'error'
	assert missing.text().contains('--reason')

	nosuch := a.handle_slash('/goal waive C7 --reason nope')
	assert nosuch.text().contains('no such clause: C7')
}

fn test_an_unknown_goal_subcommand_lists_the_real_ones() {
	mut a, dir, saved := sandboxed_router('goal-sub')
	defer {
		os.rmdir_all(dir) or {}
		restore_config(saved)
	}
	r := a.handle_slash('/goal frobnicate')
	assert r.lines[0].kind == 'error'
	for sub in ['set', 'prove', 'prove-all', 'close', 'status', 'waive', 'clear'] {
		assert r.text().contains(sub)
	}
}

// -- budget --------------------------------------------------------------------

fn test_an_unset_budget_reads_as_unlimited_not_as_a_huge_number() {
	mut a, dir, saved := sandboxed_router('budget')
	defer {
		os.rmdir_all(dir) or {}
		restore_config(saved)
	}
	r := a.handle_slash('/budget')
	assert r.text().contains('budget OK')
	assert r.text().contains('steps  0 / ∞')
	assert r.text().contains('UNLIMITED by default')
}

fn test_a_budget_limit_is_applied_and_sealed() {
	mut a, dir, saved := sandboxed_router('budget-set')
	defer {
		os.rmdir_all(dir) or {}
		restore_config(saved)
	}
	r := a.handle_slash('/budget steps 5')
	assert r.lines[0].kind == 'info', r.text()
	assert a.budget_gov.budget.max_steps == 5
	assert a.handle_slash('/budget').text().contains('steps  0 / 5')

	// the long form names the axis in the second position
	a.handle_slash('/budget extend steps 9')
	assert a.budget_gov.budget.max_steps == 9

	types := a.log.events(a.log.branch).map(it.typ)
	assert 'budget.event' in types
}

fn test_a_budget_command_that_names_no_axis_prints_the_usage() {
	mut a, dir, saved := sandboxed_router('budget-bad')
	defer {
		os.rmdir_all(dir) or {}
		restore_config(saved)
	}
	r := a.handle_slash('/budget sideways')
	assert r.lines[0].kind == 'error'
	assert r.text().contains('usage: /budget')
}

// -- usage ---------------------------------------------------------------------

fn test_usage_totals_only_the_turns_that_carry_a_usage_block() {
	mut turns := []Turn{}
	turns << Turn{
		has_usage: true
		usage:     {
			'prompt_tokens':     json2.Any(100)
			'completion_tokens': json2.Any(40)
		}
	}
	turns << Turn{} // no usage — must not be counted, and must not crash
	turns << Turn{
		has_usage: true
		usage:     {
			'prompt_tokens':     json2.Any(7)
			'completion_tokens': json2.Any(3)
		}
	}
	r := usage_result(turns)
	assert r.text() == ' turns: 3   prompt tokens: 107   completion tokens: 43'
}

// -- the deferred jobs ---------------------------------------------------------

fn test_every_job_the_router_names_is_a_job_the_runner_knows() {
	mut a, dir, saved := sandboxed_router('jobs')
	defer {
		os.rmdir_all(dir) or {}
		restore_config(saved)
	}
	// one representative invocation per command that defers work
	lines := [
		'/impact login src',
		'/judge file_exists /tmp',
		'/compile ship the thing',
		'/evolve coder',
		'/debate is this wise',
		'/market write docs | write tests',
		'/verify ship the thing',
		'/roleforge a specialist for parsers',
		'/dual what is the capital of france',
		'/race refactor the parser',
		'/crew wait a1,a2',
	]
	for line in lines {
		r := a.handle_slash(line)
		assert r.job != '', '${line} deferred nothing'
		assert r.job in slash_job_names, '${line} names an unknown job: ${r.job}'
	}
	// and an unknown job name is reported rather than silently doing nothing
	assert a.slash_job('nonexistent', '').lines[0].kind == 'error'
}

fn test_judge_shorthand_builds_the_predicate_the_job_will_run() {
	mut a, dir, saved := sandboxed_router('judge')
	defer {
		os.rmdir_all(dir) or {}
		restore_config(saved)
	}
	r := a.handle_slash('/judge file_exists /etc/hosts')
	assert r.job == 'judge'
	decoded := json2.decode[json2.Any](r.job_arg) or { panic(err) }
	m := decoded as map[string]json2.Any
	assert jstr(m, 'type') == 'file_exists'
	assert jstr(m, 'path') == '/etc/hosts'

	// a type with no shorthand lists the ones that have it
	bad := a.handle_slash('/judge vibes good')
	assert bad.lines[0].kind == 'error'
	assert bad.text().contains('predicate types:')

	// and the raw JSON form goes through untouched
	raw := a.handle_slash('/judge {"type": "exit_code", "command": "true", "expect": 0}')
	assert raw.job == 'judge'
	assert raw.job_arg.contains('exit_code')
}

fn test_a_judge_job_actually_reaches_a_verdict() {
	mut a, dir, saved := sandboxed_router('judge-run')
	defer {
		os.rmdir_all(dir) or {}
		restore_config(saved)
	}
	probe := os.join_path(dir, 'present.txt')
	os.write_file(probe, 'here') or { panic(err) }

	hit := a.handle_slash('/judge file_exists ${probe}')
	pass := a.slash_job(hit.job, hit.job_arg)
	assert pass.text().starts_with('✓ [file_exists]'), pass.text()

	miss := a.handle_slash('/judge file_exists ${probe}.nope')
	fail := a.slash_job(miss.job, miss.job_arg)
	assert fail.text().starts_with('✗ [file_exists]'), fail.text()
}

// -- commands that answer straight away ----------------------------------------

fn test_the_read_only_status_commands_all_answer_without_erroring() {
	mut a, dir, saved := sandboxed_router('status')
	defer {
		os.rmdir_all(dir) or {}
		restore_config(saved)
	}
	// every one of these is a formatter over the live log; the point is
	// that the whole set is wired, since a mis-named method here compiles
	// fine and only fails when a user types the command.
	for line in ['/state', '/forecast', '/oracle', '/vitals', '/attention', '/mastermind',
		'/dashboard', '/router', '/spec', '/heal', '/skills', '/coverage', '/fuzz', '/memory',
		'/replay', '/health', '/usage', '/about', '/brain', '/bandit', '/recall', '/mission', '/crew',
		'/council', '/enforce', '/covenant', '/auto', '/prompt', '/forge', '/graph', '/fabric',
		'/ci', '/dual', '/constitution', '/workflow', '/theater'] {
		r := a.handle_slash(line)
		for ln in r.lines {
			assert ln.kind != 'error', '${line} → ${r.text()}'
		}
	}
}

fn test_enforce_and_covenant_reject_an_unknown_subcommand_by_name() {
	mut a, dir, saved := sandboxed_router('subs')
	defer {
		os.rmdir_all(dir) or {}
		restore_config(saved)
	}
	e := a.handle_slash('/enforce sideways')
	assert e.lines[0].kind == 'error'
	assert e.text().contains("unknown /enforce subcommand 'sideways'")

	c := a.handle_slash('/covenant sideways')
	assert c.lines[0].kind == 'error'
	assert c.text().contains("unknown /covenant subcommand 'sideways'")
}

fn test_covenant_test_derives_effects_without_running_the_tool() {
	mut a, dir, saved := sandboxed_router('cov-test')
	defer {
		os.rmdir_all(dir) or {}
		restore_config(saved)
	}
	target := os.join_path(dir, 'untouched.txt')
	r := a.handle_slash('/covenant test write_file {"path": "${target}", "content": "x"}')
	assert r.text().contains('effects derived from this call')
	assert !os.exists(target), 'a dry run must not write the file'

	bad := a.handle_slash('/covenant test write_file not-json')
	assert bad.lines[0].kind == 'error'
	assert bad.text().contains('args must be JSON')

	none_named := a.handle_slash('/covenant test')
	assert none_named.lines[0].kind == 'error'
	assert none_named.text().contains('usage: /covenant test')
}

// -- partition semantics -------------------------------------------------------

fn test_covenant_splits_on_one_space_so_a_json_payload_survives() {
	// `partition(" ")` is not `split(None, 1)`: the payload here starts
	// with a brace, and the two would agree — but a payload that begins
	// with its own spacing must not be re-trimmed into the command word.
	head, tail := partition_space('test write_file  {"path": "x"}')
	assert head == 'test'
	assert tail == 'write_file  {"path": "x"}'

	only, nothing := partition_space('report')
	assert only == 'report'
	assert nothing == ''
}
