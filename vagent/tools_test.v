module vagent

import os
import x.json2

fn tmp_work(name string) string {
	dir := os.join_path(os.temp_dir(), 'vagent-tools-${os.getpid()}', name)
	os.rmdir_all(dir) or {}
	os.mkdir_all(dir) or { panic(err) }
	return dir
}

fn test_registry_has_every_tool() {
	reg := build_registry()
	for name in ['read_file', 'write_file', 'edit_file', 'list_dir', 'file_info',
		'create_directory', 'copy_path', 'move_path', 'delete_path', 'search_files',
		'glob_files', 'run_command', 'live_shell', 'live_shell_reset', 'apply_patch',
		'web_fetch', 'web_search'] {
		assert name in reg, 'registry is missing ${name}'
	}
	assert reg.len == 17
	// the destructive tools must all be gated behind approval
	for name in ['write_file', 'edit_file', 'copy_path', 'move_path', 'delete_path',
		'run_command', 'live_shell', 'apply_patch'] {
		assert reg[name].risk == risk_confirm, '${name} is not risk_confirm'
	}
	// and the read-only ones must not be
	for name in ['read_file', 'list_dir', 'search_files', 'glob_files', 'web_fetch'] {
		assert reg[name].risk == risk_safe, '${name} should not need approval'
	}
	schema := reg['read_file'].openai_schema()
	assert jstr(schema, 'type') == 'function'
	assert jstr(jmap(schema, 'function'), 'name') == 'read_file'
}

fn test_write_read_and_edit_roundtrip() {
	dir := tmp_work('rw')
	f := os.join_path(dir, 'st.py')

	created := tool_write_file(f, 'a\nb\nc\n')
	assert created.starts_with('OK: created'), created
	assert created.contains('3 line(s)')

	shown := tool_read_file(f, 1, 1000)
	assert shown.contains('3 lines total, showing 1..3')
	assert shown.contains('1→a')

	// rewriting an existing file reports a diff, not a creation
	updated := tool_write_file(f, 'a\nB\nc\n')
	assert updated.starts_with('Updated'), updated
	assert updated.contains('1 addition(s)') && updated.contains('1 removal(s)')

	edited := tool_edit_file(f, 'B', 'beta', false)
	assert edited.contains('1 occurrence(s) replaced'), edited
	assert os.read_file(f)! == 'a\nbeta\nc\n'
}

fn test_edit_file_guards() {
	dir := tmp_work('guard')
	f := os.join_path(dir, 'g.txt')
	tool_write_file(f, 'x\nx\ny\n')

	// an empty old_string would interleave the replacement between every
	// character and destroy the file
	assert tool_edit_file(f, '', 'z', false).starts_with('ERROR: old_string must be')
	assert os.read_file(f)! == 'x\nx\ny\n'

	// an ambiguous match must not silently pick one
	amb := tool_edit_file(f, 'x', 'z', false)
	assert amb.contains('matches 2 places'), amb
	assert os.read_file(f)! == 'x\nx\ny\n'

	// replace_all makes it explicit
	assert tool_edit_file(f, 'x', 'z', true).contains('2 occurrence(s)')
	assert os.read_file(f)! == 'z\nz\ny\n'

	assert tool_edit_file(f, 'nope', 'z', false).starts_with('ERROR: old_string not found')
	assert tool_edit_file(os.join_path(dir, 'missing'), 'a', 'b', false)
		.starts_with('ERROR: file not found')
}

fn test_read_file_edges() {
	dir := tmp_work('read')
	f := os.join_path(dir, 'r.txt')
	tool_write_file(f, 'l1\nl2\nl3\nl4\nl5\n')

	windowed := tool_read_file(f, 2, 2)
	assert windowed.contains('showing 2..3')
	assert windowed.contains('l2') && windowed.contains('l3')
	assert !windowed.contains('l5')

	past := tool_read_file(f, 99, 10)
	assert past.contains('offset 99 is past the end of file')

	assert tool_read_file(dir, 1, 10).contains('is a directory')
	assert tool_read_file(os.join_path(dir, 'nope'), 1, 10).starts_with('ERROR: file not found')
}

fn test_directory_tools() {
	dir := tmp_work('fs')
	sub := os.join_path(dir, 'sub')
	assert tool_create_directory(sub).starts_with('OK: created directory')

	a := os.join_path(sub, 'a.txt')
	tool_write_file(a, 'hello')
	listing := tool_list_dir(dir)
	assert listing.contains('sub/')

	b := os.join_path(dir, 'b.txt')
	assert tool_copy_path(a, b).starts_with('OK: copied')
	assert os.read_file(b)! == 'hello'

	c := os.join_path(dir, 'c.txt')
	assert tool_move_path(b, c).starts_with('OK: moved')
	assert !os.exists(b) && os.exists(c)

	assert tool_file_info(c).contains('type: file')
	assert tool_file_info(sub).contains('type: directory')

	assert tool_delete_path(c).starts_with('OK: deleted')
	assert !os.exists(c)
	assert tool_delete_path(c).starts_with('ERROR: not found')

	// copying a whole tree merges into an existing destination
	dest := os.join_path(dir, 'copy-of-sub')
	assert tool_copy_path(sub, dest).starts_with('OK: copied')
	assert os.exists(os.join_path(dest, 'a.txt'))
}

fn test_search_and_glob() {
	dir := tmp_work('search')
	tool_write_file(os.join_path(dir, 'one.py'), 'def alpha():\n    pass\n')
	tool_write_file(os.join_path(dir, 'two.py'), 'def beta():\n    return 1\n')
	tool_write_file(os.join_path(dir, 'notes.txt'), 'def gamma\n')

	hits := tool_search_files(r'def \w+', dir, '*.py', 100)
	assert hits.contains('one.py:1:')
	assert hits.contains('two.py:1:')
	assert !hits.contains('notes.txt')

	// alternation — the case V's stdlib regex could not express at all
	alt := tool_search_files('alpha|beta', dir, '*', 100)
	assert alt.contains('one.py') && alt.contains('two.py')

	assert tool_search_files('zzz-nothing', dir, '*', 100) == 'no matches'
	assert tool_search_files('(bad', dir, '*', 100).starts_with('ERROR: bad regex')

	globbed := tool_glob_files('**/*.py', dir)
	assert globbed.contains('one.py') && globbed.contains('two.py')
	assert !globbed.contains('notes.txt')
	assert tool_glob_files('/abs/*.py', dir).starts_with('ERROR: pattern must be relative')
}

fn test_apply_patch_applies_and_refuses() {
	dir := tmp_work('patch')
	f := os.join_path(dir, 'st.py')
	assert tool_write_file(f, 'a\nb\nc\n').starts_with('OK: created')

	patch := '--- a/${f}\n+++ b/${f}\n@@ -1,3 +1,3 @@\n a\n-b\n+B\n c\n'
	out := tool_apply_patch(patch)
	assert out.starts_with('Updated'), out
	assert out.contains('1 addition(s)'), out
	assert os.read_file(f)! == 'a\nB\nc\n'

	// a hunk whose context no longer matches must fail LOUDLY and leave
	// the file exactly as it was
	bad := patch.replace(' c\n', ' WRONG CONTEXT\n')
	err_msg := tool_apply_patch(bad)
	assert err_msg.starts_with('ERROR: hunk context mismatch'), err_msg
	assert os.read_file(f)! == 'a\nB\nc\n', 'a failed patch mutated the file'

	assert tool_apply_patch('').starts_with('ERROR: empty patch')
	assert tool_apply_patch('no hunks here').starts_with('ERROR: no hunks found')
}

fn test_apply_patch_multi_hunk_bottom_up() {
	dir := tmp_work('patch2')
	f := os.join_path(dir, 'm.txt')
	tool_write_file(f, '1\n2\n3\n4\n5\n6\n7\n8\n')
	// two hunks in one file; applying top-down would shift the second one
	patch := '--- a/${f}\n+++ b/${f}\n' + '@@ -1,3 +1,3 @@\n 1\n-2\n+TWO\n 3\n' +
		'@@ -6,3 +6,3 @@\n 6\n-7\n+SEVEN\n 8\n'
	out := tool_apply_patch(patch)
	assert out.starts_with('Updated'), out
	assert os.read_file(f)! == '1\nTWO\n3\n4\n5\n6\nSEVEN\n8\n'
}

fn test_parse_tool_arguments() {
	empty := parse_tool_arguments('')
	assert empty.len == 0

	obj := parse_tool_arguments('{"path": "x.txt", "limit": 5}')
	assert jstr(obj, 'path') == 'x.txt'
	assert jint(obj, 'limit') == 5

	// a non-object JSON value is wrapped rather than dropped
	scalar := parse_tool_arguments('42')
	assert 'value' in scalar

	// and outright garbage is surfaced, not silently turned into no args
	junk := parse_tool_arguments('{not json')
	assert '_raw' in junk
}

fn test_clip_keeps_head_and_tail() {
	long := 'START' + 'x'.repeat(max_tool_output_chars * 2) + 'END'
	out := clip_tool_output(long)
	assert out.starts_with('START')
	assert out.ends_with('END')
	assert out.contains('chars truncated')
	assert out.len < long.len

	short := 'nothing to clip'
	assert clip_tool_output(short) == short
}

fn test_line_numbering_marks_first_last_and_tenths() {
	body := []string{len: 12, init: 'L${index + 1}'}.join('\n')
	out := line_numbered(body, 1)
	lines := out.split('\n')
	assert lines[0].contains('1→L1')
	assert lines[9].contains('10→L10')
	assert lines[11].contains('12→L12')
	// an in-between line is aligned but not numbered
	assert !lines[4].contains('→')
}

fn test_json_tool_handlers_dispatch() {
	dir := tmp_work('dispatch')
	reg := build_registry()
	f := os.join_path(dir, 'h.txt')

	w := reg['write_file'].handler({
		'path':    json2.Any(f)
		'content': json2.Any('hi\n')
	}, no_sink)
	assert w.starts_with('OK: created'), w

	r := reg['read_file'].handler({
		'path': json2.Any(f)
	}, no_sink)
	assert r.contains('1→hi')

	// a missing optional `path` falls back to '.', it must not read ''
	l := reg['list_dir'].handler(map[string]json2.Any{}, no_sink)
	assert !l.starts_with('ERROR'), l
}
