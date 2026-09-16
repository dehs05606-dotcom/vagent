module vagent

import os
import x.json2

const oblige_spec = '§6 Every module ships with a test
@oblige on write src/**/*.py require exists tests/test_{stem}.py

§7 A deleted module takes its test with it
@oblige on delete src/**/*.py require absent tests/test_{stem}.py

§8 A migration carries a version marker
@oblige on write migrations/*.sql require contains migrations/{stem}.sql matching (?i)version
'

fn ob_args(pairs map[string]string) map[string]json2.Any {
	mut out := map[string]json2.Any{}
	for k, v in pairs {
		out[k] = json2.Any(v)
	}
	return out
}

fn oblige_root(name string) string {
	root := os.join_path(os.temp_dir(), 'vagent-oblige-${name}-${os.getpid()}')
	os.rmdir_all(root) or {}
	os.mkdir_all(os.join_path(root, 'src')) or { panic(err) }
	os.mkdir_all(os.join_path(root, 'tests')) or { panic(err) }
	return root
}

fn test_the_spec_parses_into_exactly_its_rules() {
	rules, errors := parse_oblige_rules(oblige_spec)
	assert rules.len == 3, '${rules.len}'
	assert errors.len == 0, '${errors}'
	assert rules[0].act == 'write' && rules[0].kind == 'exists'
	assert rules[1].act == 'delete' && rules[1].kind == 'absent'
	assert rules[2].kind == 'contains' && rules[2].pattern.contains('version')
}

fn test_a_write_incurs_its_debt_and_the_matching_write_settles_it() {
	root := oblige_root('ob1')
	defer {
		os.rmdir_all(root) or {}
	}
	mut log := new_event_log(os.join_path(root, 'log.jsonl'), 'main', 'test')
	mut l := new_ledger(log, oblige_spec, root)

	debts := l.record('write_file', ob_args({
		'path':    'src/parser.py'
		'content': 'x'
	}))
	assert debts.len == 1
	assert debts[0].target == 'tests/test_parser.py'
	assert debts[0].incurred_by == 'src/parser.py'

	blocker := l.blocker()
	assert blocker != ''
	assert blocker.contains('tests/test_parser.py'), blocker
	assert blocker.contains('must exist')

	// settling is a fact on disk, not a claim
	os.write_file(os.join_path(root, 'tests', 'test_parser.py'), 'def test(): pass\n') or {
		panic(err)
	}
	assert l.blocker() == ''
	assert l.outstanding().len == 0
}

fn test_a_settled_debt_that_is_undone_is_outstanding_again() {
	root := oblige_root('ob2')
	defer {
		os.rmdir_all(root) or {}
	}
	mut log := new_event_log(os.join_path(root, 'log.jsonl'), 'main', 'test')
	mut l := new_ledger(log, oblige_spec, root)
	l.record('write_file', ob_args({
		'path':    'src/parser.py'
		'content': 'x'
	}))
	test_path := os.join_path(root, 'tests', 'test_parser.py')
	os.write_file(test_path, 'ok\n') or { panic(err) }
	assert l.outstanding().len == 0
	os.rm(test_path) or { panic(err) }
	assert l.outstanding().len == 1, 'a ledger that only counts down was satisfied once'
}

fn test_a_later_act_on_a_path_supersedes_the_earlier_ones_debts() {
	root := oblige_root('ob3')
	defer {
		os.rmdir_all(root) or {}
	}
	mut log := new_event_log(os.join_path(root, 'log.jsonl'), 'main', 'test')
	mut l := new_ledger(log, oblige_spec, root)

	// write then delete: the two clauses contradict each other, and no
	// sequence of acts could satisfy both
	l.record('write_file', ob_args({
		'path':    'src/parser.py'
		'content': 'x'
	}))
	l.record('delete_path', ob_args({
		'path': 'src/parser.py'
	}))
	out := l.outstanding()
	// only the delete's debt survives, and it is already satisfied: there
	// is no test file
	assert out.len == 0, out.map(it.describe()).str()

	// with the test present, the delete's debt is the live one
	os.write_file(os.join_path(root, 'tests', 'test_parser.py'), 'ok\n') or { panic(err) }
	live := l.outstanding()
	assert live.len == 1
	assert live[0].kind == 'absent'
}

fn test_the_shell_route_incurs_exactly_what_the_tool_would() {
	root := oblige_root('ob4')
	defer {
		os.rmdir_all(root) or {}
	}
	mut log := new_event_log(os.join_path(root, 'log.jsonl'), 'main', 'test')
	mut l := new_ledger(log, oblige_spec, root)
	shell := l.incurred_by('run_command', ob_args({
		'command': 'echo x > src/parser.py'
	}))
	tool := l.incurred_by('write_file', ob_args({
		'path':    'src/parser.py'
		'content': 'x'
	}))
	assert shell.len == 1
	assert shell[0].id() == tool[0].id()
}

fn test_a_contains_debt_checks_the_content_of_the_target() {
	root := oblige_root('ob5')
	os.mkdir_all(os.join_path(root, 'migrations')) or { panic(err) }
	defer {
		os.rmdir_all(root) or {}
	}
	mut log := new_event_log(os.join_path(root, 'log.jsonl'), 'main', 'test')
	mut l := new_ledger(log, oblige_spec, root)
	l.record('write_file', ob_args({
		'path':    'migrations/001_init.sql'
		'content': 'CREATE TABLE x();'
	}))
	// the file has no version marker yet
	os.write_file(os.join_path(root, 'migrations', '001_init.sql'), 'CREATE TABLE x();') or {
		panic(err)
	}
	assert l.outstanding().len == 1
	os.write_file(os.join_path(root, 'migrations', '001_init.sql'), '-- VERSION 1\nCREATE TABLE x();') or {
		panic(err)
	}
	assert l.outstanding().len == 0
}

fn test_the_deep_glob_matches_at_every_depth() {
	root := oblige_root('ob6')
	defer {
		os.rmdir_all(root) or {}
	}
	mut log := new_event_log(os.join_path(root, 'log.jsonl'), 'main', 'test')
	l := new_ledger(log, oblige_spec, root)
	// directly under src/
	assert l.incurred_by('write_file', ob_args({
		'path':    'src/a.py'
		'content': 'x'
	})).len == 1
	// and nested
	assert l.incurred_by('write_file', ob_args({
		'path':    'src/deep/nested/b.py'
		'content': 'x'
	})).len == 1
	// a path outside the glob incurs nothing
	assert l.incurred_by('write_file', ob_args({
		'path':    'docs/readme.md'
		'content': 'x'
	})).len == 0
}

fn test_the_templates_expand_from_the_incurring_path() {
	assert expand_target('tests/test_{stem}.py', 'src/deep/parser.py') == 'tests/test_parser.py'
	assert expand_target('{parent}/test_{name}', 'src/deep/parser.py') == 'src/deep/test_parser.py'
	assert expand_target('{path}.bak', 'src/parser.py') == 'src/parser.py.bak'
	// a file with no extension keeps its whole name as the stem
	assert expand_target('{stem}', 'Makefile') == 'Makefile'
}

fn test_the_ledger_survives_a_restart() {
	root := oblige_root('ob7')
	defer {
		os.rmdir_all(root) or {}
	}
	path := os.join_path(root, 'log.jsonl')
	mut log := new_event_log(path, 'main', 'test')
	mut l := new_ledger(log, oblige_spec, root)
	l.record('write_file', ob_args({
		'path':    'src/parser.py'
		'content': 'x'
	}))
	mut reopened := new_ledger(new_event_log(path, 'main', 'test'), oblige_spec, root)
	assert reopened.outstanding().len == 1
	assert reopened.blocker().contains('tests/test_parser.py')
}

fn test_no_rules_means_no_blocker_and_malformed_ones_are_reported() {
	root := oblige_root('ob8')
	defer {
		os.rmdir_all(root) or {}
	}
	mut quiet := new_ledger(new_event_log(os.join_path(root, 'q.jsonl'), 'main', 'test'),
		'', root)
	assert quiet.blocker() == ''
	assert quiet.report().contains('no @oblige rules')

	bad := new_ledger(new_event_log(os.join_path(root, 'b.jsonl'), 'main', 'test'), '§9 x\n@oblige sideways foo\n' +
		'§10 y\n@oblige on write a require contains b\n' +
		'§11 z\n@oblige on write a require contains b matching [unclosed\n', root)
	assert bad.errors.len == 3, '${bad.errors}'
	assert bad.rules.len == 0
}
