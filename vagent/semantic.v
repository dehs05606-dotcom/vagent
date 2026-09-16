module vagent

import crypto.sha256
import math
import x.json2

// semantic.v — Semantic memory, Hippocampus 2.0 (meaning-based recall).
//
// The Hippocampus (memory.v) recalls by recency: the last N episodes. This
// module adds recall by MEANING: every episode, fact and dead-end is
// embedded into a vector, and a query retrieves whatever is semantically
// closest — "how did we solve a similar problem before?"
//
// Design (stdlib only — no model calls):
//   * Embedding = feature hashing. Tokens are hashed into a fixed-width
//     sparse vector (signed hashing so collisions cancel instead of always
//     adding), L2-normalised. Deterministic, free, and good enough for
//     nearest-neighbour recall over a few hundred records.
//   * Similarity = cosine over the sparse vectors.
//   * The corpus is ALWAYS rebuilt from the event-log fold — no separate
//     state to drift. Indexing seals a 'semantic.indexed' event so recall
//     quality is auditable.

pub const semantic_dim = 256 // feature-hash width — plenty for a session corpus

const semantic_stop = ['a', 'an', 'the', 'and', 'or', 'of', 'to', 'in', 'for',
	'is', 'are', 'was', 'were', 'be', 'been', 'this', 'that', 'with', 'on',
	'at', 'by', 'from', 'as', 'it', 'its']

// ---------------------------------------------------------------------------
// Embedding — signed feature hashing
// ---------------------------------------------------------------------------

// token_hash maps a token to (bucket, sign) via sha256 — collision-tolerant.
fn token_hash(token string) (int, f64) {
	h := sha256.sum(token.bytes())
	bucket := (int(h[0]) << 8 | int(h[1])) % semantic_dim
	sign := if h[2] & 1 == 1 { 1.0 } else { -1.0 }
	return bucket, sign
}

fn semantic_tokens(text string) []string {
	mut out := []string{}
	mut cur := ''
	for i := 0; i <= text.len; i++ {
		c := if i < text.len { text[i] } else { u8(` `) }
		if (c >= `a` && c <= `z`) || (c >= `0` && c <= `9`) || c == `_` {
			cur += c.ascii_str()
			continue
		}
		if c >= `A` && c <= `Z` {
			cur += (c + 32).ascii_str()
			continue
		}
		if cur.len > 1 && cur !in semantic_stop {
			out << cur
		}
		cur = ''
	}
	return out
}

// embed returns a sparse L2-normalised vector for a text (bucket -> weight).
//
// Unigrams plus bigrams, stop-words dropped, signed feature hashing so hash
// collisions partially cancel instead of always adding.
pub fn embed(text string) map[int]f64 {
	tokens := semantic_tokens(text)
	mut grams := tokens.clone()
	for i in 1 .. tokens.len {
		grams << '${tokens[i - 1]}_${tokens[i]}'
	}
	mut vec := map[int]f64{}
	for g in grams {
		bucket, sign := token_hash(g)
		vec[bucket] = (vec[bucket] or { 0.0 }) + sign
	}
	mut sum := 0.0
	for _, v in vec {
		sum += v * v
	}
	norm := math.sqrt(sum)
	if norm > 0 {
		for k, v in vec {
			vec[k] = v / norm
		}
	}
	return vec
}

// cosine is the similarity of two sparse vectors (both pre-normalised).
pub fn cosine(a map[int]f64, b map[int]f64) f64 {
	// iterate the shorter side and probe the longer one; swapping the maps
	// would mean copying them, which this is called far too often to afford
	mut total := 0.0
	if a.len <= b.len {
		for k, v in a {
			total += v * (b[k] or { 0.0 })
		}
	} else {
		for k, v in b {
			total += v * (a[k] or { 0.0 })
		}
	}
	return total
}

// ---------------------------------------------------------------------------
// Corpus records
// ---------------------------------------------------------------------------

pub struct MemoryItem {
pub:
	kind    string // episode | fact | dead_end
	text    string // the searchable rendering of the record
	payload Rec    // the original record from the fold
pub mut:
	vector map[int]f64
}

fn episode_text(ep Rec) string {
	mut parts := [jstr(ep, 'goal'), jstr(ep, 'approach'), jstr(ep, 'outcome'),
		jstr(ep, 'lesson')]
	parts << jstrs(ep, 'facts')
	return parts.filter(it != '').join(' ')
}

pub struct RecallHit {
pub:
	kind       string
	similarity f64
	text       string
	payload    Rec
}

// ---------------------------------------------------------------------------
// SemanticMemory
// ---------------------------------------------------------------------------

// SemanticMemory is meaning-based recall over the episodic corpus. The index
// is a pure projection of the event log — rebuild it any time, it cannot
// drift.
@[heap]
pub struct SemanticMemory {
pub mut:
	log   &EventLog
	items []MemoryItem
mut:
	// the log head at the last reindex
	indexed_head int = -1
}

pub fn new_semantic_memory(log &EventLog) &SemanticMemory {
	return &SemanticMemory{
		log: unsafe { log }
	}
}

// reindex rebuilds the whole index from the fold and returns the item count.
pub fn (mut s SemanticMemory) reindex() int {
	st := fold(mut s.log, '')
	mut items := []MemoryItem{}
	for ep in st.episodes {
		text := episode_text(ep)
		if text.trim_space() != '' {
			items << MemoryItem{
				kind:    'episode'
				text:    text
				payload: ep
				vector:  embed(text)
			}
		}
	}
	for f in st.facts {
		text := jstr(f, 'fact')
		if text.trim_space() != '' {
			items << MemoryItem{
				kind:    'fact'
				text:    text
				payload: f
				vector:  embed(text)
			}
		}
	}
	for d in st.dead_ends {
		text := '${jstr(d, "signature")} ${jstr(d, "reason")}'
		if text.trim_space() != '' {
			items << MemoryItem{
				kind:    'dead_end'
				text:    text
				payload: d
				vector:  embed(text)
			}
		}
	}
	s.items = items
	s.log.append('semantic.indexed', {
		'items': json2.Any(items.len)
	}, AppendOpts{ actor: 'librarian' })
	// capture the head AFTER the index event is sealed, so ensure_fresh does
	// not immediately reindex on its own append
	s.indexed_head = s.log.head('')
	return items.len
}

// ensure_fresh reindexes if the log has grown since the last index, so
// recall always sees the current corpus (the index is a pure projection).
//
// The emptiness of `items` must NOT trigger a reindex — an empty corpus IS a
// valid indexed state, and re-checking it here made every read on a fresh
// session append a new semantic.indexed event, which advanced the head and
// guaranteed yet another reindex next turn: unbounded log growth from reads
// alone.
fn (mut s SemanticMemory) ensure_fresh() {
	if s.log.head('') != s.indexed_head {
		s.reindex()
	}
}

// recall returns the k corpus items closest in meaning to the query, sorted
// by similarity. Dead-ends are included — remembering what FAILED is recall
// too.
pub fn (mut s SemanticMemory) recall(query string, k int, min_similarity f64) []RecallHit {
	s.ensure_fresh()
	qv := embed(query)
	mut scored := []RecallHit{}
	for it in s.items {
		scored << RecallHit{
			kind:       it.kind
			similarity: cosine(qv, it.vector)
			text:       it.text
			payload:    it.payload
		}
	}
	scored.sort_with_compare(fn (a &RecallHit, b &RecallHit) int {
		if a.similarity > b.similarity {
			return -1
		}
		if a.similarity < b.similarity {
			return 1
		}
		if a.kind != b.kind {
			return compare_strings(a.kind, b.kind)
		}
		return compare_strings(a.text, b.text)
	})
	mut out := []RecallHit{}
	for hit in scored {
		if out.len >= k {
			break
		}
		if hit.similarity < min_similarity {
			break
		}
		out << RecallHit{
			kind:       hit.kind
			similarity: f64(int(hit.similarity * 1000.0 + 0.5)) / 1000.0
			text:       clip_plain(hit.text, 300)
			payload:    hit.payload
		}
	}
	return out
}

// recall_block is a prompt-injectable rendering of a recall — an empty
// string when nothing is similar enough, so noise is never injected.
pub fn (mut s SemanticMemory) recall_block(query string, k int) string {
	hits := s.recall(query, k, 0.10)
	if hits.len == 0 {
		return ''
	}
	mut lines := ['SEMANTIC RECALL for: ${clip_plain(query, 80)}']
	for h in hits {
		lines << '- [${h.kind} ${h.similarity:.2f}] ${h.text}'
	}
	return lines.join('\n')
}

pub struct SemanticStats {
pub:
	items int
	kinds map[string]int
	dim   int
}

pub fn (s &SemanticMemory) stats() SemanticStats {
	mut kinds := map[string]int{}
	for it in s.items {
		kinds[it.kind] = (kinds[it.kind] or { 0 }) + 1
	}
	return SemanticStats{
		items: s.items.len
		kinds: kinds
		dim:   semantic_dim
	}
}
