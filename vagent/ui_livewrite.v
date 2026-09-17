module vagent

// ui_livewrite.v — pulling a growing string out of streaming JSON.
//
// A file change is shown happening line-by-line WHILE the model generates
// it — a true live write, not a replay after the tool ran. That means
// reading a JSON string field out of arguments that are still arriving, one
// chunk at a time, with no guarantee about where a chunk boundary falls: in
// the middle of a `é`, between a backslash and its escape, anywhere.
//
// The contract that makes this safe is that an incomplete escape is NOT
// consumed. The unescaper stops before it and reports how much it read, so
// the next chunk resumes exactly there. A half-decoded escape would print
// a literal backslash-u into the user's file preview and, worse, desync the
// cursor for everything after it.
//
// Robust by design: if the JSON is shaped unexpectedly, feed simply returns
// no lines and the caller falls back to the ordinary render. Nothing here
// can break a turn.

// LiveWrite incrementally extracts one JSON string field from a growing
// argument buffer. `key` selects the field: 'content' for write_file,
// 'new_string' for edit_file, 'patch' for apply_patch.
@[heap]
pub struct LiveWrite {
pub mut:
	key string = 'content'
	// accumulated argument JSON so far
	buf string
	// index into buf of the first content character, -1 until found
	content_start int = -1
	// content raw characters already consumed
	raw_pos int
	// unescaped text not yet emitted as whole lines
	pending string
	// full lines emitted so far
	lines int
	// the closing quote of the content was reached
	done bool
}

pub fn new_live_write(key string) &LiveWrite {
	return &LiveWrite{
		key: key
	}
}

// field_start is the offset just past `"<key>" :  "` in buf, or -1.
//
// The original used a regex; this is the same grammar spelled out, which
// avoids compiling a pattern per tracker and is exact about what it
// accepts: the quoted key, optional whitespace, a colon, optional
// whitespace, the opening quote.
fn field_start(buf string, key string) int {
	needle := '"${key}"'
	mut from := 0
	for {
		at := buf.index_after(needle, from) or { return -1 }
		mut i := at + needle.len
		for i < buf.len && (buf[i] == ` ` || buf[i] == `\t` || buf[i] == `\n`
			|| buf[i] == `\r`) {
			i++
		}
		if i < buf.len && buf[i] == `:` {
			i++
			for i < buf.len && (buf[i] == ` ` || buf[i] == `\t` || buf[i] == `\n`
				|| buf[i] == `\r`) {
				i++
			}
			if i < buf.len && buf[i] == `"` {
				return i + 1
			}
		}
		from = at + 1
	}
	return -1
}

// json_field returns a JSON string field's value only when it is COMPLETE
// — the closing quote has arrived. A value still streaming returns none,
// because a half-read path would name the wrong file in a header.
pub fn json_field(buf string, key string) ?string {
	start := field_start(buf, key)
	if start < 0 {
		return none
	}
	val, _, done := json_unescape(buf[start..])
	if !done {
		return none
	}
	return val
}

// path is the 'path' argument, once it has fully arrived.
pub fn (w &LiveWrite) path() ?string {
	return json_field(w.buf, 'path')
}

// feed takes a new argument chunk and returns the complete content lines
// that became available as a result.
pub fn (mut w LiveWrite) feed(chunk string) []string {
	w.buf += chunk
	if w.done {
		// the content is fully captured; the rest of the JSON is not ours
		return []
	}
	if w.content_start < 0 {
		start := field_start(w.buf, w.key)
		if start < 0 {
			return []
		}
		w.content_start = start
	}
	raw := w.buf[w.content_start..]
	if w.raw_pos > raw.len {
		return []
	}
	text, consumed, done := json_unescape(raw[w.raw_pos..])
	w.raw_pos += consumed
	w.done = done
	w.pending += text

	mut out := []string{}
	for {
		nl := w.pending.index('\n') or { break }
		out << w.pending[..nl]
		w.pending = w.pending[nl + 1..]
		w.lines++
	}
	return out
}

// flush returns the final partial line, if any, once generation ends.
pub fn (mut w LiveWrite) flush() ?string {
	if w.pending == '' {
		return none
	}
	line := w.pending
	w.pending = ''
	w.lines++
	return line
}

// json_unescape decodes a JSON string fragment. It returns the text, how
// many BYTES of the input were consumed, and whether the value's closing
// quote was reached.
//
// It stops before a trailing incomplete escape rather than guessing at it,
// so the caller can resume from `consumed` when the rest arrives.
pub fn json_unescape(s string) (string, int, bool) {
	mut out := []u8{cap: s.len}
	mut i := 0
	mut done := false
	for i < s.len {
		c := s[i]
		if c == `"` {
			done = true
			i++
			break
		}
		if c != `\\` {
			out << c
			i++
			continue
		}
		if i + 1 >= s.len {
			// a trailing backslash: wait for the next chunk
			break
		}
		e := s[i + 1]
		if e == `u` {
			if i + 6 > s.len {
				// an incomplete \uXXXX: wait for more
				break
			}
			hexs := s[i + 2..i + 6]
			code := hex_u16(hexs) or {
				// not a hex escape after all — pass it through verbatim,
				// exactly as the original did
				out << `\\`
				out << `u`
				out << hexs.bytes()
				i += 6
				continue
			}
			out << rune(code).bytes()
			i += 6
			continue
		}
		match e {
			`n` { out << `\n` }
			`t` { out << `\t` }
			`r` { out << `\r` }
			`b` { out << 0x08 }
			`f` { out << 0x0c }
			`"` { out << `"` }
			`\\` { out << `\\` }
			`/` { out << `/` }
			else {
				out << `\\`
				out << e
			}
		}
		i += 2
	}
	return out.bytestr(), i, done
}

fn hex_u16(s string) ?u16 {
	mut v := u32(0)
	for c in s {
		d := hex_digit(c) or { return none }
		v = v * 16 + u32(d)
	}
	return u16(v)
}
