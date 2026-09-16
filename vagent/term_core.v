module vagent

import os
import term
import term.termios

// term_core.v — raw terminal mode, size, cursor control and byte input.
//
// The Python original got all of this from prompt_toolkit. V has none of
// it, so this is the floor the rest of the UI stands on:
//
//   * raw mode — characters arrive one keypress at a time, unbuffered and
//     unechoed, so the editor draws every character itself and Ctrl+C is a
//     key rather than a signal;
//   * a read with a timeout — the input loop must also redraw a spinner and
//     notice a finished turn, so it cannot block forever on a keypress;
//   * cursor and erase sequences, which the pinned-box renderer uses to
//     rewrite its own region without disturbing the scrollback above it.
//
// Everything is restored on exit, including on a panic: leaving a terminal
// in raw mode makes the user's shell unusable afterwards, and "the program
// crashed" must never also mean "your terminal is broken".

// ansi escape sequences, named where the raw bytes would be unreadable
pub const esc = '\x1b'
pub const csi = '\x1b['

pub const ansi_reset = '\x1b[0m'
pub const ansi_bold = '\x1b[1m'
pub const ansi_dim = '\x1b[2m'
pub const ansi_italic = '\x1b[3m'
pub const ansi_underline = '\x1b[4m'
pub const ansi_reverse = '\x1b[7m'

// hide_cursor / show_cursor bracket every redraw, so the hardware cursor
// never flickers across the box while it is being rewritten.
pub const hide_cursor = '\x1b[?25l'
pub const show_cursor = '\x1b[?25h'

// erase_to_end clears from the cursor to the end of the screen — the
// pinned box erases its own region this way before redrawing it.
pub const erase_to_end = '\x1b[0J'
pub const erase_line = '\x1b[2K'
pub const carriage_return = '\r'

pub fn cursor_up(n int) string {
	return if n > 0 { '${csi}${n}A' } else { '' }
}

pub fn cursor_down(n int) string {
	return if n > 0 { '${csi}${n}B' } else { '' }
}

pub fn cursor_right(n int) string {
	return if n > 0 { '${csi}${n}C' } else { '' }
}

pub fn cursor_left(n int) string {
	return if n > 0 { '${csi}${n}D' } else { '' }
}

pub fn cursor_column(n int) string {
	return '${csi}${n}G'
}

// ---------------------------------------------------------------------------
// Terminal state
// ---------------------------------------------------------------------------

@[heap]
pub struct Terminal {
pub mut:
	// false when stdout is not a tty (a pipe, a CI log): the UI then prints
	// plain lines and never emits a control sequence
	interactive bool
	raw_active  bool
mut:
	saved termios.Termios
}

pub fn new_terminal() &Terminal {
	return &Terminal{
		interactive: os.is_atty(0) != 0 && os.is_atty(1) != 0
	}
}

// enable_raw puts the terminal in raw mode: no echo, no line buffering, no
// signal generation, and a read that returns after 0.1s even with no input.
//
// VMIN=0/VTIME=1 is the load-bearing pair. A blocking read would freeze the
// spinner and delay the "turn finished" redraw until the user happened to
// press a key.
pub fn (mut t Terminal) enable_raw() {
	if !t.interactive || t.raw_active {
		return
	}
	if termios.tcgetattr(0, mut t.saved) != 0 {
		t.interactive = false
		return
	}
	mut raw := t.saved
	// input: no CR->NL translation, no XON/XOFF, no parity/strip
	raw.c_iflag &= termios.invert(C.IXON | C.ICRNL | C.BRKINT | C.INPCK | C.ISTRIP)
	// output: leave post-processing ON so a bare "\n" still returns the
	// cursor to column 0; turning it off would require rewriting every
	// newline in the renderer as "\r\n" for no gain
	// local: no echo, no canonical line editing, no signal keys, no
	// implementation-defined input processing
	raw.c_lflag &= termios.invert(C.ECHO | C.ICANON | C.ISIG | C.IEXTEN)
	raw.c_cc[C.VMIN] = 0
	raw.c_cc[C.VTIME] = 1 // deciseconds
	termios.set_state(0, raw)
	t.raw_active = true
}

// disable_raw restores the terminal exactly as it was found.
pub fn (mut t Terminal) disable_raw() {
	if !t.raw_active {
		return
	}
	termios.set_state(0, t.saved)
	t.raw_active = false
}

// size returns the terminal's (columns, rows), with a sane fallback for a
// terminal that will not say.
pub fn (t &Terminal) size() (int, int) {
	cols, rows := term.get_terminal_size()
	c := if cols > 0 { cols } else { 100 }
	r := if rows > 0 { rows } else { 24 }
	return c, r
}

// read_bytes returns whatever input is available, or an empty slice when
// the read timed out. It never blocks longer than the VTIME above.
pub fn (t &Terminal) read_bytes() []u8 {
	if !t.interactive {
		return []
	}
	mut buf := [512]u8{}
	n := C.read(0, &buf[0], 512)
	if n <= 0 {
		return []
	}
	mut out := []u8{cap: n}
	for i in 0 .. n {
		out << buf[i]
	}
	return out
}

fn C.read(fd int, buf voidptr, count usize) int

// write emits text to stdout without a trailing newline.
pub fn (t &Terminal) write(s string) {
	if s == '' {
		return
	}
	print(s)
}

pub fn (t &Terminal) flush() {
	flush_stdout()
}
