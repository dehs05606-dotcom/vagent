module vagent

import math
import os
import x.json2

// brain.v — a four-store cognitive memory with forgetting and sleep.
//
// The Hippocampus (memory.v) remembers everything forever. The Brain
// remembers the way an animal does:
//
//   working     this session's scratchpad — dies with the session
//   episodic    what happened, when — ingested from the kernel events
//   semantic    distilled facts, each with an importance and a strength
//   procedural  knowledge that proved repeatedly useful, promoted to skill
//
// Two mechanics do the work, and both are arithmetic — no tokens are spent
// deciding what to keep:
//
//   IMPORTANCE = base(kind) × recency × verification × access frequency
//   RETENTION  = exp(-Δt / S) with S = S0 × (1 + strength)
//
// Every recall is a REVIEW: strength grows, the curve flattens, the memory
// survives longer. That is spaced repetition, mechanically.
//
// sleep() is the consolidation pass. Near-duplicates merge, repeated
// episodes distil into one semantic fact, semantics that survived enough
// reviews promote to procedural skills, and whatever fell below the
// retention floor is forgotten — sealed as brain.forgotten, because
// forgetting is an event and never a silent loss.

pub const brain_stores = ['working', 'episodic', 'semantic', 'procedural']

// two days of baseline strength horizon
pub const brain_s0 = 3600.0 * 24.0 * 2.0
pub const retention_floor = 0.15
pub const review_boost = 1.6
pub const promote_threshold = 5
pub const merge_similarity = 0.72
pub const max_per_store = 512

fn base_importance(kind string) f64 {
	return match kind {
		'fact' { 0.8 }
		'lesson' { 0.7 }
		'episode' { 0.5 }
		'dead_end' { 0.9 }
		'skill' { 0.9 }
		'note' { 0.4 }
		else { 0.4 }
	}
}

// brain_tokens is the `[a-z0-9]+` split, lowercased. It is written out
// rather than run through the regex engine because recall calls it for every
// memory on every query.
pub fn brain_tokens(text string) []string {
	// a rune buffer, not a string: `cur += r.str()` reallocates on every
	// character and turns one long token into quadratic work
	mut out := []string{}
	mut cur := []rune{}
	for r in text.to_lower().runes() {
		if (r >= `a` && r <= `z`) || (r >= `0` && r <= `9`) {
			cur << r
			continue
		}
		if cur.len > 0 {
			out << cur.string()
			cur = []rune{}
		}
	}
	if cur.len > 0 {
		out << cur.string()
	}
	return uniq_strings(out)
}

pub fn jaccard(a string, b string) f64 {
	ta := brain_tokens(a)
	tb := brain_tokens(b)
	if ta.len == 0 || tb.len == 0 {
		return 0.0
	}
	mut inter := 0
	for t in ta {
		if t in tb {
			inter++
		}
	}
	union_size := ta.len + tb.len - inter
	return if union_size > 0 { f64(inter) / f64(union_size) } else { 0.0 }
}

@[heap]
pub struct Memory {
pub mut:
	id          string
	store       string
	text        string
	kind        string = 'note'
	created     f64
	last_review f64
	// grows with every review
	strength f64 = 1.0
	reviews  int
	// judge-proven facts weigh more
	verified bool
	tags     []string
}

// importance is what the memory is worth right now.
pub fn (m &Memory) importance() f64 {
	base := base_importance(m.kind)
	age := max_f64(0.0, now_ts() - m.created)
	// roughly halves each day
	recency := 1.0 / (1.0 + age / (3600.0 * 24.0))
	freq := 1.0 + 0.2 * f64(min_int(m.reviews, 10))
	boost := if m.verified { 1.25 } else { 1.0 }
	return base * recency * freq * boost
}

// retention is the Ebbinghaus curve: how much of this is still held.
pub fn (m &Memory) retention(now f64) f64 {
	delta := max_f64(0.0, now - m.last_review)
	return math.exp(-delta / (brain_s0 * (1.0 + m.strength)))
}

pub fn (m &Memory) retention_now() f64 {
	return m.retention(now_ts())
}

// review is what a recall does to a memory: it survives longer for having
// been needed.
pub fn (mut m Memory) review() {
	m.reviews++
	m.strength *= review_boost
	m.last_review = now_ts()
}

pub fn (m &Memory) to_json() map[string]json2.Any {
	return {
		'id':          json2.Any(m.id)
		'store':       json2.Any(m.store)
		'text':        json2.Any(m.text)
		'kind':        json2.Any(m.kind)
		'created':     json2.Any(m.created)
		'last_review': json2.Any(m.last_review)
		'strength':    json2.Any(m.strength)
		'reviews':     json2.Any(m.reviews)
		'verified':    json2.Any(m.verified)
		'tags':        json2.Any(m.tags.map(json2.Any(it)))
	}
}

pub fn memory_from_json(d map[string]json2.Any) &Memory {
	return &Memory{
		id:          jstr(d, 'id')
		store:       jstr(d, 'store')
		text:        jstr(d, 'text')
		kind:        if k := d['kind'] { k.str() } else { 'note' }
		created:     jf64_or(d, 'created', now_ts())
		last_review: jf64_or(d, 'last_review', now_ts())
		strength:    jf64_or(d, 'strength', 1.0)
		reviews:     jint(d, 'reviews')
		verified:    jbool(d, 'verified')
		tags:        jstrs(d, 'tags')
	}
}

@[heap]
pub struct Brain {
pub mut:
	log  &EventLog
	path string
	// id -> memory. The values are pointers because a recalled memory is
	// REVIEWED in place, and a caller holding one must see that.
	memories map[string]&Memory
	counter  int
}

pub fn new_brain(log &EventLog, path string) &Brain {
	mut b := &Brain{
		log:  unsafe { log }
		path: path
	}
	if path != '' {
		b.load()
	}
	return b
}

// -- persistence -------------------------------------------------------------

fn (mut b Brain) load() {
	content := read_text_or_empty(b.path)
	if content == '' {
		return
	}
	parsed := json2.decode[json2.Any](content) or { return }
	if parsed !is map[string]json2.Any {
		// valid JSON, wrong shape — start fresh rather than crash
		return
	}
	for entry in jarr(parsed.as_map(), 'memories') {
		if entry !is map[string]json2.Any {
			continue
		}
		m := memory_from_json(entry.as_map())
		if m.id == '' {
			continue
		}
		b.memories[m.id] = m
		n := m.id[1..].int()
		if n > b.counter {
			b.counter = n
		}
	}
}

// save is a convenience and never a crash path: a brain that cannot write
// its file still thinks.
fn (b &Brain) save() {
	if b.path == '' {
		return
	}
	mut out := []json2.Any{}
	for _, m in b.memories {
		out << json2.Any(m.to_json())
	}
	dir := os.dir(b.path)
	if dir != '' {
		os.mkdir_all(dir) or { return }
	}
	text := json2.encode(json2.Any({
		'memories': json2.Any(out)
	}),
		prettify:      true
		indent_string: ' '
	)
	atomic_write_text(b.path, text) or {}
}

// -- writes ------------------------------------------------------------------

// remember stores one memory. A near-duplicate in the same store REINFORCES
// what is already there instead of piling a second copy on top of it.
pub fn (mut b Brain) remember(text string, store string, kind string, verified bool, tags []string) !&Memory {
	t := text.trim_space()
	if t == '' {
		return error('cannot remember empty text')
	}
	if store !in brain_stores {
		return error('store must be one of ${brain_stores}')
	}
	mut merge_id := ''
	for _, m in b.memories {
		if m.store == store && jaccard(m.text, t) >= merge_similarity {
			merge_id = m.id
			break
		}
	}
	if merge_id != '' {
		mut hit := b.memories[merge_id] or { return error('vanished') }
		hit.review()
		hit.verified = hit.verified || verified
		b.log.append('brain.remembered', {
			'id':     json2.Any(hit.id)
			'store':  json2.Any(store)
			'merged': json2.Any(true)
		}, AppendOpts{})
		b.save()
		return hit
	}
	b.counter++
	now := now_ts()
	m := &Memory{
		id:          'm${b.counter}'
		store:       store
		text:        t
		kind:        kind
		created:     now
		last_review: now
		verified:    verified
		tags:        tags.clone()
	}
	b.memories[m.id] = m
	b.cap(store)
	b.log.append('brain.remembered', {
		'id':       json2.Any(m.id)
		'store':    json2.Any(store)
		'kind':     json2.Any(kind)
		'verified': json2.Any(verified)
		'chars':    json2.Any(t.len)
	}, AppendOpts{})
	b.save()
	return m
}

// ingest_kernel pulls episodic material out of the event log. It is
// idempotent: only events newer than the last consolidation marker are read,
// so calling it twice does not double the brain.
//
// The marker starts at 0 and the test is `seq <= marker`, which means the
// event at seq 0 is never ingested. That is the original's behaviour, kept:
// it only bites on a log whose very first event is already ingestible, and
// changing it would make a replayed log disagree with the Python agent that
// wrote it.
pub fn (mut b Brain) ingest_kernel() int {
	mut last := 0
	for ev in b.log.events(b.log.branch) {
		if ev.typ == 'brain.consolidated' {
			marker := jint(ev.data, 'brain_marker')
			if marker > last {
				last = marker
			}
		}
	}
	mut added := 0
	for ev in b.log.events(b.log.branch) {
		if ev.seq <= last {
			continue
		}
		match ev.typ {
			'fact.learned' {
				b.remember(clip_plain(jstr(ev.data, 'fact'), 400), 'semantic', 'fact', jstr(ev.data, 'kind') == 'goal', []) or { continue }
				added++
			}
			'deadend.recorded' {
				b.remember(clip_plain('dead end: ${jstr(ev.data, 'reason')}', 400), 'semantic', 'dead_end', false, []) or { continue }
				added++
			}
			'assistant.message' {
				text := jstr(ev.data, 'text')
				// substantive replies only — a one-word answer is not an episode
				if text.len > 120 {
					b.remember(clip_plain(text, 300), 'episodic', 'episode', false, []) or {
						continue
					}
					added++
				}
			}
			else {}
		}
	}
	return added
}

// -- reads -------------------------------------------------------------------

struct ScoredMemory {
	score f64
	mem   &Memory
}

// recall ranks by retention × importance × relevance, so only what the curve
// has kept alive can surface at all. Whatever surfaces is reviewed.
pub fn (mut b Brain) recall(query string, k int, store string) []&Memory {
	q := brain_tokens(query)
	mut scored := []ScoredMemory{}
	for _, m in b.memories {
		if store != '' && m.store != store {
			continue
		}
		t := brain_tokens(m.text)
		mut overlap := 0
		for tok in q {
			if tok in t {
				overlap++
			}
		}
		relevance := if q.len > 0 { f64(overlap) / f64(q.len + 1) } else { 0.0 }
		scored << ScoredMemory{
			score: m.retention_now() * m.importance() * (0.25 + relevance)
			mem:   m
		}
	}
	scored.sort(a.score > b.score)
	limit := min_int(max_int(0, k), scored.len)
	mut top := []&Memory{}
	for i in 0 .. limit {
		top << scored[i].mem
	}
	for mut m in top {
		m.review()
	}
	if top.len > 0 {
		b.log.append('brain.recalled', {
			'query': json2.Any(clip_plain(query, 200))
			'ids':   json2.Any(top.map(json2.Any(it.id)))
		}, AppendOpts{})
		b.save()
	}
	return top
}

// context_block is the compact recall the model sees.
pub fn (mut b Brain) context_block(query string, k int) string {
	q := if query != '' { query } else { 'current work' }
	mems := b.recall(q, k, '')
	if mems.len == 0 {
		return ''
	}
	mut lines := ['MEMORY (${mems.len} recalled, ranked by the forgetting curve):']
	for m in mems {
		v := if m.verified { ' ✓verified' } else { '' }
		lines << '- [${m.kind}${v}] ${clip_plain(m.text, 200)}'
	}
	return lines.join('\n')
}

// -- sleep -------------------------------------------------------------------

pub struct SleepStats {
pub mut:
	merged    int
	distilled int
	promoted  int
	forgotten int
}

// sleep is the consolidation pass: forget, merge, distil, promote.
pub fn (mut b Brain) sleep() SleepStats {
	now := now_ts()
	mut stats := SleepStats{}

	// 1. forget what the curve has killed. A memory that was never recalled
	// is the only kind that can go: being needed once buys it a reprieve.
	mut dead := []&Memory{}
	for _, m in b.memories {
		if m.retention(now) < retention_floor && m.reviews == 0 {
			dead << m
		}
	}
	for m in dead {
		b.memories.delete(m.id)
		stats.forgotten++
		b.log.append('brain.forgotten', {
			'id':    json2.Any(m.id)
			'store': json2.Any(m.store)
			'text':  json2.Any(clip_plain(m.text, 200))
		}, AppendOpts{})
	}

	// 2. merge near-duplicates within each store, keeping the stronger
	for store in brain_stores {
		mut items := []&Memory{}
		for _, m in b.memories {
			if m.store == store {
				items << m
			}
		}
		items.sort(a.strength > b.strength)
		mut kept := []&Memory{}
		for m in items {
			mut dup := false
			for k in kept {
				if jaccard(m.text, k.text) >= merge_similarity {
					dup = true
					break
				}
			}
			if dup {
				b.memories.delete(m.id)
				stats.merged++
				continue
			}
			kept << m
		}
	}

	// 3. distil: a theme running through three or more distinct episodes
	// becomes one semantic fact
	mut episodes := []&Memory{}
	for _, m in b.memories {
		if m.store == 'episodic' {
			episodes << m
		}
	}
	mut seen := map[string]int{}
	for m in episodes {
		for tag in theme_tags(m) {
			seen[tag] = seen[tag] + 1
		}
	}
	for tag, n in seen {
		if n < 3 {
			continue
		}
		mut siblings := []&Memory{}
		for m in episodes {
			if tag in theme_tags(m) {
				siblings << m
			}
		}
		if siblings.len == 0 {
			continue
		}
		digest := clip_plain(siblings[0].text, 160)
		// compare against the DIGEST, not the decorated text: a distilled
		// fact reads "[distilled from N episodes] <digest>", and matching on
		// the whole string would never fire, so every sleep would distil the
		// same theme again
		mut exists := false
		for _, m in b.memories {
			if m.store == 'semantic' && m.text.contains(digest) {
				exists = true
				break
			}
		}
		if exists {
			continue
		}
		b.counter++
		fact := &Memory{
			id:          'm${b.counter}'
			store:       'semantic'
			text:        '[distilled from ${n} episodes] ${digest}'
			kind:        'fact'
			created:     now
			last_review: now
			strength:    2.0
			reviews:     n
		}
		b.memories[fact.id] = fact
		stats.distilled++
	}

	// 4. promote: semantics that proved useful often enough become skills
	for _, mut m in b.memories {
		if m.store == 'semantic' && m.reviews >= promote_threshold {
			m.store = 'procedural'
			m.kind = 'skill'
			stats.promoted++
		}
	}

	b.cap_all()
	b.log.append('brain.consolidated', {
		'merged':       json2.Any(stats.merged)
		'distilled':    json2.Any(stats.distilled)
		'promoted':     json2.Any(stats.promoted)
		'forgotten':    json2.Any(stats.forgotten)
		'brain_marker': json2.Any(b.log.head(b.log.branch))
		'remaining':    json2.Any(b.memories.len)
	}, AppendOpts{})
	b.save()
	return stats
}

// theme_tags are a memory's own tags, or the crude signature the
// distillation falls back to: its longest few tokens.
fn theme_tags(m &Memory) []string {
	if m.tags.len > 0 {
		return m.tags
	}
	mut toks := brain_tokens(m.text)
	toks.sort(a.len > b.len)
	return toks[..min_int(3, toks.len)].clone()
}

fn (mut b Brain) cap(store string) {
	mut items := []&Memory{}
	for _, m in b.memories {
		if m.store == store {
			items << m
		}
	}
	if items.len <= max_per_store {
		return
	}
	// keep the memories worth the most: retention times importance
	mut ranked := []ScoredMemory{}
	for m in items {
		ranked << ScoredMemory{
			score: m.retention_now() * m.importance()
			mem:   m
		}
	}
	ranked.sort(a.score > b.score)
	for r in ranked[max_per_store..] {
		b.memories.delete(r.mem.id)
	}
}

fn (mut b Brain) cap_all() {
	for store in brain_stores {
		b.cap(store)
	}
}

// -- reporting ---------------------------------------------------------------

pub struct BrainStats {
pub:
	total         int
	by_store      map[string]int
	alive         int
	avg_retention f64
}

pub fn (b &Brain) stats() BrainStats {
	mut by_store := map[string]int{}
	for s in brain_stores {
		by_store[s] = 0
	}
	mut alive := 0
	mut total_retention := 0.0
	now := now_ts()
	for _, m in b.memories {
		by_store[m.store] = by_store[m.store] + 1
		r := m.retention(now)
		total_retention += r
		if r >= retention_floor {
			alive++
		}
	}
	return BrainStats{
		total:         b.memories.len
		by_store:      by_store.clone()
		alive:         alive
		avg_retention: round_to(total_retention / f64(max_int(1, b.memories.len)), 3)
	}
}

pub fn (b &Brain) format_stats() string {
	s := b.stats()
	return 'BRAIN — ${s.total} memories (${s.alive} above the retention floor)\n' + '  working    ${s.by_store['working']}\n' + '  episodic   ${s.by_store['episodic']}\n' + '  semantic   ${s.by_store['semantic']}\n' + '  procedural ${s.by_store['procedural']}\n' + '  avg retention ${s.avg_retention}'
}
