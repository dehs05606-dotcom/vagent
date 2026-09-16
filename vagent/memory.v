module vagent

import x.json2

// memory.v — Hippocampus: episodic memory + dead-end ledger.
//
// Closed task nodes are compressed into STRUCTURED episode records (never
// prose) and appended to the event log as `memory.episode` events.
// Approaches known not to work are appended as `deadend.recorded` events.
// This module keeps no state of its own: every query is a pure fold over the
// log, so memory survives rewind, replay, and resume for free.
//
// Design (V stdlib only):
//   * Records are plain JSON values — they live in the JSONL log.
//   * Dead-end checks are deterministic lookups over the fold. No LLM.
//   * context_block() renders a compact, prompt-injectable summary.

// field_chars is a rough cap for one field rendered into context_block
// (~400 tokens total).
const field_chars = 120

// clip_field clips a string for prompt injection without breaking the line
// format.
fn clip_field(text string, limit int) string {
	t := text.replace('\n', ' ').trim_space()
	r := t.runes()
	if r.len <= limit {
		return t
	}
	return r[..limit - 1].string() + '…'
}

// DeadEnd is one entry of the ledger of approaches known not to work.
pub struct DeadEnd {
pub:
	signature  string
	reason     string
	scope      string = 'session'
	confidence string = 'definitive'
}

// Episode is one compressed, closed task node.
pub struct Episode {
pub:
	goal      string
	approach  string
	actions   []string
	outcome   string
	artifacts []string
	facts     []string
	lesson    string
	dead_ends []DeadEnd
	cost_usd  f64
	steps     int
}

pub fn (e &Episode) to_json() map[string]json2.Any {
	mut de := []json2.Any{}
	for d in e.dead_ends {
		de << json2.Any({
			'signature':  json2.Any(d.signature)
			'reason':     json2.Any(d.reason)
			'scope':      json2.Any(d.scope)
			'confidence': json2.Any(d.confidence)
		})
	}
	return {
		'goal':      json2.Any(e.goal)
		'approach':  json2.Any(e.approach)
		'actions':   json2.Any(strs_to_any(e.actions))
		'outcome':   json2.Any(e.outcome)
		'artifacts': json2.Any(strs_to_any(e.artifacts))
		'facts':     json2.Any(strs_to_any(e.facts))
		'lesson':    if e.lesson == '' { json2.null } else { json2.Any(e.lesson) }
		'dead_ends': json2.Any(de)
		'cost_usd':  json2.Any(e.cost_usd)
		'steps':     json2.Any(e.steps)
	}
}

// Hippocampus is episodic memory projected from `memory.episode` /
// `deadend.recorded` events in the log. All reads fold the log; writes
// append to it.
pub struct Hippocampus {
pub mut:
	log &EventLog
}

pub fn new_hippocampus(log &EventLog) Hippocampus {
	return Hippocampus{
		log: unsafe { log }
	}
}

// -- writes ----------------------------------------------------------------

// record_episode compresses a closed task node into a STRUCTURED record
// (never prose) and emits a 'memory.episode' event. If the episode carries
// dead ends, each one is also sealed through record_dead_end.
pub fn (mut h Hippocampus) record_episode(ep Episode) !Episode {
	h.log.append('memory.episode', ep.to_json(), AppendOpts{})
	for entry in ep.dead_ends {
		reason := if entry.reason != '' {
			entry.reason
		} else {
			'failed while pursuing: ${ep.goal}'
		}
		h.record_dead_end(DeadEnd{
			signature:  entry.signature
			reason:     reason
			scope:      entry.scope
			confidence: entry.confidence
		})!
	}
	return ep
}

// record_dead_end records an approach known NOT to work and emits
// 'deadend.recorded'. signature = canonical hash/id of the approach.
pub fn (mut h Hippocampus) record_dead_end(d DeadEnd) !DeadEnd {
	sig := d.signature.trim_space()
	// an empty signature would make is_dead_end('') match every caller's
	// query, freezing the agent into thinking "everything has failed".
	// Refuse to seal such a record so the bug is loud, not silent.
	if sig == '' {
		return error('record_dead_end requires a non-empty signature')
	}
	if d.reason.trim_space() == '' {
		// same reasoning — a dead-end without a reason is an audit hole
		return error('record_dead_end requires a non-empty reason')
	}
	rec := DeadEnd{
		signature:  sig
		reason:     d.reason
		scope:      d.scope
		confidence: d.confidence
	}
	h.log.append('deadend.recorded', {
		'signature':  json2.Any(rec.signature)
		'reason':     json2.Any(rec.reason)
		'scope':      json2.Any(rec.scope)
		'confidence': json2.Any(rec.confidence)
	}, AppendOpts{})
	return rec
}

// -- reads (pure folds, no LLM) --------------------------------------------

// is_dead_end is a deterministic check (no LLM): is this signature in the
// ledger? Folds the log and scans State.dead_ends.
pub fn (mut h Hippocampus) is_dead_end(signature string) bool {
	st := fold(mut h.log, '')
	for d in st.dead_ends {
		if jstr(d, 'signature') == signature {
			return true
		}
	}
	return false
}

// recent_episodes returns the last n episode records from the fold, newest
// first.
pub fn (mut h Hippocampus) recent_episodes(n int) []Rec {
	if n <= 0 {
		return []
	}
	st := fold(mut h.log, '')
	start := if st.episodes.len > n { st.episodes.len - n } else { 0 }
	mut out := st.episodes[start..].clone()
	out.reverse_in_place()
	return out
}

// facts aggregates all 'facts' across episodes, deduplicated and
// order-preserving.
pub fn (mut h Hippocampus) facts() []string {
	st := fold(mut h.log, '')
	mut seen := map[string]bool{}
	mut out := []string{}
	for ep in st.episodes {
		for fact in jstrs(ep, 'facts') {
			if fact !in seen {
				seen[fact] = true
				out << fact
			}
		}
	}
	return out
}

// context_block renders a compact, prompt-injectable text block summarizing
// recent episodes, learned facts, and active dead-ends. Kept <= ~400 tokens
// by clipping each rendered field.
pub fn (mut h Hippocampus) context_block(max_episodes int) string {
	st := fold(mut h.log, '')
	mut lines := ['MEMORY']

	mut episodes := []Rec{}
	if max_episodes > 0 {
		start := if st.episodes.len > max_episodes {
			st.episodes.len - max_episodes
		} else {
			0
		}
		episodes = st.episodes[start..].clone()
	}
	if episodes.len > 0 {
		lines << 'RECENT EPISODES (newest first):'
		for i := episodes.len - 1; i >= 0; i-- {
			ep := episodes[i]
			outcome := if 'outcome' in ep { jstr(ep, 'outcome') } else { '?' }
			lines << '- [${clip_field(outcome, 20)}] ' +
				'goal: ${clip_field(jstr(ep, "goal"), field_chars)} | ' +
				'approach: ${clip_field(jstr(ep, "approach"), field_chars)} | ' +
				'steps: ${jint(ep, "steps")} | ' + 'cost: \$${jf64(ep, "cost_usd"):.4f}'
			lesson := jstr(ep, 'lesson')
			if lesson != '' {
				lines << '  lesson: ${clip_field(lesson, field_chars)}'
			}
		}
	}

	mut facts := []string{}
	mut seen_facts := map[string]bool{}
	for ep in st.episodes {
		for fact in jstrs(ep, 'facts') {
			if fact !in seen_facts {
				seen_facts[fact] = true
				facts << fact
			}
		}
	}
	// top-level learned facts (goal proofs, team worker results)
	for f in st.facts {
		fact := jstr(f, 'fact')
		if fact != '' && fact !in seen_facts {
			seen_facts[fact] = true
			facts << fact
		}
	}
	if facts.len > 0 {
		lines << 'FACTS:'
		start := if facts.len > 12 { facts.len - 12 } else { 0 }
		for f in facts[start..] {
			lines << '- ${clip_field(f, field_chars)}'
		}
	}

	if st.dead_ends.len > 0 {
		lines << 'DEAD ENDS (do not retry):'
		mut seen_sigs := map[string]bool{}
		for i := st.dead_ends.len - 1; i >= 0; i-- {
			d := st.dead_ends[i]
			sig := jstr(d, 'signature')
			if sig in seen_sigs {
				continue
			}
			seen_sigs[sig] = true
			conf := if 'confidence' in d { jstr(d, 'confidence') } else { 'definitive' }
			lines << '- ${sig} — ${clip_field(jstr(d, "reason"), field_chars)} ' +
				'(${clip_field(conf, 20)})'
		}
	}
	return lines.join('\n')
}
