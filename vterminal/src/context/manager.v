module context

import src.model
import src.utils

// Manager keeps the conversation inside the model's context window. The policy
// is deliberately simple and predictable: never touch the system prompt or the
// most recent exchanges, and shrink the oldest tool output first, because tool
// output is both the bulkiest and the least re-readable part of a transcript.
pub struct Manager {
pub mut:
	limit int = 128000
	// reserve leaves room for the model's own reply plus the next tool result.
	reserve int = 16000
	// keep_recent messages are never compressed.
	keep_recent int = 8
}

// estimate approximates the token cost of a message list.
pub fn (m &Manager) estimate(messages []model.Message) int {
	mut total := 0
	for msg in messages {
		total += utils.estimate_tokens(msg.content) + 4
		for c in msg.tool_calls {
			total += utils.estimate_tokens(c.arguments) + utils.estimate_tokens(c.name) + 8
		}
	}
	return total
}

// budget is the number of tokens the conversation is allowed to occupy.
pub fn (m &Manager) budget() int {
	b := m.limit - m.reserve
	return if b > 1000 { b } else { m.limit / 2 }
}

pub fn (m &Manager) over_budget(messages []model.Message) bool {
	return m.estimate(messages) > m.budget()
}

// CompactionReport says what a compaction actually did, so `/compact` and the
// automatic path can both report honestly rather than claiming a fixed win.
pub struct CompactionReport {
pub:
	before_tokens int
	after_tokens  int
	trimmed       int
	dropped       int
}

// compact shrinks the conversation in two escalating passes.
//
// Pass one truncates the body of old tool results, which usually recovers
// enough on its own. Pass two drops the oldest exchanges entirely and leaves a
// synthetic note in their place so the model knows history was elided rather
// than never existed.
pub fn (m &Manager) compact(messages []model.Message) ([]model.Message, CompactionReport) {
	before := m.estimate(messages)
	mut out := messages.clone()
	mut trimmed := 0
	mut dropped := 0

	// Index of the first message that is off-limits to compaction.
	protect_from := if out.len > m.keep_recent { out.len - m.keep_recent } else { out.len }

	for i in 0 .. protect_from {
		if out[i].role != .tool {
			continue
		}
		if out[i].content.len <= 600 {
			continue
		}
		out[i].content = utils.truncate_middle(out[i].content, 600)
		trimmed++
	}
	if !m.over_budget(out) {
		return out, CompactionReport{
			before_tokens: before
			after_tokens:  m.estimate(out)
			trimmed:       trimmed
		}
	}

	// Second pass: drop from the front, keeping the system prompt and the
	// first user message (the original task) as anchors.
	mut head := []model.Message{}
	mut idx := 0
	for idx < out.len && out[idx].role == .system {
		head << out[idx]
		idx++
	}
	if idx < out.len && out[idx].role == .user {
		head << out[idx]
		idx++
	}
	mut tail := []model.Message{}
	start_tail := if out.len > m.keep_recent { out.len - m.keep_recent } else { idx }
	for i in start_tail .. out.len {
		tail << out[i]
	}
	dropped = out.len - head.len - tail.len
	if dropped > 0 {
		head << model.Message{
			role:    .user
			content: '[${dropped} earlier message(s) were removed to stay within the context window. Ask to re-read any file you still need.]'
		}
	}
	// A dropped assistant turn can orphan its tool results; those must go too,
	// because a tool message without its call is a protocol error.
	mut merged := head.clone()
	mut valid_ids := map[string]bool{}
	for msg in merged {
		for c in msg.tool_calls {
			valid_ids[c.id] = true
		}
	}
	for msg in tail {
		for c in msg.tool_calls {
			valid_ids[c.id] = true
		}
	}
	for msg in tail {
		if msg.role == .tool && !valid_ids[msg.tool_call_id] {
			dropped++
			continue
		}
		merged << msg
	}
	return merged, CompactionReport{
		before_tokens: before
		after_tokens:  m.estimate(merged)
		trimmed:       trimmed
		dropped:       dropped
	}
}
