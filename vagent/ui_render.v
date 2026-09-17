module vagent

import os

// ui_render.v — turning tool calls and model output into styled rows.
//
// The Python original used rich; this is the same layout without it. Every
// tool call prints one header and one body:
//
//     ⏺ Ran command                ⏺ Wrote ./notes.md
//     │ $ ls -la                   │  1 +  # Notes
//     │ total 40                   │  2 +  ## Today
//     └ Exited with code 0         └ …
//
//     ⏺ Read ./file.md             ⏺ Edited ./file.md
//     └ 57 lines                   │ 24    ## Applications
//                                  │ 26 -  - diagnosis
//                                  └ 26 +  - diagnosis, imaging
//
// The tree glyphs are the whole readability trick: `│` for every body row
// but the last, `└` for the last, so a block's extent is visible without
// counting lines.

const devin_verb = {
	'glob_files':       'Globbed'
	'search_files':     'Searched'
	'list_dir':         'Listed'
	'file_info':        'Inspected'
	'create_directory': 'Created directory'
	'copy_path':        'Copied'
	'move_path':        'Moved'
	'delete_path':      'Deleted'
	'web_fetch':        'Fetched'
	'web_search':       'Searched the web'
	'live_shell_reset': 'Reset the shell session'
	'run_command':      'Ran command'
	'live_shell':       'Ran command'
	'write_file':       'Wrote'
	'edit_file':        'Edited'
	'read_file':        'Read'
	'apply_patch':      'Applied patch'
}

const devin_arg = {
	'glob_files':       'pattern'
	'search_files':     'pattern'
	'list_dir':         'path'
	'file_info':        'path'
	'create_directory': 'path'
	'delete_path':      'path'
	'copy_path':        'src'
	'move_path':        'src'
	'web_fetch':        'url'
	'web_search':       'query'
	'write_file':       'path'
	'edit_file':        'path'
	'read_file':        'path'
}

const devin_path_arg = ['list_dir', 'file_info', 'create_directory', 'delete_path', 'copy_path',
	'move_path', 'write_file', 'edit_file', 'read_file']

// live_tools render as a streamed block rather than a summary.
const live_tools = ['run_command', 'live_shell', 'write_file', 'edit_file', 'read_file', 'apply_patch']

pub fn is_live_tool(name string) bool {
	return name in live_tools
}

// rel_path is the Devin-style path display: relative to cwd with a ./
// prefix, and absolute when the path is outside the tree.
pub fn rel_path(path string) string {
	if path == '' {
		return ''
	}
	cwd := os.getwd()
	abs := resolve_path(path)
	if abs == cwd {
		return '.'
	}
	prefix := cwd + '/'
	if !abs.starts_with(prefix) {
		return path
	}
	rel := abs[prefix.len..]
	return if rel.starts_with('.') { rel } else { './' + rel }
}

// devin_title is the one-line header a tool call prints.
pub fn devin_title(ev &ToolEvent) string {
	verb := devin_verb[ev.name] or { ev.name.replace('_', ' ').trim_space() }
	key := devin_arg[ev.name] or { '' }
	mut arg := ''
	if key != '' {
		raw := jstr(ev.args, key)
		if raw != '' {
			arg = if ev.name in devin_path_arg { rel_path(raw) } else { raw }
			arg = truncate_width(arg, 60, '…')
		}
	}
	if ev.name in ['copy_path', 'move_path'] {
		dst := jstr(ev.args, 'dst')
		arg = if arg != '' { '${arg} → ${dst}' } else { dst }
	}
	return '${verb} ${arg}'.trim_space()
}

pub fn tool_call_line(ev &ToolEvent) []Span {
	return [
		span(' ⏺ ', Style{
			fg:   c_accent
			bold: true
		}),
		span(devin_title(ev), Style{
			fg:   c_fg
			bold: true
		}),
	]
}

fn ev_failed(ev &ToolEvent) bool {
	return ev.status != 'done' || ev.result.starts_with('ERROR')
}

// capped_rows renders at most `cap` items and says how many were dropped.
fn capped_rows(items []string, cap_n int) [][]Span {
	mut rows := [][]Span{}
	mut shown := 0
	for it in items {
		if shown >= cap_n {
			break
		}
		rows << [span(it, Style{
			fg: c_fg
		})]
		shown++
	}
	if items.len > cap_n {
		rows << [span('… +${items.len - cap_n} more', Style{
			fg: c_dim
		})]
	}
	return rows
}

// generic_rows are the body rows of a finished non-live tool. It always
// returns at least one row, so a block never renders as a bare header.
pub fn generic_rows(ev &ToolEvent) [][]Span {
	res := ev.result.trim_right(' \t\n')
	if ev_failed(ev) {
		lines := split_lines(res)
		msg := if lines.len > 0 { lines[0] } else { ev.status }
		return [[span(truncate_width(msg, 200, '…'), Style{
			fg: c_red
		})]]
	}
	lines := split_lines(res)
	green := Style{
		fg: c_green
	}
	dim := Style{
		fg: c_dim
	}

	match ev.name {
		'glob_files' {
			if res.trim_space() == 'no matches' {
				return [[span('no matches', dim)]]
			}
			files := lines.filter(it.trim_space() != '')
			mut rows := capped_rows(files.map(rel_path(it)), 5)
			rows << [span('${files.len} file(s)', green)]
			return rows
		}
		'search_files' {
			if res.trim_space() == 'no matches' {
				return [[span('no matches', dim)]]
			}
			hits := lines.filter(it.trim_space() != '')
			mut rows := capped_rows(hits.map(truncate_width(it, 160, '…')), 5)
			rows << [span('${hits.len} match(es)', green)]
			return rows
		}
		'list_dir' {
			entries := if lines.len > 1 {
				lines[1..].map(it.trim_space()).filter(it != '')
			} else {
				[]string{}
			}
			if entries.len == 0 {
				return [[span('(empty)', dim)]]
			}
			mut rows := capped_rows(entries, 8)
			word := if entries.len == 1 { 'entry' } else { 'entries' }
			rows << [span('${entries.len} ${word}', green)]
			return rows
		}
		'web_search' {
			mut n := 0
			if re := compile_regex_flags(r'^\d+\.', RxFlags{ multiline: true }) {
				n = re.find_all(res).len
			}
			body := lines.filter(it.trim_space() != '' && !it.starts_with('web search:'))
			mut rows := capped_rows(body.map(truncate_width(it, 160, '…')), 6)
			rows << [span('${n} result(s)', green)]
			return rows
		}
		'web_fetch' {
			return [[span('${res.len} characters fetched', green)]]
		}
		'create_directory', 'copy_path', 'move_path', 'delete_path' {
			return [[span('done', green)]]
		}
		'file_info' {
			mut rows := [][]Span{}
			for l in lines {
				if l.trim_space() != '' {
					rows << [span(truncate_width(l.trim_space(), 160, '…'), Style{
						fg: c_fg
					})]
				}
			}
			return if rows.len > 0 { rows } else { [[span('done', green)]] }
		}
		else {
			first := if lines.len > 0 { lines[0] } else { 'done' }
			return [[span(truncate_width(first, 200, '…'), green)]]
		}
	}
}

// ---------------------------------------------------------------------------
// Shell receipts
// ---------------------------------------------------------------------------

pub struct ShellResult {
pub:
	exit_code int = -999 // -999 means "the receipt carried none"
	stdout    string
	stderr    string
}

// parse_shell_result splits a run_command/live_shell receipt into its parts.
pub fn parse_shell_result(result string) ShellResult {
	mut code := -999
	if re := compile_regex_flags(r'^exit code: (-?\d+)', RxFlags{ multiline: true }) {
		if m := re.search(result) {
			code = group_text(result, &m, 1).int()
		}
	}
	mut stdout := ''
	mut stderr := ''
	if idx := result.index('--- stdout ---\n') {
		rest := result[idx + '--- stdout ---\n'.len..]
		if e := rest.index('\n--- stderr ---\n') {
			stdout = rest[..e]
			stderr = rest[e + '\n--- stderr ---\n'.len..]
		} else {
			stdout = rest
		}
	} else if idx := result.index('--- stderr ---\n') {
		stderr = result[idx + '--- stderr ---\n'.len..]
	} else if code == -999 {
		stdout = result
	}
	return ShellResult{
		exit_code: code
		stdout:    stdout.trim_right('\n')
		stderr:    stderr.trim_right('\n')
	}
}

// ---------------------------------------------------------------------------
// Edit diffs
// ---------------------------------------------------------------------------

pub struct DiffRow {
pub:
	line_no int
	marker  string
	colour  string
	text    string
}

// find_hunk_line is the 1-based line where an edited hunk now sits, so the
// diff view shows real file line numbers rather than hunk-relative ones.
pub fn find_hunk_line(path string, new string) int {
	if new == '' || path == '' {
		return 1
	}
	text := os.read_file(resolve_path(path)) or { return 1 }
	idx := text.index(new) or { return 1 }
	return text[..idx].count('\n') + 1
}

// diff_rows renders an edit as numbered +/- rows.
//
// Old-side and new-side numbers both start at the hunk's file line: context
// BEFORE any change keeps old-file numbers, and context after a change
// switches to new-file numbers, which is what makes the numbers line up
// with the file as it now stands.
pub fn diff_rows(old string, new string, start int) []DiffRow {
	old_lines := split_lines(old)
	new_lines := split_lines(new)
	ops := diff_lines(old_lines, new_lines)

	mut rows := []DiffRow{}
	mut i := start
	mut j := start
	mut changed := false

	// the edit script is per-line; group consecutive runs so a replacement
	// renders as its removals followed by its additions, like a real diff
	mut k := 0
	for k < ops.len {
		op := ops[k]
		match op.kind {
			.equal {
				base := if changed { j } else { i }
				rows << DiffRow{
					line_no: base
					marker:  '   '
					colour:  c_fg
					text:    op.text
				}
				i++
				j++
				k++
			}
			.delete {
				// gather this run of deletions, then the insertions that
				// immediately follow it
				mut dels := []DiffOp{}
				for k < ops.len && ops[k].kind == .delete {
					dels << ops[k]
					k++
				}
				mut adds := []DiffOp{}
				for k < ops.len && ops[k].kind == .insert {
					adds << ops[k]
					k++
				}
				changed = true
				for d in dels {
					rows << DiffRow{
						line_no: i
						marker:  '-  '
						colour:  c_red
						text:    d.text
					}
					i++
				}
				for a in adds {
					rows << DiffRow{
						line_no: j
						marker:  '+  '
						colour:  c_green
						text:    a.text
					}
					j++
				}
			}
			.insert {
				changed = true
				rows << DiffRow{
					line_no: j
					marker:  '+  '
					colour:  c_green
					text:    op.text
				}
				j++
				k++
			}
		}
	}
	return rows
}

// ---------------------------------------------------------------------------
// Live blocks
// ---------------------------------------------------------------------------

// live_rows are the body rows of a finished live block. The caller adds the
// │ / └ tree glyphs.
pub fn live_rows(ev &ToolEvent, w int) [][]Span {
	mut rows := [][]Span{}
	failed := ev_failed(ev)
	dim := Style{
		fg: c_dim
	}
	fgs := Style{
		fg: c_fg
	}

	add := fn [w] (mut rows [][]Span, text string, style Style) {
		rows << [span(truncate_width(text, w, '…'), style)]
	}

	match ev.name {
		'run_command', 'live_shell' {
			add(mut rows, '\$ ${jstr(ev.args, 'command')}', Style{
				fg:   c_fg
				bold: true
			})
			if failed {
				add(mut rows, if ev.result.trim_space() != '' {
					ev.result.trim_space()
				} else {
					ev.status
				}, Style{ fg: c_red })
				return rows
			}
			res := parse_shell_result(ev.result)
			out_lines := split_lines(res.stdout)
			for idx, ln in out_lines {
				if idx >= 30 {
					break
				}
				add(mut rows, if ln != '' { ln } else { ' ' }, fgs)
			}
			if out_lines.len > 30 {
				add(mut rows, '… +${out_lines.len - 30} more lines', dim)
			}
			err_lines := split_lines(res.stderr)
			for idx, ln in err_lines {
				if idx >= 10 {
					break
				}
				add(mut rows, ln, Style{ fg: c_orange })
			}
			if res.exit_code != -999 {
				add(mut rows, 'Exited with code ${res.exit_code}', Style{
					fg: if res.exit_code == 0 { c_green } else { c_red }
				})
			}
		}
		'write_file' {
			if failed {
				add(mut rows, if ev.result.trim_space() != '' {
					ev.result.trim_space()
				} else {
					ev.status
				}, Style{ fg: c_red })
				return rows
			}
			content := jstr(ev.args, 'content')
			lines := split_lines(content)
			width := max_int(1, lines.len).str().len
			for n, ln in lines {
				if n >= 300 {
					break
				}
				rows << [
					span(pad_left((n + 1).str(), width) + ' ', dim),
					span('+  ', Style{ fg: c_green }),
					span(truncate_width(ln, w, '…'), fgs),
				]
			}
			if lines.len > 300 {
				add(mut rows, '… +${lines.len - 300} more lines', dim)
			}
		}
		'edit_file' {
			if failed {
				add(mut rows, if ev.result.trim_space() != '' {
					ev.result.trim_space()
				} else {
					ev.status
				}, Style{ fg: c_red })
				return rows
			}
			old := jstr(ev.args, 'old_string')
			new := jstr(ev.args, 'new_string')
			start := find_hunk_line(jstr(ev.args, 'path'), new)
			drows := diff_rows(old, new, start)
			mut max_no := 1
			for r in drows {
				if r.line_no > max_no {
					max_no = r.line_no
				}
			}
			width := max_no.str().len
			for idx, r in drows {
				if idx >= 100 {
					break
				}
				marker_style := if r.marker == '   ' { dim } else { Style{ fg: r.colour } }
				rows << [
					span(pad_left(r.line_no.str(), width) + ' ', dim),
					span(r.marker, marker_style),
					span(truncate_width(r.text, w, '…'), Style{ fg: r.colour }),
				]
			}
			if drows.len > 100 {
				add(mut rows, '… +${drows.len - 100} more lines', dim)
			}
		}
		'read_file' {
			mut shown := false
			if re := compile_regex(r'(\d+) lines total, showing (\d+)\.\.(\d+)') {
				if m := re.search(ev.result) {
					total := group_text(ev.result, &m, 1)
					from := group_text(ev.result, &m, 2)
					to := group_text(ev.result, &m, 3)
					if from == '1' && to == total {
						add(mut rows, '${total} lines', dim)
					} else {
						add(mut rows, 'lines ${from}..${to} of ${total}', dim)
					}
					shown = true
				}
			}
			if !shown {
				lines := split_lines(ev.result)
				add(mut rows, if lines.len > 0 { lines[0] } else { '' }, dim)
			}
		}
		else {
			// apply_patch, and anything else that streams its argument
			lines := split_lines(jstr(ev.args, 'patch'))
			for idx, ln in lines {
				if idx >= 60 {
					break
				}
				style := if ln.starts_with('@@') {
					Style{ fg: c_cyan }
				} else if ln.starts_with('+++ ') || ln.starts_with('--- ') {
					Style{ fg: c_dim, bold: true }
				} else if ln.starts_with('+') {
					Style{ fg: c_green }
				} else if ln.starts_with('-') {
					Style{ fg: c_red }
				} else {
					fgs
				}
				add(mut rows, ln, style)
			}
			if lines.len > 60 {
				add(mut rows, '… +${lines.len - 60} more lines', dim)
			}
			if failed {
				add(mut rows, if ev.result.trim_space() != '' {
					ev.result.trim_space()
				} else {
					ev.status
				}, Style{ fg: c_red })
			}
		}
	}
	if rows.len == 0 {
		lines := split_lines(ev.result)
		add(mut rows, if lines.len > 0 { lines[0] } else { ev.status }, dim)
	}
	return rows
}

// tree_block adds the │ / └ glyphs to a set of body rows.
pub fn tree_block(rows [][]Span) [][]Span {
	dim := Style{
		fg: c_dim
	}
	mut out := [][]Span{}
	for idx, row in rows {
		glyph := if idx == rows.len - 1 { ' └ ' } else { ' │ ' }
		mut line := [span(glyph, dim)]
		line << row
		out << line
	}
	return out
}

// tool_result_block is the finished body of any tool call, tree glyphs
// included.
pub fn tool_result_block(ev &ToolEvent, width int) [][]Span {
	rows := if is_live_tool(ev.name) {
		live_rows(ev, max_int(20, width - 8))
	} else {
		generic_rows(ev)
	}
	return tree_block(rows)
}

// -- the closing lines of a live-streamed block --------------------------------
//
// A block that streamed its own body still needs an ending. These are that
// ending, and they are separate from the block renderers above because the
// body was already on screen: replaying it to draw a footer would print the
// whole file a second time.

// shell_footer closes a live-streamed shell block with the exit code, or
// with the error if the command never got that far.
pub fn shell_footer(ev &ToolEvent) []Span {
	lead := fg(' └ ', c_dim)
	if ev.status != 'done' || ev.result.starts_with('ERROR') {
		msg := if ev.result != '' { ev.result.all_before('\n') } else { ev.status }
		return [lead, fg(cap_at(msg, 200), c_red)]
	}
	parsed := parse_shell_result(ev.result)
	if parsed.exit_code != -999 {
		colour := if parsed.exit_code == 0 { c_green } else { c_red }
		return [lead, fg('Exited with code ${parsed.exit_code}', colour)]
	}
	return [lead, fg('done', c_green)]
}

// write_footer closes a live-streamed write block with the tool's own
// receipt — 'OK: created … 286 line(s)' — rather than a line this file
// makes up, so what is shown is what the tool actually reported.
pub fn write_footer(ev &ToolEvent, nlines int) []Span {
	lead := fg(' └ ', c_dim)
	if ev.status != 'done' || ev.result.starts_with('ERROR') {
		msg := if ev.result != '' { ev.result.all_before('\n') } else { ev.status }
		return [lead, fg(cap_at(msg, 200), c_red)]
	}
	first := if ev.result != '' { ev.result.all_before('\n') } else { '' }
	body := if first != '' { cap_at(first, 200) } else { '${nlines} line(s) written' }
	return [lead, fg(body, c_green)]
}
