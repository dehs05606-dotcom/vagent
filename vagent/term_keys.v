module vagent

// term_keys.v — turning a byte stream into keypresses.
//
// In raw mode a terminal delivers escape sequences, not key names: Up is
// ESC [ A, Home is ESC [ H or ESC [ 1 ~ depending on the emulator, Alt+x is
// ESC x, and a UTF-8 character arrives as two to four bytes. This decoder
// turns all of it into one Key at a time.
//
// The load-bearing case is a BARE Escape, which is also the first byte of
// every sequence above and the first key of the Escape+Enter newline
// binding. The decoder cannot know which was meant from the bytes alone, so
// it reports `pending` when a lone ESC ends the buffer and lets the caller
// decide after a short wait — the Python original set prompt_toolkit's
// timeout to 0.08s for exactly this reason, because a full second of "Esc
// does nothing" reads as broken rather than slow.

pub enum KeyKind {
	char_
	enter
	tab
	back_tab
	backspace
	delete
	up
	down
	left
	right
	home
	end
	page_up
	page_down
	escape
	ctrl
	alt
	unknown
}

pub struct Key {
pub:
	kind KeyKind
	// the rune for .char_, or the control letter for .ctrl ('c' for Ctrl+C)
	ch rune
	// the raw bytes this key was decoded from, for diagnostics
	raw string
}

pub fn (k &Key) is_ctrl(letter rune) bool {
	return k.kind == .ctrl && k.ch == letter
}

// KeyDecoder holds bytes that did not yet form a complete key.
@[heap]
pub struct KeyDecoder {
pub mut:
	buf []u8
	// true when the buffer ends in an incomplete sequence — the caller
	// should read again briefly before treating a lone ESC as Escape
	pending bool
}

pub fn (mut d KeyDecoder) feed(bytes []u8) {
	d.buf << bytes
}

// next decodes one key, or returns none when the buffer holds nothing
// complete. `flush` forces a decision: a trailing lone ESC becomes Escape
// rather than waiting for a sequence that is not coming.
pub fn (mut d KeyDecoder) next(flush bool) ?Key {
	d.pending = false
	if d.buf.len == 0 {
		return none
	}
	b := d.buf[0]

	// -- escape sequences ---------------------------------------------------
	if b == 0x1b {
		if d.buf.len == 1 {
			if !flush {
				d.pending = true
				return none
			}
			d.buf = []
			return Key{
				kind: .escape
				raw:  '\x1b'
			}
		}
		if d.buf[1] == `[` || d.buf[1] == `O` {
			if key := d.decode_csi() {
				return key
			}
			if !flush {
				d.pending = true
				return none
			}
			// a sequence that never completed — drop the ESC and re-read
			d.buf.delete(0)
			return Key{
				kind: .escape
				raw:  '\x1b'
			}
		}
		// ESC followed by a plain character is Alt+<char>
		rest := d.buf[1..].clone()
		mut sub := KeyDecoder{
			buf: rest
		}
		inner := sub.next(true) or {
			d.buf = []
			return Key{
				kind: .escape
				raw:  '\x1b'
			}
		}
		d.buf = sub.buf.clone()
		return Key{
			kind: .alt
			ch:   inner.ch
			raw:  '\x1b' + inner.raw
		}
	}

	// -- control characters -------------------------------------------------
	d.buf.delete(0)
	match b {
		`\r`, `\n` {
			return Key{
				kind: .enter
				raw:  b.ascii_str()
			}
		}
		`\t` {
			return Key{
				kind: .tab
				raw:  '\t'
			}
		}
		0x7f, 0x08 {
			return Key{
				kind: .backspace
				raw:  b.ascii_str()
			}
		}
		else {}
	}
	if b < 0x20 {
		// Ctrl+A is 0x01 … Ctrl+Z is 0x1a
		return Key{
			kind: .ctrl
			ch:   rune(b + 96)
			raw:  b.ascii_str()
		}
	}

	// -- a UTF-8 character --------------------------------------------------
	mut extra := 0
	if b & 0xE0 == 0xC0 {
		extra = 1
	} else if b & 0xF0 == 0xE0 {
		extra = 2
	} else if b & 0xF8 == 0xF0 {
		extra = 3
	}
	if extra == 0 {
		return Key{
			kind: .char_
			ch:   rune(b)
			raw:  b.ascii_str()
		}
	}
	if d.buf.len < extra {
		// an incomplete character — put the lead byte back and wait
		d.buf.prepend(b)
		if !flush {
			d.pending = true
			return none
		}
		d.buf = []
		return none
	}
	mut bytes := [b]
	for _ in 0 .. extra {
		bytes << d.buf[0]
		d.buf.delete(0)
	}
	text := bytes.bytestr()
	runes := text.runes()
	return Key{
		kind: .char_
		ch:   if runes.len > 0 { runes[0] } else { rune(b) }
		raw:  text
	}
}

// decode_csi reads a CSI/SS3 sequence from the front of the buffer.
fn (mut d KeyDecoder) decode_csi() ?Key {
	// ESC [ <params> <final>   or   ESC O <final>
	mut i := 2
	mut params := ''
	for i < d.buf.len {
		c := d.buf[i]
		if (c >= `0` && c <= `9`) || c == `;` || c == `?` {
			params += c.ascii_str()
			i++
			continue
		}
		break
	}
	if i >= d.buf.len {
		return none // the sequence is still arriving
	}
	final := d.buf[i]
	raw := d.buf[..i + 1].bytestr()
	// modifier params ("1;5C" = Ctrl+Right) are parsed but not distinguished
	// beyond the base key, which is all the bindings need
	base_params := params.all_before(';')

	kind := match final {
		`A` { KeyKind.up }
		`B` { KeyKind.down }
		`C` { KeyKind.right }
		`D` { KeyKind.left }
		`H` { KeyKind.home }
		`F` { KeyKind.end }
		`Z` { KeyKind.back_tab }
		`~` {
			match base_params {
				'1', '7' { KeyKind.home }
				'2' { KeyKind.unknown } // Insert
				'3' { KeyKind.delete }
				'4', '8' { KeyKind.end }
				'5' { KeyKind.page_up }
				'6' { KeyKind.page_down }
				else { KeyKind.unknown }
			}
		}
		else { KeyKind.unknown }
	}
	d.buf = d.buf[i + 1..].clone()
	return Key{
		kind: kind
		raw:  raw
	}
}
