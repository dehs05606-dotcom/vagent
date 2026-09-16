module vagent

// term_style.v — colour, styled text, and how wide a string really is.
//
// Two jobs the Python original got from prompt_toolkit and rich:
//
//   * a style is a name, not an escape sequence. The palette below is the
//     same dracula-flavoured one the original used, and every renderer
//     names a colour rather than emitting a code, so a theme is one table.
//   * measuring a line. Box borders are drawn to a column count, and a
//     string's byte length is not its width: a UTF-8 rune can be one to
//     four bytes, a CJK character occupies TWO columns, a combining mark
//     occupies none, and an escape sequence occupies none either. Padding a
//     border with byte counts puts the closing corner in the wrong place
//     the moment anyone types an emoji.

// palette — the dracula-flavoured colours the whole UI names.
pub const c_border = '#6272a4'
pub const c_accent = '#bd93f9'
pub const c_cyan = '#8be9fd'
pub const c_green = '#50fa7b'
pub const c_yellow = '#f1fa8c'
pub const c_orange = '#ffb86c'
pub const c_red = '#ff5555'
pub const c_pink = '#ff79c6'
pub const c_fg = '#f8f8f2'
pub const c_dim = '#6272a4'
pub const c_selection_bg = '#44475a'
pub const c_panel_bg = '#282a36'

// spinner_frames are the braille frames the busy indicator cycles.
pub const spinner_frames = ['⠋', '⠙', '⠹', '⠸', '⠼', '⠴', '⠦', '⠧', '⠇', '⠏']

// Style is a foreground/background pair plus attributes. An empty colour
// means "leave the terminal's own".
pub struct Style {
pub:
	fg        string
	bg        string
	bold      bool
	dim       bool
	italic    bool
	underline bool
	reverse   bool
	strike    bool
}

// hex_rgb parses '#rrggbb' into its components. A malformed colour yields
// ok=false, and the caller then emits no colour at all rather than a
// corrupt escape sequence.
pub fn hex_rgb(hex string) (int, int, int, bool) {
	s := hex.trim_left('#')
	if s.len != 6 {
		return 0, 0, 0, false
	}
	mut vals := [0, 0, 0]
	for i in 0 .. 3 {
		hi := hex_digit(s[i * 2]) or { return 0, 0, 0, false }
		lo := hex_digit(s[i * 2 + 1]) or { return 0, 0, 0, false }
		vals[i] = hi * 16 + lo
	}
	return vals[0], vals[1], vals[2], true
}

fn hex_digit(c u8) ?int {
	return match c {
		`0`...`9` { int(c - `0`) }
		`a`...`f` { int(c - `a`) + 10 }
		`A`...`F` { int(c - `A`) + 10 }
		else { none }
	}
}

// ansi renders a style as the escape sequence that turns it on.
pub fn (s &Style) ansi() string {
	mut parts := []string{}
	if s.bold {
		parts << '1'
	}
	if s.dim {
		parts << '2'
	}
	if s.italic {
		parts << '3'
	}
	if s.underline {
		parts << '4'
	}
	if s.reverse {
		parts << '7'
	}
	if s.strike {
		parts << '9'
	}
	if s.fg != '' {
		r, g, b, ok := hex_rgb(s.fg)
		if ok {
			parts << '38;2;${r};${g};${b}'
		}
	}
	if s.bg != '' {
		r, g, b, ok := hex_rgb(s.bg)
		if ok {
			parts << '48;2;${r};${g};${b}'
		}
	}
	if parts.len == 0 {
		return ''
	}
	return '${csi}${parts.join(";")}m'
}

pub fn (s &Style) is_plain() bool {
	return s.fg == '' && s.bg == '' && !s.bold && !s.dim && !s.italic
		&& !s.underline && !s.reverse && !s.strike
}

// Span is a run of text carrying one style — the unit every renderer
// produces and the screen consumes.
pub struct Span {
pub:
	text  string
	style Style
}

pub fn span(text string, style Style) Span {
	return Span{
		text:  text
		style: style
	}
}

pub fn plain(text string) Span {
	return Span{
		text: text
	}
}

pub fn fg(text string, colour string) Span {
	return Span{
		text:  text
		style: Style{
			fg: colour
		}
	}
}

pub fn bold_fg(text string, colour string) Span {
	return Span{
		text:  text
		style: Style{
			fg:   colour
			bold: true
		}
	}
}

// render_spans turns a line of spans into terminal output, resetting after
// every styled run so a colour never bleeds into what follows.
pub fn render_spans(spans []Span, colour bool) string {
	mut out := []string{}
	for sp in spans {
		if sp.text == '' {
			continue
		}
		if !colour || sp.style.is_plain() {
			out << sp.text
			continue
		}
		out << sp.style.ansi() + sp.text + ansi_reset
	}
	return out.join('')
}

pub fn spans_text(spans []Span) string {
	mut out := []string{}
	for sp in spans {
		out << sp.text
	}
	return out.join('')
}

pub fn spans_width(spans []Span) int {
	mut w := 0
	for sp in spans {
		w += display_width(sp.text)
	}
	return w
}

// ---------------------------------------------------------------------------
// Display width
// ---------------------------------------------------------------------------

// rune_width is how many terminal columns one rune occupies: zero for a
// combining mark or a zero-width joiner, two for the wide CJK and emoji
// ranges, one for everything else.
pub fn rune_width(r rune) int {
	if r == 0 {
		return 0
	}
	// C0/C1 control characters occupy nothing
	if r < 32 || (r >= 0x7f && r < 0xa0) {
		return 0
	}
	// combining marks, variation selectors, zero-width space/joiner
	if (r >= 0x0300 && r <= 0x036f) || (r >= 0x200b && r <= 0x200f)
		|| (r >= 0xfe00 && r <= 0xfe0f) || (r >= 0x20d0 && r <= 0x20ff)
		|| r == 0xfeff {
		return 0
	}
	// the wide ranges: CJK, Hangul, Kana, fullwidth forms, and the emoji
	// blocks a modern terminal renders double-width
	if (r >= 0x1100 && r <= 0x115f) || (r >= 0x2e80 && r <= 0x303e)
		|| (r >= 0x3041 && r <= 0x33ff) || (r >= 0x3400 && r <= 0x4dbf)
		|| (r >= 0x4e00 && r <= 0x9fff) || (r >= 0xa000 && r <= 0xa4cf)
		|| (r >= 0xac00 && r <= 0xd7a3) || (r >= 0xf900 && r <= 0xfaff)
		|| (r >= 0xfe30 && r <= 0xfe6f) || (r >= 0xff00 && r <= 0xff60)
		|| (r >= 0xffe0 && r <= 0xffe6) || (r >= 0x1f300 && r <= 0x1f64f)
		|| (r >= 0x1f900 && r <= 0x1f9ff) || (r >= 0x20000 && r <= 0x3fffd) {
		return 2
	}
	return 1
}

// display_width is how many columns a string occupies, ignoring any escape
// sequences it already carries.
pub fn display_width(s string) int {
	mut w := 0
	runes := s.runes()
	mut i := 0
	for i < runes.len {
		if runes[i] == rune(0x1b) {
			// skip an escape sequence up to its final byte
			i++
			if i < runes.len && (runes[i] == `[` || runes[i] == `]`) {
				i++
				for i < runes.len && !is_csi_final(runes[i]) {
					i++
				}
			}
			i++
			continue
		}
		w += rune_width(runes[i])
		i++
	}
	return w
}

fn is_csi_final(r rune) bool {
	return (r >= `@` && r <= `~`) && r != `[`
}

// truncate_width clips a string to at most `width` columns, appending `tail`
// (usually '…') when anything was dropped. It never splits a rune.
pub fn truncate_width(s string, width int, tail string) string {
	if display_width(s) <= width {
		return s
	}
	tail_w := display_width(tail)
	budget := if width - tail_w > 0 { width - tail_w } else { 0 }
	mut w := 0
	mut out := []rune{}
	for r in s.runes() {
		rw := rune_width(r)
		if w + rw > budget {
			break
		}
		out << r
		w += rw
	}
	return out.string() + tail
}

// pad_width right-pads a string to `width` columns.
pub fn pad_width(s string, width int) string {
	w := display_width(s)
	return if w >= width { s } else { s + ' '.repeat(width - w) }
}

// wrap_width breaks text into lines of at most `width` columns, preferring a
// space boundary and hard-breaking a word that is longer than the line.
pub fn wrap_width(text string, width int) []string {
	if width <= 0 {
		return [text]
	}
	mut out := []string{}
	for para in split_lines(text) {
		if display_width(para) <= width {
			out << para
			continue
		}
		mut line := ''
		mut line_w := 0
		for word in para.split(' ') {
			ww := display_width(word)
			if ww > width {
				// a word longer than the line: flush, then hard-break it
				if line != '' {
					out << line
					line = ''
					line_w = 0
				}
				mut chunk := ''
				mut chunk_w := 0
				for r in word.runes() {
					rw := rune_width(r)
					if chunk_w + rw > width {
						out << chunk
						chunk = ''
						chunk_w = 0
					}
					chunk += r.str()
					chunk_w += rw
				}
				if chunk != '' {
					line = chunk
					line_w = chunk_w
				}
				continue
			}
			if line == '' {
				line = word
				line_w = ww
				continue
			}
			if line_w + 1 + ww > width {
				out << line
				line = word
				line_w = ww
				continue
			}
			line += ' ' + word
			line_w += 1 + ww
		}
		if line != '' {
			out << line
		}
	}
	return out
}

// -- span-aware wrapping -------------------------------------------------------

// wrap_spans breaks a styled line into lines of at most `width` columns,
// keeping each run's style intact across the break.
//
// wrap_width above works on plain strings and is enough for output that
// carries one colour. Rendered markdown does not: a sentence can hold bold,
// code and link runs, and re-styling after a naive wrap would repaint the
// whole line in the last style it saw.
pub fn wrap_spans(spans []Span, width int) [][]Span {
	if width <= 0 {
		return [spans]
	}
	// split into words and the spaces between them, each keeping its style
	mut toks := []Span{}
	for sp in spans {
		mut cur := ''
		for r in sp.text.runes() {
			if r == ` ` {
				if cur != '' {
					toks << span(cur, sp.style)
					cur = ''
				}
				toks << span(' ', sp.style)
				continue
			}
			cur += r.str()
		}
		if cur != '' {
			toks << span(cur, sp.style)
		}
	}

	mut out := [][]Span{}
	mut line := []Span{}
	mut line_w := 0
	for tok in toks {
		tw := display_width(tok.text)
		if tok.text == ' ' {
			// a space at the head of a line is the seam of a break: drop it
			if line_w == 0 {
				continue
			}
			line << tok
			line_w += tw
			continue
		}
		if line_w + tw <= width {
			line << tok
			line_w += tw
			continue
		}
		// the word does not fit: flush, dropping the trailing space
		if line_w > 0 {
			for line.len > 0 && line.last().text == ' ' {
				line.delete_last()
			}
			out << line
			line = []Span{}
			line_w = 0
		}
		if tw <= width {
			line << tok
			line_w = tw
			continue
		}
		// a single word wider than the line — hard-break it
		mut chunk := ''
		mut chunk_w := 0
		for r in tok.text.runes() {
			rw := rune_width(r)
			if chunk_w + rw > width {
				out << [span(chunk, tok.style)]
				chunk = ''
				chunk_w = 0
			}
			chunk += r.str()
			chunk_w += rw
		}
		if chunk != '' {
			line = [span(chunk, tok.style)]
			line_w = chunk_w
		}
	}
	for line.len > 0 && line.last().text == ' ' {
		line.delete_last()
	}
	if line.len > 0 {
		out << line
	}
	if out.len == 0 {
		out << []Span{}
	}
	return out
}
