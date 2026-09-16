module vagent

import os
import x.json2

fn ev(name string, args map[string]json2.Any, result string, status string) ToolEvent {
	return ToolEvent{
		name:   name
		args:   args
		result: result
		status: status
	}
}

fn text_of(rows [][]Span) string {
	return rows.map(spans_text(it)).join('\n')
}

fn test_devin_titles_name_the_act_and_its_subject() {
	ran := ev('run_command', {
		'command': json2.Any('ls -la')
	}, '', 'done')
	assert devin_title(&ran) == 'Ran command'

	globbed := ev('glob_files', {
		'pattern': json2.Any('**/*.v')
	}, '', 'done')
	assert devin_title(&globbed) == 'Globbed **/*.v'

	searched := ev('web_search', {
		'query': json2.Any('v language')
	}, '', 'done')
	assert devin_title(&searched) == 'Searched the web v language'

	// a copy names both ends
	copied := ev('copy_path', {
		'src': json2.Any('a.txt')
		'dst': json2.Any('b.txt')
	}, '', 'done')
	assert devin_title(&copied).contains('→ b.txt')

	// an unknown tool still reads as words rather than an identifier
	unknown := ev('some_new_tool', map[string]json2.Any{}, '', 'done')
	assert devin_title(&unknown) == 'some new tool'

	// a very long argument is clipped rather than wrapping the header
	huge := ev('search_files', {
		'pattern': json2.Any('x'.repeat(200))
	}, '', 'done')
	long := devin_title(&huge)
	assert display_width(long) <= 'Searched '.len + 60
}

fn test_a_failed_tool_shows_its_error_not_a_summary() {
	failed := ev('glob_files', {
		'pattern': json2.Any('*.v')
	}, 'ERROR: bad glob pattern', 'error')
	rows := generic_rows(&failed)
	assert rows.len == 1
	assert spans_text(rows[0]).contains('ERROR: bad glob pattern')

	// a `done` status whose result still starts with ERROR counts as failed
	sneaky := ev('glob_files', {
		'pattern': json2.Any('*.v')
	}, 'ERROR: something', 'done')
	assert spans_text(generic_rows(&sneaky)[0]).contains('ERROR')
}

fn test_generic_bodies_summarise_and_cap() {
	mut files := []string{}
	for i in 0 .. 12 {
		files << '/tmp/file${i}.v'
	}
	globbed := ev('glob_files', {
		'pattern': json2.Any('*.v')
	}, files.join('\n'), 'done')
	rows := generic_rows(&globbed)
	body := text_of(rows)
	assert body.contains('… +7 more'), body
	assert body.contains('12 file(s)'), body

	empty := ev('glob_files', {
		'pattern': json2.Any('*.zz')
	}, 'no matches', 'done')
	assert text_of(generic_rows(&empty)) == 'no matches'

	listed := ev('list_dir', {
		'path': json2.Any('.')
	}, '[/tmp]\n  a.txt  (1 bytes)\n  b/\n', 'done')
	assert text_of(generic_rows(&listed)).contains('2 entries')

	one := ev('list_dir', {
		'path': json2.Any('.')
	}, '[/tmp]\n  only.txt  (1 bytes)\n', 'done')
	assert text_of(generic_rows(&one)).contains('1 entry')

	fetched := ev('web_fetch', {
		'url': json2.Any('http://x')
	}, 'body text', 'done')
	assert text_of(generic_rows(&fetched)).contains('9 characters fetched')
}

fn test_tree_glyphs_mark_the_end_of_a_block() {
	rows := tree_block([[plain('one')], [plain('two')], [plain('three')]])
	assert spans_text(rows[0]).starts_with(' │ ')
	assert spans_text(rows[1]).starts_with(' │ ')
	assert spans_text(rows[2]).starts_with(' └ ')

	// a single-row body is all end, no continuation
	single := tree_block([[plain('only')]])
	assert spans_text(single[0]).starts_with(' └ ')
}

fn test_shell_receipts_parse_into_their_parts() {
	res := parse_shell_result('exit code: 0\n--- stdout ---\nhello\nworld\n' +
		'--- stderr ---\nwarning\n')
	assert res.exit_code == 0
	assert res.stdout == 'hello\nworld'
	assert res.stderr == 'warning'

	only_err := parse_shell_result('exit code: 1\n--- stderr ---\nboom')
	assert only_err.exit_code == 1
	assert only_err.stdout == ''
	assert only_err.stderr == 'boom'

	// a receipt with no exit line at all is treated as plain output
	bare := parse_shell_result('just some text')
	assert bare.exit_code == -999
	assert bare.stdout == 'just some text'

	negative := parse_shell_result('exit code: -1\n')
	assert negative.exit_code == -1
}

fn test_a_shell_block_shows_the_command_output_and_verdict() {
	e := ev('run_command', {
		'command': json2.Any('ls -la')
	}, 'exit code: 0\n--- stdout ---\ntotal 40\ndrwxr-xr-x\n', 'done')
	body := text_of(live_rows(&e, 80))
	assert body.contains('\$ ls -la')
	assert body.contains('total 40')
	assert body.contains('Exited with code 0')
}

fn test_a_long_shell_output_is_capped() {
	mut lines := []string{}
	for i in 0 .. 100 {
		lines << 'line ${i}'
	}
	e := ev('run_command', {
		'command': json2.Any('seq 100')
	}, 'exit code: 0\n--- stdout ---\n' + lines.join('\n'), 'done')
	body := text_of(live_rows(&e, 80))
	assert body.contains('… +70 more lines'), body
	// the verdict survives the cap — it is the point of the block
	assert body.contains('Exited with code 0')
}

fn test_a_write_block_numbers_every_added_line() {
	e := ev('write_file', {
		'path':    json2.Any('/tmp/x.md')
		'content': json2.Any('# Title\n\n## Section\n')
	}, 'OK: created', 'done')
	rows := live_rows(&e, 80)
	assert rows.len == 3
	first := spans_text(rows[0])
	assert first.contains('1 ')
	assert first.contains('+  ')
	assert first.contains('# Title')
}

fn test_an_edit_block_renders_a_real_diff() {
	dir := os.join_path(os.temp_dir(), 'vagent-render-${os.getpid()}')
	os.rmdir_all(dir) or {}
	os.mkdir_all(dir) or { panic(err) }
	path := os.join_path(dir, 'f.py')
	// the edit has already been applied by the time the block renders, so the
	// file on disk carries the NEW text — that is what locates the hunk
	os.write_file(path, 'a\nb\nNEW\nc\n') or { panic(err) }

	e := ev('edit_file', {
		'path':       json2.Any(path)
		'old_string': json2.Any('OLD')
		'new_string': json2.Any('NEW')
	}, 'Updated', 'done')
	body := text_of(live_rows(&e, 80))
	assert body.contains('-  OLD'), body
	assert body.contains('+  NEW'), body
	// the numbers are real file lines: OLD sat on line 3
	assert body.contains('3 '), body
}

fn test_diff_rows_number_context_before_and_after_a_change() {
	rows := diff_rows('one\nTWO\nthree', 'one\n2\nthree', 10)
	assert rows.len == 4
	// context before the change keeps the old-side number
	assert rows[0].line_no == 10 && rows[0].marker == '   '
	// the replacement renders as a removal then an addition
	assert rows[1].marker == '-  ' && rows[1].text == 'TWO'
	assert rows[2].marker == '+  ' && rows[2].text == '2'
	// context after the change uses the new-side number
	assert rows[3].marker == '   ' && rows[3].text == 'three'
}

fn test_a_read_block_reports_the_span_it_read() {
	whole := ev('read_file', {
		'path': json2.Any('/tmp/x')
	}, '[/tmp/x — 57 lines total, showing 1..57]\n…', 'done')
	assert text_of(live_rows(&whole, 80)).contains('57 lines')

	part := ev('read_file', {
		'path': json2.Any('/tmp/x')
	}, '[/tmp/x — 57 lines total, showing 10..20]\n…', 'done')
	assert text_of(live_rows(&part, 80)).contains('lines 10..20 of 57')
}

fn test_a_patch_block_colours_its_hunks() {
	patch := '--- a/x.py\n+++ b/x.py\n@@ -1 +1 @@\n-old\n+new\n'
	e := ev('apply_patch', {
		'patch': json2.Any(patch)
	}, 'Updated', 'done')
	rows := live_rows(&e, 80)
	texts := rows.map(spans_text(it))
	assert '@@ -1 +1 @@' in texts
	assert '-old' in texts
	assert '+new' in texts
}

fn test_tool_result_block_routes_live_and_generic_tools() {
	live := ev('run_command', {
		'command': json2.Any('true')
	}, 'exit code: 0\n', 'done')
	assert is_live_tool('run_command')
	assert text_of(tool_result_block(&live, 80)).contains('\$ true')

	generic := ev('web_fetch', {
		'url': json2.Any('http://x')
	}, 'abc', 'done')
	assert !is_live_tool('web_fetch')
	assert text_of(tool_result_block(&generic, 80)).contains('characters fetched')
}

fn test_rel_path_prefers_a_short_relative_form() {
	cwd := os.getwd()
	assert rel_path(os.join_path(cwd, 'sub', 'file.v')) == './sub/file.v'
	assert rel_path('') == ''
	// a path outside the tree stays absolute rather than growing ../../..
	assert rel_path('/definitely/elsewhere/x') == '/definitely/elsewhere/x'
}
