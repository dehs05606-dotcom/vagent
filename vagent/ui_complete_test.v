module vagent

fn texts_of_completions(cs []Completion) []string {
	return cs.map(it.text)
}

fn test_only_a_single_slash_line_completes() {
	assert complete_slash('') == []
	assert complete_slash('hello') == []
	assert complete_slash('/model\nmore') == []
	assert complete_slash('/mod').len > 0
}

fn test_a_prefix_offers_every_command_that_starts_with_it() {
	got := texts_of_completions(complete_slash('/go'))
	assert '/goal' in got
	assert '/graph' !in got

	// a bare slash offers all of them
	assert complete_slash('/').len == slash_commands.len

	// an unknown command offers nothing rather than everything
	assert complete_slash('/zzzz') == []
}

fn test_the_command_table_matches_the_original() {
	assert slash_commands.len == 77
	assert slash_commands[0].text == '/model'
	assert slash_commands.last().text == '/exit'
	// every entry is a command with a description
	mut seen := map[string]bool{}
	for c in slash_commands {
		assert c.text.starts_with('/'), c.text
		assert c.meta != '', c.text
		assert !seen[c.text], 'duplicate ${c.text}'
		seen[c.text] = true
	}
}

fn test_four_commands_complete_their_arguments_instead() {
	efforts_offered := texts_of_completions(complete_slash('/effort '))
	assert efforts_offered.len == efforts.len
	assert efforts_offered[0].starts_with('/effort ')

	// a bare command offers its subcommands too
	assert texts_of_completions(complete_slash('/goal')) == ['/goal set', '/goal prove',
		'/goal prove-all', '/goal close', '/goal status', '/goal waive', '/goal clear']

	// and a typed argument narrows them
	assert texts_of_completions(complete_slash('/goal pr')) == ['/goal prove', '/goal prove-all']

	levels := texts_of_completions(complete_slash('/autonomy '))
	assert levels == ['/autonomy 0', '/autonomy 1', '/autonomy 2', '/autonomy 3',
		'/autonomy 4', '/autonomy 5']
	assert complete_slash('/autonomy ')[3].meta.starts_with('Collaborator')

	judges := complete_slash('/judge file')
	assert texts_of_completions(judges) == ['/judge file_exists ', '/judge file_contains ',
		'/judge file_matches ']
	// the predicate is followed by a space because a JSON argument comes next
	assert judges[0].text.ends_with(' ')
}

fn test_a_command_that_merely_starts_with_one_is_not_it() {
	// /goalkeeper is not /goal, so it gets the command list, not subcommands
	assert complete_slash('/goalkeeper') == []
	assert texts_of_completions(complete_slash('/goa')) == ['/goal']
}

fn test_completion_is_case_insensitive() {
	assert texts_of_completions(complete_slash('/MOD')) == ['/model']
	assert texts_of_completions(complete_slash('/GOAL pr')) == ['/goal prove', '/goal prove-all']
}

fn test_the_menu_wraps_and_scrolls_like_the_overlay() {
	mut items := []Completion{}
	for i in 0 .. 20 {
		items << Completion{
			text: '/c${i}'
			meta: 'meta ${i}'
		}
	}
	mut m := new_completion_menu(items)
	assert m.selected() == '/c0'
	m.move(-1)
	assert m.index == 19
	assert m.top == 19 - completion_window + 1
	m.move(1)
	assert m.index == 0 && m.top == 0

	// an empty menu is inert rather than a division by zero
	mut e := new_completion_menu([]Completion{})
	e.move(1)
	assert e.selected() == ''
	assert e.rows(60).len == 0
}

fn test_menu_rows_align_their_descriptions_and_mark_the_selection() {
	m := new_completion_menu(complete_slash('/go'))
	rows := m.rows(70)
	assert rows.len >= 1
	first := spans_text(rows[0])
	assert first.starts_with(' ▶ /goal')
	assert first.contains('goal contract')
	assert rows[0][1].style.bg == c_selection_bg

	// the name column is the same width on every row, so the metas line up
	wide := new_completion_menu([
		Completion{
			text: '/a'
			meta: 'x'
		},
		Completion{
			text: '/abcdefgh'
			meta: 'y'
		},
	])
	wr := wide.rows(70)
	assert display_width(wr[0][1].text) == display_width(wr[1][1].text)

	// a menu longer than the window says how many there are
	mut many := []Completion{}
	for i in 0 .. 30 {
		many << Completion{
			text: '/c${i}'
			meta: ''
		}
	}
	tall := new_completion_menu(many)
	trows := tall.rows(60)
	assert trows.len == completion_window + 1
	assert spans_text(trows.last()).contains('30 matches')

	// a narrow terminal drops the description rather than overflowing
	narrow := new_completion_menu([Completion{
		text: '/somewhat-long-command'
		meta: 'a description'
	}])
	nrows := narrow.rows(20)
	assert spans_width(nrows[0]) <= 20, spans_text(nrows[0])
}
