module vagent

import time
import x.json2

// agent_turn.v — one user turn through the whole loop.
//
// The shape is: route, reseat the prompt, speculate, then iterate. Each
// iteration asks the model, records the spend, and either runs the tool calls
// it asked for or takes the reply as final. Everything that can refuse — the
// budget, the cancel flag, the boundary — is checked INSIDE the loop rather
// than around it, because a refusal that only applies before the first
// iteration is not a refusal at all.

// TurnCallbacks is everything the UI wants to watch while a turn runs.
pub struct TurnCallbacks {
pub:
	on_token       TokenFn        = noop_token
	on_reasoning   TokenFn        = noop_token
	on_tool_call   ToolEventFn    = noop_tool_event
	on_tool_update ToolEventFn    = noop_tool_event
	on_status      StatusSink     = noop_status
	on_route       RouteFn        = noop_route
	on_tool_output ToolOutputSink = unsafe { nil }
	on_tool_args   ToolArgsFn     = noop_tool_args
	approve        ApprovalFn     = unsafe { nil }
	should_cancel  CancelFn       = never_cancel
}

pub type ToolEventFn = fn (ev &ToolEvent)

pub type RouteFn = fn (route &RouteDecision)

pub fn noop_tool_event(ev &ToolEvent) {}

pub fn noop_route(route &RouteDecision) {}

pub fn noop_status(text string) {}

// run_turn runs one user turn through the full agent loop.
pub fn (mut a Agent) run_turn(user_text string, cb TurnCallbacks) Turn {
	mut turn := Turn{
		user_text: user_text
		model_id:  a.model().id
		effort:    a.cfg.effort
	}
	started := time.now()
	a.turn_start_seq = a.log.head('main')
	a.failed_over = false

	// The autopilot decides for itself which powers this turn needs — goal
	// mode, live web — and enables them. Every decision is logged and
	// surfaced rather than applied quietly.
	route := a.autopilot.route(user_text, a.goal.status().active, a.autonomy)
	if route.active() {
		cb.on_route(&route)
	}
	if route.suggest_goal {
		a.autopilot_goal(route)
	}

	// refresh the system document through the gate: the sealed prompt is
	// guaranteed at position 0, and the live sections are composed beneath it
	a.reseat_system_prompt(a.context_sections(route, user_text), true)

	// The cancel check has to reach the post-reply passes too. Without it,
	// pressing escape still fired a fresh request to reshape a reply nobody
	// was waiting for any more.
	a.should_cancel = CancelCheck(cb.should_cancel)

	// speculate on the read-only calls this turn will probably make; they
	// run in the background while the model thinks
	mut recent := []ToolEvent{}
	for tn in tail_turns(a.turns, 2) {
		recent << tn.tools
	}
	a.speculator.speculate(user_text, recent)

	// A single giant paste must never blow the window by itself. The full
	// text goes in the log; the model sees a capped copy.
	full_text := user_text
	capped := a.cap_user_message(user_text)
	a.messages << Message{
		role:    'user'
		content: capped
	}
	user_ev := a.log.append('user.message', {
		'text':    json2.Any(full_text)
		'session': json2.Any(a.session_id)
	}, AppendOpts{ actor: 'human', provenance: 'user' })

	a.turn_status = StatusSink(cb.on_status)
	mut iterations := 0
	mut cancelled := false

	for iterations < max_tool_iterations {
		iterations++

		// a budget breach PAUSES the turn rather than killing it silently
		if !a.budget_gov.enforce() {
			evs := a.state().budget_events
			reason := if evs.len > 0 {
				jstr(evs[evs.len - 1], 'reason')
			} else {
				'budget exceeded'
			}
			turn.error = 'PAUSED — ${reason}. Extend the budget with /budget ' + '(e.g. /budget steps 500 or /budget reset) or stop.'
			break
		}
		if cb.should_cancel() {
			cancelled = true
			break
		}
		cb.on_status('thinking')
		a.maybe_compact()

		result := a.complete(cb) or {
			turn.error = err.msg()
			// Only drop this turn's user prompt when nothing was appended
			// after it. Once tool calls have landed, popping would orphan
			// an assistant tool_call and the next request dies on pairing.
			if a.messages.len > 0 && a.messages[a.messages.len - 1].role == 'user' {
				a.messages.delete_last()
			}
			a.log.append('turn.error', {
				'error': json2.Any(err.msg())
			}, AppendOpts{})
			break
		}

		turn.reasoning += result.reasoning
		// every completion burns tokens, tool iterations included, so the
		// spend is recorded per call rather than once per turn
		a.emit_cost(result)

		if result.tool_calls.len > 0 {
			a.messages << assistant_message(result.content, result.tool_calls, result.reasoning)
			turn.assistant_text += result.content
			for tc in result.tool_calls {
				// The cancel flag is read before EACH call. It used to be
				// checked only per streamed event, so a reply carrying
				// five tool calls ran all five after the user pressed
				// escape. Work already done stands; work not yet started
				// does not begin.
				if cb.should_cancel() {
					cancelled = true
					break
				}
				mut ev := ToolEvent{
					name: tc.function.name
					args: parse_tool_arguments(tc.function.arguments)
				}
				turn.tools << ev
				cb.on_tool_call(&ev)
				a.execute_tool(mut ev, ExecOpts{
					approve:        cb.approve
					on_status:      cb.on_status
					on_tool_output: cb.on_tool_output
					causation_id:   user_ev.id
				})
				turn.tools[turn.tools.len - 1] = ev
				cb.on_tool_update(&ev)
				a.log.append('tool.result', {
					'name':     json2.Any(ev.name)
					'status':   json2.Any(ev.status)
					'duration': json2.Any(round_to(ev.duration, 3))
					'preview':  json2.Any(clip_plain(ev.result, 300))
				}, AppendOpts{
					actor:          'system'
					provenance:     'tool_output'
					correlation_id: ev.clause_id
				})
				a.messages << Message{
					role:         'tool'
					tool_call_id: tc.id
					content:      ev.result
				}
				// the goal kernel ticks after every action
				a.goal_tick()
			}
			if cancelled {
				break
			}
			continue
		}

		// a plain assistant reply — the turn is done
		turn.assistant_text += result.content
		turn.usage = result.usage.clone()
		turn.has_usage = result.has_usage
		a.messages << Message{
			role:    'assistant'
			content: result.content
		}
		a.log.append('assistant.message', {
			'text':    json2.Any(result.content)
			'session': json2.Any(a.session_id)
		}, AppendOpts{
			actor:        'sovereign'
			provenance:   'model'
			causation_id: user_ev.id
		})

		// The output contract is checked against the DRAFT. A reply that
		// breaks an @output clause is not a record to preserve; it is a
		// draft that has not met the contract yet.
		shaped := a.charter.shape(result.content, Regenerator(fn [mut a] (note string) !string {
			unsafe {
				return a.redraft(note)
			}
		}))
		final := shaped.annotated()
		turn.assistant_text = final

		// The reply is a claim about the world, and the log knows. A
		// contradicted claim is surfaced rather than left to stand as the
		// one artefact the user actually reads.
		att := a.charter.attest_reply(final)
		contradicted := att.contradicted()
		if contradicted.len > 0 {
			turn.assistant_text += '\n\n[attest] ' + contradicted.map("'${it.quote.trim_space()}' — ${it.evidence}").join('; ')
		}
		a.detect_goal_clauses(final)
		break
	}

	if iterations >= max_tool_iterations && turn.error == '' {
		turn.error = 'stopped after ${max_tool_iterations} tool iterations'
	}
	if cancelled {
		turn.error = 'cancelled'
		a.messages << Message{
			role:    'assistant'
			content: if turn.assistant_text != '' {
				turn.assistant_text
			} else {
				'(cancelled by user)'
			}
		}
		a.log.append('turn.cancelled', map[string]json2.Any{}, AppendOpts{})
	}

	a.turn_status = unsafe { nil }
	turn.duration = (time.now() - started).seconds()
	a.score_turn(mut turn)
	a.flush_notifications()
	a.turns << turn
	return turn
}

fn tail_turns(turns []Turn, n int) []Turn {
	return if turns.len > n { turns[turns.len - n..].clone() } else { turns.clone() }
}

// autopilot_goal drafts and freezes a machine-checkable contract from the
// request. A contract that cannot be made checkable is simply not set, and
// the turn proceeds without one.
fn (mut a Agent) autopilot_goal(route RouteDecision) {
	a.goal.set_goal(route.goal_statement, route.goal_clauses, SetGoalOpts{}) or { return }
}

fn (mut a Agent) emit_cost(result &StreamResult) {
	if !result.has_usage {
		return
	}
	// the configured models are free-tier; the ledger still tracks tokens
	// so a price table can be dropped in later without a schema change
	a.log.append('cost.incurred', {
		'usd':        json2.Any(0.0)
		'tokens_in':  json2.Any(jint(result.usage, 'prompt_tokens'))
		'tokens_out': json2.Any(jint(result.usage, 'completion_tokens'))
		'model':      json2.Any(a.model().id)
	}, AppendOpts{ correlation_id: a.goal.status().focus })
}

// goal_tick measures distance and re-aims focus. Pure projection, zero
// tokens.
fn (mut a Agent) goal_tick() {
	if !a.goal.status().active {
		return
	}
	a.goal.measure()
	a.goal.reaim('tick') or {}
}

// detect_goal_clauses reads a claim of proof out of the reply — and then
// checks it.
//
// The model may CLAIM 'PROVEN: <id>'. The clause is only marked proven if its
// own predicate actually passes: the binary proven flag is never set from
// model output alone.
fn (mut a Agent) detect_goal_clauses(text string) {
	status := a.goal.status()
	if !status.active {
		return
	}
	low := text.to_lower()
	for clause in status.clauses {
		if clause.state in ['PROVEN', 'WAIVED'] {
			continue
		}
		key := clause.id.to_lower()
		claimed := low.contains('proven: ${key}') || low.contains('done: ${key}')
			|| low.contains('completed: ${key}') || low.contains('✓ ${key}')
		if !claimed {
			continue
		}
		if clause.has_proof {
			// verify the claim against reality
			ok, detail := a.goal.prove_by_predicate(clause.id)
			if ok {
				a.log.append('fact.learned', {
					'fact': json2.Any('clause ${clause.id} proven: ${detail}')
					'kind': json2.Any('goal')
				}, AppendOpts{})
			}
		} else if clause.advisory {
			// an advisory clause has no predicate — it is human-tracked
			a.goal.prove_clause(clause.id, true, 'human_approval', -1, 'model claim, advisory clause')
		}
	}
}

// redraft asks the model for another draft that meets the output contract.
//
// The note names the rule and the miss; it never supplies wording. A failure
// here returns an empty string so conform keeps the original draft rather
// than losing the turn.
pub fn (mut a Agent) redraft(note string) !string {
	if a.should_cancel != unsafe { nil } && a.should_cancel() {
		// cancelled: keep the draft as it is
		return ''
	}
	mut msgs := a.messages.clone()
	msgs << Message{
		role:    'user'
		content: note
	}
	// no tools on a redraft: this asks for the same answer in a conforming
	// shape, not for more work
	result := chat_blocking(a.provider(), a.model(), a.effort(), mut msgs, []json2.Any{}, StreamCallbacks{ should_cancel: CancelFn(a.should_cancel) }, 120.0) or { return '' }
	return result.content
}
