module vagent

import x.json2

fn write_call(path string, content string) map[string]json2.Any {
	return {
		'name': json2.Any('write_file')
		'args': json2.Any({
			'path':    json2.Any(path)
			'content': json2.Any(content)
		})
	}
}

fn texts_on(mut log EventLog, branch string, typ string) []string {
	return log.events(branch).filter(it.typ == typ).map(jstr(it.data, 'text'))
}

fn diverged_log(name string) (&EventLog, string, int) {
	mut log := new_event_log(tmp_log_path(name), 'main', 'test')
	for i in 0 .. 2 {
		log.append('user.message', {
			'text': json2.Any('base ${i}')
		}, AppendOpts{})
	}
	anc := log.head('main')

	alt := log.fork(anc, 'alt')
	log.checkout('main')
	log.append('user.message', {
		'text': json2.Any('main continues')
	}, AppendOpts{})
	log.append('tool.call', write_call('app.py', "print('main')"), AppendOpts{})
	log.append('assistant.message', {
		'text': json2.Any('main shipped app.py')
	}, AppendOpts{})

	log.checkout(alt)
	log.append('user.message', {
		'text': json2.Any('alt diverges')
	}, AppendOpts{})
	log.append('tool.call', write_call('app.py', "print('alt')"), AppendOpts{})
	log.append('tool.call', write_call('lib.py', 'x = 1'), AppendOpts{})
	log.append('fact.learned', {
		'fact': json2.Any('alt learned lib.py layout')
	}, AppendOpts{})
	return log, alt, anc
}

fn test_the_ancestor_is_found_exactly_not_guessed() {
	mut log, alt, anc := diverged_log('mrg1')
	mut m := new_timeline_merger(log)
	assert m.ancestor('main', alt) == anc
	// and it is symmetric
	assert m.ancestor(alt, 'main') == anc
}

fn test_both_sides_work_survives_the_merge() {
	mut log, alt, _ := diverged_log('mrg2')
	mut m := new_timeline_merger(log)
	result := m.merge('main', alt, '') or { panic(err) }

	assert result.only_a.len > 0
	assert result.only_b.len > 0

	messages := texts_on(mut log, result.branch, 'user.message')
	assert 'main continues' in messages, messages.str()
	assert 'alt diverges' in messages, messages.str()

	paths := log.events(result.branch).filter(it.typ == 'tool.call').map(jstr(jmap(it.data, 'args'), 'path'))
	assert 'lib.py' in paths, paths.str()
	assert 'app.py' in paths, paths.str()

	// the merged branch is a real kernel branch with an intact spine
	ok, msg := log.verify(result.branch)
	assert ok, msg
	assert log.branch == result.branch
}

fn test_the_same_file_written_differently_is_a_sealed_conflict() {
	mut log, alt, _ := diverged_log('mrg3')
	mut m := new_timeline_merger(log)
	result := m.merge('main', alt, '') or { panic(err) }

	assert result.conflicts.map(it.path) == ['app.py'], result.conflicts.str()
	c := result.conflicts[0]
	assert c.kind == 'file_write'
	// both versions are recorded — nothing is dropped, the human decides
	assert c.a.hash != ''
	assert c.b.hash != ''
	assert c.a.hash != c.b.hash
	assert c.a.seq != c.b.seq

	mut sealed := []Event{}
	for br in log.branches() {
		sealed << log.events(br).filter(it.typ == 'merge.conflict')
	}
	assert sealed.len >= 1
	assert jstr(sealed[0].data, 'path') == 'app.py'
}

fn test_the_same_file_written_identically_is_no_conflict() {
	mut log := new_event_log(tmp_log_path('mrg4'), 'main', 'test')
	log.append('user.message', {
		'text': json2.Any('base')
	}, AppendOpts{})
	anc := log.head('main')
	alt := log.fork(anc, 'alt')

	log.checkout('main')
	log.append('user.message', {
		'text': json2.Any('main side')
	}, AppendOpts{})
	log.append('tool.call', write_call('same.py', 'x = 1'), AppendOpts{})
	log.checkout(alt)
	log.append('user.message', {
		'text': json2.Any('alt side')
	}, AppendOpts{})
	log.append('tool.call', write_call('same.py', 'x = 1'), AppendOpts{})

	mut m := new_timeline_merger(log)
	result := m.merge('main', alt, '') or { panic(err) }
	// both sides did the same work: that is agreement, not conflict
	assert result.conflicts.len == 0
	assert result.shared.len == 1
	assert m.format(&result).contains('no conflicts — clean merge')
}

fn test_identical_work_on_both_sides_replays_once() {
	mut log, alt, _ := diverged_log('mrg5')
	log.checkout('main')
	log.append('user.message', {
		'text': json2.Any('same insight')
	}, AppendOpts{})
	log.checkout(alt)
	log.append('user.message', {
		'text': json2.Any('same insight')
	}, AppendOpts{})

	mut m := new_timeline_merger(log)
	result := m.merge('main', alt, 'merge/clean') or { panic(err) }
	texts := texts_on(mut log, result.branch, 'user.message')
	assert texts.filter(it == 'same insight').len == 1, texts.str()
	assert result.shared.len >= 1
}

fn test_a_genuine_repeat_is_not_collapsed_into_one() {
	mut log := new_event_log(tmp_log_path('mrg6'), 'main', 'test')
	log.append('user.message', {
		'text': json2.Any('base')
	}, AppendOpts{})
	anc := log.head('main')
	alt := log.fork(anc, 'alt')

	// the user really did say it twice on one side, and once on the other
	log.checkout('main')
	log.append('user.message', {
		'text': json2.Any('ping')
	}, AppendOpts{})
	log.append('user.message', {
		'text': json2.Any('ping')
	}, AppendOpts{})
	log.checkout(alt)
	log.append('user.message', {
		'text': json2.Any('ping')
	}, AppendOpts{})

	mut m := new_timeline_merger(log)
	result := m.merge('main', alt, '') or { panic(err) }
	// one copy matched one-to-one; the extra is genuinely A's own
	assert result.shared.len == 1
	assert result.only_a.len == 1
	assert result.only_b.len == 0
	texts := texts_on(mut log, result.branch, 'user.message')
	assert texts.filter(it == 'ping').len == 2, texts.str()
}

fn test_structural_events_are_never_replayed_onto_the_merge() {
	mut log, alt, _ := diverged_log('mrg7')
	mut m := new_timeline_merger(log)
	result := m.merge('main', alt, '') or { panic(err) }
	// a rewind or a branch marker replayed here would assert a history
	// that never happened on this branch
	replayed := log.events(result.branch).filter(it.actor == 'merge').map(it.typ)
	for t in replayed {
		assert t !in merge_skip_types, t
		assert t in merge_content_types, t
	}
}

fn test_a_second_merge_never_clobbers_the_first() {
	mut log, alt, _ := diverged_log('mrg8')
	mut m := new_timeline_merger(log)
	first := m.merge('main', alt, 'merge/x') or { panic(err) }
	before := log.events(first.branch).len

	log.checkout('main')
	log.append('user.message', {
		'text': json2.Any('more main work')
	}, AppendOpts{})
	second := m.merge('main', alt, 'merge/x') or { panic(err) }

	assert second.branch != first.branch, second.branch
	// the first merge's events are untouched
	assert log.events(first.branch).len == before
	ok, msg := log.verify(first.branch)
	assert ok, msg
}

fn test_an_unknown_branch_is_refused_with_the_roster() {
	mut log, alt, _ := diverged_log('mrg9')
	mut m := new_timeline_merger(log)
	m.merge('main', 'nope', '') or {
		assert err.msg().contains('unknown branch')
		assert err.msg().contains(alt), err.msg()
		return
	}
	assert false, 'an unknown branch must be refused'
}

fn test_the_whole_merge_is_sealed() {
	mut log, alt, _ := diverged_log('mrg10')
	mut m := new_timeline_merger(log)
	result := m.merge('main', alt, '') or { panic(err) }

	mut types := map[string]bool{}
	for br in log.branches() {
		for e in log.events(br) {
			types[e.typ] = true
		}
	}
	for want in ['merge.started', 'merge.conflict', 'merge.merged'] {
		assert types[want], want
	}

	text := m.format(&result)
	assert text.contains("MERGED → branch '${result.branch}'")
	assert text.contains('A exclusive :')
	assert text.contains('FILE CONFLICT(S)')
	assert text.contains('app.py')

	d := result.to_json()
	assert jint(d, 'only_a') == result.only_a.len
	assert jint(d, 'ancestor_seq') == result.ancestor_seq
}
