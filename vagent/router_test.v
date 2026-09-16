module vagent

import x.json2

fn router_fixture(name string) (&EventLog, &Router) {
	mut log := new_event_log(tmp_log_path('${name}.jsonl'), 'main', '')
	return log, new_router(log, map[string]ModelSpec{})
}

fn test_classify_scores_the_axes() {
	easy := classify('hi')
	hard := classify('refactor the algorithm and prove the complexity ' +
		'trade-off, then debug the root cause')
	assert hard.score > easy.score
	assert hard.needs_reasoning
	assert !easy.needs_reasoning

	tooly := classify('run the build, then test and grep the file')
	assert tooly.needs_tools

	coded := classify('```\ndef f():\n    import os\n```\nclass X: pass')
	assert coded.axes['code'] or { 0.0 } > 0.0
}

fn test_cheap_capable_model_wins_an_easy_task() {
	mut log, mut r := router_fixture('router-cheap')
	defer {
		log.close()
	}
	choice := r.choose('say hello', 1500, '')
	chosen := model_table[choice.model_id] or { ModelSpec{} }
	// an easy task must not be routed to an expensive model
	assert chosen.cost_in == 0.0, '${choice.model_id} cost ${chosen.cost_in}'
	assert choice.reason.contains('cheapest capable')
}

fn test_a_hard_task_escalates() {
	mut log, mut r := router_fixture('router-hard')
	defer {
		log.close()
	}
	hard := 'prove the theorem, derive the algorithm complexity, analyse the ' +
		'security vulnerability, diagnose the root cause and design the ' +
		'architecture trade-off ' + 'with more context '.repeat(40)
	choice := r.choose(hard, 4000, '')
	cap_chosen := (model_table[choice.model_id] or { ModelSpec{} }).capability
	easy := r.choose('hi', 1500, '')
	cap_easy := (model_table[easy.model_id] or { ModelSpec{} }).capability
	assert cap_chosen >= cap_easy, '${choice.model_id} vs ${easy.model_id}'
}

fn test_a_pinned_model_is_still_capability_checked() {
	mut log, mut r := router_fixture('router-pin')
	defer {
		log.close()
	}
	// a capable pin is honoured
	pinned := r.choose('say hello', 1500, 'claude-sonnet-4-5')
	assert pinned.model_id == 'claude-sonnet-4-5'
	assert pinned.reason.contains('pinned')

	// a pin that cannot do the job is escalated past, not obeyed
	tool_task := 'run the build and test the file, then grep and edit it'
	escaped := r.choose(tool_task, 1500, 'mimo-v2.5-free')
	assert escaped.model_id != 'mimo-v2.5-free', 'an incapable pin was obeyed'
}

fn test_a_model_without_tools_is_never_chosen_for_a_tool_task() {
	mut log, mut r := router_fixture('router-tools')
	defer {
		log.close()
	}
	choice := r.choose('run the build and test the file, grep and edit it', 1500, '')
	assert (model_table[choice.model_id] or { ModelSpec{} }).tools
}

fn test_an_empty_table_degrades_instead_of_failing() {
	mut log := new_event_log(tmp_log_path('router-empty.jsonl'), 'main', '')
	defer {
		log.close()
	}
	mut r := &Router{
		log:   log
		table: map[string]ModelSpec{}
	}
	choice := r.choose('anything', 1500, '')
	assert choice.model_id == strongest_model
	assert choice.escalated
	assert choice.reason.contains('no models in routing table')
}

fn test_every_decision_is_sealed_and_auditable() {
	mut log, mut r := router_fixture('router-seal')
	defer {
		log.close()
	}
	r.choose('say hello', 1500, '')
	r.choose('refactor the algorithm', 1500, '')
	decisions := fold(mut log, '').router_decisions
	assert decisions.len == 2
	assert jstr(decisions[0], 'model') != ''
	assert 'axes' in decisions[0]

	spent, ceiling := r.savings()
	assert ceiling >= spent, 'the ceiling must not undercut actual spend'
	assert r.format_report().contains('ROUTER')
}

fn test_routing_is_deterministic() {
	mut log, mut r := router_fixture('router-det')
	defer {
		log.close()
	}
	task := 'refactor the tokenizer and run the tests'
	a := r.choose(task, 1500, '').model_id
	b := r.choose(task, 1500, '').model_id
	assert a == b
}

// -- semantic memory ---------------------------------------------------------

fn sem_fixture(name string) (&EventLog, Hippocampus, &SemanticMemory) {
	mut log := new_event_log(tmp_log_path('${name}.jsonl'), 'main', '')
	return log, new_hippocampus(log), new_semantic_memory(log)
}

fn test_embedding_is_normalised_and_deterministic() {
	a := embed('the parser rewrites the tokenizer')
	b := embed('the parser rewrites the tokenizer')
	assert a == b
	// L2-normalised: self-similarity is 1
	assert math_abs(cosine(a, a) - 1.0) < 1e-9
	// an empty text embeds to nothing rather than crashing
	assert embed('').len == 0
	assert cosine(embed(''), a) == 0.0
}

fn test_recall_finds_meaning_not_recency() {
	mut log, mut hip, mut sem := sem_fixture('semantic')
	defer {
		log.close()
	}
	hip.record_episode(Episode{
		goal:     'fix the tokenizer so it handles unicode'
		approach: 'rewrote the scanner'
		outcome:  'success'
	}) or { panic(err) }
	hip.record_episode(Episode{
		goal:     'update the deployment pipeline credentials'
		approach: 'rotated the secrets'
		outcome:  'success'
	}) or { panic(err) }

	hits := sem.recall('unicode tokenizer scanner problem', 3, 0.10)
	assert hits.len >= 1
	assert hits[0].text.contains('tokenizer'), hits[0].text
	assert hits[0].similarity > 0.0
}

fn test_dead_ends_are_recalled_too() {
	mut log, mut hip, mut sem := sem_fixture('semantic-dead')
	defer {
		log.close()
	}
	hip.record_dead_end(DeadEnd{
		signature: 'regex-backtracking'
		reason:    'the regex approach hit catastrophic backtracking'
	}) or { panic(err) }
	hits := sem.recall('catastrophic backtracking regex', 3, 0.10)
	assert hits.len >= 1
	assert hits[0].kind == 'dead_end'
}

fn test_recall_block_injects_nothing_when_nothing_matches() {
	mut log, mut hip, mut sem := sem_fixture('semantic-empty')
	defer {
		log.close()
	}
	hip.record_episode(Episode{
		goal:     'fix the tokenizer'
		approach: 'rewrote it'
		outcome:  'success'
	}) or { panic(err) }
	assert sem.recall_block('completely unrelated pasta recipe', 3) == ''
	assert sem.recall_block('tokenizer', 3).contains('SEMANTIC RECALL')
}

fn test_reads_do_not_grow_the_log_without_bound() {
	mut log, mut hip, mut sem := sem_fixture('semantic-growth')
	defer {
		log.close()
	}
	hip.record_episode(Episode{
		goal:     'something'
		approach: 'somehow'
		outcome:  'success'
	}) or { panic(err) }

	sem.recall('anything', 3, 0.10)
	after_first := log.len()
	// repeated reads on an unchanged log must not reindex, or every read
	// would append an event, advance the head and force the next reindex
	for _ in 0 .. 5 {
		sem.recall('anything', 3, 0.10)
	}
	assert log.len() == after_first, 'reads grew the log'

	// an empty corpus is a valid indexed state, not a reason to reindex
	mut log2 := new_event_log(tmp_log_path('semantic-fresh.jsonl'), 'main', '')
	defer {
		log2.close()
	}
	mut sem2 := new_semantic_memory(log2)
	sem2.recall('anything', 3, 0.10)
	size := log2.len()
	sem2.recall('anything', 3, 0.10)
	sem2.recall('anything', 3, 0.10)
	assert log2.len() == size, 'an empty corpus kept reindexing'
}

fn test_index_is_a_pure_projection_of_the_log() {
	mut log, mut hip, mut sem := sem_fixture('semantic-project')
	defer {
		log.close()
	}
	hip.record_episode(Episode{
		goal:     'first job'
		approach: 'a'
		outcome:  'success'
	}) or { panic(err) }
	assert sem.reindex() == 1

	// a new episode appears in recall without any explicit reindex
	hip.record_episode(Episode{
		goal:     'second job about databases'
		approach: 'b'
		outcome:  'success'
	}) or { panic(err) }
	hits := sem.recall('databases', 3, 0.05)
	assert hits.len >= 1
	assert sem.stats().items == 2
	assert sem.stats().dim == semantic_dim
	assert (sem.stats().kinds['episode'] or { 0 }) == 2
	// the index event is sealed
	assert fold(mut log, '').semantic_index.len >= 1
	_ = json2.Any('')
}
