module vagent

import os
import x.json2

// cli_test.v — the headless subcommands.
//
// Exit codes are the point of most of these: a `verify-log` that always
// answered 0 would pass in CI while the log rotted.

fn sandboxed_cli(name string) (&Agent, string) {
	dir := os.join_path(os.temp_dir(), 'vagent-cli-${name}-${os.getpid()}')
	os.rmdir_all(dir) or {}
	os.mkdir_all(dir) or { panic(err) }
	return new_agent_in(Config{}, AgentOpts{ home: dir, cwd: os.getwd() }), dir
}

fn test_no_argument_prints_the_usage_and_fails() {
	mut a, dir := sandboxed_cli('bare')
	defer {
		os.rmdir_all(dir) or {}
	}
	r := a.run_headless([])
	assert r.code == 2
	assert r.out.len == 0
	assert r.errs[0].contains('vagent verify-log')
}

fn test_an_unknown_command_reports_it_and_shows_the_usage() {
	mut a, dir := sandboxed_cli('unknown')
	defer {
		os.rmdir_all(dir) or {}
	}
	r := a.run_headless(['frobnicate'])
	assert r.code == 2
	assert r.errs[0] == 'unknown command: frobnicate'
	assert r.errs[1].contains('headless subcommands')
}

fn test_verify_log_passes_on_a_fresh_log() {
	mut a, dir := sandboxed_cli('verify')
	defer {
		os.rmdir_all(dir) or {}
	}
	r := a.run_headless(['verify-log'])
	assert r.code == 0
	assert r.out[0].starts_with('OK: '), r.out[0]
}

fn test_replay_renders_the_session_as_a_film() {
	mut a, dir := sandboxed_cli('replay')
	defer {
		os.rmdir_all(dir) or {}
	}
	a.log.append('user.message', {
		'text': json2.Any('ship the parser')
	}, AppendOpts{ actor: 'human' })
	a.log.append('tool.call', {
		'name': json2.Any('write_file')
	}, AppendOpts{})
	a.log.append('tool.result', {
		'name':   json2.Any('write_file')
		'status': json2.Any('done')
	}, AppendOpts{})

	r := a.run_headless(['replay'])
	assert r.code == 0
	body := r.out.join('\n')
	assert body.contains('❯ ship the parser')
	assert body.contains('⚙ write_file')
	assert body.contains('✓ write_file (done)')
}

fn test_a_seq_command_refuses_a_missing_or_non_numeric_argument() {
	mut a, dir := sandboxed_cli('seqs')
	defer {
		os.rmdir_all(dir) or {}
	}
	for cmd in ['rewind', 'revert', 'why'] {
		missing := a.run_headless([cmd])
		assert missing.code == 2, cmd
		assert missing.errs[0] == 'usage: ${cmd} <seq>', cmd

		// "soon" must not be read as seq 0 — that would rewind everything
		word := a.run_headless([cmd, 'soon'])
		assert word.code == 2, cmd
		assert word.errs[0] == 'usage: ${cmd} <seq>', cmd
	}
}

fn test_why_reports_a_seq_that_does_not_exist() {
	mut a, dir := sandboxed_cli('why-missing')
	defer {
		os.rmdir_all(dir) or {}
	}
	r := a.run_headless(['why', '9999'])
	assert r.code == 1
	assert r.errs[0] == 'no event at seq 9999'
}

fn test_why_walks_the_causal_chain_back_to_the_instruction() {
	mut a, dir := sandboxed_cli('why')
	defer {
		os.rmdir_all(dir) or {}
	}
	cause := a.log.append('user.message', {
		'text': json2.Any('add a parser')
	}, AppendOpts{ actor: 'human' })
	effect := a.log.append('tool.call', {
		'name': json2.Any('write_file')
	}, AppendOpts{ causation_id: cause.id })

	r := a.run_headless(['why', effect.seq.str()])
	assert r.code == 0
	body := r.out.join('\n')
	assert body.contains('seq ${effect.seq} tool.call')
	assert body.contains('seq ${cause.seq} user.message')
	assert body.contains('add a parser')
}

fn test_cost_reports_the_fold_not_a_running_total() {
	mut a, dir := sandboxed_cli('cost')
	defer {
		os.rmdir_all(dir) or {}
	}
	r := a.run_headless(['cost'])
	assert r.code == 0
	assert r.out[0].starts_with('cost: ')
	assert r.out[1].starts_with('tool calls: ')
}

fn test_goal_status_is_the_compass_and_an_unknown_subcommand_fails() {
	mut a, dir := sandboxed_cli('goal')
	defer {
		os.rmdir_all(dir) or {}
	}
	status := a.run_headless(['goal'])
	assert status.code == 0
	assert status.out.len == 1

	bad := a.run_headless(['goal', 'frobnicate'])
	assert bad.code == 2
	assert bad.errs[0] == 'unknown goal subcommand: frobnicate'

	no_clause := a.run_headless(['goal', 'prove'])
	assert no_clause.code == 2
	assert no_clause.errs[0] == 'usage: goal prove <clause-id>'
}

fn test_closing_an_unachieved_goal_exits_non_zero() {
	mut a, dir := sandboxed_cli('goal-close')
	defer {
		os.rmdir_all(dir) or {}
	}
	a.handle_slash('/goal set ship it | docs exist @ file_exists:${dir}/missing.md')
	r := a.run_headless(['goal', 'close'])
	// nothing proved the clause, so this is not an achievement — and a
	// script that gates on it must see the failure
	assert r.code == 1, r.out.join('\n')
	assert r.out[0].starts_with('GOAL CLOSED: ')
}

fn test_forge_prints_the_environment_digest() {
	mut a, dir := sandboxed_cli('forge')
	defer {
		os.rmdir_all(dir) or {}
	}
	r := a.run_headless(['forge'])
	assert r.code == 0
	assert r.out[0].starts_with('environment digest: ')
	assert r.out.len == 4
	// the probe is sealed, so the digest a later drift check compares
	// against is on the log rather than in memory
	types := a.log.events(a.log.branch).map(it.typ)
	assert 'env.digest' in types
}

fn test_stats_answers_even_with_no_history() {
	mut a, dir := sandboxed_cli('stats')
	defer {
		os.rmdir_all(dir) or {}
	}
	r := a.run_headless(['stats'])
	assert r.code == 0
	assert r.out.len == 1
}
