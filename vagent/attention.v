module vagent

import x.json2

// attention.v — the attention economy: context sections compete for tokens.
//
// Free context is why agents bloat: every subsystem piles its text in "just
// in case". Here, every context section PAYS for its tokens in an auction,
// every turn:
//
//     bid         each section's value is computed mechanically:
//                 relevance (token overlap with the current request) ×
//                 recency (fresh sections beat stale ones) × source
//                 priority (goal > constitution > memory > web — the
//                 constitution always wins ties) — normalized to [0, 1]
//     allocate    the char budget distributes proportionally to bids, under
//                 two constraints: every section keeps a FLOOR (never
//                 starved to zero — a silent context is a lie) and no
//                 section exceeds a CEILING (no monopolist). When the budget
//                 cannot cover the floors, the floors win and the
//                 over-budget is reported honestly.
//     enforce     sections are trimmed (head+tail) to their allocation with
//                 a visible [...trimmed by the attention auction] marker —
//                 the model KNOWS what it did not get
//
// Every auction is sealed (attention.auction) with the full allocation
// table — the economics of attention are auditable, per turn.

// source_priority: constitutional documents outrank ephemera.
const source_priority = {
	'goal':         1.30
	'constitution': 1.25
	'memory':       1.0
	'brain':        0.95
	'web':          0.85
	'compacted':    0.6
}

const floor_frac = 0.06 // each section's minimum share of budget
const ceil_frac = 0.45 // no section may take more than this
const keep_head = 0.6 // when trimming: keep 60% head, 40% tail

// attention_tokens splits text into lowercase alphanumeric runs.
fn attention_tokens(text string) map[string]bool {
	// a byte buffer, not a string: appending to a string reallocates it
	// each time, which is quadratic in the length of one token
	mut out := map[string]bool{}
	mut cur := []u8{}
	for i := 0; i <= text.len; i++ {
		c := if i < text.len { text[i] } else { u8(` `) }
		if (c >= `a` && c <= `z`) || (c >= `0` && c <= `9`) {
			cur << c
			continue
		}
		if c >= `A` && c <= `Z` {
			cur << c + 32
			continue
		}
		if cur.len > 0 {
			out[cur.bytestr()] = true
			cur = []u8{}
		}
	}
	return out
}

pub struct Allocation {
pub:
	section string
	chars   int
	limit   int
	bid     f64
	trimmed bool
}

pub fn (a &Allocation) to_json() map[string]json2.Any {
	return {
		'section': json2.Any(a.section)
		'chars':   json2.Any(a.chars)
		'limit':   json2.Any(a.limit)
		'bid':     json2.Any(f64(int(a.bid * 1000.0 + 0.5)) / 1000.0)
		'trimmed': json2.Any(a.trimmed)
	}
}

pub struct AuctionResult {
pub mut:
	budget      int
	used        int
	allocations []Allocation
}

pub fn (r &AuctionResult) to_json() map[string]json2.Any {
	return {
		'budget':      json2.Any(r.budget)
		'used':        json2.Any(r.used)
		'allocations': json2.Any(r.allocations.map(json2.Any(it.to_json())))
	}
}

// AttentionEconomy is a proportional-share auction over context sections.
@[heap]
pub struct AttentionEconomy {
pub mut:
	log          &EventLog
	budget_chars int = 12_000
	last         AuctionResult
	has_last     bool
}

pub fn new_attention_economy(log &EventLog, budget_chars int) &AttentionEconomy {
	return &AttentionEconomy{
		log:          unsafe { log }
		budget_chars: if budget_chars > 0 { budget_chars } else { 12_000 }
	}
}

// -- bids --------------------------------------------------------------------

// bid is the mechanical value of one section for this turn. `fresh_ts` of 0
// means "no age is known", which leaves recency neutral.
pub fn (e &AttentionEconomy) bid(section string, text string, query string, fresh_ts f64) f64 {
	mut relevance := 0.0
	q := attention_tokens(query)
	if q.len > 0 {
		t := attention_tokens(text)
		mut overlap := 0
		for k, _ in q {
			if k in t {
				overlap++
			}
		}
		relevance = f64(overlap) / f64(q.len + 2)
	}
	mut recency := 1.0
	if fresh_ts > 0 {
		mut age_h := (now_ts() - fresh_ts) / 3600.0
		if age_h < 0 {
			age_h = 0
		}
		recency = 1.0 / (1.0 + age_h / 24.0) // halves per ~day
	}
	priority := source_priority[section] or { 0.9 }
	mut v := (0.25 + 0.75 * relevance) * recency * priority
	if v < 0.0 {
		v = 0.0
	}
	if v > 1.0 {
		v = 1.0
	}
	return v
}

// -- the auction ---------------------------------------------------------------

// allocate runs the auction and returns the allocations; enforce() applies
// them to the section texts.
pub fn (mut e AttentionEconomy) allocate(sections map[string]string, query string, fresh map[string]f64) AuctionResult {
	budget := e.budget_chars
	mut names := []string{}
	for s, text in sections {
		if text.trim_space() != '' {
			names << s
		}
	}
	names.sort()
	mut result := AuctionResult{
		budget: budget
	}
	if names.len == 0 {
		e.last = result
		e.has_last = true
		return result
	}

	mut bids := map[string]f64{}
	for s in names {
		bids[s] = e.bid(s, sections[s] or { '' }, query, fresh[s] or { 0.0 })
	}
	floor := int(f64(budget) * floor_frac)
	ceil_limit := int(f64(budget) * ceil_frac)

	// proportional share, clamped to [floor, ceil]; iterate the surplus back
	// to unclamped sections (water-filling): a section pinned at its ceiling
	// frees its excess for the next round until nobody new clamps
	mut limits := map[string]int{}
	mut fixed := map[string]bool{}
	for _ in 0 .. 6 { // converges fast
		mut pinned_total := 0
		for s, _ in fixed {
			pinned_total += limits[s] or { 0 }
		}
		mut pool := names.filter(it !in fixed)
		mut pool_bid := 0.0
		for s in pool {
			pool_bid += bids[s] or { 0.0 }
		}
		if pool_bid == 0.0 {
			pool_bid = 1.0
		}
		avail := budget - pinned_total
		mut changed := false
		for s in pool {
			want := int(f64(avail) * (bids[s] or { 0.0 }) / pool_bid)
			if want >= ceil_limit {
				limits[s] = ceil_limit
				fixed[s] = true
				changed = true
			} else {
				mut v := want
				if v < floor {
					v = floor
				}
				if v > ceil_limit {
					v = ceil_limit
				}
				limits[s] = v
			}
		}
		if !changed {
			break
		}
	}

	// floors may have pushed the total over budget — shave the largest
	// allocations back down toward their floor
	mut total := 0
	for _, v in limits {
		total += v
	}
	mut over := total - budget
	mut by_size := limits.keys()
	by_size.sort_with_compare(fn [limits] (a &string, b &string) int {
		av := limits[*a] or { 0 }
		bv := limits[*b] or { 0 }
		return bv - av
	})
	for s in by_size {
		if over <= 0 {
			break
		}
		cur := limits[s] or { 0 }
		mut shave := cur - floor
		if shave > over {
			shave = over
		}
		if shave > 0 {
			limits[s] = cur - shave
			over -= shave
		}
	}

	for s in names {
		text := sections[s] or { '' }
		limit := limits[s] or { floor }
		result.allocations << Allocation{
			section: s
			chars:   if text.len < limit { text.len } else { limit }
			limit:   limit
			bid:     bids[s] or { 0.0 }
			trimmed: text.len > limit
		}
	}
	mut used := 0
	for a in result.allocations {
		used += a.chars
	}
	result.used = used
	e.last = result
	e.has_last = true
	e.log.append('attention.auction', result.to_json(), AppendOpts{ actor: 'kernel' })
	return result
}

// -- enforcement ---------------------------------------------------------------

// enforce applies the allocations: every over-budget section is trimmed,
// visibly — the model sees what was cut and why.
pub fn (e &AttentionEconomy) enforce(sections map[string]string, result AuctionResult) map[string]string {
	mut limits := map[string]int{}
	for a in result.allocations {
		limits[a.section] = a.limit
	}
	mut out := map[string]string{}
	for name, text in sections {
		limit := limits[name] or { text.len }
		if text.len <= limit {
			out[name] = text
			continue
		}
		// a zero or negative limit means EVERYTHING is cut; slicing a tail
		// of zero would otherwise hand back the whole body
		if limit <= 0 {
			out[name] = '\n[…trimmed by the attention auction — ' + '${thousands(text.len)} chars wanted, 0 allocated]'
			continue
		}
		head := int(f64(limit) * keep_head)
		tail := limit - head
		mut trimmed := text[..head]
		if tail > 0 {
			trimmed += '\n…\n' + text[text.len - tail..]
		}
		out[name] = trimmed + '\n[…trimmed by the attention auction — ' + '${thousands(text.len)} chars wanted, ${thousands(limit)} allocated]'
	}
	return out
}

pub fn (e &AttentionEconomy) format_last() string {
	if !e.has_last {
		return 'no auction has run yet'
	}
	r := e.last
	mut lines := ['ATTENTION AUCTION — budget ${thousands(r.budget)} chars, ' + 'used ${thousands(r.used)}']
	for a in r.allocations {
		mut width := int(f64(a.limit) / f64(r.budget) * 20.0)
		if width < 1 {
			width = 1
		}
		cut := if a.trimmed { ' ✂' } else { '' }
		lines << '  ${pad_right(a.section, 14)} bid ${a.bid:.2f} → ' + '${thousands(a.limit)}${cut} ${'█'.repeat(width)}'
	}
	return lines.join('\n')
}
