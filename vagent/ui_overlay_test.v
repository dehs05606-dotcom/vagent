module vagent

fn items_of(n int) []OverlayItem {
	mut out := []OverlayItem{}
	for i in 0 .. n {
		out << OverlayItem{
			text: 'item ${i}'
			meta: 'm${i}'
		}
	}
	return out
}

fn test_the_selection_wraps_at_both_ends() {
	mut o := new_overlay('PICK', items_of(3), 0, 'model', '')
	o.move(-1)
	assert o.index == 2
	assert o.selected_meta() == 'm2'
	o.move(1)
	assert o.index == 0

	// a page step is five items, and it wraps too
	mut p := new_overlay('PICK', items_of(12), 0, 'model', '')
	p.page(1)
	assert p.index == 5
	p.page(-1)
	assert p.index == 0
	p.page(-1)
	assert p.index == 7
}

fn test_an_empty_list_never_divides_by_zero() {
	mut o := new_overlay('EMPTY', []OverlayItem{}, 0, 'history', '')
	o.move(1)
	o.page(-1)
	o.go_last()
	assert o.index == 0
	assert o.selected_meta() == ''
	// and it still draws: a border and a footer, no rows between them
	rows := o.rows(60)
	assert rows.len == 2
}

fn test_the_window_scrolls_to_follow_the_selection() {
	mut o := new_overlay('PICK', items_of(30), 0, 'model', '')
	assert o.top == 0
	// walking past the tenth item pushes the window down by one
	for _ in 0 .. overlay_window {
		o.move(1)
	}
	assert o.index == overlay_window
	assert o.top == 1

	// walking back above the window pulls it up again
	o.move(-overlay_window)
	assert o.index == 0
	assert o.top == 0

	// the window never shows more than WINDOW rows
	o.go_last()
	assert o.index == 29
	assert o.top == 30 - overlay_window
	assert o.rows(60).len == overlay_window + 2
}

fn test_a_preselected_item_opens_centred() {
	o := new_overlay('PICK', items_of(30), 20, 'model', '')
	assert o.index == 20
	assert o.top == 20 - overlay_window / 2
	// and an index past the end is clamped rather than crashing
	c := new_overlay('PICK', items_of(3), 99, 'model', '')
	assert c.index == 2
}

fn test_every_rendered_row_is_exactly_as_wide_as_the_border() {
	o := new_overlay('SELECT MODEL', items_of(4), 1, 'model', '')
	rows := o.rows(64)
	widths := rows.map(spans_width(it))
	for w in widths {
		assert w == widths[0], '${widths}'
	}
	assert widths[0] == 64

	// a narrow terminal still gets the 30-column minimum the original set
	narrow := o.rows(12)
	assert spans_width(narrow[0]) == 32
}

fn test_the_selected_row_is_marked_and_the_rest_are_not() {
	o := new_overlay('PICK', items_of(3), 1, 'model', '')
	rows := o.rows(50)
	assert spans_text(rows[1]).starts_with('║  item 0')
	assert spans_text(rows[2]).starts_with('║▶ item 1')
	assert spans_text(rows[3]).starts_with('║  item 2')
}

fn test_an_over_long_item_is_clipped_not_wrapped() {
	long := [OverlayItem{
		text: 'x'.repeat(200)
		meta: ''
	}]
	o := new_overlay('PICK', long, 0, 'help', '')
	rows := o.rows(40)
	assert spans_width(rows[1]) == 40
	assert spans_text(rows[1]).contains('…')
}

fn test_the_footer_defaults_to_the_key_legend() {
	o := new_overlay('PICK', items_of(1), 0, 'model', '')
	foot := spans_text(o.rows(80).last())
	assert foot.contains('↑↓ PgUp PgDn Tab move · Enter select · Esc close')
	assert foot.starts_with('╚')
	assert foot.ends_with('╝')

	// an explicit footer replaces it, and a footer wider than the box is cut
	e := new_overlay('HELP', items_of(1), 0, 'help', 'Esc close')
	assert spans_text(e.rows(80).last()).contains('Esc close')
	w := new_overlay('HELP', items_of(1), 0, 'help', 'z'.repeat(300))
	assert spans_width(w.rows(40).last()) == 40
}

fn test_mod_floor_matches_pythons_modulo() {
	assert mod_floor(-1, 3) == 2
	assert mod_floor(-3, 3) == 0
	assert mod_floor(-4, 3) == 2
	assert mod_floor(7, 3) == 1
	assert mod_floor(5, 0) == 0
}
