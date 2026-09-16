module vagent

// ui_markdown.v — rendered-markdown replies.
//
// The Python original handed the finished reply to rich's Markdown with two
// substitutions installed at import time (tui.py, `Markdown.elements[...]`):
//
//   * every heading renders as `◆ {text}` in bold accent, not as rich's
//     underlined rule;
//   * every fenced block renders as syntax-highlighted code with one column
//     of padding, followed by a blank line.
//
// Both are reproduced here. What is NOT reproduced is pygments: rich chose a
// lexer per fence and coloured with monokai, and there is no pygments in V.
// The highlighter below is generic — comments, strings, numbers and a shared
// keyword set — which reads correctly for every language the agent writes
// and mis-colours nothing, because it only ever paints tokens it is sure of.
//
// This whole path is behind /render, which is OFF by default: streaming
// replies print raw, exactly as before.

// md_code_keywords are the words highlighted inside a fence. The set is the
// intersection of the languages an agent actually emits, so a word only gets
// a colour when it is a keyword in whatever language this is.
const md_code_keywords = ['if', 'else', 'elif', 'for', 'while', 'return', 'break',
	'continue', 'fn', 'func', 'def', 'class', 'struct', 'enum', 'interface', 'import',
	'from', 'pub', 'const', 'let', 'var', 'mut', 'match', 'switch', 'case', 'default',
	'try', 'catch', 'except', 'finally', 'raise', 'throw', 'new', 'delete', 'in', 'is',
	'not', 'and', 'or', 'true', 'false', 'none', 'nil', 'null', 'self', 'this', 'type',
	'module', 'package', 'public', 'private', 'static', 'void', 'int', 'string', 'bool',
	'float', 'with', 'as', 'yield', 'async', 'await', 'lambda', 'defer', 'go', 'select',
	'unsafe', 'assert', 'echo', 'end', 'do', 'then', 'fi', 'elsif', 'use', 'where']

// ---------------------------------------------------------------------------
// Inline markup
// ---------------------------------------------------------------------------

// md_inline turns one line of markdown into styled runs.
//
// The `_` rules are the ones worth stating: `_x_` is emphasis only when the
// opener does not sit inside a word. Without that rule an agent printing
// `some_function_name` would render the middle in italics and the reader
// would lose the identifier.
pub fn md_inline(text string) []Span {
	rs := text.runes()
	mut out := []Span{}
	mut buf := ''
	mut i := 0

	flush := fn (mut out []Span, buf string) {
		if buf != '' {
			out << span(buf, Style{ fg: c_fg })
		}
	}

	for i < rs.len {
		r := rs[i]

		// backslash escapes the next punctuation character
		if r == `\\` && i + 1 < rs.len && !is_alnum_rune(rs[i + 1]) {
			buf += rs[i + 1].str()
			i += 2
			continue
		}

		// `code`  (a run of N backticks closes on the next run of N)
		if r == `\`` {
			mut n := 0
			for i + n < rs.len && rs[i + n] == `\`` {
				n++
			}
			if close := find_run(rs, i + n, `\``, n) {
				flush(mut out, buf)
				buf = ''
				code := rs[i + n..close].string()
				out << span(code, Style{
					fg:   c_cyan
					bold: true
				})
				i = close + n
				continue
			}
		}

		// **bold**, __bold__, ~~strike~~
		if i + 1 < rs.len && rs[i + 1] == r && (r == `*` || r == `_` || r == `~`) {
			marker := rs[i..i + 2].string()
			if close := index_of_sub(rs, i + 2, marker) {
				if close > i + 2 {
					flush(mut out, buf)
					buf = ''
					inner := rs[i + 2..close].string()
					st := if r == `~` {
						Style{
							fg:     c_fg
							strike: true
						}
					} else {
						Style{
							fg:   c_fg
							bold: true
						}
					}
					out << restyle(md_inline(inner), st)
					i = close + 2
					continue
				}
			}
		}

		// *italic* / _italic_
		if r == `*` || r == `_` {
			opens := if r == `_` {
				(i == 0 || !is_alnum_rune(rs[i - 1])) && i + 1 < rs.len && rs[i + 1] != ` `
			} else {
				i + 1 < rs.len && rs[i + 1] != ` `
			}
			if opens {
				if close := find_emph_close(rs, i + 1, r) {
					flush(mut out, buf)
					buf = ''
					inner := rs[i + 1..close].string()
					out << restyle(md_inline(inner), Style{
						fg:     c_fg
						italic: true
					})
					i = close + 1
					continue
				}
			}
		}

		// [label](url) and ![alt](url)
		if r == `[` || (r == `!` && i + 1 < rs.len && rs[i + 1] == `[`) {
			start := if r == `!` { i + 1 } else { i }
			if rb := index_of_rune(rs, start + 1, `]`) {
				if rb + 1 < rs.len && rs[rb + 1] == `(` {
					if rp := index_of_rune(rs, rb + 2, `)`) {
						flush(mut out, buf)
						buf = ''
						label := rs[start + 1..rb].string()
						url := rs[rb + 2..rp].string()
						out << restyle(md_inline(label), Style{
							fg:        c_cyan
							underline: true
						})
						// the terminal cannot be clicked, so the target is
						// shown — unless it is the label already, which is
						// what a bare autolink looks like
						if url != label && url != '' {
							out << span(' (${url})', Style{ fg: c_dim })
						}
						i = rp + 1
						continue
					}
				}
			}
		}

		buf += r.str()
		i++
	}
	flush(mut out, buf)
	if out.len == 0 {
		out << span('', Style{ fg: c_fg })
	}
	return out
}

// restyle re-paints a run of spans with an outer style, keeping whatever the
// inner markup set for itself: `**bold `code`**` stays code-coloured AND
// bold.
fn restyle(spans []Span, outer Style) []Span {
	mut out := []Span{}
	for sp in spans {
		out << span(sp.text, Style{
			fg:        if sp.style.fg != '' && sp.style.fg != c_fg { sp.style.fg } else { outer.fg }
			bg:        if sp.style.bg != '' { sp.style.bg } else { outer.bg }
			bold:      sp.style.bold || outer.bold
			dim:       sp.style.dim || outer.dim
			italic:    sp.style.italic || outer.italic
			underline: sp.style.underline || outer.underline
			strike:    sp.style.strike || outer.strike
		})
	}
	return out
}

fn is_alnum_rune(r rune) bool {
	return (r >= `a` && r <= `z`) || (r >= `A` && r <= `Z`) || (r >= `0` && r <= `9`)
		|| r == `_` || r > 127
}

fn index_of_rune(rs []rune, from int, want rune) ?int {
	for i := from; i < rs.len; i++ {
		if rs[i] == want {
			return i
		}
	}
	return none
}

fn index_of_sub(rs []rune, from int, sub string) ?int {
	needle := sub.runes()
	if needle.len == 0 {
		return none
	}
	for i := from; i + needle.len <= rs.len; i++ {
		mut ok := true
		for j in 0 .. needle.len {
			if rs[i + j] != needle[j] {
				ok = false
				break
			}
		}
		if ok {
			return i
		}
	}
	return none
}

// find_run locates the next run of exactly `n` of `want` — a two-backtick
// code span must not close on a single backtick inside it.
fn find_run(rs []rune, from int, want rune, n int) ?int {
	mut i := from
	for i < rs.len {
		if rs[i] != want {
			i++
			continue
		}
		mut len := 0
		for i + len < rs.len && rs[i + len] == want {
			len++
		}
		if len == n {
			return i
		}
		i += len
	}
	return none
}

// find_emph_close finds the matching single `*` or `_`, skipping a doubled
// marker (which belongs to a bold run) and requiring the closer to sit at
// the end of a word.
fn find_emph_close(rs []rune, from int, marker rune) ?int {
	mut i := from
	for i < rs.len {
		if rs[i] != marker {
			i++
			continue
		}
		if i + 1 < rs.len && rs[i + 1] == marker {
			i += 2
			continue
		}
		if rs[i - 1] == ` ` {
			i++
			continue
		}
		if marker == `_` && i + 1 < rs.len && is_alnum_rune(rs[i + 1]) {
			i++
			continue
		}
		return i
	}
	return none
}

// ---------------------------------------------------------------------------
// Block structure
// ---------------------------------------------------------------------------

// render_markdown lays a whole reply out at `width` columns.
pub fn render_markdown(text string, width int) [][]Span {
	w := max_int(8, width)
	lines := split_lines(text)
	mut out := [][]Span{}
	mut i := 0

	// blocks are separated by one blank row, never leading or trailing
	sep := fn (mut out [][]Span) {
		if out.len > 0 && spans_text(out.last()) != '' {
			out << []Span{}
		}
	}

	for i < lines.len {
		raw := lines[i]
		line := raw.trim_left(' \t')

		if line.trim_space() == '' {
			i++
			continue
		}

		// fenced code
		if fence := fence_marker(line) {
			lang := line.trim_left('`~').trim_space()
			mut body := []string{}
			i++
			for i < lines.len {
				probe := lines[i].trim_left(' \t')
				if probe.starts_with(fence) && probe.trim_right('`~ ') == '' {
					i++
					break
				}
				body << lines[i]
				i++
			}
			sep(mut out)
			for row in code_rows(body, lang, w) {
				out << row
			}
			continue
		}

		// ATX heading
		if h := atx_heading(line) {
			sep(mut out)
			for row in wrap_spans(restyle(md_inline('◆ ' + h), Style{
				fg:   c_accent
				bold: true
			}), w)
			{
				out << row
			}
			i++
			continue
		}

		// thematic break
		if is_thematic_break(line) {
			sep(mut out)
			out << [span('─'.repeat(w), Style{ fg: c_border })]
			i++
			continue
		}

		// block quote — gather, strip the markers, render the inside
		if line.starts_with('>') {
			mut body := []string{}
			for i < lines.len {
				probe := lines[i].trim_left(' \t')
				if !probe.starts_with('>') {
					if probe.trim_space() == '' {
						break
					}
					// a lazy continuation line belongs to the quote
					body << lines[i]
					i++
					continue
				}
				body << probe[1..].trim_string_left(' ')
				i++
			}
			sep(mut out)
			for row in render_markdown(body.join('\n'), w - 2) {
				mut quoted := [span('▌ ', Style{ fg: c_border })]
				quoted << restyle(row, Style{ fg: c_dim })
				out << quoted
			}
			continue
		}

		// table — a header row followed by a |---|---| delimiter
		if line.starts_with('|') && i + 1 < lines.len
			&& is_table_delimiter(lines[i + 1].trim_left(' \t')) {
			mut body := []string{}
			for i < lines.len && lines[i].trim_left(' \t').starts_with('|') {
				body << lines[i].trim_left(' \t')
				i++
			}
			sep(mut out)
			for row in table_rows(body, w) {
				out << row
			}
			continue
		}

		// list — gather every item at this level and below
		if list_marker(line) != none {
			mut body := []string{}
			for i < lines.len {
				probe := lines[i]
				if probe.trim_space() == '' {
					// a blank line inside a list continues it only if the
					// next line is another item
					if i + 1 < lines.len && list_marker(lines[i + 1].trim_left(' \t')) != none {
						i++
						continue
					}
					break
				}
				if list_marker(probe.trim_left(' \t')) == none && indent_of(probe) == 0 {
					break
				}
				body << probe
				i++
			}
			sep(mut out)
			for row in list_rows(body, w) {
				out << row
			}
			continue
		}

		// paragraph
		mut para := []string{}
		for i < lines.len {
			probe := lines[i].trim_left(' \t')
			if probe.trim_space() == '' || probe.starts_with('>') || atx_heading(probe) != none
				|| fence_marker(probe) != none || is_thematic_break(probe)
				|| list_marker(probe) != none {
				break
			}
			// a setext underline turns the paragraph so far into a heading
			if para.len > 0 && is_setext_underline(probe) {
				i++
				sep(mut out)
				for row in wrap_spans(restyle(md_inline('◆ ' + para.join(' ')), Style{
					fg:   c_accent
					bold: true
				}), w)
				{
					out << row
				}
				para = []
				break
			}
			para << probe
			i++
		}
		if para.len == 0 {
			continue
		}
		sep(mut out)
		for row in wrap_spans(md_inline(para.join(' ')), w) {
			out << row
		}
	}
	return out
}

fn indent_of(line string) int {
	mut n := 0
	for c in line {
		if c == ` ` {
			n++
		} else if c == `\t` {
			n += 4
		} else {
			break
		}
	}
	return n
}

fn fence_marker(line string) ?string {
	if line.starts_with('```') {
		return '```'
	}
	if line.starts_with('~~~') {
		return '~~~'
	}
	return none
}

fn atx_heading(line string) ?string {
	mut n := 0
	for n < line.len && line[n] == `#` {
		n++
	}
	if n == 0 || n > 6 {
		return none
	}
	if n < line.len && line[n] != ` ` {
		return none
	}
	return line[n..].trim_space().trim_right('#').trim_space()
}

fn is_thematic_break(line string) bool {
	s := line.replace(' ', '')
	if s.len < 3 {
		return false
	}
	c := s[0]
	if c != `-` && c != `*` && c != `_` {
		return false
	}
	for ch in s {
		if ch != c {
			return false
		}
	}
	return true
}

fn is_setext_underline(line string) bool {
	s := line.trim_space()
	if s.len < 2 {
		return false
	}
	c := s[0]
	if c != `=` {
		return false
	}
	for ch in s {
		if ch != c {
			return false
		}
	}
	return true
}

// ---------------------------------------------------------------------------
// Lists
// ---------------------------------------------------------------------------

// list_marker splits an item line into its marker and its text, or reports
// that the line is not a list item at all.
fn list_marker(line string) ?(string, string) {
	if line.len >= 2 && (line[0] == `-` || line[0] == `*` || line[0] == `+`)
		&& line[1] == ` ` {
		return '•', line[2..].trim_string_left(' ')
	}
	mut n := 0
	for n < line.len && line[n] >= `0` && line[n] <= `9` {
		n++
	}
	if n > 0 && n + 1 < line.len && (line[n] == `.` || line[n] == `)`) && line[n + 1] == ` ` {
		return line[..n + 1], line[n + 2..].trim_string_left(' ')
	}
	return none
}

fn list_rows(body []string, width int) [][]Span {
	mut out := [][]Span{}
	mut pending := []Span{}
	mut pending_indent := 0
	mut pending_marker := ''

	emit := fn [width] (mut out [][]Span, marker string, indent int, spans []Span) {
		if spans.len == 0 && marker == '' {
			return
		}
		pad := ' '.repeat(indent)
		bullet := pad + marker + ' '
		bw := display_width(bullet)
		wrapped := wrap_spans(spans, max_int(4, width - bw))
		for n, row in wrapped {
			mut line := []Span{}
			if n == 0 {
				line << span(bullet, Style{
					fg:   c_accent
					bold: true
				})
			} else {
				line << plain(' '.repeat(bw))
			}
			line << row
			out << line
		}
	}

	for raw in body {
		line := raw.trim_left(' \t')
		if marker, text := list_marker(line) {
			if pending_marker != '' || pending.len > 0 {
				emit(mut out, pending_marker, pending_indent, pending)
			}
			pending_marker = marker
			// two source columns of indent is one nesting level
			pending_indent = (indent_of(raw) / 2) * 2
			pending = md_inline(text)
			continue
		}
		// a continuation line folds into the item above it
		if pending_marker != '' {
			pending << span(' ', Style{ fg: c_fg })
			pending << md_inline(line)
		}
	}
	if pending_marker != '' || pending.len > 0 {
		emit(mut out, pending_marker, pending_indent, pending)
	}
	return out
}

// ---------------------------------------------------------------------------
// Tables
// ---------------------------------------------------------------------------

fn is_table_delimiter(line string) bool {
	if !line.starts_with('|') {
		return false
	}
	cells := split_table_row(line)
	if cells.len == 0 {
		return false
	}
	for cell in cells {
		s := cell.trim_space()
		if s == '' {
			return false
		}
		for ch in s {
			if ch != `-` && ch != `:` {
				return false
			}
		}
	}
	return true
}

fn split_table_row(line string) []string {
	mut s := line.trim_space()
	if s.starts_with('|') {
		s = s[1..]
	}
	if s.ends_with('|') {
		s = s[..s.len - 1]
	}
	return s.split('|').map(it.trim_space())
}

fn table_rows(body []string, width int) [][]Span {
	if body.len < 2 {
		return [][]Span{}
	}
	header := split_table_row(body[0])
	mut rows := [][]string{}
	for i := 2; i < body.len; i++ {
		mut cells := split_table_row(body[i])
		for cells.len < header.len {
			cells << ''
		}
		rows << cells[..header.len].clone()
	}

	// natural column widths, then shrunk together until the table fits
	mut cols := []int{len: header.len, init: 0}
	for n, cell in header {
		cols[n] = display_width(cell)
	}
	for row in rows {
		for n, cell in row {
			w := display_width(cell)
			if w > cols[n] {
				cols[n] = w
			}
		}
	}
	// │ + per column (space + text + space + │)
	mut total := 1
	for c in cols {
		total += c + 3
	}
	for total > width {
		mut widest := 0
		for n, c in cols {
			if c > cols[widest] {
				widest = n
			}
			_ = c
		}
		if cols[widest] <= 3 {
			break
		}
		cols[widest]--
		total--
	}

	border := Style{
		fg: c_border
	}
	rule := fn [cols, border] (left string, mid string, right string) []Span {
		mut s := left
		for n, c in cols {
			if n > 0 {
				s += mid
			}
			s += '─'.repeat(c + 2)
		}
		return [span(s + right, border)]
	}
	line_of := fn [cols, border] (cells []string, style Style) []Span {
		mut out := [span('│', border)]
		for n, c in cols {
			text := if n < cells.len { cells[n] } else { '' }
			out << span(' ' + pad_width(truncate_width(text, c, '…'), c) + ' ', style)
			out << span('│', border)
		}
		return out
	}

	mut out := [][]Span{}
	out << rule('╭', '┬', '╮')
	out << line_of(header, Style{
		fg:   c_accent
		bold: true
	})
	out << rule('├', '┼', '┤')
	for row in rows {
		out << line_of(row, Style{ fg: c_fg })
	}
	out << rule('╰', '┴', '╯')
	return out
}

// ---------------------------------------------------------------------------
// Code fences
// ---------------------------------------------------------------------------

fn code_rows(body []string, lang string, width int) [][]Span {
	mut out := [][]Span{}
	inner := max_int(4, width - 2)
	for raw in body {
		for chunk in wrap_width(raw.replace('\t', '    '), inner) {
			mut line := [plain(' ')]
			line << highlight_code(chunk, lang)
			out << line
		}
	}
	// rich's CodeBlock yielded a trailing blank Text() — the fence never
	// abuts the paragraph after it
	out << []Span{}
	return out
}

// highlight_code paints the tokens any language agrees on. Anything it is
// not sure of stays foreground-coloured, which is the point: a wrong colour
// is worse than no colour.
fn highlight_code(line string, lang string) []Span {
	rs := line.runes()
	mut out := []Span{}
	mut buf := ''
	mut i := 0

	code_fg := Style{
		fg: c_fg
	}
	flush := fn [code_fg] (mut out []Span, buf string) {
		if buf != '' {
			out << span(buf, code_fg)
		}
	}

	for i < rs.len {
		r := rs[i]

		// comment to end of line
		if r == `#` || (r == `/` && i + 1 < rs.len && rs[i + 1] == `/`)
			|| (r == `-` && i + 1 < rs.len && rs[i + 1] == `-` && lang == 'sql') {
			flush(mut out, buf)
			buf = ''
			out << span(rs[i..].string(), Style{ fg: c_dim })
			return out
		}

		// string literal
		if r == `"` || r == `'` || r == `\`` {
			mut j := i + 1
			for j < rs.len {
				if rs[j] == `\\` {
					j += 2
					continue
				}
				if rs[j] == r {
					break
				}
				j++
			}
			if j < rs.len {
				flush(mut out, buf)
				buf = ''
				out << span(rs[i..j + 1].string(), Style{ fg: c_yellow })
				i = j + 1
				continue
			}
		}

		// word — a keyword, a number, or neither
		if is_alnum_rune(r) {
			mut j := i
			for j < rs.len && is_alnum_rune(rs[j]) {
				j++
			}
			word := rs[i..j].string()
			flush(mut out, buf)
			buf = ''
			if word.to_lower() in md_code_keywords {
				out << span(word, Style{
					fg:   c_pink
					bold: true
				})
			} else if is_number_word(word) {
				out << span(word, Style{ fg: c_orange })
			} else {
				out << span(word, code_fg)
			}
			i = j
			continue
		}

		buf += r.str()
		i++
	}
	flush(mut out, buf)
	if out.len == 0 {
		out << span('', code_fg)
	}
	return out
}

fn is_number_word(word string) bool {
	if word == '' {
		return false
	}
	if word[0] < `0` || word[0] > `9` {
		return false
	}
	for c in word {
		if !((c >= `0` && c <= `9`) || (c >= `a` && c <= `f`) || (c >= `A` && c <= `F`)
			|| c == `x` || c == `X` || c == `_`) {
			return false
		}
	}
	return true
}
