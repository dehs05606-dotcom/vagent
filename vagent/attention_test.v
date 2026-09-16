module vagent

fn att_fixture(name string, budget int) (&EventLog, &AttentionEconomy) {
	mut log := new_event_log(tmp_log_path('${name}.jsonl'), 'main', '')
	return log, new_attention_economy(log, budget)
}

fn att_sections() map[string]string {
	return {
		'goal':         'ship the parser v2 with property tests and docs covering the tokenizer rewrite'
		'constitution': 'standing rules that barely change at all and are mostly always the same words here'
		'memory':       'unrelated pasta recipes and old notes about a printer'
		'web':          'live cricket scores and weather for a city somewhere'
	}
}

fn by_section(r AuctionResult) map[string]Allocation {
	mut m := map[string]Allocation{}
	for a in r.allocations {
		m[a.section] = a
	}
	return m
}

fn test_relevance_decides_the_share() {
	mut log, mut eco := att_fixture('attention', 10_000)
	defer {
		log.close()
	}
	sections := att_sections()
	result := eco.allocate(sections, 'ship the parser v2 tokenizer rewrite',
		map[string]f64{})
	by := by_section(result)
	assert (by['goal'] or { Allocation{} }).limit > (by['web'] or { Allocation{} }).limit
	assert (by['memory'] or { Allocation{} }).limit > (by['web'] or { Allocation{} }).limit
}

fn test_floors_and_ceilings_hold() {
	mut log, mut eco := att_fixture('attention-bounds', 10_000)
	defer {
		log.close()
	}
	result := eco.allocate(att_sections(), 'parser', map[string]f64{})
	floor := int(10_000.0 * floor_frac)
	ceil_limit := int(10_000.0 * ceil_frac)
	for a in result.allocations {
		// nothing starves — a silent context is a lie
		assert a.limit >= floor, '${a.section} starved to ${a.limit}'
		// and no monopolist
		assert a.limit <= ceil_limit, '${a.section} took ${a.limit}'
	}
	assert result.used <= 10_000
}

fn test_enforcement_trims_visibly() {
	mut log, mut eco := att_fixture('attention-trim', 10_000)
	defer {
		log.close()
	}
	mut fat := att_sections()
	fat['goal'] = 'ship the parser v2. '.repeat(2000) // ~40k chars
	big := eco.allocate(fat, 'parser v2', map[string]f64{})
	enforced := eco.enforce(fat, big)

	// the model KNOWS what it did not get
	assert (enforced['goal'] or { '' }).contains('attention auction')
	goal_limit := (by_section(big)['goal'] or { Allocation{} }).limit
	assert (enforced['goal'] or { '' }).len <= goal_limit + 200

	// a section that fits passes through untouched
	assert (enforced['web'] or { '' }) == (fat['web'] or { 'x' })
}

fn test_a_zero_allocation_cuts_everything() {
	mut log, mut eco := att_fixture('attention-zero', 100)
	defer {
		log.close()
	}
	sections := {
		'memory': 'x'.repeat(500)
	}
	// a zero limit must not hand back the whole body through a zero-length
	// tail slice
	result := AuctionResult{
		budget:      100
		allocations: [Allocation{
			section: 'memory'
			limit:   0
			trimmed: true
		}]
	}
	out := eco.enforce(sections, result)
	assert (out['memory'] or { '' }).contains('0 allocated')
	assert (out['memory'] or { 'x'.repeat(500) }).len < 200
}

fn test_recency_beats_staleness() {
	mut log, mut eco := att_fixture('attention-recency', 10_000)
	defer {
		log.close()
	}
	now := now_ts()
	fresh_bid := eco.bid('memory', 'parser notes', 'parser', now)
	stale_bid := eco.bid('memory', 'parser notes', 'parser', now - 7.0 * 86400.0)
	assert stale_bid < fresh_bid
	// with no timestamp at all, recency is neutral rather than penalising
	assert eco.bid('memory', 'parser notes', 'parser', 0) >= fresh_bid
}

fn test_source_priority_breaks_ties() {
	mut log, mut eco := att_fixture('attention-priority', 10_000)
	defer {
		log.close()
	}
	// identical text and query: only the source priority separates them
	text := 'the same words entirely'
	assert eco.bid('goal', text, 'same words', 0) > eco.bid('web', text, 'same words', 0)
	assert eco.bid('constitution', text, 'same words', 0) > eco.bid('memory', text,
		'same words', 0)
}

fn test_empty_input_is_clean_and_every_auction_is_sealed() {
	mut log, mut eco := att_fixture('attention-empty', 10_000)
	defer {
		log.close()
	}
	assert eco.allocate(map[string]string{}, '', map[string]f64{}).allocations.len == 0
	// a blank section is dropped rather than given a floor
	only_blank := eco.allocate({
		'memory': '   '
	}, 'x', map[string]f64{})
	assert only_blank.allocations.len == 0

	eco.allocate(att_sections(), 'parser', map[string]f64{})
	eco.allocate(att_sections(), 'parser', map[string]f64{})
	mut sealed := 0
	for e in log.events('') {
		if e.typ == 'attention.auction' {
			sealed++
		}
	}
	assert sealed >= 2
	assert eco.format_last().contains('ATTENTION AUCTION')
}
