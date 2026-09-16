module vagent

import os

fn sample_state() BoxState {
	return BoxState{
		model_label:     'MiMo v2.5'
		model_tag:       'FREE'
		effort_label:    'HIGH'
		effort_colour:   c_green
		autonomy:        3
		goal_percent:    42
		context_percent: 17
		session_id:      'a1b2c3d4'
	}
}

fn row_width(spans []Span) int {
	return spans_width(spans)
}

fn test_top_border_is_exactly_the_terminal_width() {
	st := sample_state()
	for width in [60, 80, 100, 120, 200] {
		row := st.render_top(width)
		assert row_width(row) == width, 'width ${width} rendered ${row_width(row)}'
		text := spans_text(row)
		assert text.starts_with('╭')
		assert text.ends_with('╮')
	}
}

fn test_top_border_drops_cells_rather_than_overflowing() {
	st := sample_state()
	// a terminal too narrow for everything must still produce an exact row
	narrow := st.render_top(40)
	assert row_width(narrow) == 40, '${row_width(narrow)}'
	assert spans_text(narrow).ends_with('╮')
	// the app name and the model survive; the session id is the first to go
	assert spans_text(narrow).contains('FullAgent')
	assert !spans_text(narrow).contains('a1b2c3d4')
}

fn test_a_wide_label_does_not_tear_the_border() {
	mut st := sample_state()
	// CJK is two columns per character — measuring in bytes would overflow
	st = BoxState{
		...st
		model_label: '日本語モデル'
	}
	row := st.render_top(100)
	assert row_width(row) == 100, '${row_width(row)}'
	// and an emoji badge is two columns too
	mut focused := BoxState{
		...st
		focus_remaining: 3
	}
	assert row_width(focused.render_top(100)) == 100
}

fn test_bottom_border_shows_the_right_thing_first() {
	base := sample_state()

	idle := base.render_bottom(100)
	assert row_width(idle) == 100
	assert spans_text(idle).contains('Enter send')

	busy := BoxState{
		...base
		busy:          true
		spinner_frame: '⠹'
		status:        'thinking…'
	}
	busy_row := busy.render_bottom(100)
	assert row_width(busy_row) == 100
	assert spans_text(busy_row).contains('⠹')
	assert spans_text(busy_row).contains('thinking…')
	assert spans_text(busy_row).contains('cancel')

	// a flash replaces the hints, but not the spinner
	flashed := BoxState{
		...base
		flash: 'model switched'
	}
	assert spans_text(flashed.render_bottom(100)).contains('model switched')
	busy_and_flashed := BoxState{
		...base
		busy:          true
		spinner_frame: '⠋'
		flash:         'ignored while busy'
	}
	assert !spans_text(busy_and_flashed.render_bottom(100)).contains('ignored')

	// an approval outranks everything
	approving := BoxState{
		...base
		busy:         true
		approving:    true
		approve_tool: 'delete_path'
	}
	appr := approving.render_bottom(100)
	assert row_width(appr) == 100
	assert spans_text(appr).contains('approve delete_path?')
	assert spans_text(appr).contains('[y]es')
}

fn test_bottom_border_degrades_on_a_narrow_terminal() {
	st := sample_state()
	for width in [30, 40, 50, 60, 80] {
		row := st.render_bottom(width)
		assert row_width(row) == width, 'width ${width} rendered ${row_width(row)}'
		assert spans_text(row).ends_with('╯')
	}
	// the shortest form is still a complete sentence, not a cut one
	assert spans_text(st.render_bottom(30)).contains('Enter send')
}

// -- the input area ----------------------------------------------------------

fn new_buf(text string) &EditBuffer {
	mut b := &EditBuffer{}
	b.set_text(text)
	return b
}

fn test_empty_input_shows_the_arrow_and_parks_the_cursor_on_it() {
	b := &EditBuffer{}
	layout := render_input(b, 80, '')
	assert layout.rows.len == 1
	assert row_width(layout.rows[0]) == 80, '${row_width(layout.rows[0])}'
	assert spans_text(layout.rows[0]).contains('❯')
	// the caret sits just past "│ ❯ "
	assert layout.cursor_col == 4
	assert layout.cursor_row == 0
}

fn test_every_input_row_is_exactly_the_box_width() {
	cases := ['hi', 'a longer line that will certainly need to wrap around ' +
		'because it is much wider than the box we are rendering it into',
		'first\nsecond\nthird', '日本語のテキストがここにあります', '']
	for text in cases {
		b := new_buf(text)
		for width in [40, 60, 80, 120] {
			layout := render_input(b, width, '')
			for i, row in layout.rows {
				assert row_width(row) == width, 'text=${text} width=${width} ' +
					'row ${i} rendered ${row_width(row)}'
				assert spans_text(row).starts_with('│')
				assert spans_text(row).ends_with('│')
			}
		}
	}
}

fn test_continuation_rows_align_under_the_first() {
	b := new_buf('line one\nline two')
	layout := render_input(b, 60, '')
	assert layout.rows.len == 2
	assert spans_text(layout.rows[0]).contains('❯ line one')
	// the second logical line is indented to match, not given another arrow
	assert !spans_text(layout.rows[1]).contains('❯')
	assert spans_text(layout.rows[1]).contains('  line two')
}

fn test_the_cursor_tracks_the_buffer_exactly() {
	mut b := new_buf('hello')
	// end of the text
	assert render_input(b, 80, '').cursor_col == 4 + 5
	// home
	b.move_home()
	assert render_input(b, 80, '').cursor_col == 4
	// into the middle
	b.cursor = 2
	assert render_input(b, 80, '').cursor_col == 6

	// on the second line the row moves and the column restarts
	mut multi := new_buf('ab\ncd')
	multi.cursor = 4 // between c and d
	l := render_input(multi, 80, '')
	assert l.cursor_row == 1
	assert l.cursor_col == 4 + 1
}

fn test_the_cursor_follows_a_wide_rune() {
	mut b := new_buf('日本x')
	b.cursor = 2 // after two double-width runes
	layout := render_input(b, 80, '')
	// two CJK characters occupy four columns, not two
	assert layout.cursor_col == 4 + 4, '${layout.cursor_col}'
}

fn test_a_long_buffer_scrolls_instead_of_growing_forever() {
	mut lines := []string{}
	for i in 0 .. 40 {
		lines << 'line ${i}'
	}
	mut b := new_buf(lines.join('\n'))
	layout := render_input(b, 80, '')
	assert layout.rows.len == max_input_rows, '${layout.rows.len}'
	// the cursor is at the end, so the view is scrolled to the bottom
	assert spans_text(layout.rows.last()).contains('line 39')
	assert layout.cursor_row < max_input_rows

	// with the cursor at the top, the view scrolls back up
	b.cursor = 0
	top := render_input(b, 80, '')
	assert spans_text(top.rows[0]).contains('line 0')
	assert top.cursor_row == 0
}

fn test_render_box_assembles_the_whole_region() {
	st := sample_state()
	b := new_buf('hello')
	rows, cursor_row, cursor_col := render_box(&st, b, 80, [][]Span{}, '')
	// top border + one input row + bottom border
	assert rows.len == 3
	assert spans_text(rows[0]).starts_with('╭')
	assert spans_text(rows[2]).starts_with('╰')
	assert cursor_row == 1
	assert cursor_col == 4 + 5
	for row in rows {
		assert row_width(row) == 80
	}

	// an overlay pushes the box down and the cursor with it
	overlay := [[span('═'.repeat(80), Style{})]]
	_, with_overlay, _ := render_box(&st, b, 80, overlay, '')
	assert with_overlay == 2
}

// -- the edit buffer ---------------------------------------------------------

fn test_editing_operates_on_runes_not_bytes() {
	mut b := &EditBuffer{}
	b.insert('héllo')
	assert b.text() == 'héllo'
	assert b.cursor == 5 // five runes, not six bytes
	b.backspace()
	assert b.text() == 'héll'
	b.move_home()
	b.delete_forward()
	assert b.text() == 'éll'
}

fn test_word_motions_and_kills() {
	mut b := &EditBuffer{}
	b.insert('one two three')
	b.move_word_left()
	assert b.cursor == 8 // start of "three"
	b.delete_word_back()
	assert b.text() == 'one three'
	b.yank()
	assert b.text() == 'one two three'

	b.move_home()
	b.kill_to_end()
	assert b.text() == ''
	b.yank()
	assert b.text() == 'one two three'
	b.move_end()
	b.kill_to_start()
	assert b.text() == ''
}

fn test_arrows_reach_history_only_at_the_edges() {
	mut b := &EditBuffer{}
	b.remember('earlier message')
	b.insert('line one\nline two')

	// on the last line, Down is at an edge
	assert b.on_last_line()
	// the cursor starts at the end, so moving up stays inside the buffer
	assert b.move_up() == true
	assert b.on_first_line()
	// now at the top, another Up is the caller's cue to walk history
	assert b.move_up() == false
	assert b.history_prev()
	assert b.text() == 'earlier message'
}

fn test_history_restores_the_stashed_draft() {
	mut b := &EditBuffer{}
	b.remember('first')
	b.remember('second')
	b.insert('a draft in progress')

	assert b.history_prev()
	assert b.text() == 'second'
	assert b.history_prev()
	assert b.text() == 'first'
	assert !b.history_prev() // the oldest entry

	assert b.history_next()
	assert b.text() == 'second'
	assert b.history_next()
	// walking past the newest entry returns the draft, not an empty line
	assert b.text() == 'a draft in progress'
	assert !b.history_next()
}

fn test_history_persists_multiline_entries_as_one() {
	path := os.join_path(os.temp_dir(), 'vagent-hist-${os.getpid()}', 'history')
	os.rmdir_all(os.dir(path)) or {}
	os.mkdir_all(os.dir(path)) or { panic(err) }

	mut b := new_edit_buffer(path)
	b.remember('single line')
	b.remember('two\nlines here')
	b.remember('with a \\ backslash')

	mut reloaded := new_edit_buffer(path)
	assert reloaded.history.len == 3, '${reloaded.history}'
	assert reloaded.history[1] == 'two\nlines here'
	assert reloaded.history[2] == 'with a \\ backslash'

	// a repeat of the newest entry is not stored twice
	reloaded.remember('with a \\ backslash')
	assert reloaded.history.len == 3
}

fn test_a_missing_history_directory_is_never_a_crash() {
	path := os.join_path(os.temp_dir(), 'vagent-hist-gone-${os.getpid()}', 'sub', 'history')
	os.rmdir_all(os.dir(os.dir(path))) or {}
	mut b := new_edit_buffer(path)
	assert b.history.len == 0
	// remembering recreates the directory rather than raising
	b.remember('hello')
	assert b.history == ['hello']
	assert os.exists(path)
}

fn test_the_cursor_at_a_wrap_boundary_lands_on_the_next_row() {
	// exactly one row's worth of text, cursor at the very end: the caret
	// belongs at the START of the next row, not past the right rail
	width := 30
	text_width := width - 6
	mut b := new_buf('x'.repeat(text_width))
	layout := render_input(b, width, '')
	assert layout.rows.len == 1
	// the only row is full, so the caret sits just past the last character
	assert layout.cursor_row == 0
	assert layout.cursor_col == 4 + text_width

	// one more character wraps, and the caret follows onto the new row
	b.insert('y')
	wrapped := render_input(b, width, '')
	assert wrapped.rows.len == 2
	assert wrapped.cursor_row == 1
	assert wrapped.cursor_col == 4 + 1, '${wrapped.cursor_col}'
	for row in wrapped.rows {
		assert row_width(row) == width
	}
}

fn test_the_cursor_at_the_end_of_a_multiline_buffer() {
	second := 'line two is longer'
	mut b := new_buf('line one\n' + second)
	layout := render_input(b, 80, '')
	assert layout.rows.len == 2
	assert layout.cursor_row == 1
	// '│ ' + '  ' continuation prefix + the text
	assert layout.cursor_col == 4 + second.len, '${layout.cursor_col}'
}
