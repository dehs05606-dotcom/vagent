module vagent

fn test_display_width_counts_columns_not_bytes() {
	assert display_width('hello') == 5
	// a multi-byte rune is still one column
	assert display_width('héllo') == 5
	assert display_width('→') == 1
	// CJK occupies two columns each
	assert display_width('日本語') == 6
	// a combining mark occupies none
	assert display_width('é') == 1
	// an escape sequence occupies none at all
	assert display_width('\x1b[31mred\x1b[0m') == 3
	assert display_width('') == 0
}

fn test_truncate_and_pad_respect_width() {
	assert truncate_width('hello world', 5, '…') == 'hell…'
	assert truncate_width('hello', 10, '…') == 'hello'
	// a wide rune is never split in half
	out := truncate_width('日本語です', 5, '…')
	assert display_width(out) <= 5, '${display_width(out)}'

	assert pad_width('ab', 5) == 'ab   '
	assert pad_width('abcdef', 3) == 'abcdef'
	assert display_width(pad_width('日本', 6)) == 6
}

fn test_wrap_breaks_on_spaces_then_hard() {
	lines := wrap_width('the quick brown fox jumps', 10)
	for l in lines {
		assert display_width(l) <= 10, '${l}'
	}
	assert lines.join(' ').contains('quick')

	// a word longer than the line is hard-broken rather than overflowing
	long := wrap_width('supercalifragilistic', 8)
	assert long.len > 1
	for l in long {
		assert display_width(l) <= 8
	}
}

fn test_style_renders_truecolor() {
	s := Style{
		fg:   '#ff5555'
		bold: true
	}
	out := s.ansi()
	assert out.contains('38;2;255;85;85')
	assert out.contains('1')
	assert Style{}.is_plain()
	assert !s.is_plain()

	// a malformed colour emits nothing rather than a corrupt sequence
	bad := Style{
		fg: '#zzz'
	}
	assert bad.ansi() == ''
}

fn test_render_spans_resets_after_every_run() {
	spans := [bold_fg('A', c_red), plain('B')]
	coloured := render_spans(spans, true)
	assert coloured.contains(ansi_reset)
	assert coloured.ends_with('B'), coloured
	// with colour off, the text is exactly the text
	assert render_spans(spans, false) == 'AB'
	assert spans_text(spans) == 'AB'
	assert spans_width(spans) == 2
}

// -- key decoding ------------------------------------------------------------

fn decode_all(bytes string) []Key {
	mut d := KeyDecoder{}
	d.feed(bytes.bytes())
	mut out := []Key{}
	for {
		k := d.next(true) or { break }
		out << k
	}
	return out
}

fn test_plain_characters_and_control_keys() {
	keys := decode_all('ab')
	assert keys.len == 2
	assert keys[0].kind == .char_ && keys[0].ch == `a`

	assert decode_all('\r')[0].kind == .enter
	assert decode_all('\n')[0].kind == .enter
	assert decode_all('\t')[0].kind == .tab
	assert decode_all('\x7f')[0].kind == .backspace

	ctrl_c := decode_all('\x03')[0]
	assert ctrl_c.kind == .ctrl
	assert ctrl_c.is_ctrl(`c`)
	assert decode_all('\x04')[0].is_ctrl(`d`)
	assert decode_all('\x14')[0].is_ctrl(`t`)
}

fn test_arrow_and_navigation_sequences() {
	assert decode_all('\x1b[A')[0].kind == .up
	assert decode_all('\x1b[B')[0].kind == .down
	assert decode_all('\x1b[C')[0].kind == .right
	assert decode_all('\x1b[D')[0].kind == .left
	assert decode_all('\x1b[H')[0].kind == .home
	assert decode_all('\x1b[F')[0].kind == .end
	assert decode_all('\x1b[5~')[0].kind == .page_up
	assert decode_all('\x1b[6~')[0].kind == .page_down
	assert decode_all('\x1b[3~')[0].kind == .delete
	assert decode_all('\x1b[Z')[0].kind == .back_tab
	// the SS3 spelling some terminals use for the arrows
	assert decode_all('\x1bOA')[0].kind == .up
	// a modified arrow still reports the base key
	assert decode_all('\x1b[1;5C')[0].kind == .right
}

fn test_a_bare_escape_waits_before_it_is_believed() {
	mut d := KeyDecoder{}
	d.feed('\x1b'.bytes())
	// without a flush the decoder says "not yet" — the rest of a real
	// sequence may still be in flight
	assert d.next(false) == none
	assert d.pending
	// with a flush it is a genuine Escape
	k := d.next(true) or { panic('escape never decoded') }
	assert k.kind == .escape

	// and a sequence split across two reads still decodes as one key
	mut d2 := KeyDecoder{}
	d2.feed('\x1b['.bytes())
	assert d2.next(false) == none
	d2.feed('A'.bytes())
	k2 := d2.next(false) or { panic('split sequence lost') }
	assert k2.kind == .up
}

fn test_alt_combinations() {
	k := decode_all('\x1bx')[0]
	assert k.kind == .alt
	assert k.ch == `x`
	// Escape followed by Enter is the newline binding's first half
	esc_enter := decode_all('\x1b\r')[0]
	assert esc_enter.kind == .alt
}

fn test_utf8_characters_decode_whole() {
	k := decode_all('é')[0]
	assert k.kind == .char_
	assert k.ch == `é`

	emoji := decode_all('🎯')[0]
	assert emoji.kind == .char_
	assert emoji.ch == `🎯`

	// a character split across reads is held until it is complete
	mut d := KeyDecoder{}
	bytes := 'é'.bytes()
	d.feed([bytes[0]])
	assert d.next(false) == none
	assert d.pending
	d.feed([bytes[1]])
	k2 := d.next(false) or { panic('split rune lost') }
	assert k2.ch == `é`
}
