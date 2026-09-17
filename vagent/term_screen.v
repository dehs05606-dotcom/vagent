module vagent

import sync

// term_screen.v — the pinned prompt box, and output that scrolls above it.
//
// This is what prompt_toolkit's patch_stdout did in the Python original,
// and it is the one piece of the UI that has to be exactly right or every
// frame after it is wrong.
//
// The rule is simple and the bookkeeping is not: the box occupies the last
// N rows of the terminal and must stay there, while everything the agent
// prints scrolls past above it. So every write goes through here:
//
//   1. erase the box — move the cursor back up to where the box began and
//      clear from there to the end of the screen;
//   2. print the new output, letting the terminal scroll normally;
//   3. draw the box again at the new bottom, and remember how many rows it
//      took so step 1 can undo it next time.
//
// The remembered row count is the whole trick. A line that WRAPS occupies
// more than one row, so the count is of rendered rows, not of strings — get
// that wrong and the erase reaches too far (eating scrollback) or not far
// enough (leaving a torn half-box on screen).
//
// A non-interactive stdout (a pipe, a CI log) skips all of it: output is
// printed plainly and the box is never drawn, because a control sequence in
// a log file is noise nobody asked for.

@[heap]
pub struct Screen {
pub mut:
	term &Terminal
	// rows the pinned region currently occupies on screen
	pinned_rows int
	// which of those rows the hardware cursor was parked on by the last
	// draw. The erase has to climb exactly this far and no further: the
	// cursor does NOT sit on the bottom row, because it sits where the user
	// is typing, and assuming otherwise clears one real line of scrollback
	// above the box every time the region has something over it — a
	// completion menu, or a picker.
	cursor_at int
	// false suppresses colour (a pipe, or NO_COLOR)
	colour bool
mut:
	mu sync.Mutex
}

pub fn new_screen(term &Terminal, colour bool) &Screen {
	return &Screen{
		term:   unsafe { term }
		colour: colour && term.interactive
	}
}

// rendered_rows is how many terminal rows a line of spans will occupy once
// the terminal wraps it.
fn rendered_rows(spans []Span, width int) int {
	w := spans_width(spans)
	if w == 0 {
		return 1
	}
	if width <= 0 {
		return 1
	}
	return (w + width - 1) / width
}

// erase_pinned moves the cursor to the top of the pinned region and clears
// to the end of the screen. The caller holds the mutex.
fn (mut s Screen) erase_pinned() {
	if !s.term.interactive || s.pinned_rows == 0 {
		return
	}
	// climb from wherever the last draw parked the cursor to the region's
	// first row, then clear everything below
	mut out := carriage_return
	if s.cursor_at > 0 {
		out += cursor_up(s.cursor_at)
	}
	out += erase_to_end
	s.term.write(out)
	s.pinned_rows = 0
	s.cursor_at = 0
}

// park_row is the row a draw actually leaves the cursor on.
//
// It is the requested row, clamped into the region: a caller can ask for a
// row past the bottom when a line WRAPS (cursor_row counts lines, while the
// region is measured in rendered rows), and the draw then leaves the cursor
// on the last row rather than climbing a negative number of rows.
fn park_row(pinned_rows int, cursor_row int) int {
	last := max_int(0, pinned_rows - 1)
	if cursor_row < 0 {
		return 0
	}
	return if cursor_row > last { last } else { cursor_row }
}

// draw_pinned renders the pinned region and remembers its height. The
// caller holds the mutex.
//
// `cursor_row` and `cursor_col` place the hardware cursor inside the region
// once it is drawn, which is what makes the caret appear where the user is
// typing rather than below the box.
fn (mut s Screen) draw_pinned(lines [][]Span, cursor_row int, cursor_col int) {
	if !s.term.interactive {
		return
	}
	width, _ := s.term.size()
	mut out := hide_cursor
	mut rows := 0
	for i, line in lines {
		if i > 0 {
			out += '\n'
		}
		out += render_spans(line, s.colour)
		rows += rendered_rows(line, width)
	}
	s.pinned_rows = if rows > 0 { rows } else { 1 }

	// park the cursor: climb from the last drawn row to the target row, then
	// set the column absolutely. Remember where it landed — the next erase
	// climbs from there.
	park := park_row(s.pinned_rows, cursor_row)
	s.cursor_at = park
	rows_from_bottom := s.pinned_rows - 1 - park
	if rows_from_bottom > 0 {
		out += cursor_up(rows_from_bottom)
	}
	out += cursor_column(cursor_col + 1)
	out += show_cursor
	s.term.write(out)
	s.term.flush()
}

// redraw replaces the pinned region in place.
pub fn (mut s Screen) redraw(lines [][]Span, cursor_row int, cursor_col int) {
	s.mu.lock()
	defer {
		s.mu.unlock()
	}
	s.erase_pinned()
	s.draw_pinned(lines, cursor_row, cursor_col)
}

// print_above writes scrollback output above the pinned region and then
// redraws the region at the new bottom.
//
// Passing the region back in on every call is deliberate: the alternative
// is for the screen to hold a reference to the UI and call back into it,
// which makes the lock order depend on who printed first.
pub fn (mut s Screen) print_above(output []string, lines [][]Span, cursor_row int, cursor_col int) {
	s.mu.lock()
	defer {
		s.mu.unlock()
	}
	if !s.term.interactive {
		for line in output {
			println(line)
		}
		return
	}
	s.erase_pinned()
	mut buf := ''
	for line in output {
		buf += line + '\n'
	}
	s.term.write(buf)
	s.draw_pinned(lines, cursor_row, cursor_col)
}

// print_plain writes output with no pinned region at all — the banner
// before the box exists, and every headless subcommand.
pub fn (mut s Screen) print_plain(output []string) {
	s.mu.lock()
	defer {
		s.mu.unlock()
	}
	if s.term.interactive {
		s.erase_pinned()
	}
	for line in output {
		println(line)
	}
}

// clear_screen wipes the terminal and forgets the pinned region, so the
// next redraw starts from a clean bottom.
pub fn (mut s Screen) clear_screen() {
	s.mu.lock()
	defer {
		s.mu.unlock()
	}
	if !s.term.interactive {
		return
	}
	s.term.write('${csi}2J${csi}H')
	s.pinned_rows = 0
	s.cursor_at = 0
	s.term.flush()
}

// leave tears the pinned region down for good — on exit the shell prompt
// must land on a clean line, not inside half a box.
pub fn (mut s Screen) leave() {
	s.mu.lock()
	defer {
		s.mu.unlock()
	}
	if !s.term.interactive {
		return
	}
	s.erase_pinned()
	s.term.write(show_cursor + ansi_reset)
	s.term.flush()
}
