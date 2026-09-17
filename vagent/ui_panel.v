module vagent

// ui_panel.v — rich's Panel, and the banner that opens a session.
//
// rich draws a Panel as a rounded box whose title is centred INSIDE the top
// border and whose subtitle is centred inside the bottom one, with the body
// padded one column on each side. That layout is reproduced here exactly,
// including the two edge cases rich handles quietly:
//
//   * a box four columns or narrower has no room for a title, so the border
//     is drawn plain rather than with a title that would overflow it;
//   * the centring split is floor-halved — the extra fill column goes to the
//     RIGHT, which is what makes two stacked panels line up.

// panel_rows draws `body` inside a rounded box exactly `width` columns wide.
pub fn panel_rows(body [][]Span, width int, border Style, title []Span, subtitle []Span) [][]Span {
	w := max_int(4, width)
	content := max_int(1, w - 4)
	mut out := [][]Span{}
	out << border_row('╭', '╮', title, w, border)
	for line in body {
		// rich wraps a body line that outgrows the panel rather than letting
		// it push through the right border, and so does this
		wrapped := if spans_width(line) > content {
			wrap_spans(line, content)
		} else {
			[line]
		}
		for part in wrapped {
			mut row := [span('│ ', border)]
			row << part
			pad := content - spans_width(part)
			if pad > 0 {
				row << plain(' '.repeat(pad))
			}
			row << span(' │', border)
			out << row
		}
	}
	out << border_row('╰', '╯', subtitle, w, border)
	return out
}

// border_row is `╭─ title ──────╮`: the label centred in the fill.
fn border_row(left string, right string, label []Span, width int, border Style) []Span {
	if label.len == 0 || width <= 4 {
		return [span(left + '─'.repeat(width - 2) + right, border)]
	}
	// rich pads the label with one space on each side before centring it
	mut padded := [plain(' ')]
	padded << label
	padded << plain(' ')
	inner := width - 4
	excess := inner - spans_width(padded)
	if excess < 0 {
		// no room: fall back to the plain border rather than overflow the box
		return [span(left + '─'.repeat(width - 2) + right, border)]
	}
	lpad := excess / 2
	mut row := [span(left + '─' + '─'.repeat(lpad), border)]
	row << padded
	row << span('─'.repeat(excess - lpad) + '─' + right, border)
	return row
}

// ---------------------------------------------------------------------------
// The banner
// ---------------------------------------------------------------------------

// banner_ascii is the six-line block logo, verbatim from the original. It is
// 72 columns wide, which is why the fallback below exists.
pub const banner_ascii = [
	'███████╗██╗   ██╗██╗    ██╗    █████╗  ██████╗ ███████╗███╗ ██╗████████╗',
	'██╔════╝██║   ██║██║    ██║   ██╔══██╗██╔════╝ ██╔════╝████╗██║╚══██╔══╝',
	'█████╗  ██║   ██║██║    ██║   ███████║██║  ███╗█████╗  ██╔██╗██║  ██║   ',
	'██╔══╝  ██║   ██║██║    ██║   ██╔══██║██║   ██║██╔══╝  ██║╚██╗██║  ██║   ',
	'██║     ╚██████╔╝██████╗█████╗██║  ██║╚██████╔╝███████╗██║ ╚████║  ██║   ',
	'╚═╝      ╚═════╝ ╚═════╝╚════╝╚═╝  ╚═╝ ╚═════╝ ╚══════╝╚═╝  ╚═══╝  ╚═╝   ',
]

// banner_colours is the gradient walked down the block, one colour per line.
pub const banner_colours = [c_accent, c_accent, c_pink, c_cyan, c_cyan, c_pink]

// The three prose lines are consts rather than literals at their use sites.
// That is not a style choice: V 0.5.2 miscompiles one of them when it is
// written inline inside the nested array literal below — the generated C
// string comes out a byte short (`40+Commands`). Naming them makes the
// codegen emit them verbatim, and banner_says_exactly_what_it_should in the
// tests pins the text so a regression cannot pass silently.
pub const banner_stripe = '  ⚡ 40+ Commands · 16 Tools · 5 Providers · Real-time Web · Self-Healing'
pub const banner_tagline = '  ·  Event-Sourced Kernel  ·  Goal Contracts  ·  Crew'
pub const banner_compact_tagline = '  ·  advanced terminal AI agent'
pub const banner_compact_stripe = 'event-sourced kernel · goal contracts · persistent crew · self-healing'

// banner_rows renders the opening panel.
//
// `term_width` is the real terminal width; the panel is capped at 84 columns
// and at two columns narrower than the terminal, exactly as the original
// computed it. Below 78 columns the block logo cannot fit, so the compact
// one-line logo is used instead — a wrapped ASCII banner looks broken, and
// the original would rather print less than print it wrapped.
pub fn banner_rows(term_width int, session_id string) [][]Span {
	width := min_int(term_width - 2, 84)
	border := Style{
		fg: c_border
	}
	mut body := [][]Span{}

	mut max_ascii := 0
	for line in banner_ascii {
		w := display_width(line)
		if w > max_ascii {
			max_ascii = w
		}
	}
	need := max_ascii + 6

	if width >= max_int(78, need) {
		for i, line in banner_ascii {
			body << [
				span(line.trim_right(' '), Style{
					fg:   banner_colours[i % banner_colours.len]
					bold: true
				}),
			]
		}
		body << [
			span('  ◆ ${app_name} ', Style{
				fg:   c_accent
				bold: true
			}),
			span('v${version}', Style{
				fg:   c_pink
				bold: true
			}),
			span(banner_tagline, Style{ fg: c_dim }),
		]
		body << [span(banner_stripe, Style{ fg: c_dim })]
		return panel_rows(body, width, border, [
			span(app_name, Style{
				fg:   c_accent
				bold: true
			}),
		], [
			span('session ${session_id}', Style{ fg: c_dim }),
		])
	}

	body << [
		span('◆ ', Style{
			fg:   c_accent
			bold: true
		}),
		span(app_name, Style{
			fg:   c_accent
			bold: true
		}),
		span(' v${version}', Style{
			fg:   c_pink
			bold: true
		}),
		span(banner_compact_tagline, Style{ fg: c_dim }),
	]
	body << [span(banner_compact_stripe, Style{ fg: c_dim })]
	return panel_rows(body, width, border, []Span{}, []Span{})
}

// banner_status is the line printed under the panel: what the session is
// configured to do, at a glance.
pub fn banner_status(model &Model, effort &Effort, autonomy int, session_id string) []Span {
	mut row := [
		span(' ❯ model  ', Style{ fg: c_dim }),
		span(model.label, Style{
			fg:   c_cyan
			bold: true
		}),
	]
	if model.tag != '' {
		row << span(' ${model.tag} ', Style{
			fg:   c_green
			bold: true
		})
	}
	row << span('   effort  ', Style{ fg: c_dim })
	row << span(effort.label.to_lower(), Style{
		fg:   effort.color
		bold: true
	})
	row << span('   autonomy  ', Style{ fg: c_dim })
	row << span('L${autonomy}', Style{
		fg:   c_yellow
		bold: true
	})
	row << span('   session  ', Style{ fg: c_dim })
	row << span(session_id, Style{ fg: c_fg })
	return row
}

// banner_hints is the third line of the opening: the four things worth
// knowing before you type anything.
pub fn banner_hints() []Span {
	return [
		span('   ', Style{ fg: c_dim }),
		span('/', Style{
			fg:   c_green
			bold: true
		}),
		span(' commands · ', Style{ fg: c_dim }),
		span('Ctrl+T', Style{
			fg:   c_cyan
			bold: true
		}),
		span(' models · ', Style{ fg: c_dim }),
		span('Ctrl+E', Style{
			fg:   c_cyan
			bold: true
		}),
		span(' effort · ', Style{ fg: c_dim }),
		span('/crew', Style{
			fg:   c_pink
			bold: true
		}),
		span(' background subagents', Style{ fg: c_dim }),
	]
}
