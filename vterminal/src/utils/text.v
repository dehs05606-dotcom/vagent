module utils

import strings

// truncate shortens `s` to at most `max` characters, marking the cut so the
// model can tell the difference between a short output and a clipped one.
pub fn truncate(s string, max int) string {
	if max <= 0 || s.len <= max {
		return s
	}
	cut := s#[..max]
	return '${cut}\n... [truncated, ${s.len - max} more bytes]'
}

// truncate_middle keeps both ends of a long output. Errors usually live at the
// tail of a build log while the command echo lives at the head, so dropping
// the middle preserves more signal than dropping the tail.
pub fn truncate_middle(s string, max int) string {
	if max <= 0 || s.len <= max {
		return s
	}
	half := max / 2
	head := s#[..half]
	tail := s#[-half..]
	omitted := s.len - (half * 2)
	return '${head}\n... [${omitted} bytes omitted] ...\n${tail}'
}

// estimate_tokens is a cheap character-based approximation. It is deliberately
// not a real tokenizer: budgeting only needs to be roughly right, and shipping
// a per-model BPE table would be a lot of weight for that.
pub fn estimate_tokens(s string) int {
	if s == '' {
		return 0
	}
	return (s.len / 4) + 1
}

// indent prefixes every line of `s` with `prefix`.
pub fn indent(s string, prefix string) string {
	mut sb := strings.new_builder(s.len + 16)
	lines := s.split('\n')
	for i, line in lines {
		sb.write_string(prefix)
		sb.write_string(line)
		if i < lines.len - 1 {
			sb.write_string('\n')
		}
	}
	return sb.str()
}

// first_line is used for one-line summaries of multi-line tool output.
pub fn first_line(s string) string {
	t := s.trim_space()
	idx := t.index('\n') or { return t }
	return t#[..idx]
}

// abbreviations are the sentence-looking fragments that must not end a
// sentence when first_sentence scans for a period.
const abbreviations = ['e.g', 'i.e', 'etc', 'vs', 'cf', 'approx']

// first_sentence extracts the leading sentence of a description for compact
// listings, without being fooled by "e.g." mid-sentence.
pub fn first_sentence(s string) string {
	t := s.trim_space()
	mut i := 0
	for i < t.len {
		idx := t.index_after('.', i) or { return t }
		// A sentence end is a period followed by end-of-string or whitespace.
		if idx + 1 < t.len && t[idx + 1] != ` ` && t[idx + 1] != `\n` {
			i = idx + 1
			continue
		}
		head := t#[..idx]
		mut is_abbrev := false
		for ab in abbreviations {
			if head.to_lower().ends_with(ab) {
				is_abbrev = true
				break
			}
		}
		if is_abbrev {
			i = idx + 1
			continue
		}
		return head
	}
	return t
}

// count_lines counts lines the way an editor does: a trailing newline does not
// create an extra empty line.
pub fn count_lines(s string) int {
	if s == '' {
		return 0
	}
	mut n := s.count('\n')
	if !s.ends_with('\n') {
		n++
	}
	return n
}

// human_bytes formats a byte count for the status bar.
pub fn human_bytes(n i64) string {
	if n < 1024 {
		return '${n}B'
	}
	if n < 1024 * 1024 {
		return '${f64(n) / 1024.0:.1f}K'
	}
	return '${f64(n) / (1024.0 * 1024.0):.1f}M'
}

// human_count abbreviates token counts for the status bar.
pub fn human_count(n int) string {
	if n < 1000 {
		return n.str()
	}
	if n < 1000000 {
		return '${f64(n) / 1000.0:.1f}K'
	}
	return '${f64(n) / 1000000.0:.2f}M'
}

// glob_match implements `*`, `?` and `**` matching against a slash-separated
// path. V's stdlib has no glob matcher, and the search tools need one.
//
//   `?`  matches one character, never a separator
//   `*`  matches within a single path segment
//   `**` matches across segments; `**/` also matches zero directories
pub fn glob_match(pattern string, path string) bool {
	return glob_here(pattern.replace('\\', '/'), path.replace('\\', '/'))
}

// glob_here is written recursively rather than with the usual single-slot
// backtracking loop: that trick cannot express two different star semantics at
// once, and silently mismatches patterns like `src/**/*.v`.
fn glob_here(p string, s string) bool {
	if p == '' {
		return s == ''
	}
	if p.starts_with('**') {
		mut rest := p#[2..]
		for rest.starts_with('*') {
			rest = rest#[1..]
		}
		if rest.starts_with('/') {
			tail := rest#[1..]
			// zero directories consumed
			if glob_here(tail, s) {
				return true
			}
			for i in 0 .. s.len {
				if s[i] == `/` && glob_here(tail, s#[i + 1..]) {
					return true
				}
			}
			return false
		}
		for i in 0 .. s.len + 1 {
			if glob_here(rest, s#[i..]) {
				return true
			}
		}
		return false
	}
	if p[0] == `*` {
		rest := p#[1..]
		mut i := 0
		for {
			if glob_here(rest, s#[i..]) {
				return true
			}
			// A single star stops at a separator.
			if i >= s.len || s[i] == `/` {
				return false
			}
			i++
		}
		return false
	}
	if p[0] == `?` {
		if s.len == 0 || s[0] == `/` {
			return false
		}
		return glob_here(p#[1..], s#[1..])
	}
	if s.len == 0 || s[0] != p[0] {
		return false
	}
	return glob_here(p#[1..], s#[1..])
}
