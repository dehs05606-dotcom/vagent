module vagent

import crypto.sha256
import os
import time
import x.json2

// agent_exec.v — attribution, the gate, and executing one tool call.
//
// This is where the boundary actually bites. Every refusal here is
// mechanical: nothing in this file asks the model to behave, and nothing
// depends on it having read anything.
//
// The order is the point. Attribution runs first, because an action with no
// clause to serve should not be evaluated at all. The autonomy ladder and the
// dead-end ledger run next, cheaply. The specification runs LAST, so that
// when a call is refused the reason cites the clause rather than whichever
// lower rule happened to catch it first.

// ApprovalFn asks the human. It returns false for "do not do this".
pub type ApprovalFn = fn (tool &Tool, args map[string]json2.Any) bool

// ToolOutputSink relays a shell tool's output while it is still running.
pub type ToolOutputSink = fn (line string, stream string)

pub struct Attribution {
pub:
	clause_id string
	orphan    string
}

// attribute binds an action to the clause it serves.
//
// With an active goal, every action binds to the focus clause — the open one
// under the most gravity. An action with no open clause to serve is an orphan
// and is refused before it runs.
//
// The exception is a CLOSED contract. A terminal contract no longer demands
// attribution, because otherwise the agent could never run another command
// after a goal completed: attribution gates an OPEN contract, not the rest of
// the session.
pub fn (mut a Agent) attribute(tool_name string) Attribution {
	status := a.goal.status()
	if !status.active {
		// normal mode: no attribution required
		return Attribution{}
	}
	if status.closed_state in terminal_states {
		return Attribution{}
	}
	mut focus := status.focus
	if focus == '' {
		focus = a.goal.reaim('attribution') or { '' }
	}
	mut open_ids := []string{}
	for c in status.clauses {
		if c.state in ['OPEN', 'REGRESSED'] {
			open_ids << c.id
		}
	}
	if focus != '' && focus in open_ids {
		return Attribution{
			clause_id: focus
		}
	}
	if open_ids.len > 0 {
		open_ids.sort()
		return Attribution{
			clause_id: open_ids[0]
		}
	}
	return Attribution{
		orphan: 'OrphanAction: no open clause to serve — the goal is fully ' + 'proven, waived, or blocked. Close the goal or amend the contract.'
	}
}

// the sentinel a gate returns when the human must be asked rather than the
// action refused
const gate_ask = 'ASK'

// gate returns a block reason, or an empty string when the action may
// proceed.
pub fn (mut a Agent) gate(tool &Tool, args map[string]json2.Any) string {
	if tool.name in mutating_tool_names {
		if a.autonomy <= 1 {
			return 'autonomy L${a.autonomy} is read-only — raise it with /autonomy ' + 'to allow mutations'
		}
		if a.autonomy == 2 {
			return gate_ask
		}
		if a.autonomy == 4 && tool.name in always_ask_tools {
			return gate_ask
		}
	}
	// a deterministic dead-end: this exact approach already failed twice
	sig := tool_signature(tool.name, args)
	if a.memory.is_dead_end(sig) {
		return 'this exact approach is in the dead-end ledger (signature ' + '${sig}) — choose a different approach'
	}
	// The specification, as a boundary rather than as advice. Last in the
	// gate so a refusal cites the specification and not a lower rule.
	verdict := a.charter.gate(tool.name, args)
	if !verdict.allowed {
		return verdict.reason
	}
	return ''
}

// snapshot_paths are the files a mutating tool touches — the recovery
// targets taken before it runs.
pub fn (mut a Agent) snapshot_paths(tool_name string, args map[string]json2.Any) []string {
	if tool_name == 'run_command' {
		// a command can touch anything, so the cwd tree is snapshotted
		// shallowly rather than guessing at its targets
		mut paths := []string{}
		for name in os.ls(a.cwd) or { []string{} } {
			full := os.join_path(a.cwd, name)
			if os.is_file(full) {
				paths << full
			}
			if paths.len >= 200 {
				break
			}
		}
		return paths
	}
	mut paths := []string{}
	for key in path_arg_tools[tool_name] or { []string{} } {
		v := jstr(args, key)
		if v != '' {
			paths << v
		}
	}
	return paths
}

pub struct ExecOpts {
pub:
	approve        ApprovalFn     = unsafe { nil }
	on_status      StatusSink     = unsafe { nil }
	on_tool_output ToolOutputSink = unsafe { nil }
	causation_id   string
}

// execute_tool runs one call, with everything that has to happen around it.
pub fn (mut a Agent) execute_tool(mut ev ToolEvent, opts ExecOpts) {
	started := time.now()
	tool := a.tools[ev.name] or {
		ev.status = 'error'
		mut names := a.tools.keys()
		names.sort()
		ev.result = "ERROR: unknown tool '${ev.name}'. Available: " + names.join(', ')
		return
	}

	// attribution — an orphan is refused before execution
	attribution := a.attribute(ev.name)
	ev.clause_id = attribution.clause_id
	if attribution.orphan != '' {
		ev.status = 'blocked'
		ev.result = 'ERROR: blocked — ${attribution.orphan}'
		a.log.append('tool.blocked', {
			'name':   json2.Any(ev.name)
			'reason': json2.Any(attribution.orphan)
		}, AppendOpts{ causation_id: opts.causation_id })
		return
	}

	block := a.gate(&tool, ev.args)
	if block != '' && block != gate_ask {
		ev.status = 'blocked'
		ev.result = 'ERROR: blocked — ${block}'
		a.log.append('tool.blocked', {
			'name':   json2.Any(ev.name)
			'reason': json2.Any(block)
		}, AppendOpts{
			causation_id:   opts.causation_id
			correlation_id: attribution.clause_id
		})
		return
	}

	needs_ask := block == gate_ask
		|| (tool.risk == risk_confirm && !a.cfg.auto_approve && a.autonomy < 4)
	if needs_ask && !a.cfg.auto_approve {
		approved := if opts.approve != unsafe { nil } {
			opts.approve(&tool, ev.args)
		} else {
			// nobody to ask means nobody approved. Treating an absent
			// human as a yes is how an unattended session does the one
			// thing it was supposed to ask about.
			false
		}
		if !approved {
			ev.status = 'denied'
			ev.result = 'ERROR: user denied this action. Ask the user how to proceed ' + 'or choose another approach.'
			return
		}
	}

	// the snapshot comes BEFORE any mutation: no write without a committed
	// recovery path
	mut snapshot_tree := ''
	mut snapshot_paths := []string{}
	if ev.name in mutating_tool_names {
		paths := a.snapshot_paths(ev.name, ev.args)
		if paths.len > 0 {
			snap := a.store.take(paths)
			// kept here as well as in the event: rewind and revert read
			// the tree back from snapshot.taken, but reverting THIS call
			// needs it now
			snapshot_tree = snap.tree
			snapshot_paths = paths.clone()
			mut sealed_paths := snap.paths.keys()
			sealed_paths.sort()
			a.log.append('snapshot.taken', {
				'tree':        json2.Any(snap.tree)
				'paths':       json2.Any(strs_to_any(sealed_paths))
				'before_tool': json2.Any(ev.name)
			}, AppendOpts{
				actor:          'kernel'
				causation_id:   opts.causation_id
				correlation_id: attribution.clause_id
			})
		}
	}

	a.log.append('tool.call', {
		'name': json2.Any(ev.name)
		'args': json2.Any(ev.args.clone())
	}, AppendOpts{
		actor:          'sovereign'
		provenance:     'model'
		causation_id:   opts.causation_id
		correlation_id: attribution.clause_id
	})

	if opts.on_status != unsafe { nil } {
		opts.on_status('running:${ev.name}')
	}

	// if the speculator already prefetched this exact read-only call, the
	// cached result is served instead of running it again
	if cached := a.speculator.serve(ev.name, ev.args) {
		ev.result = cached
		ev.status = 'done'
	} else {
		sink := if opts.on_tool_output != unsafe { nil }
			&& ev.name in ['run_command', 'live_shell'] {
			OutputSink(opts.on_tool_output)
		} else {
			OutputSink(no_sink)
		}
		ev.result = tool.handler(ev.args, sink)
		ev.status = 'done'
	}
	// Most handlers report failure as an 'ERROR: …' string rather than
	// failing outward. Those count as errors too, or the dead-end ledger
	// would never see the failures that actually happen.
	if ev.status == 'done' && ev.result.starts_with('ERROR:') {
		ev.status = 'error'
	}
	ev.duration = (time.now() - started).seconds()

	// The boundary's other half. The gate judged an intention; this judges
	// what occurred. A call whose real effects broke a clause is reverted
	// to the snapshot taken before it ran, so a step nobody could analyse
	// ahead of time still does not get to keep its result.
	if ev.status == 'done' {
		reverted := a.charter.settled(ev.name, ev.args, ev.result, snapshot_tree, snapshot_paths)
		if reverted != '' {
			ev.status = 'error'
			ev.result = reverted
		}
	}

	// after EVERY successful write, the anti-clauses are re-checked
	if ev.status == 'done' && ev.name in mutating_tool_names {
		violations := a.goal.check_anti_clauses()
		if violations.len > 0 {
			v := violations[0]
			ev.result += '\nWARNING: anti-clause ' + jstr(v, 'clause') + ' violated — ' + jstr(v, 'detail') + '. The run cannot close until this is ' + 'repaired or rewound.'
		}
	}

	// oscillation: a file's content flipping A-B-A-B
	if ev.name in ['write_file', 'edit_file'] && ev.status == 'done' {
		p := jstr(ev.args, 'path')
		data := os.read_bytes(p) or { []u8{} }
		if data.len > 0 || os.is_file(p) {
			h := sha256.sum(data).hex()[..16]
			a.file_hashes[p] << h
			if a.loop_det.oscillation(p, a.file_hashes[p]) {
				a.log.append('loop.alert', {
					'kind':   json2.Any('oscillation')
					'path':   json2.Any(p)
					'action': json2.Any('hard stop — present both versions to the human')
				}, AppendOpts{ actor: 'kernel' })
			}
		}
	}

	// a repeated identical failure becomes a deterministic dead-end
	if ev.status == 'error' {
		sig := tool_signature(ev.name, ev.args)
		a.error_counts[sig] = a.error_counts[sig] + 1
		if a.error_counts[sig] == 2 {
			a.memory.record_dead_end(DeadEnd{
				signature:  sig
				reason:     '${ev.name} failed twice: ' + clip_plain(ev.result, 200)
				scope:      'session'
				confidence: 'contextual'
			}) or {}
		}
		// the healer classifies the root cause and seals a lesson, so the
		// same failure is recognised instantly next time. No fixer is
		// attached: the agent reads the diagnosis and decides, and the
		// healer never mutates on its own.
		a.healer.heal(ev.result, '${ev.name} ' + canonical(json2.Any(ev.args.clone())))
	}

	a.loop_det.detect()
}
