module vagent

import x.json2

// agent_complete.v — one model call, and everything that can go wrong with it.
//
// A long session must never die at the API boundary, so each failure has a
// specific answer rather than a general retry:
//
//   * the input no longer fits      → compact hard, once, and try again
//   * the provider refuses tools    → ask again without them
//   * the provider refuses streams  → ask again blocking
//   * the provider is down          → fail over to another model, ONCE
//
// Anything else propagates. A retry loop that answers every error the same
// way is how a broken request becomes an expensive one.

// complete asks the model for one reply.
pub fn (mut a Agent) complete(cb TurnCallbacks) !StreamResult {
	schemas := a.tool_schemas()

	// replay: zero API cost, fully deterministic
	if a.cassette != unsafe { nil } && a.cassette.mode == 'replay' {
		stored := a.cassette.replay(a.model().id, a.messages, schemas, a.effort().key) or {
			return api_error('cassette replay miss — request not in the recorded ' + 'cassette (deterministic replay never falls back to a live call)', 0)
		}
		content := jstr(stored, 'content')
		if content != '' {
			cb.on_token(content)
		}
		mut calls := []ToolCall{}
		for c in jarr(stored, 'tool_calls') {
			if c is map[string]json2.Any {
				calls << tool_call_from_json(c)
			}
		}
		return StreamResult{
			content:    content
			reasoning:  jstr(stored, 'reasoning')
			tool_calls: calls
			usage:      jmap(stored, 'usage')
			has_usage:  'usage' in stored
			model:      a.model().id
		}
	}

	callbacks := StreamCallbacks{
		on_token:      cb.on_token
		on_reasoning:  cb.on_reasoning
		on_tool_start: ToolStartFn(fn [cb] (name string) {
			cb.on_status('tool:${name}')
		})
		on_tool_args:  cb.on_tool_args
		should_cancel: cb.should_cancel
		on_overflow:   OverflowFn(fn [mut a] () bool {
			unsafe {
				return a.overflow_shrink()
			}
		})
	}

	mut result := chat_stream(a.provider(), a.model(), a.effort(), mut a.messages, schemas, callbacks, 0.0) or {
		if err is TurnCancelled {
			return err
		}
		status := if err is APIError { err.status } else { 0 }
		msg := err.msg().to_lower()

		if is_context_overflow(err.msg()) {
			// The last line of defence. The client already re-clamped,
			// retried and shrunk, so this compacts once more and asks
			// again — a long session must never die with a
			// context-length error.
			cb.on_status('compacting context')
			a.emergency_compact()
			return chat_stream(a.provider(), a.model(), a.effort(), mut a.messages, schemas, callbacks, 0.0)
		}
		if status == 400 && msg.contains('tool') && schemas.len > 0 {
			cb.on_status('retrying (no tools)')
			return chat_stream(a.provider(), a.model(), a.effort(), mut a.messages, []json2.Any{}, callbacks, 0.0)
		}
		if status == 400 && msg.contains('stream') {
			cb.on_status('retrying (non-stream)')
			return chat_blocking(a.provider(), a.model(), a.effort(), mut a.messages, schemas, callbacks, 0.0)
		}

		// a provider outage: switch model once and try again
		a.model_errors[a.cfg.model_id] = a.model_errors[a.cfg.model_id] + 1
		fallback := a.failover_candidate(status) or { return err }
		old_id := a.cfg.model_id
		a.cfg.model_id = fallback
		a.failed_over = true
		a.failovers++
		a.log.append('provider.failover', {
			'from':  json2.Any(old_id)
			'to':    json2.Any(fallback)
			'error': json2.Any(clip_plain(err.msg(), 140))
		}, AppendOpts{ actor: 'kernel' })
		label := if m := model_by_id(fallback) { m.label } else { fallback }
		a.push_status('⚠ provider failover → ${label}')
		// the schemas belong to the old model, so they are rebuilt
		a.schemas_tool_count = -1
		return chat_stream(a.provider(), a.model(), a.effort(), mut a.messages, a.tool_schemas(), callbacks, 0.0)
	}

	if a.cassette != unsafe { nil } && a.cassette.mode == 'record' {
		a.cassette.record(a.model().id, a.messages, schemas, {
			'content':    json2.Any(result.content)
			'reasoning':  json2.Any(result.reasoning)
			'tool_calls': json2.Any(result.tool_calls.map(json2.Any(it.to_json())))
			'usage':      json2.Any(result.usage.clone())
		}, a.effort().key)
	}
	return result
}

// failover_candidate picks the model to fail over to, or none when failover
// is impossible or not warranted.
//
// At most one failover per turn: a second one means the problem is not the
// provider, and cycling models would only spend the budget proving it.
pub fn (a &Agent) failover_candidate(status int) ?string {
	if a.failed_over {
		return none
	}
	if status != 0 && status !in failover_statuses {
		// a 4xx that is not a timeout is a bad request, not an outage
		return none
	}
	explicit := jstr(a.cfg.extra, 'failover_model')
	if explicit != '' && explicit != a.cfg.model_id {
		if _ := model_by_id(explicit) {
			return explicit
		}
	}
	current := a.model()
	// the same provider first (a per-model fault), then anything capable
	mut candidates := []string{}
	for m in models {
		if m.provider == current.provider && m.id != current.id
			&& capability_kept(m, current) {
			candidates << m.id
		}
	}
	for m in models {
		if m.provider != current.provider && m.id != current.id
			&& capability_kept(m, current) {
			candidates << m.id
		}
	}
	return if candidates.len > 0 { candidates[0] } else { none }
}

// capability_kept refuses a failover that would silently take tools away: a
// model that cannot act is not a substitute for one that can.
fn capability_kept(candidate Model, current Model) bool {
	return candidate.supports_tools || !current.supports_tools
}

// -- the scorecard ---------------------------------------------------------------

// score_turn is the deterministic quality record of a finished turn.
//
// No model judgement anywhere: only measured facts. A score the agent gave
// itself would be the one number in the ledger that nobody could check.
pub fn (mut a Agent) score_turn(mut turn Turn) map[string]json2.Any {
	errors := turn.tools.filter(it.status in ['error', 'blocked', 'denied']).len
	mut writes := map[string]int{}
	for t in turn.tools {
		if t.name in ['write_file', 'edit_file'] && t.status == 'done' {
			path := jstr(t.args, 'path')
			if path != '' {
				writes[path] = writes[path] + 1
			}
		}
	}
	mut rework := 0
	for _, n in writes {
		if n > 1 {
			rework++
		}
	}
	verdicts := a.log.events('main').filter(it.typ == 'judge.verdict'
		&& it.seq > a.turn_start_seq)
	verified := verdicts.filter(jbool(it.data, 'passed')).len
	mut score := 100 - 20 * errors - 10 * rework
	if score < 0 {
		score = 0
	}
	if score > 100 {
		score = 100
	}
	card := {
		'tool_calls':   json2.Any(turn.tools.len)
		'errors':       json2.Any(errors)
		'rework_files': json2.Any(rework)
		'verified':     json2.Any(verified)
		'verdicts':     json2.Any(verdicts.len)
		'score':        json2.Any(score)
		'duration':     json2.Any(round_to(turn.duration, 2))
	}
	turn.scorecard = card.clone()
	a.log.append('turn.scorecard', card, AppendOpts{ actor: 'kernel' })
	return card
}

// -- notifications ------------------------------------------------------------------

// flush_notifications emits the notifiable events sealed since the last
// flush. With no sink configured the cursor still moves, so switching one on
// mid-session does not replay the whole history at it.
pub fn (mut a Agent) flush_notifications() {
	if a.notifier.sink == '' {
		a.notify_seq = a.log.head('main')
		return
	}
	for ev in a.log.events('main') {
		if ev.seq <= a.notify_seq {
			continue
		}
		if ev.typ in notify_events {
			a.notifier.emit(ev.typ, ev.data.clone())
		}
	}
	a.notify_seq = a.log.head('main')
}
