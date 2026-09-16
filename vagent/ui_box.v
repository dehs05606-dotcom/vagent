module vagent

// ui_box.v — the double-line prompt box.
//
//   ╭─ FullAgent ── model: MiMo v2.5 FREE ── effort: HIGH ── session a1b2c3d4 ─╮
//   │ ❯ user types here…                                                       │
//   ╰─ ⠹ thinking…  ·  Ctrl+C cancel ──────────────────────────────────────────╯
//
// The border carries live state: model, effort, autonomy level, goal
// distance, context usage and session id along the top; the spinner, a
// flash message, or the key hints along the bottom.
//
// Every measurement here is in DISPLAY COLUMNS, not bytes. A model label
// with a non-ASCII character, an emoji in the focus badge, a CJK path in a
// flash message — each is more bytes than columns, and padding a border by
// byte count puts the closing corner past the right edge, where the
// terminal wraps it onto the next row and the box visibly tears.

// BoxState is everything the border renders. The UI fills it each frame;
// keeping it a plain value means the renderer can be tested without a
// terminal, an agent, or a network.
pub struct BoxState {
pub:
	app_name  string = app_name
	model_label string
	model_tag   string
	effort_label string
	effort_colour string
	autonomy    int
	// -1 when no goal is active
	goal_percent int = -1
	// remaining auto-continuation turns, 0 when not in focus mode
	focus_remaining int
	// estimated context usage, 0..100
	context_percent int
	session_id      string

	// bottom border
	busy          bool
	spinner_frame string
	status        string
	flash         string
	flash_colour  string
	// the pending approval, when one is blocking the turn
	approving bool
	approve_tool string
}

// segment is one labelled cell of the top border.
struct Segment {
	text  string
	style Style
}

// top_segments builds the border's cells in priority order: the ones at the
// end are the first to be dropped when the terminal is narrow.
fn (st &BoxState) top_segments() []Segment {
	mut segs := []Segment{}
	segs << Segment{
		text:  ' ${st.app_name} '
		style: Style{
			fg:   c_accent
			bold: true
		}
	}
	segs << Segment{
		text:  ' model: ${st.model_label} '
		style: Style{
			fg:   c_cyan
			bold: true
		}
	}
	if st.model_tag != '' {
		segs << Segment{
			text:  '${st.model_tag} '
			style: Style{
				fg:   c_green
				bold: true
			}
		}
	}
	segs << Segment{
		text:  ' effort: ${st.effort_label.to_lower()} '
		style: Style{
			fg:   if st.effort_colour != '' { st.effort_colour } else { c_fg }
			bold: true
		}
	}
	segs << Segment{
		text:  ' L${st.autonomy} '
		style: Style{
			fg:   c_green
			bold: true
		}
	}
	// live goal distance — always on screen when a goal is active (§24)
	if st.goal_percent >= 0 {
		segs << Segment{
			text:  ' goal: ${st.goal_percent}% '
			style: Style{
				fg:   c_cyan
				bold: true
			}
		}
	}
	if st.focus_remaining > 0 {
		segs << Segment{
			text:  ' 🎯 focus×${st.focus_remaining} '
			style: Style{
				fg:   c_yellow
				bold: true
			}
		}
	}
	ctx_colour := if st.context_percent < 60 {
		c_green
	} else if st.context_percent < 85 {
		c_yellow
	} else {
		c_red
	}
	segs << Segment{
		text:  ' ctx ${st.context_percent}% '
		style: Style{
			fg:   ctx_colour
			bold: true
		}
	}
	segs << Segment{
		text:  ' session: ${st.session_id} '
		style: Style{
			fg: c_dim
		}
	}
	return segs
}

// fixed_len is the width a segment list occupies with its separators:
// two corners, the first dash, and a two-dash join before each later cell.
fn fixed_len(segs []Segment) int {
	mut total := 0
	for s in segs {
		total += display_width(s.text)
	}
	return total + 3 + 2 * (segs.len - 1)
}

// render_top draws the top border, dropping trailing cells until it fits.
//
// Letting the border exceed the terminal width is not a cosmetic problem:
// the closing "╮" wraps to the next row, the box grows a row the renderer
// did not account for, and every subsequent erase is off by one.
pub fn (st &BoxState) render_top(width int) []Span {
	mut segs := st.top_segments()
	for fixed_len(segs) > width && segs.len > 2 {
		segs.delete_last()
	}
	border := Style{
		fg: c_border
	}
	mut fill := width - fixed_len(segs)
	if fill < 0 {
		fill = 0
	}
	mut out := [span('╭', border)]
	for i, seg in segs {
		out << span(if i > 0 { '──' } else { '─' }, border)
		out << span(seg.text, seg.style)
	}
	out << span('─'.repeat(fill) + '╮', border)
	return out
}

// render_bottom draws the bottom border: the approval bar, the spinner, a
// flash message, or the key hints — in that order of urgency.
pub fn (st &BoxState) render_bottom(width int) []Span {
	border := Style{
		fg: c_border
	}
	inner := width - 2

	if st.approving {
		bar := truncate_width(' ⚠ approve ${st.approve_tool}?  [y]es  [n]o  [a]lways ',
			max_int(1, inner), '')
		return [
			span('╰', border),
			span(bar, Style{
				fg:   c_yellow
				bold: true
			}),
			span('─'.repeat(max_int(0, inner - display_width(bar))) + '╯', border),
		]
	}

	if st.busy {
		hint := '  ·  Esc/Ctrl+C cancel '
		// the status is what gives when the terminal is narrow; the spinner
		// and the cancel hint are the two things the user needs to see
		budget := inner - display_width(' ${st.spinner_frame} ') - display_width(hint)
		status := truncate_width(st.status, max_int(0, budget), '')
		used := display_width(' ${st.spinner_frame} ') + display_width(status) +
			display_width(hint)
		return [
			span('╰', border),
			span(' ${st.spinner_frame} ', Style{
				fg:   c_accent
				bold: true
			}),
			span(status, Style{
				fg:   c_cyan
				bold: true
			}),
			span(hint, Style{
				fg: c_dim
			}),
			span('─'.repeat(max_int(0, inner - used)) + '╯', border),
		]
	}

	if st.flash != '' {
		colour := if st.flash_colour != '' { st.flash_colour } else { c_yellow }
		text := truncate_width(' ${st.flash} ', max_int(1, inner), '')
		return [
			span('╰', border),
			span(text, Style{
				fg:   colour
				bold: true
			}),
			span('─'.repeat(max_int(0, inner - display_width(text))) + '╯', border),
		]
	}

	// the hints degrade in three steps rather than being truncated
	// mid-word, so a narrow terminal still shows a complete sentence
	mut hint := ' Enter send · Esc+Enter newline · / commands · ' +
		'Ctrl+T models · Ctrl+E effort · Ctrl+C cancel '
	if display_width(hint) > inner {
		hint = ' Enter send · / commands · Ctrl+T models · Ctrl+C cancel '
	}
	if display_width(hint) > inner {
		hint = ' Enter send '
	}
	shown := truncate_width(hint, max_int(0, inner), '')
	return [
		span('╰', border),
		span(shown, Style{
			fg: c_dim
		}),
		span('─'.repeat(max_int(0, inner - display_width(shown))) + '╯', border),
	]
}

fn max_int(a int, b int) int {
	return if a > b { a } else { b }
}

fn min_int(a int, b int) int {
	return if a < b { a } else { b }
}

// InputLayout is the wrapped input area plus where the cursor landed in it.
pub struct InputLayout {
pub:
	rows [][]Span
	// zero-based row within `rows`, and the absolute screen column
	cursor_row int
	cursor_col int
}

// max_input_rows caps the input area, matching the original's 10-row
// Dimension. Past that the view scrolls to keep the cursor visible rather
// than growing the box until it fills the screen.
pub const max_input_rows = 10

// render_input lays the buffer out inside the box's side rails.
//
//     │ ❯ first line
//     │   a continuation
//
// The "❯ " prefix belongs to the first row only; wrapped and later rows get
// two spaces, so the text stays aligned under itself. The cursor's screen
// position is computed from the same walk that produced the rows, which is
// the only way the caret and the text can be guaranteed to agree.
pub fn render_input(b &EditBuffer, width int, placeholder string) InputLayout {
	border := Style{
		fg: c_border
	}
	arrow := Style{
		fg:   c_green
		bold: true
	}
	cont := Style{
		fg: c_dim
	}
	// the rails and the prefix: '│ ' + '❯ ' on the left, ' │' on the right
	text_width := max_int(1, width - 6)

	// an empty buffer shows the placeholder, with the cursor on the arrow
	if b.runes.len == 0 {
		hint := if placeholder != '' {
			truncate_width(placeholder, text_width, '…')
		} else {
			''
		}
		mut row := [
			span('│ ', border),
			span('❯ ', arrow),
			span(hint, Style{
				fg: c_dim
			}),
			span(' '.repeat(max_int(0, text_width - display_width(hint))), Style{}),
		]
		return InputLayout{
			rows:       [close_row(row, width, border)]
			cursor_row: 0
			cursor_col: 4
		}
	}

	mut rows := [][]Span{}
	mut cursor_row := 0
	mut cursor_col := 4
	mut seen := 0 // runes consumed so far, for locating the cursor

	for line_index, line in b.lines() {
		// wrap this logical line into physical rows
		mut chunks := wrap_runes(line.runes(), text_width)
		if chunks.len == 0 {
			chunks = [[]rune{}]
		}
		for chunk_index, chunk in chunks {
			first := line_index == 0 && chunk_index == 0
			prefix := if first { '❯ ' } else { '  ' }
			prefix_style := if first { arrow } else { cont }
			text := chunk.string()
			pad := max_int(0, text_width - display_width(text))
			mut row := [
				span('│ ', border),
				span(prefix, prefix_style),
				span(text, Style{
					fg: c_fg
				}),
				span(' '.repeat(pad), Style{}),
			]
			rows << close_row(row, width, border)

			// does the cursor fall inside this chunk?
			chunk_start := seen
			chunk_end := seen + chunk.len
			in_chunk := b.cursor >= chunk_start && b.cursor <= chunk_end
			// a cursor exactly at a wrap boundary belongs to the row that
			// starts there, not the one that ends there — unless this is the
			// last chunk, where there is no next row to move to
			last_chunk := chunk_index == chunks.len - 1
			if in_chunk && (b.cursor < chunk_end || last_chunk) {
				cursor_row = rows.len - 1
				offset := b.cursor - chunk_start
				cursor_col = 2 + display_width(prefix) +
					display_width(chunk[..offset].string())
			}
			seen = chunk_end
		}
		seen++ // the newline between logical lines
	}

	// keep the box bounded: scroll so the cursor's row stays visible
	if rows.len > max_input_rows {
		mut top := cursor_row - max_input_rows + 1
		if top < 0 {
			top = 0
		}
		if top > rows.len - max_input_rows {
			top = rows.len - max_input_rows
		}
		rows = rows[top..top + max_input_rows].clone()
		cursor_row -= top
	}
	return InputLayout{
		rows:       rows
		cursor_row: cursor_row
		cursor_col: cursor_col
	}
}

// close_row appends the right-hand rail, trimming the text if a wide rune
// pushed the row past the box.
fn close_row(row []Span, width int, border Style) []Span {
	mut out := row.clone()
	used := spans_width(out)
	if used > width - 2 {
		// trim the last text span rather than letting the rail wrap
		mut trimmed := out[..out.len - 1].clone()
		over := used - (width - 2)
		last := out.last()
		trimmed << span(truncate_width(last.text, max_int(0, display_width(last.text) - over),
			''), last.style)
		out = trimmed.clone()
	}
	out << span(' │', border)
	return out
}

// wrap_runes splits a rune slice into chunks of at most `width` display
// columns. It wraps by column, not by rune count, so a line of CJK breaks at
// the right place.
fn wrap_runes(runes []rune, width int) [][]rune {
	mut out := [][]rune{}
	mut cur := []rune{}
	mut w := 0
	for r in runes {
		rw := rune_width(r)
		if w + rw > width && cur.len > 0 {
			out << cur
			cur = []rune{}
			w = 0
		}
		cur << r
		w += rw
	}
	out << cur
	return out
}

// render_box assembles the whole pinned region: optional overlay, top
// border, input rows, bottom border.
pub fn render_box(st &BoxState, b &EditBuffer, width int, overlay_rows [][]Span, placeholder string) ([][]Span, int, int) {
	layout := render_input(b, width, placeholder)
	mut rows := [][]Span{}
	rows << overlay_rows
	rows << st.render_top(width)
	rows << layout.rows
	rows << st.render_bottom(width)
	// the input rows start after the overlay and the top border
	cursor_row := overlay_rows.len + 1 + layout.cursor_row
	return rows, cursor_row, layout.cursor_col
}
