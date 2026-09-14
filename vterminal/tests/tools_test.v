module main

import os
import src.config
import src.security
import src.tools
import src.utils

// sandbox creates an isolated project directory plus a registry wired to an
// allow-everything policy, so the tests exercise the tools rather than the
// permission prompt (which has its own test file).
fn sandbox(name string) (string, tools.Registry) {
	root := os.join_path(os.temp_dir(), 'vagent_test_${name}_${os.getpid()}')
	os.rmdir_all(root) or {}
	os.mkdir_all(root) or { panic(err) }
	mut log := utils.discard_logger()
	mut perms := security.new_engine(config.PermissionConfig{
		mode: 'allow'
	}, root, mut log)
	mut ctx := tools.Context{
		root:    root
		workdir: root
		log:     &log
	}
	ctx.probe_environment()
	mut reg := tools.new_registry(ctx, mut perms)
	reg.register_builtins()
	return root, reg
}

fn cleanup(root string) {
	os.rmdir_all(root) or {}
}

fn test_write_then_read_round_trip() {
	root, mut reg := sandbox('rw')
	defer { cleanup(root) }
	w := reg.execute('write_file', '{"path":"a/b/hello.txt","content":"line1\\nline2\\n"}')
	assert w.ok, w.error
	assert os.exists(os.join_path(root, 'a', 'b', 'hello.txt'))

	r := reg.execute('read_file', '{"path":"a/b/hello.txt"}')
	assert r.ok, r.error
	// Output is line numbered so later edits can cite accurate line numbers.
	assert r.output.contains('1 | line1')
	assert r.output.contains('2 | line2')
}

fn test_read_file_paging() {
	root, mut reg := sandbox('paging')
	defer { cleanup(root) }
	mut body := ''
	for i in 1 .. 51 {
		body += 'line${i}\n'
	}
	reg.execute('write_file', '{"path":"big.txt","content":"${body.replace('\n', '\\n')}"}')
	r := reg.execute('read_file', '{"path":"big.txt","offset":10,"limit":5}')
	assert r.ok, r.error
	assert r.output.contains('10 | line10')
	assert r.output.contains('14 | line14')
	assert !r.output.contains('15 | line15')
	assert r.output.contains('offset=15')
}

fn test_edit_file_requires_unique_match() {
	root, mut reg := sandbox('edit')
	defer { cleanup(root) }
	reg.execute('write_file', '{"path":"dup.txt","content":"x\\nx\\ny\\n"}')

	ambiguous := reg.execute('edit_file', '{"path":"dup.txt","old_string":"x","new_string":"z"}')
	assert !ambiguous.ok
	assert ambiguous.error.contains('appears 2 times')

	all := reg.execute('edit_file',
		'{"path":"dup.txt","old_string":"x","new_string":"z","replace_all":true}')
	assert all.ok, all.error
	content := os.read_file(os.join_path(root, 'dup.txt')) or { panic(err) }
	assert content == 'z\nz\ny\n'
}

fn test_edit_file_reports_missing_old_string() {
	root, mut reg := sandbox('editmiss')
	defer { cleanup(root) }
	reg.execute('write_file', '{"path":"f.txt","content":"hello\\n"}')
	res := reg.execute('edit_file', '{"path":"f.txt","old_string":"nope","new_string":"x"}')
	assert !res.ok
	assert res.error.contains('not found')
}

fn test_path_confinement_blocks_escape() {
	root, mut reg := sandbox('confine')
	defer { cleanup(root) }
	res := reg.execute('read_file', '{"path":"../../../etc/passwd"}')
	assert !res.ok
	assert res.error.contains('escapes the workspace')
}

fn test_search_text_finds_lines_with_locations() {
	root, mut reg := sandbox('search')
	defer { cleanup(root) }
	reg.execute('write_file', '{"path":"src/one.v","content":"fn alpha() {}\\nfn beta() {}\\n"}')
	reg.execute('write_file', '{"path":"src/two.v","content":"fn alpha_two() {}\\n"}')

	res := reg.execute('search_text', '{"pattern":"alpha"}')
	assert res.ok, res.error
	assert res.output.contains('src/one.v:1')
	assert res.output.contains('src/two.v:1')

	scoped := reg.execute('search_text', '{"pattern":"alpha","glob":"**/one.v"}')
	assert scoped.ok, scoped.error
	assert scoped.output.contains('one.v')
	assert !scoped.output.contains('two.v')
}

fn test_search_files_by_glob() {
	root, mut reg := sandbox('globfiles')
	defer { cleanup(root) }
	reg.execute('write_file', '{"path":"src/a/deep.v","content":"x"}')
	reg.execute('write_file', '{"path":"notes.md","content":"x"}')

	res := reg.execute('search_files', '{"pattern":"**/*.v"}')
	assert res.ok, res.error
	assert res.output.contains('deep.v')
	assert !res.output.contains('notes.md')
}

fn test_shell_reports_exit_code() {
	root, mut reg := sandbox('shell')
	defer { cleanup(root) }
	ok := reg.execute('shell', '{"command":"echo hello-from-shell"}')
	assert ok.ok, ok.error
	assert ok.output.contains('hello-from-shell')
	assert ok.output.contains('exit code: 0')

	bad := reg.execute('shell', '{"command":"exit 3"}')
	assert !bad.ok
	assert bad.output.contains('exit code: 3')
}

fn test_unknown_tool_and_bad_arguments_are_reported_not_fatal() {
	root, mut reg := sandbox('args')
	defer { cleanup(root) }
	unknown := reg.execute('no_such_tool', '{}')
	assert !unknown.ok
	assert unknown.error.contains('unknown tool')

	missing := reg.execute('read_file', '{}')
	assert !missing.ok
	assert missing.error.contains('missing required argument "path"')

	malformed := reg.execute('read_file', '{not json')
	assert !malformed.ok
	assert malformed.error.contains('could not parse arguments')
}

fn test_update_plan_writes_context_plan() {
	root, mut reg := sandbox('plan')
	defer { cleanup(root) }
	res := reg.execute('update_plan', '{"steps":["read code","patch it","run tests"],"active":2}')
	assert res.ok, res.error
	assert reg.ctx.plan.len == 3
	assert reg.ctx.plan[0].status == 'done'
	assert reg.ctx.plan[1].status == 'active'
	assert reg.ctx.plan[2].status == 'pending'
}

fn test_schema_matches_registered_tools() {
	root, mut reg := sandbox('schema')
	defer { cleanup(root) }
	schema := reg.schema()
	assert schema.len == reg.len()
	first := schema[0].str()
	assert first.contains('"type"')
	assert first.contains('"function"')
	assert first.contains('"parameters"')
}

fn test_delete_file_guards_directories_and_root() {
	root, mut reg := sandbox('del')
	defer { cleanup(root) }
	reg.execute('write_file', '{"path":"sub/file.txt","content":"x"}')

	dir := reg.execute('delete_file', '{"path":"sub"}')
	assert !dir.ok
	assert dir.error.contains('recursive=true')

	self_delete := reg.execute('delete_file', '{"path":"."}')
	assert !self_delete.ok
	assert self_delete.error.contains('project root')

	file := reg.execute('delete_file', '{"path":"sub/file.txt"}')
	assert file.ok, file.error
	assert !os.exists(os.join_path(root, 'sub', 'file.txt'))
}
