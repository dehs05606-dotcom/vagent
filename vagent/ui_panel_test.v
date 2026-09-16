module vagent

fn test_a_plain_panel_is_a_rounded_box_of_the_asked_width() {
	rows := panel_rows([[plain('hi')]], 20, Style{ fg: c_border }, []Span{}, []Span{})
	texts := rows.map(spans_text(it))
	assert texts[0] == '╭──────────────────╮'
	assert texts[1] == '│ hi               │'
	assert texts[2] == '╰──────────────────╯'
	for row in rows {
		assert spans_width(row) == 20
	}
}

fn test_a_title_sits_centred_in_the_border() {
	rows := panel_rows([[plain('x')]], 20, Style{ fg: c_border }, [plain('AB')], [plain('cd')])
	top := spans_text(rows[0])
	bot := spans_text(rows.last())
	assert top == '╭─────── AB ───────╮', top
	assert bot == '╰─────── cd ───────╯', bot
	assert spans_width(rows[0]) == 20
	assert spans_width(rows.last()) == 20
}

fn test_a_title_with_no_room_falls_back_to_a_plain_border() {
	// four columns or fewer: rich draws no title at all
	tiny := panel_rows([], 4, Style{}, [plain('nope')], []Span{})
	assert spans_text(tiny[0]) == '╭──╮'

	// wider, but still narrower than the title needs
	cramped := panel_rows([], 10, Style{}, [plain('a-very-long-title')], []Span{})
	assert spans_text(cramped[0]) == '╭────────╮'
	assert spans_width(cramped[0]) == 10
}

fn test_panel_body_lines_are_padded_and_over_wide_ones_wrap() {
	// content room is width-4 = 4
	rows := panel_rows([[plain('1234 5678')]], 8, Style{}, []Span{}, []Span{})
	assert rows.len == 4
	assert spans_text(rows[1]) == '│ 1234 │'
	assert spans_text(rows[2]) == '│ 5678 │'

	// a short line is padded out to the border
	short := panel_rows([[plain('1')]], 8, Style{}, []Span{}, []Span{})
	assert spans_text(short[1]) == '│ 1    │'
}

fn test_the_banner_says_exactly_what_it_should() {
	// V 0.5.2 silently drops a byte from banner_stripe when it is written
	// inline rather than named; this is the guard on that
	assert banner_stripe == '  ⚡ 40+ Commands · 16 Tools · 5 Providers · Real-time Web · Self-Healing'
	assert banner_tagline == '  ·  Event-Sourced Kernel  ·  Goal Contracts  ·  Crew'
	assert banner_compact_tagline == '  ·  advanced terminal AI agent'
	assert banner_compact_stripe == 'event-sourced kernel · goal contracts · persistent crew · self-healing'

	joined := banner_rows(100, 's').map(spans_text(it)).join('\n')
	assert joined.contains(banner_stripe), joined
	assert joined.contains(banner_tagline), joined
}

fn test_the_wide_banner_draws_the_block_logo() {
	rows := banner_rows(100, 'abc123')
	texts := rows.map(spans_text(it))
	// capped at 84 columns
	assert spans_width(rows[0]) == 84
	assert texts[0].contains('FullAgent')
	assert texts[1].contains('███████╗')
	assert texts.any(it.contains('v${version}'))
	assert texts.any(it.contains('40+ Commands'))
	assert texts.last().contains('session abc123')
	for row in rows {
		assert spans_width(row) == 84, spans_text(row)
	}
}

fn test_the_narrow_banner_falls_back_to_the_one_line_logo() {
	rows := banner_rows(70, 'abc123')
	texts := rows.map(spans_text(it))
	assert !texts.any(it.contains('███████╗'))
	assert texts[1].contains('◆ FullAgent v${version}')
	assert texts[2].contains('event-sourced kernel')
	for row in rows {
		assert spans_width(row) == 68, spans_text(row)
	}
}

fn test_the_banner_never_overflows_a_tiny_terminal() {
	for w in [20, 40, 60, 78, 79, 80, 120] {
		rows := banner_rows(w, 's')
		cap := min_int(w - 2, 84)
		for row in rows {
			assert spans_width(row) == max_int(4, cap), '${w}: ${spans_text(row)}'
		}
	}
}

fn test_the_status_line_names_the_whole_configuration() {
	m := models[0]
	e := efforts[0]
	text := spans_text(banner_status(&m, &e, 3, 'sess-1'))
	assert text.contains('❯ model  ${m.label}')
	assert text.contains('effort  ${e.label.to_lower()}')
	assert text.contains('autonomy  L3')
	assert text.contains('session  sess-1')
	if m.tag != '' {
		assert text.contains(' ${m.tag} ')
	}
}
