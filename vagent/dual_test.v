module vagent

__global (
	dual_calls_fast int
	dual_calls_slow int
)

fn dual_fast(q string) string {
	dual_calls_fast++
	if q.contains('weather') {
		return 'It is sunny, 24°C.'
	}
	return 'maybe I think it could be something, not sure'
}

fn dual_slow(q string) string {
	dual_calls_slow++
	return 'Verified deep answer.'
}

fn new_dual(name string) &DualProcess {
	dual_calls_fast = 0
	dual_calls_slow = 0
	return new_dual_process(new_event_log(tmp_log_path(name), 'main', 'test'), dual_fast,
		dual_slow, unsafe { nil }, escalate_bar)
}

fn test_a_clean_fast_answer_stays_on_system_one_and_is_cached() {
	mut d := new_dual('dual1')
	r1 := d.ask('what is the weather today?')
	assert r1.system == 1, r1.why
	assert r1.answer.contains('sunny')
	assert !r1.cached

	// the same question again costs no model call at all
	r2 := d.ask('what is the weather today?')
	assert r2.system == 1
	assert r2.cached
	assert dual_calls_fast == 1
	assert d.stats.cache_hits == 1
}

fn test_a_hedged_answer_on_a_complex_question_escalates() {
	mut d := new_dual('dual2')
	r := d.ask('compare the two architectures; which one and why?')
	assert r.system == 2
	assert r.answer.contains('Verified deep')
	assert d.stats.escalations == 1
	assert r.why.contains('escalated')

	// the escalated answer is cached with deep provenance, so the repeat
	// clears the bar that the fast path could not
	r2 := d.ask('compare the two architectures; which one and why?')
	assert r2.system == 1
	assert r2.cached
	assert r2.answer.contains('Verified deep')
	assert dual_calls_slow == 1
}

fn test_complexity_alone_can_push_a_question_over_the_bar() {
	mut d := new_dual('dual3')
	r := d.ask('derive step by step; prove it; why? how come?')
	assert r.system == 2
}

fn test_novelty_from_the_brain_pushes_confidence_down() {
	mut brain_log := new_event_log(tmp_log_path('dual4b'), 'main', 'test')
	mut brain := new_brain(brain_log, '')
	brain.remember('the weather service lives behind the sunny gateway today', 'semantic',
		'fact', true, []) or { panic(err) }
	mut d := new_dual_process(new_event_log(tmp_log_path('dual4'), 'main', 'test'), dual_fast,
		dual_slow, brain, escalate_bar)
	dual_calls_fast = 0
	dual_calls_slow = 0

	// a clean answer in a familiar domain survives
	assert d.ask('what is the weather today?').system == 1
	// a hedged answer in a novel one escalates
	assert d.ask('explain the quantum trade-off maybe?').system == 2
}

fn test_an_empty_question_is_clean() {
	mut d := new_dual('dual5')
	r := d.ask('   ')
	assert r.confidence == 0.0
	assert r.system == 1
	assert r.answer == ''
	assert dual_calls_fast == 0
}

fn test_a_stale_cache_entry_loses_confidence() {
	mut d := new_dual('dual6')
	d.ask('what is the weather today?')
	// age it by three days: the decay is capped at 0.25, which is enough to
	// drop a 0.75 fast answer under the bar
	key := 'what is the weather today?'
	mut e := d.cache[key] or { panic('not cached') }
	e.sealed_at -= 3.0 * 86400.0
	d.cache[key] = e
	r := d.ask('what is the weather today?')
	assert !r.cached
	assert dual_calls_fast == 2
}

fn test_the_cache_is_capped_so_a_nonce_flood_cannot_grow_it() {
	mut d := new_dual('dual7')
	for i in 0 .. dual_cache_max + 50 {
		d.ask('what is the weather today ${i}?')
	}
	assert d.cache.len == dual_cache_max
	assert d.order.len == dual_cache_max
	// the oldest questions were the ones evicted
	assert 'what is the weather today 0?' !in d.cache
	assert 'what is the weather today ${dual_cache_max + 49}?' in d.cache
}

fn test_the_signal_counters_match_the_patterns() {
	assert count_matches(hedge_pattern, 'maybe I think, not sure') == 3
	assert count_matches(hedge_pattern, 'a definite answer') == 0
	assert count_matches(hedge_pattern, '') == 0
	assert count_matches(complexity_pattern, 'why? compare; prove') == 5
	// case does not matter
	assert count_matches(hedge_pattern, 'MAYBE') == 1
}

fn test_the_stats_render() {
	mut d := new_dual('dual8')
	d.ask('what is the weather today?')
	d.ask('compare the two architectures; which one and why?')
	text := d.format_stats()
	assert text.contains('DUAL PROCESS')
	assert text.contains('system1 1')
	assert text.contains('system2 1')
	assert text.contains('bar: 0.62')
}

fn test_both_routes_are_sealed_in_the_log() {
	mut log := new_event_log(tmp_log_path('dual9'), 'main', 'test')
	mut d := new_dual_process(log, dual_fast, dual_slow, unsafe { nil }, escalate_bar)
	d.ask('what is the weather today?')
	d.ask('compare the two architectures; which one and why?')
	kinds := log.events('main').map(it.typ)
	assert 'dual.route' in kinds
	assert 'dual.escalation' in kinds
}
