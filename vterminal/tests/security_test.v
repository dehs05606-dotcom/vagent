module main

import src.config
import src.security
import src.utils

fn engine(cfg config.PermissionConfig) security.Engine {
	mut log := utils.discard_logger()
	return security.new_engine(cfg, '/tmp/project', mut log)
}

// req mirrors how the registry builds a request: the summary is qualified with
// the tool name, the target is the bare command or path.
fn req(tool string, level security.Level, target string) security.Request {
	return security.Request{
		tool:    tool
		level:   level
		summary: '${tool} ${target}'
		target:  target
	}
}

fn test_read_is_auto_approved_by_default() {
	e := engine(config.PermissionConfig{})
	assert e.evaluate(req('read_file', .read, 'src/a.v')) == .allow
}

fn test_write_asks_in_ask_mode_and_denies_when_headless() {
	mut e := engine(config.PermissionConfig{
		mode: 'ask'
	})
	assert e.evaluate(req('write_file', .write, 'a.v')) == .ask
	e.interactive = false
	// With nobody to ask, the safe answer is no.
	assert e.evaluate(req('write_file', .write, 'a.v')) == .deny
}

fn test_allow_mode_permits_writes() {
	e := engine(config.PermissionConfig{
		mode: 'allow'
	})
	assert e.evaluate(req('write_file', .write, 'a.v')) == .allow
}

fn test_deny_rules_beat_allow_mode() {
	e := engine(config.PermissionConfig{
		mode: 'allow'
		deny: ['git push']
	})
	assert e.evaluate(req('shell', .execute, 'git push origin main')) == .deny
	assert e.evaluate(req('shell', .execute, 'git status')) == .allow
}

fn test_allow_rules_match_prefix_tool_and_glob() {
	e := engine(config.PermissionConfig{
		mode:  'ask'
		allow: ['shell ls', 'write_file:src/**', 'git_commit']
	})
	assert e.evaluate(req('shell', .execute, 'ls -la')) == .allow
	assert e.evaluate(req('shell', .execute, 'rm x')) == .ask

	in_scope := security.Request{
		tool:    'write_file'
		level:   .write
		summary: 'write_file src/a/b.v'
		target:  'src/a/b.v'
	}
	assert e.evaluate(in_scope) == .allow
	out_of_scope := security.Request{
		tool:    'write_file'
		level:   .write
		summary: 'write_file secrets/key.pem'
		target:  'secrets/key.pem'
	}
	assert e.evaluate(out_of_scope) == .ask

	assert e.evaluate(req('git_commit', .write, 'fix things')) == .allow
}

fn test_destructive_commands_are_flagged() {
	assert security.classify_command('rm -rf /') != ''
	assert security.classify_command('sudo apt install x') != ''
	assert security.classify_command('git push --force origin main') != ''
	assert security.classify_command('ls -la') == ''
	assert security.classify_command('v test .') == ''
}

fn test_danger_always_prompts_even_in_allow_mode() {
	e := engine(config.PermissionConfig{
		mode: 'allow'
	})
	// `sudo` is flagged as destructive but is not in the default deny list, so
	// this exercises the danger path rather than the deny path.
	r := security.Request{
		tool:    'shell'
		level:   .execute
		summary: 'shell sudo apt install x'
		target:  'sudo apt install x'
		danger:  security.classify_command('sudo apt install x')
	}
	assert r.danger != ''
	assert e.evaluate(r) == .ask
}

fn test_explicit_deny_rule_wins_over_the_danger_prompt() {
	// A configured deny is a decision already made; it must not be re-asked.
	e := engine(config.PermissionConfig{
		mode: 'allow'
	})
	r := security.Request{
		tool:    'shell'
		level:   .execute
		summary: 'shell rm -rf /'
		target:  'rm -rf /'
		danger:  security.classify_command('rm -rf /')
	}
	assert e.evaluate(r) == .deny
}

fn test_always_allow_grant_persists_for_the_session() {
	mut e := engine(config.PermissionConfig{
		mode: 'ask'
	})
	e.ask_fn = fn (r security.Request) security.Approval {
		return .always
	}
	first := e.authorize(req('write_file', .write, 'a.v')) or { false }
	assert first
	// The second call must not reach the prompt at all.
	e.ask_fn = fn (r security.Request) security.Approval {
		return .reject
	}
	second := e.authorize(req('write_file', .write, 'b.v')) or { false }
	assert second
	assert 'write_file' in e.granted_this_session()

	e.reset_session_grants()
	third := e.authorize(req('write_file', .write, 'c.v')) or { false }
	assert !third
}

fn test_reject_all_stops_everything_afterwards() {
	mut e := engine(config.PermissionConfig{
		mode: 'ask'
	})
	e.ask_fn = fn (r security.Request) security.Approval {
		return .reject_all
	}
	assert !(e.authorize(req('write_file', .write, 'w')) or { true })
	// Even a normally auto-approved read is refused once the user said stop.
	assert e.evaluate(req('read_file', .read, 'r')) == .deny
}
