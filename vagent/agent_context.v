module vagent

import x.json2

// agent_context.v — keeping the conversation inside the window.
//
// The event log keeps everything. This is only about what the MODEL sees,
// and the difference matters: a compaction here loses nothing, because every
// byte is still in the log and still replayable. What it costs is the
// model's memory of the middle of a long session, which is why the passes
// escalate rather than starting with the blunt one.
//
// Three passes, run only when needed:
//
//   1. truncate stale tool outputs to summaries
//   2. drop the oldest user→(assistant + tool results) turns as WHOLE units,
//      so a tool_call is never separated from its response
//   3. last resort — truncate every tool output and trim the oldest
//      assistant messages
//
// The knowledge in a dropped turn is distilled into a digest first, so what
// leaves the window leaves a note behind.

// fit_budget is the input token budget the agent aims to stay under.
//
// It mirrors the client's own clamp so the two can never disagree: the
// largest input that still leaves room for the margin and a minimum
// completion. Staying under it means the request fits however long the
// session has run.
pub fn (a &Agent) fit_budget() int {
	window := a.model().context_window
	// solve: input + (8192 + input/32) + 1024 <= window
	return int(f64(window - 9216) * 32.0 / 33.0)
}

// cap_user_message caps ONE message so a giant paste cannot consume the
// whole window by itself. The full text is preserved in the event log by the
// caller; the model sees a head, a tail, and instructions to read the file
// from disk if it needs the middle.
pub fn (mut a Agent) cap_user_message(text string) string {
	cap_chars := int(f64(a.fit_budget()) * 3.2 / 4.0)
	if text.len <= cap_chars {
		return text
	}
	head := text[..cap_chars / 2]
	tail := text[text.len - cap_chars / 4..]
	a.log.append('user.message.capped', {
		'chars': json2.Any(text.len)
		'kept':  json2.Any(head.len + tail.len)
	}, AppendOpts{ actor: 'kernel' })
	return head + '\n\n[… the kernel truncated this message — ' + thousands(text.len) + ' chars originally. If you need the full text, it is on disk; use ' + 'read_file/search_files instead of relying on this paste.]\n\n' + tail
}

// messages_chars is the cheap size proxy that gates the expensive estimate.
// It is a character count, not a token count, and it is only ever used to
// decide whether counting tokens is worth the work.
pub fn (a &Agent) messages_chars() int {
	mut n := 0
	for m in a.messages {
		n += m.text().len
		for tc in m.tool_calls {
			n += tc.function.name.len + tc.function.arguments.len
		}
		if rc := m.reasoning_content {
			n += rc.len
		} else if r := m.reasoning {
			n += r.len
		}
	}
	return n
}

fn (a &Agent) estimated_tokens() int {
	return estimate_message_tokens(a.messages, a.cfg.model_id)
}

fn (a &Agent) schema_tokens(schemas []json2.Any) int {
	if schemas.len == 0 {
		return 0
	}
	return estimate_tokens(json2.Any(schemas.clone()), a.cfg.model_id)
}

// maybe_compact keeps the conversation under the window, doing nothing at all
// when it already fits.
//
// The expensive token estimate runs only once the conversation has measurably
// grown since the last check; the character count is the gate. Before that
// change the full estimate ran ahead of every model call inside a turn.
pub fn (mut a Agent) maybe_compact() {
	schemas := a.tool_schemas()
	schema_tokens := a.schema_tokens(schemas)
	budget := a.fit_budget()
	chars := a.messages_chars()
	if a.compact_check_chars > 0 && f64(chars) <= f64(a.compact_check_chars) * 1.15 {
		// not yet grown enough to justify a full re-estimate
		return
	}
	fits := a.estimated_tokens() + schema_tokens <= budget
	a.compact_check_chars = if chars > 1 { chars } else { 1 }
	if fits {
		return
	}

	mut dropped := a.compact_old_tools(2)
	for a.estimated_tokens() + schema_tokens > budget && a.messages.len > 2 {
		if !a.drop_oldest_turn() {
			break
		}
		dropped++
	}
	if a.estimated_tokens() + schema_tokens > budget {
		a.compact_old_tools(0)
		a.trim_oldest_assistant(budget - schema_tokens)
	}
	if dropped > 0 {
		// force a real re-estimate next time rather than trusting a gate
		// that was computed before the conversation changed shape
		a.compact_check_chars = 0
		a.log.append('context.compacted', {
			'messages':   json2.Any(a.messages.len)
			'units':      json2.Any(dropped)
			'digests':    json2.Any(a.compact_digests.len)
			'est_tokens': json2.Any(a.estimated_tokens())
		}, AppendOpts{ actor: 'kernel' })
	}
}

// compact_old_tools truncates stale tool results to summaries, keeping the
// newest `keep` verbatim. It returns how many it actually shortened.
pub fn (mut a Agent) compact_old_tools(keep int) int {
	mut tool_idx := []int{}
	for i, m in a.messages {
		if m.role == 'tool' {
			tool_idx << i
		}
	}
	mut stale := tool_idx.clone()
	if keep > 0 {
		stale = if tool_idx.len > keep { tool_idx[..tool_idx.len - keep].clone() } else { [] }
	}
	mut n := 0
	for i in stale {
		content := a.messages[i].text()
		if content.len > 500 {
			a.messages[i].content = content[..350] + '\n[… truncated by the kernel — ' + thousands(content.len) + ' chars originally; re-read the file if you need it]'
			n++
		}
	}
	return n
}

// trim_oldest_assistant shrinks the oldest assistant messages, which are the
// least actionable once their tool results are gone.
pub fn (mut a Agent) trim_oldest_assistant(budget int) {
	for a.estimated_tokens() > budget && a.messages.len > 2 {
		mut target := -1
		for i, m in a.messages {
			if m.role == 'assistant' && m.text() != '' {
				target = i
				break
			}
		}
		if target < 0 {
			return
		}
		content := a.messages[target].text()
		if content.len <= 400 {
			// nothing left worth trimming; trimming further would cost
			// more meaning than it saves tokens
			return
		}
		a.messages[target].content = content[..300] + '\n[… trimmed by the kernel — ' + thousands(content.len) + ' chars originally]'
	}
}

// drop_oldest_turn removes the oldest user message plus everything up to the
// next one — the assistant reply and its tool results — as a single unit.
//
// Dropping a tool result without the assistant message that called for it
// leaves a tool_call with no response, which the next request rejects.
pub fn (mut a Agent) drop_oldest_turn() bool {
	start := if a.messages.len > 0 && a.messages[0].role == 'system' { 1 } else { 0 }
	mut end := -1
	for j in start + 1 .. a.messages.len {
		if a.messages[j].role == 'user' {
			end = j
			break
		}
	}
	if end <= start {
		return false
	}
	digest := a.digest_messages(a.messages[start..end])
	if digest != '' {
		a.compact_digests << digest
		if a.compact_digests.len > 20 {
			a.compact_digests = a.compact_digests[a.compact_digests.len - 20..].clone()
		}
	}
	a.messages.delete_many(start, end - start)
	return true
}

// emergency_compact is the hard pass used when a request was ALREADY
// rejected for exceeding the window.
//
// It is more aggressive than maybe_compact on purpose: it compacts to a
// third of the window, leaving a wide margin so the retry is guaranteed to
// fit rather than merely likely to.
pub fn (mut a Agent) emergency_compact() {
	a.compact_old_tools(0)
	target := a.model().context_window / 3
	for a.estimated_tokens() > target && a.messages.len > 2 {
		if !a.drop_oldest_turn() {
			break
		}
	}
	a.trim_oldest_assistant(target)
	a.log.append('context.compacted', {
		'messages':   json2.Any(a.messages.len)
		'est_tokens': json2.Any(a.estimated_tokens())
		'reason':     json2.Any('emergency — request rejected for context length')
	}, AppendOpts{ actor: 'kernel' })
}

// overflow_shrink is the callback the client invokes when the backend
// rejects a request because the INPUT no longer fits.
//
// It reports whether anything actually shrank, and the client retries only
// when it did. That is what lets an arbitrarily long session on a huge
// project recover instead of dying with a context-length error — and what
// stops it retrying forever when there is nothing left to give up.
pub fn (mut a Agent) overflow_shrink() bool {
	before := a.estimated_tokens()
	a.emergency_compact()
	return a.estimated_tokens() < before
}

// digest_messages is the deterministic one-line note left behind by a turn
// about to be compacted away — the knowledge survives even when the tokens
// do not.
//
// It is mechanical on purpose. A model-written summary of a turn being
// dropped for cost reasons would cost a model call, and would be the one
// artefact of that turn nobody could check.
pub fn (a &Agent) digest_messages(msgs []Message) string {
	mut tools_used := []string{}
	mut files := []string{}
	mut problems := []string{}

	wrote_re := compile_regex(r'OK: (?:wrote \d+ chars to|replaced .*? in) (\S+)') or {
		return ''
	}
	for m in msgs {
		for tc in m.tool_calls {
			name := tc.function.name
			if name != '' && name !in tools_used {
				tools_used << name
			}
		}
		if m.role != 'tool' {
			continue
		}
		content := m.text()
		mut pos := 0
		for pos < content.len {
			hit := wrote_re.search(content[pos..]) or { break }
			f := group_text(content[pos..], &hit, 1)
			if f != '' && f !in files {
				files << f
			}
			if hit.end <= 0 {
				break
			}
			pos += hit.end
		}
		if content.starts_with('ERROR:') {
			problems << content[6..int_min(80, content.len)]
		}
	}

	mut parts := []string{}
	if tools_used.len > 0 {
		parts << 'tools: ' + head_of(tools_used, 6).join(', ')
	}
	if files.len > 0 {
		parts << 'wrote: ' + head_of(files, 5).join(', ')
	}
	if problems.len > 0 {
		parts << 'hit: ' + problems[0]
	}
	return parts.join('; ')
}

fn head_of(items []string, n int) []string {
	return if items.len > n { items[..n].clone() } else { items.clone() }
}

fn int_min(a int, b int) int {
	return if a < b { a } else { b }
}
