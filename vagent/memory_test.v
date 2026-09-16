module vagent

fn test_hippocampus_records_and_folds() {
	path := tmp_log_path('memory-test.jsonl')
	mut log := new_event_log(path, 'main', '')
	defer {
		log.close()
	}
	mut hip := new_hippocampus(log)

	rec := hip.record_episode(Episode{
		goal:      'fix the parser'
		approach:  'rewrite tokenizer'
		actions:   ['read parser.py', 'edit tokenizer', 'run tests']
		outcome:   'success'
		artifacts: ['parser.py']
		facts:     ['tokenizer is line-based', 'tests live in tests/',
			'tokenizer is line-based']
		lesson:    'run the test suite after every edit'
		dead_ends: [
			DeadEnd{
				signature: 'sha256:abc123'
				reason:    'regex approach hit catastrophic backtracking'
			},
		]
		cost_usd:  0.0123
		steps:     4
	}) or { panic(err) }
	assert rec.goal == 'fix the parser'
	assert rec.steps == 4
	assert rec.dead_ends[0].signature == 'sha256:abc123'

	hip.record_dead_end(DeadEnd{
		signature: 'sha256:def456'
		reason:    'API requires a token we do not have'
	}) or { panic(err) }

	assert hip.is_dead_end('sha256:abc123') // via episode dead_ends
	assert hip.is_dead_end('sha256:def456') // recorded directly
	assert !hip.is_dead_end('sha256:unknown')

	recent := hip.recent_episodes(5)
	assert recent.len == 1
	assert jstr(recent[0], 'goal') == 'fix the parser'

	// deduped, order-preserving
	assert hip.facts() == ['tokenizer is line-based', 'tests live in tests/']

	block := hip.context_block(3)
	assert block.contains('MEMORY')
	assert block.contains('fix the parser')
	assert block.contains('sha256:def456')
	assert block.len < 1600 // ~400-token budget
}

fn test_dead_end_refuses_empty_signature_or_reason() {
	path := tmp_log_path('memory-guard.jsonl')
	mut log := new_event_log(path, 'main', '')
	defer {
		log.close()
	}
	mut hip := new_hippocampus(log)

	// an empty signature would match every is_dead_end() query
	if _ := hip.record_dead_end(DeadEnd{ signature: '   ', reason: 'x' }) {
		assert false, 'an empty signature was accepted'
	}
	// a dead end without a reason is an audit hole
	if _ := hip.record_dead_end(DeadEnd{ signature: 'sig', reason: ' ' }) {
		assert false, 'an empty reason was accepted'
	}
	assert !hip.is_dead_end('')
	assert !hip.is_dead_end('sig')
}

fn test_memory_survives_reload() {
	path := tmp_log_path('memory-reload.jsonl')
	mut log := new_event_log(path, 'main', '')
	mut hip := new_hippocampus(log)
	hip.record_episode(Episode{
		goal:     'ship it'
		approach: 'small steps'
		outcome:  'success'
		facts:    ['the build is cmake']
		steps:    2
	}) or { panic(err) }
	log.close()

	// memory keeps no state of its own, so a fresh log over the same file
	// projects exactly the same memory
	mut log2 := new_event_log(path, 'main', '')
	defer {
		log2.close()
	}
	mut hip2 := new_hippocampus(log2)
	assert hip2.facts() == ['the build is cmake']
	assert hip2.recent_episodes(1).len == 1
	assert hip2.context_block(3).contains('ship it')
}
