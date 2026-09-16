module vagent

import os
import x.json2

fn test_append_seqs_and_spine() {
	path := tmp_log_path('kernel-basic.jsonl')
	mut log := new_event_log(path, 'main', '')
	defer {
		log.close()
	}
	for i in 0 .. 5 {
		log.append('user.message', {
			'text': json2.Any('msg${i}')
		}, AppendOpts{})
	}
	assert log.head('') == 4
	assert log.events('').map(it.seq) == [0, 1, 2, 3, 4]
	ok, msg := log.verify('')
	assert ok, msg
}

fn test_rewind_never_reuses_seqs() {
	path := tmp_log_path('kernel-rewind.jsonl')
	mut log := new_event_log(path, 'main', '')
	defer {
		log.close()
	}
	for i in 0 .. 5 {
		log.append('user.message', {
			'text': json2.Any('msg${i}')
		}, AppendOpts{})
	}
	log.rewind(2, '')
	assert texts_of(log.events('')) == ['msg0', 'msg1', 'msg2']
	// the kernel.rewind marker is the new head
	assert log.head('') == 5

	log.append('user.message', {
		'text': json2.Any('after-rewind')
	}, AppendOpts{})
	seqs := log.events('').map(it.seq)
	mut sorted := seqs.clone()
	sorted.sort()
	assert seqs == sorted
	mut uniq := map[int]bool{}
	for s in seqs {
		uniq[s] = true
	}
	assert uniq.len == seqs.len
	assert texts_of(log.events('')) == ['msg0', 'msg1', 'msg2', 'after-rewind']
	ok, msg := log.verify('')
	assert ok, msg

	// fold sees only the live chain
	st := fold(mut log, '')
	assert st.messages.map(it.text()) == ['msg0', 'msg1', 'msg2', 'after-rewind']
}

fn test_fork_inherits_history_and_isolates_writes() {
	path := tmp_log_path('kernel-fork.jsonl')
	mut log := new_event_log(path, 'main', '')
	defer {
		log.close()
	}
	for i in 0 .. 3 {
		log.append('user.message', {
			'text': json2.Any('msg${i}')
		}, AppendOpts{})
	}
	branch := log.fork(log.head(''), 'alt')
	log.checkout(branch)
	assert log.branch == 'alt'

	st := fold(mut log, 'alt')
	assert st.messages.map(it.text()) == ['msg0', 'msg1', 'msg2']

	log.append('user.message', {
		'text': json2.Any('alt-only')
	}, AppendOpts{})
	// main is untouched by writes on alt
	st_main := fold(mut log, 'main')
	assert 'alt-only' !in st_main.messages.map(it.text())

	ok, msg := log.verify('alt')
	assert ok, msg

	// a second fork with the same name must not clobber the first
	log.checkout('main')
	second := log.fork(-1, 'alt')
	assert second == 'alt-2'
}

fn test_reload_rebuilds_heads_and_chains() {
	path := tmp_log_path('kernel-reload.jsonl')
	mut log := new_event_log(path, 'main', '')
	for i in 0 .. 3 {
		log.append('user.message', {
			'text': json2.Any('msg${i}')
		}, AppendOpts{})
	}
	log.fork(log.head(''), 'alt')
	log.checkout('alt')
	log.append('user.message', {
		'text': json2.Any('alt-only')
	}, AppendOpts{})
	main_head := log.head('main')
	alt_head := log.head('alt')
	log.close()

	mut log2 := new_event_log(path, 'main', '')
	defer {
		log2.close()
	}
	mut brs := log2.branches()
	brs.sort()
	assert brs == ['alt', 'main']
	assert log2.head('main') == main_head
	assert log2.head('alt') == alt_head

	st := fold(mut log2, 'alt')
	assert st.messages.map(it.text()).last() == 'alt-only'
	ok_main, m1 := log2.verify('main')
	assert ok_main, m1
	ok_alt, m2 := log2.verify('alt')
	assert ok_alt, m2
}

fn test_rewind_survives_reload() {
	path := tmp_log_path('kernel-rewind-reload.jsonl')
	mut log := new_event_log(path, 'main', '')
	for i in 0 .. 4 {
		log.append('user.message', {
			'text': json2.Any('msg${i}')
		}, AppendOpts{})
	}
	log.rewind(1, 'main')
	log.close()

	mut log2 := new_event_log(path, 'main', '')
	defer {
		log2.close()
	}
	assert texts_of(log2.events('main')) == ['msg0', 'msg1']
	ok, msg := log2.verify('main')
	assert ok, msg
}

fn test_tampering_is_detected() {
	path := tmp_log_path('kernel-tamper.jsonl')
	mut log := new_event_log(path, 'main', '')
	defer {
		log.close()
	}
	for i in 0 .. 3 {
		log.append('user.message', {
			'text': json2.Any('msg${i}')
		}, AppendOpts{})
	}
	// rewrite the file with one event's payload altered — the content
	// address must no longer match what the line claims
	lines := os.read_file(path) or { panic(err) }
	mut out := []string{}
	for raw in lines.split('\n') {
		if raw.trim_space() == '' {
			continue
		}
		mut o := decode_obj(raw)
		if jstr(jmap(o, 'data'), 'text') == 'msg1' {
			mut d := jmap(o, 'data')
			d['text'] = 'tampered'
			o['data'] = d
		}
		out << canonical(json2.Any(o))
	}
	os.write_file(path, out.join('\n') + '\n') or { panic(err) }

	mut log2 := new_event_log(path, 'main', '')
	defer {
		log2.close()
	}
	ok, msg := log2.verify('main')
	assert !ok
	assert msg.contains('content hash')
}

fn test_causal_envelope_and_why() {
	path := tmp_log_path('kernel-causal.jsonl')
	mut log := new_event_log(path, 'main', 's1')
	root := log.append('user.message', {
		'text': json2.Any('fix the bug')
	}, AppendOpts{ actor: 'human', provenance: 'user' })
	mid := log.append('tool.call', {
		'name': json2.Any('edit_file')
	}, AppendOpts{
		actor:          'sovereign'
		causation_id:   root.id
		correlation_id: 'C1'
		provenance:     'model'
	})
	leaf := log.append('tool.result', {
		'status': json2.Any('done')
	}, AppendOpts{
		actor:          'system'
		causation_id:   mid.id
		correlation_id: 'C1'
		provenance:     'tool_output'
	})
	chain := log.why(leaf.id, 50)
	assert chain.map(it.typ) == ['tool.result', 'tool.call', 'user.message']
	assert chain.last().actor == 'human'
	assert (leaf.correlation_id or { '' }) == 'C1'
	ok, msg := log.verify('')
	assert ok, msg
	log.close()

	// envelope survives reload
	mut log2 := new_event_log(path, 'main', 's1')
	defer {
		log2.close()
	}
	ev := log2.events('').last()
	assert (ev.causation_id or { '' }) == mid.id
	assert ev.provenance == 'tool_output'
	assert log2.why(ev.id, 50).map(it.typ) == ['tool.result', 'tool.call', 'user.message']
}

fn test_fold_projects_tools_cost_and_files() {
	path := tmp_log_path('kernel-fold.jsonl')
	mut log := new_event_log(path, 'main', '')
	defer {
		log.close()
	}
	log.append('tool.call', {
		'name': json2.Any('write_file')
		'args': json2.Any({
			'path': json2.Any('/tmp/a.txt')
		})
	}, AppendOpts{})
	log.append('tool.result', {
		'status': json2.Any('error')
	}, AppendOpts{})
	log.append('tool.call', {
		'name': json2.Any('run_command')
	}, AppendOpts{})
	log.append('cost.incurred', {
		'usd':        json2.Any(0.25)
		'tokens_in':  json2.Any(100)
		'tokens_out': json2.Any(40)
	}, AppendOpts{})
	log.append('goal.set', {
		'mission': json2.Any('ship it')
	}, AppendOpts{})
	log.append('goal.clause.done', {
		'clause': json2.Any('C1')
	}, AppendOpts{})
	// an advanced-subsystem event lands in the shared bucket, tagged
	log.append('mcts.best', {
		'score': json2.Any(3)
	}, AppendOpts{})

	st := fold(mut log, '')
	assert st.tool_calls == 2
	assert st.tool_errors == 1
	assert st.commands_run == 1
	assert st.touched_files() == ['/tmp/a.txt']
	assert st.cost_usd == 0.25
	assert st.tokens_in == 100 && st.tokens_out == 40
	assert st.goal != none
	assert st.goal_done == ['C1']
	assert st.advanced_events.len == 1
	assert jstr(st.advanced_events[0], 'type') == 'mcts.best'
	assert st.cost_summary() == '\$0.2500 · 100→40 tok'
}

fn test_fold_cache_extends_incrementally() {
	path := tmp_log_path('kernel-foldcache.jsonl')
	mut log := new_event_log(path, 'main', '')
	defer {
		log.close()
	}
	for i in 0 .. 3 {
		log.append('user.message', {
			'text': json2.Any('m${i}')
		}, AppendOpts{})
	}
	first := fold(mut log, '')
	assert first.messages.len == 3
	log.append('user.message', {
		'text': json2.Any('m3')
	}, AppendOpts{})
	second := fold(mut log, '')
	assert second.messages.len == 4
	assert second.messages.last().text() == 'm3'
	// a rewind must invalidate the cache rather than extend a stale chain
	log.rewind(1, '')
	third := fold(mut log, '')
	assert third.messages.map(it.text()) == ['m0', 'm1']
}

fn test_fold_window_bounds_the_horizon() {
	path := tmp_log_path('kernel-window.jsonl')
	mut log := new_event_log(path, 'main', '')
	defer {
		log.close()
	}
	for i in 0 .. 5 {
		log.append('user.message', {
			'text': json2.Any('m${i}')
		}, AppendOpts{})
	}
	upto := fold_window(mut log, '', 2, -1)
	assert upto.messages.map(it.text()) == ['m0', 'm1', 'm2']
	from := fold_window(mut log, '', -1, 2)
	assert from.messages.map(it.text()) == ['m3', 'm4']
}

fn test_corrupt_lines_are_skipped_not_fatal() {
	path := tmp_log_path('kernel-corrupt.jsonl')
	mut log := new_event_log(path, 'main', '')
	log.append('user.message', {
		'text': json2.Any('good')
	}, AppendOpts{})
	log.close()
	mut f := os.open_append(path) or { panic(err) }
	f.write_string('{not json at all\n') or { panic(err) }
	f.write_string('{"seq":"nope","id":"x","type":"user.message","data":{}}\n') or { panic(err) }
	f.write_string('{"seq":9,"id":"y","type":"user.message","data":[]}\n') or { panic(err) }
	f.close()

	mut log2 := new_event_log(path, 'main', '')
	defer {
		log2.close()
	}
	assert texts_of(log2.events('main')) == ['good']
}
