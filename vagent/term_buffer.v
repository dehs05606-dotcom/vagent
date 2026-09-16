module vagent

import os

// term_buffer.v — the editable text buffer behind the prompt box.
//
// prompt_toolkit's Buffer did this in the Python original: multi-line text,
// a cursor, word motions, kill/yank, and a persistent history the Up arrow
// walks. All of it is here, in runes rather than bytes, because a cursor
// that moves by bytes lands in the middle of a multi-byte character and the
// next redraw prints a replacement glyph.
//
// Two behaviours are worth naming because they are easy to get subtly
// wrong, and both are how the original behaved:
//
//   * Up and Down only reach history at the EDGES. On line 2 of a
//     three-line message, Up moves the cursor up a line; on line 1 it
//     recalls the previous entry. Otherwise a multi-line draft becomes
//     impossible to navigate.
//   * Recalling history stashes whatever was being typed, so walking down
//     past the newest entry returns the draft rather than an empty line.

@[heap]
pub struct EditBuffer {
pub mut:
	// the text, as runes: every index below is a rune index
	runes  []rune
	cursor int
	// persistent history, oldest first
	history []string
	// where the Up/Down walk currently sits; history.len means "not in the
	// history, editing the live draft"
	hist_pos int
	// the draft stashed when the history walk began
	stashed      string
	has_stashed  bool
	history_path string
	// the most recent kill, for Ctrl+Y
	kill_ring string
}

pub fn new_edit_buffer(history_path string) &EditBuffer {
	mut b := &EditBuffer{
		history_path: history_path
	}
	b.load_history()
	b.hist_pos = b.history.len
	return b
}

// -- text ---------------------------------------------------------------------

pub fn (b &EditBuffer) text() string {
	return b.runes.string()
}

pub fn (mut b EditBuffer) set_text(s string) {
	b.runes = s.runes()
	b.cursor = b.runes.len
}

pub fn (mut b EditBuffer) reset() {
	b.runes = []
	b.cursor = 0
	b.hist_pos = b.history.len
	b.has_stashed = false
	b.stashed = ''
}

pub fn (b &EditBuffer) is_empty() bool {
	return b.runes.len == 0
}

// -- editing ------------------------------------------------------------------

pub fn (mut b EditBuffer) insert(text string) {
	ins := text.runes()
	if ins.len == 0 {
		return
	}
	mut out := b.runes[..b.cursor].clone()
	out << ins
	out << b.runes[b.cursor..]
	b.runes = out
	b.cursor += ins.len
}

pub fn (mut b EditBuffer) backspace() {
	if b.cursor == 0 {
		return
	}
	mut out := b.runes[..b.cursor - 1].clone()
	out << b.runes[b.cursor..]
	b.runes = out
	b.cursor--
}

pub fn (mut b EditBuffer) delete_forward() {
	if b.cursor >= b.runes.len {
		return
	}
	mut out := b.runes[..b.cursor].clone()
	out << b.runes[b.cursor + 1..]
	b.runes = out
}

// delete_word_back removes the word before the cursor (Ctrl+W), including
// the whitespace that led up to it.
pub fn (mut b EditBuffer) delete_word_back() {
	if b.cursor == 0 {
		return
	}
	mut i := b.cursor
	for i > 0 && is_space_rune(b.runes[i - 1]) {
		i--
	}
	for i > 0 && !is_space_rune(b.runes[i - 1]) {
		i--
	}
	b.kill_ring = b.runes[i..b.cursor].string()
	mut out := b.runes[..i].clone()
	out << b.runes[b.cursor..]
	b.runes = out
	b.cursor = i
}

// kill_to_end removes from the cursor to the end of the line (Ctrl+K).
pub fn (mut b EditBuffer) kill_to_end() {
	end := b.line_end(b.cursor)
	if end <= b.cursor {
		return
	}
	b.kill_ring = b.runes[b.cursor..end].string()
	mut out := b.runes[..b.cursor].clone()
	out << b.runes[end..]
	b.runes = out
}

// kill_to_start removes from the start of the line to the cursor (Ctrl+U).
pub fn (mut b EditBuffer) kill_to_start() {
	start := b.line_start(b.cursor)
	if start >= b.cursor {
		return
	}
	b.kill_ring = b.runes[start..b.cursor].string()
	mut out := b.runes[..start].clone()
	out << b.runes[b.cursor..]
	b.runes = out
	b.cursor = start
}

pub fn (mut b EditBuffer) yank() {
	b.insert(b.kill_ring)
}

// -- motion -------------------------------------------------------------------

pub fn (mut b EditBuffer) move_left() {
	if b.cursor > 0 {
		b.cursor--
	}
}

pub fn (mut b EditBuffer) move_right() {
	if b.cursor < b.runes.len {
		b.cursor++
	}
}

pub fn (mut b EditBuffer) move_word_left() {
	mut i := b.cursor
	for i > 0 && is_space_rune(b.runes[i - 1]) {
		i--
	}
	for i > 0 && !is_space_rune(b.runes[i - 1]) {
		i--
	}
	b.cursor = i
}

pub fn (mut b EditBuffer) move_word_right() {
	mut i := b.cursor
	for i < b.runes.len && !is_space_rune(b.runes[i]) {
		i++
	}
	for i < b.runes.len && is_space_rune(b.runes[i]) {
		i++
	}
	b.cursor = i
}

pub fn (mut b EditBuffer) move_home() {
	b.cursor = b.line_start(b.cursor)
}

pub fn (mut b EditBuffer) move_end() {
	b.cursor = b.line_end(b.cursor)
}

fn is_space_rune(r rune) bool {
	return r == ` ` || r == `\t` || r == `\n`
}

fn (b &EditBuffer) line_start(pos int) int {
	mut i := pos
	for i > 0 && b.runes[i - 1] != `\n` {
		i--
	}
	return i
}

fn (b &EditBuffer) line_end(pos int) int {
	mut i := pos
	for i < b.runes.len && b.runes[i] != `\n` {
		i++
	}
	return i
}

// lines splits the buffer into its logical lines.
pub fn (b &EditBuffer) lines() []string {
	return b.text().split('\n')
}

// cursor_row is the zero-based logical line the cursor sits on.
pub fn (b &EditBuffer) cursor_row() int {
	mut row := 0
	for i in 0 .. b.cursor {
		if b.runes[i] == `\n` {
			row++
		}
	}
	return row
}

// cursor_col is the cursor's rune offset within its logical line.
pub fn (b &EditBuffer) cursor_col() int {
	return b.cursor - b.line_start(b.cursor)
}

pub fn (b &EditBuffer) line_count() int {
	mut n := 1
	for r in b.runes {
		if r == `\n` {
			n++
		}
	}
	return n
}

pub fn (b &EditBuffer) on_first_line() bool {
	return b.cursor_row() == 0
}

pub fn (b &EditBuffer) on_last_line() bool {
	return b.cursor_row() == b.line_count() - 1
}

// move_up moves the cursor one logical line up, keeping the column where it
// can. It returns false at the top, which is the caller's signal to walk
// history instead.
pub fn (mut b EditBuffer) move_up() bool {
	start := b.line_start(b.cursor)
	if start == 0 {
		return false
	}
	col := b.cursor - start
	prev_start := b.line_start(start - 1)
	prev_len := start - 1 - prev_start
	b.cursor = prev_start + if col < prev_len { col } else { prev_len }
	return true
}

// move_down is move_up's mirror: false at the bottom.
pub fn (mut b EditBuffer) move_down() bool {
	end := b.line_end(b.cursor)
	if end >= b.runes.len {
		return false
	}
	col := b.cursor - b.line_start(b.cursor)
	next_start := end + 1
	next_end := b.line_end(next_start)
	next_len := next_end - next_start
	b.cursor = next_start + if col < next_len { col } else { next_len }
	return true
}

// -- history ------------------------------------------------------------------

// load_history reads the persisted entries. Input history is a convenience,
// never a crash path, so an unreadable file is simply an empty history.
fn (mut b EditBuffer) load_history() {
	if b.history_path == '' {
		return
	}
	content := read_text_or_empty(b.history_path)
	if content == '' {
		return
	}
	for raw in content.split('\n') {
		line := raw.trim_right('\r')
		if line == '' {
			continue
		}
		// entries are stored with escaped newlines so a multi-line message
		// round-trips as ONE history entry rather than several
		b.history << line.replace('\\n', '\n').replace('\\\\', '\\')
	}
}

// remember appends an entry to the history and persists it.
//
// The Python original wrapped FileHistory because prompt_toolkit raised
// straight into the event loop when the history directory was missing — a
// fresh install or a deleted home dir took the whole UI down over a
// convenience file. Here every persistence error is swallowed for the same
// reason.
pub fn (mut b EditBuffer) remember(text string) {
	entry := text.trim_space()
	if entry == '' {
		return
	}
	// a repeat of the newest entry is not worth a second copy
	if b.history.len > 0 && b.history.last() == entry {
		b.hist_pos = b.history.len
		return
	}
	b.history << entry
	b.hist_pos = b.history.len
	if b.history_path == '' {
		return
	}
	encoded := entry.replace('\\', '\\\\').replace('\n', '\\n')
	append_line(b.history_path, encoded) or {
		// the directory may have vanished mid-session; recreate it once
		dir := os.dir(b.history_path)
		if dir != '' {
			os.mkdir_all(dir) or { return }
			append_line(b.history_path, encoded) or {}
		}
	}
}

// history_prev walks back through the history, stashing the live draft on
// the first step so it can be walked back to.
pub fn (mut b EditBuffer) history_prev() bool {
	if b.history.len == 0 || b.hist_pos == 0 {
		return false
	}
	if b.hist_pos == b.history.len {
		b.stashed = b.text()
		b.has_stashed = true
	}
	b.hist_pos--
	b.set_text(b.history[b.hist_pos])
	return true
}

// history_next walks forward, and past the newest entry restores the draft
// rather than clearing the line.
pub fn (mut b EditBuffer) history_next() bool {
	if b.hist_pos >= b.history.len {
		return false
	}
	b.hist_pos++
	if b.hist_pos == b.history.len {
		b.set_text(if b.has_stashed { b.stashed } else { '' })
		b.has_stashed = false
		return true
	}
	b.set_text(b.history[b.hist_pos])
	return true
}
