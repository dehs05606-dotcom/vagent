module vagent

import x.json2

fn theater_session(name string) &EventLog {
	mut log := new_event_log(tmp_log_path(name), 'main', 'test')
	root := log.append('user.message', {
		'text': json2.Any('fix the parser')
	}, AppendOpts{ actor: 'human' })
	mid := log.append('tool.call', {
		'name': json2.Any('edit_file')
		'args': json2.Any({
			'path':       json2.Any('p.py')
			'new_string': json2.Any('x=1')
		})
	}, AppendOpts{ actor: 'sovereign', causation_id: root.id })
	log.append('tool.result', {
		'name':   json2.Any('edit_file')
		'status': json2.Any('done')
	}, AppendOpts{ actor: 'system', causation_id: mid.id })
	log.append('cost.incurred', {
		'usd':        json2.Any(0.01)
		'tokens_in':  json2.Any(500)
		'tokens_out': json2.Any(100)
	}, AppendOpts{})
	log.append('assistant.message', {
		'text': json2.Any('parser fixed')
	}, AppendOpts{})
	return log
}

fn test_the_strip_covers_every_event() {
	mut log := theater_session('the1')
	mut t := new_theater(log)
	strip := t.frames('main')
	assert strip.map(it.seq) == [0, 1, 2, 3, 4]
	assert strip[0].summary.contains('parser')
	assert strip[0].actor == 'human'
	assert strip[1].summary.contains('edit_file')
	assert strip[1].summary.contains('p.py')
}

fn test_a_frame_reconstructs_the_state_at_that_instant() {
	mut log := theater_session('the2')
	mut t := new_theater(log)

	// at seq 2 the edit has happened but the cost has not landed yet
	f2 := t.frame(2) or { panic('no frame at 2') }
	assert f2.state.tool_calls == 1
	assert f2.state.cost_usd == 0.0

	f3 := t.frame(3) or { panic('no frame at 3') }
	assert f3.state.cost_usd == 0.01
	assert f3.state.messages > 0

	// a seq that never happened has no frame, rather than an empty one
	if _ := t.frame(99) {
		assert false, 'a frame was invented for a seq that does not exist'
	}

	text := f3.format()
	assert text.contains('FRAME seq 3')
	assert text.contains('cost: $0.0100')
}

fn test_why_reads_the_sealed_causal_chain() {
	mut log := theater_session('the3')
	mut t := new_theater(log)
	why := t.why(2)
	assert why.contains('WHY seq 2')
	// the chain is evidence from the envelope, not a reconstruction
	assert why.contains('tool.call'), why
	assert why.contains('user.message'), why
	assert t.why(99) == 'no event at seq 99'
}

fn test_diff_measures_what_changed_between_two_moments() {
	mut log := theater_session('the4')
	mut t := new_theater(log)
	d := t.diff(1, 4)
	assert d.contains('DIFF seq 1 → seq 4')
	assert d.contains('tool calls 1 → 1')
	assert d.contains('cost       $0.0000 → $0.0100')
	// the added assistant message is shown, not just counted
	assert d.contains('parser fixed'), d
}

fn test_a_counterfactual_branch_is_real_and_verifiable() {
	mut log := theater_session('the5')
	mut t := new_theater(log)

	report := t.counterfactual(1, '') or { panic(err) }
	assert report.removed_type == 'tool.call'
	assert report.branch in log.branches()

	// the branch carries the world WITHOUT the removed call, and with
	// everything that came after it
	cf_types := log.events(report.branch).map(it.typ)
	assert 'tool.call' !in cf_types, cf_types.str()
	assert 'assistant.message' in cf_types, cf_types.str()
	assert 'tool.result' in cf_types

	// the divergence is measured rather than asserted
	assert report.divergence.tool_calls_with == 1
	assert report.divergence.tool_calls_without == 0
	assert report.events_replayed == 3

	// the spine survives the surgery: this is a branch, not a mock
	ok, msg := log.verify(report.branch)
	assert ok, msg
	assert 'theater.counterfactual' in log.events('main').map(it.typ)

	// and the original timeline is untouched
	assert log.branch == 'main'
	assert 'tool.call' in log.events('main').map(it.typ)

	text := t.format_cf(&report)
	assert text.contains('COUNTERFACTUAL — removed seq 1')
	assert text.contains('tool calls: 1 → 0')
	assert text.contains('/branch ${report.branch}')
}

fn test_removing_the_very_first_event_leaves_an_empty_base() {
	mut log := theater_session('the6')
	mut t := new_theater(log)
	// there is no event before seq 0 to fork from. Defaulting to the head
	// would build a branch containing exactly the history being removed.
	report := t.counterfactual(0, '') or { panic(err) }
	cf := log.events(report.branch)
	types := cf.map(it.typ)
	assert 'user.message' !in types, types.str()
	assert 'assistant.message' in types, types.str()
	// the counts happen to match — one message on each side — but they are
	// not the same message, which is the whole point of the branch
	assert report.divergence.messages_with == 1
	assert report.divergence.messages_without == 1
	ok, msg := log.verify(report.branch)
	assert ok, msg
}

fn test_a_second_counterfactual_at_the_same_seq_gets_its_own_branch() {
	mut log := theater_session('the7')
	mut t := new_theater(log)
	first := t.counterfactual(1, 'cf/fixed') or { panic(err) }
	before := log.events(first.branch).len
	second := t.counterfactual(1, 'cf/fixed') or { panic(err) }
	assert second.branch != first.branch
	// the first branch's head was not silently rewound
	assert log.events(first.branch).len == before
}

fn test_an_event_that_does_not_exist_cannot_be_removed() {
	mut log := theater_session('the8')
	mut t := new_theater(log)
	t.counterfactual(99, '') or {
		assert err.msg().contains('no event at seq 99')
		return
	}
	assert false, 'a counterfactual on a missing event must be refused'
}

fn test_frames_work_on_a_counterfactual_branch_too() {
	mut log := theater_session('the9')
	mut t := new_theater(log)
	report := t.counterfactual(1, '') or { panic(err) }
	strip := t.frames(report.branch)
	assert strip.len > 0
	assert strip[0].typ != 'kernel.branch'
}

fn test_the_summary_says_something_for_the_events_worth_reading() {
	mut log := new_event_log(tmp_log_path('the10'), 'main', 'test')
	goal := log.append('goal.set', {
		'statement': json2.Any('ship the parser')
	}, AppendOpts{})
	fact := log.append('fact.learned', {
		'fact': json2.Any('the tokenizer is line-based')
	}, AppendOpts{})
	crew := log.append('crew.done', {
		'role':    json2.Any('coder')
		'summary': json2.Any('wrote the fix')
	}, AppendOpts{})
	quiet := log.append('some.internal.event', {
		'x': json2.Any(1)
	}, AppendOpts{})

	assert frame_summary(&goal) == 'ship the parser'
	assert frame_summary(&fact) == 'the tokenizer is line-based'
	assert frame_summary(&crew) == '[coder] wrote the fix'
	// an event with nothing worth reading summarises to nothing rather
	// than to a guess
	assert frame_summary(&quiet) == ''
}
