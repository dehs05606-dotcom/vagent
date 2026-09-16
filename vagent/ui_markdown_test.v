module vagent

fn md_text(src string, width int) string {
	return render_markdown(src, width).map(spans_text(it)).join('\n')
}

fn inline_text(src string) string {
	return spans_text(md_inline(src))
}

fn test_inline_markers_are_consumed_not_printed() {
	assert inline_text('a **bold** b') == 'a bold b'
	assert inline_text('a *em* b') == 'a em b'
	assert inline_text('a `code` b') == 'a code b'
	assert inline_text('a ~~gone~~ b') == 'a gone b'
	assert inline_text('an \\*escaped\\* star') == 'an *escaped* star'
}

fn test_bold_and_italic_carry_their_attributes() {
	b := md_inline('x **y** z')
	assert b.len == 3
	assert b[1].text == 'y' && b[1].style.bold
	assert !b[0].style.bold

	i := md_inline('x _y_ z')
	assert i[1].text == 'y' && i[1].style.italic

	// nested markup keeps both
	n := md_inline('**bold `code`**')
	assert n.len == 2
	assert n[0].text == 'bold ' && n[0].style.bold
	assert n[1].text == 'code' && n[1].style.bold && n[1].style.fg == c_cyan
}

fn test_an_underscore_inside_a_word_is_not_emphasis() {
	// this is the rule that keeps identifiers readable
	assert inline_text('call some_function_name(x)') == 'call some_function_name(x)'
	spans := md_inline('call some_function_name(x)')
	for sp in spans {
		assert !sp.style.italic
	}
	// but a real emphasis still works next to punctuation
	e := md_inline('(_yes_)')
	assert spans_text(e) == '(yes)'
	assert e[1].style.italic
}

fn test_code_spans_take_the_longest_fence() {
	c := md_inline('``a ` b``')
	assert c[0].text == 'a ` b'
	assert c[0].style.fg == c_cyan && c[0].style.bold

	// an unclosed backtick is literal text, not a swallowed rest-of-line
	assert inline_text('cost is 3 ` dollars') == 'cost is 3 ` dollars'
}

fn test_links_show_their_target_once() {
	l := md_inline('see [docs](http://x/y) now')
	assert spans_text(l) == 'see docs (http://x/y) now'
	assert l[1].style.underline && l[1].style.fg == c_cyan

	// an autolink whose label is the url does not repeat it
	assert inline_text('[http://x](http://x)') == 'http://x'
}

fn test_headings_render_as_the_diamond_rule() {
	rows := render_markdown('# Title\n\nbody', 40)
	assert spans_text(rows[0]) == '◆ Title'
	assert rows[0][0].style.bold && rows[0][0].style.fg == c_accent
	assert spans_text(rows[1]) == ''
	assert spans_text(rows[2]) == 'body'

	// every level is the same diamond, and closing hashes are dropped
	assert md_text('###### deep ###', 40) == '◆ deep'
	// a hash with no space is not a heading
	assert md_text('#nothashtag', 40) == '#nothashtag'
	// setext underlining counts too
	assert md_text('Title\n=====', 40) == '◆ Title'
}

fn test_paragraphs_wrap_and_blocks_are_separated_by_one_blank_line() {
	out := md_text('one two three four five six seven', 12)
	assert out == 'one two\nthree four\nfive six\nseven', out

	two := md_text('first para\n\nsecond para', 40)
	assert two == 'first para\n\nsecond para'

	// several blank lines still separate by exactly one
	many := md_text('a\n\n\n\n\nb', 40)
	assert many == 'a\n\nb'
}

fn test_a_fence_renders_padded_and_is_followed_by_a_blank_line() {
	rows := render_markdown('```python\nx = 1\n```\nafter', 40)
	texts := rows.map(spans_text(it))
	assert texts[0] == ' x = 1'
	assert texts[1] == ''
	assert texts[2] == 'after'

	// the fence body is taken literally — markdown inside it is not markup
	lit := md_text('```\n**not bold**\n```', 40)
	assert lit.contains('**not bold**')

	// an unterminated fence still ends the document cleanly
	open_fence := md_text('```\nstuck', 40)
	assert open_fence.trim_space() == 'stuck'
}

fn test_code_highlighting_only_paints_what_it_is_sure_of() {
	spans := highlight_code('if x == "hi":  # note', 'python')
	mut got := map[string]string{}
	for sp in spans {
		got[sp.text.trim_space()] = sp.style.fg
	}
	assert got['if'] == c_pink
	assert got['"hi"'] == c_yellow
	assert got['# note'] == c_dim
	assert got['x'] == c_fg

	nums := highlight_code('n = 42', '')
	assert nums.any(it.text == '42' && it.style.fg == c_orange)
	// an identifier that merely starts with a digit is not a number
	assert !highlight_code('3dmodel = 1', '').any(it.text == '3dmodel'
		&& it.style.fg == c_orange)
}

fn test_lists_get_bullets_and_hanging_indents() {
	out := md_text('- alpha\n- beta', 40)
	assert out == '• alpha\n• beta', out

	// ordered lists keep their own numbers
	assert md_text('1. one\n2. two', 40) == '1. one\n2. two'

	// a wrapped item lines up under its text, not under its bullet
	wrapped := md_text('- alpha beta gamma delta', 14)
	assert wrapped == '• alpha beta\n  gamma delta', wrapped

	// a nested item is indented
	nested := md_text('- top\n  - under', 40)
	assert nested == '• top\n  • under', nested

	// a continuation line folds into the item above
	folded := md_text('- alpha\n  still alpha', 40)
	assert folded == '• alpha still alpha', folded
}

fn test_block_quotes_get_a_bar_and_render_their_contents() {
	out := md_text('> quoted **text**', 40)
	assert out == '▌ quoted text', out
	rows := render_markdown('> quoted', 40)
	assert rows[0][0].style.fg == c_border
	assert rows[0][1].style.fg == c_dim
}

fn test_a_thematic_break_spans_the_width() {
	rows := render_markdown('a\n\n---\n\nb', 20)
	assert spans_text(rows[2]) == '─'.repeat(20)
	assert spans_width(rows[2]) == 20
	// asterisks and underscores mean the same thing
	assert md_text('***', 10) == '─'.repeat(10)
	assert md_text('___', 10) == '─'.repeat(10)
	// two dashes are not a rule
	assert md_text('--', 10) == '--'
}

fn test_tables_render_as_a_box_with_aligned_columns() {
	src := '| a | bbbb |\n|---|------|\n| 1 | 2 |'
	rows := render_markdown(src, 40)
	texts := rows.map(spans_text(it))
	assert texts[0] == '╭───┬──────╮', texts[0]
	assert texts[1] == '│ a │ bbbb │', texts[1]
	assert texts[2] == '├───┼──────┤', texts[2]
	assert texts[3] == '│ 1 │ 2    │', texts[3]
	assert texts[4] == '╰───┴──────╯', texts[4]

	// every row is the same width, and a narrow terminal shrinks the widest
	// column rather than overflowing
	narrow := render_markdown('| aaaaaaaaaaaaaaa | b |\n|---|---|\n| x | y |', 20)
	widths := narrow.map(spans_width(it))
	for w in widths {
		assert w == widths[0], '${widths}'
	}
	assert widths[0] <= 20

	// a short row is padded out to the header's column count
	short := render_markdown('| a | b |\n|---|---|\n| 1 |', 40)
	assert spans_text(short[3]) == '│ 1 │   │'
}

fn test_a_pipe_line_without_a_delimiter_is_just_a_paragraph() {
	assert md_text('| not | a table |', 40) == '| not | a table |'
}

fn test_wrap_spans_keeps_each_run_styled_across_the_break() {
	spans := [
		span('hello ', Style{ fg: c_fg }),
		span('brave', Style{
			fg:   c_green
			bold: true
		}),
		span(' world', Style{ fg: c_fg }),
	]
	rows := wrap_spans(spans, 11)
	assert rows.map(spans_text(it)) == ['hello brave', 'world']
	assert rows[0].last().style.fg == c_green
	assert rows[1][0].style.fg == c_fg

	// a word longer than the line is hard-broken, not dropped
	long := wrap_spans([span('x'.repeat(10), Style{ fg: c_red })], 4)
	assert long.map(spans_text(it)) == ['xxxx', 'xxxx', 'xx']
	assert long[2][0].style.fg == c_red

	// no width means no wrapping rather than an infinite loop
	assert wrap_spans(spans, 0).len == 1
}
