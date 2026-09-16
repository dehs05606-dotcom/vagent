module vagent

// ui_overlay.v — the modal picker that opens directly above the prompt box.
//
// /model, /effort, /help and /history all use it. The Python original built
// it out of prompt_toolkit HTML fragments, but note what that code actually
// did with them: `fragment_list_to_text(to_formatted_text(HTML(html)))`
// flattens the markup to PLAIN TEXT and then paints the whole row with one
// class. The per-item colours in the HTML never reached the screen. So an
// item here is plain text plus its meta value, which is both simpler and
// exactly what the original displayed.
//
// One deliberate departure: the original held an `on_select` callback. V
// closures stored in struct fields and later invoked through a reference
// miscompile, so the overlay carries a `kind` instead and the UI matches on
// it. The behaviour is the same and the crash is not.

pub const overlay_page = 5
pub const overlay_window = 10

pub struct OverlayItem {
pub:
	text string
	meta string
}

@[heap]
pub struct OverlayList {
pub mut:
	title string
	items []OverlayItem
	index int
	// what the selection means: 'model' | 'effort' | 'help' | 'history'
	kind    string
	footer  string
	visible bool
	// first item currently on screen
	top int
}

pub fn new_overlay(title string, items []OverlayItem, selected_index int, kind string, footer string) &OverlayList {
	mut idx := selected_index
	if idx < 0 {
		idx = 0
	}
	if idx > items.len - 1 {
		idx = items.len - 1
	}
	if idx < 0 {
		idx = 0
	}
	mut top := idx - overlay_window / 2
	if top < 0 {
		top = 0
	}
	return &OverlayList{
		title:  title
		items:  items
		index:  idx
		kind:   kind
		footer: footer
		top:    top
	}
}

pub fn (mut o OverlayList) open() {
	o.visible = true
}

pub fn (mut o OverlayList) close() {
	o.visible = false
}

// move walks the selection, wrapping at both ends, and scrolls the window
// to keep the selection inside it.
//
// An empty list is a no-op: the original guarded this explicitly because the
// modulo below is a division by zero, and a /history with no turns must not
// take the session down.
pub fn (mut o OverlayList) move(delta int) {
	if o.items.len == 0 {
		return
	}
	o.index = mod_floor(o.index + delta, o.items.len)
	if o.index < o.top {
		o.top = o.index
	} else if o.index >= o.top + overlay_window {
		o.top = o.index - overlay_window + 1
	}
}

pub fn (mut o OverlayList) page(delta int) {
	o.move(delta * overlay_page)
}

pub fn (mut o OverlayList) go_first() {
	o.index = 0
	o.top = 0
}

pub fn (mut o OverlayList) go_last() {
	if o.items.len == 0 {
		return
	}
	o.index = o.items.len - 1
	o.top = max_int(0, o.index - overlay_window + 1)
}

// selected_meta is the value the selection stands for — a model id, an
// effort key — or '' for a list that is only there to be read.
pub fn (o &OverlayList) selected_meta() string {
	if o.index < 0 || o.index >= o.items.len {
		return ''
	}
	return o.items[o.index].meta
}

// mod_floor is Python's `%`: the result carries the divisor's sign, so
// walking up from the first item lands on the last one rather than on a
// negative index.
pub fn mod_floor(a int, n int) int {
	if n == 0 {
		return 0
	}
	m := a % n
	return if m < 0 { m + n } else { m }
}

// rows renders the overlay as styled lines, borders included.
pub fn (o &OverlayList) rows(width int) [][]Span {
	inner := max_int(30, width - 2)
	border := Style{
		fg: c_accent
	}
	mut out := [][]Span{}

	title := ' ${o.title} '
	title_w := display_width(title)
	out << [span('╔' + title + '═'.repeat(max_int(0, inner - title_w)) + '╗', border)]

	last := min_int(o.top + overlay_window, o.items.len)
	for i := o.top; i < last; i++ {
		selected := i == o.index
		marker := if selected { '▶ ' } else { '  ' }
		mut line := marker + o.items[i].text
		if display_width(line) > inner - 2 {
			line = truncate_width(line, inner - 2, '…')
		}
		style := if selected {
			Style{
				fg:   c_fg
				bg:   c_selection_bg
				bold: true
			}
		} else {
			Style{
				fg: c_fg
			}
		}
		pad := max_int(0, inner - display_width(line))
		out << [
			span('║', border),
			span(line + ' '.repeat(pad), style),
			span('║', border),
		]
	}

	mut foot := if o.footer != '' {
		o.footer
	} else {
		'↑↓ PgUp PgDn Tab move · Enter select · Esc close'
	}
	if display_width(foot) > inner {
		foot = truncate_width(foot, inner, '')
	}
	out << [
		span('╚', border),
		span(foot, Style{ fg: c_dim }),
		span('═'.repeat(max_int(0, inner - display_width(foot))) + '╝', border),
	]
	return out
}
