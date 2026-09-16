module vagent

import x.json2
import os

fn brain_dir(name string) string {
	dir := os.join_path(os.temp_dir(), 'vagent-brain-${name}-${os.getpid()}')
	os.rmdir_all(dir) or {}
	os.mkdir_all(dir) or { panic(err) }
	return dir
}

fn test_a_near_duplicate_reinforces_rather_than_piling_up() {
	dir := brain_dir('b1')
	defer {
		os.rmdir_all(dir) or {}
	}
	mut b := new_brain(new_event_log(os.join_path(dir, 'log.jsonl'), 'main', 'test'),
		os.join_path(dir, 'brain.json'))
	m := b.remember('the parser lives in src/parser.py', 'semantic', 'fact', true, []) or {
		panic(err)
	}
	assert m.store == 'semantic'
	assert m.reviews == 0
	b.remember('parser lives in src/parser.py', 'semantic', 'note', false, []) or { panic(err) }
	assert b.memories.len == 1
	assert m.reviews == 1
	// and the merge cannot demote a verified memory
	assert m.verified
}

fn test_the_forgetting_curve_decays_and_a_review_flattens_it() {
	dir := brain_dir('b2')
	defer {
		os.rmdir_all(dir) or {}
	}
	mut b := new_brain(new_event_log(os.join_path(dir, 'log.jsonl'), 'main', 'test'), '')
	mut m := b.remember('the parser lives in src/parser.py', 'semantic', 'fact', true, []) or {
		panic(err)
	}
	before := m.retention_now()
	// nothing has decayed yet, so retention is still whole
	assert before <= 1.0 && before > 0.999
	m.last_review -= 3600.0 * 24.0 * 10.0
	stale := m.retention_now()
	assert stale < before
	assert stale < 1.0
	m.review()
	assert m.retention_now() > 0.99
}

fn test_sleep_forgets_only_what_was_never_needed() {
	dir := brain_dir('b3')
	defer {
		os.rmdir_all(dir) or {}
	}
	mut log := new_event_log(os.join_path(dir, 'log.jsonl'), 'main', 'test')
	mut b := new_brain(log, '')
	mut keep := b.remember('the parser lives in src/parser.py', 'semantic', 'fact', true, []) or {
		panic(err)
	}
	mut gone := b.remember('totally irrelevant fluff', 'semantic', 'note', false, []) or {
		panic(err)
	}
	// a year of silence, and never recalled
	gone.last_review -= 3600.0 * 24.0 * 365.0
	gone.created -= 3600.0 * 24.0 * 365.0
	// the other is equally stale but HAS been recalled, so it stays
	keep.last_review -= 3600.0 * 24.0 * 365.0
	keep.review()
	keep.last_review -= 3600.0 * 24.0 * 365.0

	id := gone.id
	stats := b.sleep()
	assert stats.forgotten == 1, '${stats}'
	assert id !in b.memories
	assert keep.id in b.memories
	assert log.events('main').map(it.typ).contains('brain.forgotten')
}

fn test_recall_ranks_relevance_and_reviews_the_winners() {
	dir := brain_dir('b4')
	defer {
		os.rmdir_all(dir) or {}
	}
	mut b := new_brain(new_event_log(os.join_path(dir, 'log.jsonl'), 'main', 'test'), '')
	m := b.remember('the parser lives in src/parser.py', 'semantic', 'fact', true, []) or {
		panic(err)
	}
	b.remember('cooking pasta needs salt water', 'semantic', 'note', false, []) or { panic(err) }
	hits := b.recall('where is the parser file?', 2, '')
	assert hits.len == 2
	assert hits[0].id == m.id, hits.map(it.text).str()
	assert m.reviews >= 1

	// a store filter narrows the search
	assert b.recall('parser', 5, 'episodic').len == 0
	assert b.recall('parser', 0, '').len == 0
}

fn test_enough_reviews_promote_a_fact_to_a_skill() {
	dir := brain_dir('b5')
	defer {
		os.rmdir_all(dir) or {}
	}
	mut b := new_brain(new_event_log(os.join_path(dir, 'log.jsonl'), 'main', 'test'), '')
	mut m := b.remember('run the suite with pytest -q', 'semantic', 'fact', true, []) or {
		panic(err)
	}
	for m.reviews < promote_threshold {
		m.review()
	}
	b.sleep()
	assert m.store == 'procedural'
	assert m.kind == 'skill'
}

fn test_three_episodes_on_one_theme_distil_into_a_fact() {
	dir := brain_dir('b6')
	defer {
		os.rmdir_all(dir) or {}
	}
	mut b := new_brain(new_event_log(os.join_path(dir, 'log.jsonl'), 'main', 'test'), '')
	for txt in ['wired retry logic into charge calls', 'added idempotency keys for safety',
		'replayed events through the ledger twice'] {
		b.remember(txt, 'episodic', 'episode', false, ['payment', 'gateway']) or { panic(err) }
	}
	b.sleep()
	mut found := false
	for _, m in b.memories {
		if m.text.contains('distilled from 3 episodes') {
			found = true
		}
	}
	assert found

	// a second sleep does not distil the same theme again
	before := b.memories.len
	b.sleep()
	assert b.memories.len == before
}

fn test_kernel_ingestion_pulls_facts_dead_ends_and_long_replies() {
	dir := brain_dir('b7')
	defer {
		os.rmdir_all(dir) or {}
	}
	mut log := new_event_log(os.join_path(dir, 'log.jsonl'), 'main', 'test')
	mut b := new_brain(log, '')
	// the marker starts at 0 and the test is `seq <= marker`, so the event at
	// seq 0 is never ingested — the original behaves the same way, and a log
	// in real use always has a session.start ahead of anything ingestible
	log.append('session.start', map[string]json2.Any{}, AppendOpts{})
	log.append('fact.learned', {
		'fact': json2_str('tests run with pytest -q')
		'kind': json2_str('goal')
	}, AppendOpts{})
	log.append('deadend.recorded', {
		'reason': json2_str('sed -i broke on BSD')
	}, AppendOpts{})
	log.append('assistant.message', {
		'text': json2_str('short')
	}, AppendOpts{})
	log.append('assistant.message', {
		'text': json2_str('we shipped the new parser after fixing the tokenizer bug ' +
			'and adding property tests across the whole token pipeline, twice over')
	}, AppendOpts{})
	added := b.ingest_kernel()
	assert added == 3, '${added}'
	mut has_pytest := false
	for _, m in b.memories {
		if m.text.contains('pytest') {
			has_pytest = true
		}
	}
	assert has_pytest

	// and it is idempotent past the consolidation marker
	b.sleep()
	assert b.ingest_kernel() == 0
}

fn test_the_store_round_trips_through_its_file() {
	dir := brain_dir('b8')
	defer {
		os.rmdir_all(dir) or {}
	}
	path := os.join_path(dir, 'brain.json')
	mut b := new_brain(new_event_log(os.join_path(dir, 'log.jsonl'), 'main', 'test'), path)
	b.remember('the parser lives in src/parser.py', 'semantic', 'fact', true, []) or { panic(err) }
	b.remember('a second unrelated thing about deployment', 'episodic', 'episode', false,
		[]) or { panic(err) }

	mut b2 := new_brain(new_event_log(os.join_path(dir, 'log2.jsonl'), 'main', 'test'),
		path)
	assert b2.memories.len == b.memories.len
	for id, m in b.memories {
		assert id in b2.memories
		assert b2.memories[id] or { panic('missing') }.text == m.text
	}
	// the id counter resumes where it left off rather than colliding
	n := b2.remember('a third and quite different subject entirely', 'semantic', 'note',
		false, []) or { panic(err) }
	assert n.id !in b.memories

	// a file that is valid JSON of the wrong shape starts fresh, not crashes
	os.write_file(path, '[1, 2, 3]') or { panic(err) }
	mut b3 := new_brain(new_event_log(os.join_path(dir, 'log3.jsonl'), 'main', 'test'),
		path)
	assert b3.memories.len == 0
	os.write_file(path, 'not json at all') or { panic(err) }
	mut b4 := new_brain(new_event_log(os.join_path(dir, 'log4.jsonl'), 'main', 'test'),
		path)
	assert b4.memories.len == 0
}

fn test_empty_text_and_unknown_stores_are_refused() {
	dir := brain_dir('b9')
	defer {
		os.rmdir_all(dir) or {}
	}
	mut b := new_brain(new_event_log(os.join_path(dir, 'log.jsonl'), 'main', 'test'), '')
	b.remember('   ', 'semantic', 'note', false, []) or {
		assert err.msg().contains('empty')
		b.remember('fine', 'nowhere', 'note', false, []) or {
			assert err.msg().contains('store must be')
			assert b.memories.len == 0
			return
		}
		assert false, 'an unknown store must be refused'
		return
	}
	assert false, 'empty text must be refused'
}

fn test_the_context_block_and_the_stats_render() {
	dir := brain_dir('b10')
	defer {
		os.rmdir_all(dir) or {}
	}
	mut b := new_brain(new_event_log(os.join_path(dir, 'log.jsonl'), 'main', 'test'), '')
	assert b.context_block('parser', 4) == ''
	b.remember('the parser lives in src/parser.py', 'semantic', 'fact', true, []) or { panic(err) }
	block := b.context_block('parser', 4)
	assert block.contains('MEMORY')
	assert block.contains('parser')
	assert block.contains('✓verified')
	assert b.format_stats().contains('BRAIN')
	assert b.format_stats().contains('semantic   1')
}

fn test_jaccard_and_the_tokeniser() {
	assert brain_tokens('Hello, world! 42') == ['hello', 'world', '42']
	assert brain_tokens('') == []
	// tokens are a set: a repeated word does not count twice
	assert brain_tokens('a a a b') == ['a', 'b']
	assert jaccard('a b c', 'a b c') == 1.0
	assert jaccard('a b c', 'x y z') == 0.0
	assert jaccard('', 'a') == 0.0
	assert jaccard('a b', 'a b c d') == 0.5
}

fn json2_str(s string) json2.Any {
	return json2.Any(s)
}
