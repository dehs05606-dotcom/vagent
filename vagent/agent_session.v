module vagent

import os
import x.json2

// agent_session.v — autonomy, focus mode, sessions and time travel.
//
// The two time-travel verbs are deliberately different, and the difference
// is the whole point:
//
//   rewind  — the filesystem AND the agent's state return to step N. The
//             old branch stays intact; nothing is destroyed.
//   revert  — only the filesystem returns. The agent KEEPS its memory of
//             what happened, which is what feeds the dead-end ledger: the
//             files go back, the lesson stays.

// set_autonomy moves the ladder, within what the contract allows.
pub fn (mut a Agent) set_autonomy(requested int) string {
	mut level := requested
	if level < 0 {
		level = 0
	}
	if level > 5 {
		level = 5
	}
	// the contract's ceiling cannot be raised by the agent
	if a.goal.status().active {
		if ceiling := a.goal_autonomy_ceiling() {
			if level > ceiling {
				level = ceiling
			}
		}
	}
	a.autonomy = level
	a.log.append('autonomy.changed', {
		'level': json2.Any(level)
	}, AppendOpts{ actor: 'human' })
	return autonomy_levels[level] or { '' }
}

fn (mut a Agent) goal_autonomy_ceiling() ?int {
	goal := a.state().goal or { return none }
	if 'autonomy_ceiling' !in goal {
		return none
	}
	return jint(goal, 'autonomy_ceiling')
}

// -- focus mode ----------------------------------------------------------------

// focus_continue decides whether the deep-work loop keeps going, and returns
// the next continuation prompt when it does.
//
// Every decision is sealed, because autonomous work must never be invisible.
// The stop conditions are mechanical:
//
//   * the turn errored, was cancelled, or the budget paused it
//   * the goal closed, or every clause is proven or waived
//   * the distance stalled — no improvement for three consecutive ticks
//   * with no goal, the agent answered twice in a row without tool work,
//     which is it saying it believes itself done
pub fn (mut a Agent) focus_continue(last_turn &Turn, remaining int) ?string {
	status := a.goal.status()

	if last_turn.error != '' {
		a.focus_stop('turn ended with: ' + clip_plain(last_turn.error, 80))
		return none
	}

	if status.active {
		open_clauses := status.clauses.filter(it.state in ['OPEN', 'REGRESSED'])
		if open_clauses.len == 0 || status.closed_state in terminal_states {
			a.focus_stop('goal achieved — every clause proven or waived')
			return none
		}
		distance := status.distance
		a.focus_history << distance
		recent := tail_f64(a.focus_history, 4)
		if recent.len >= 4 {
			mut stalled := true
			for i in 1 .. recent.len {
				if recent[i] < recent[i - 1] - 1e-9 {
					stalled = false
					break
				}
			}
			if stalled {
				a.focus_stop('stalled — distance stuck at ${distance:.2f} for 3 ticks; ' + 'needs a human decision')
				return none
			}
		}
		focus_clause := if status.focus != '' { status.focus } else { open_clauses[0].id }
		a.log.append('focus.tick', {
			'distance':  json2.Any(distance)
			'remaining': json2.Any(remaining)
			'focus':     json2.Any(focus_clause)
		}, AppendOpts{ actor: 'kernel' })
		return 'CONTINUE — deep-work mode (${remaining} turns left). Goal: ' + '${status.statement}. Current focus: clause ${focus_clause}. ' + 'Distance to done: ${distance:.2f}. Do NOT repeat completed work ' + 'and do NOT re-prove PROVEN clauses. Take the next concrete step ' + 'that moves clause ${focus_clause} forward, then verify it.'
	}

	// no active goal — stop once the agent is clearly done
	worked := last_turn.tools.len > 0
	a.focus_history << if worked { 1.0 } else { 0.0 }
	tail := tail_f64(a.focus_history, 2)
	if tail.len == 2 && tail[0] == 0.0 && tail[1] == 0.0 {
		a.focus_stop('agent answered without further tool work — done')
		return none
	}
	a.log.append('focus.tick', {
		'remaining': json2.Any(remaining)
	}, AppendOpts{ actor: 'kernel' })
	return 'CONTINUE — deep-work mode (${remaining} turns left). Review what is ' + 'done, verify it against reality, and complete whatever is still ' + 'missing. Do not repeat completed work.'
}

fn (mut a Agent) focus_stop(reason string) {
	a.log.append('focus.stop', {
		'reason': json2.Any(reason)
	}, AppendOpts{ actor: 'kernel' })
	a.focus_history = []
}

fn tail_f64(items []f64, n int) []f64 {
	return if items.len > n { items[items.len - n..].clone() } else { items.clone() }
}

// -- reports ----------------------------------------------------------------------

// export_report writes the audit report next to the project.
pub fn (mut a Agent) export_report(fmt string) !string {
	title := 'FullAgent session ${a.session_id}'
	text, suffix := if fmt == 'html' {
		export_html(mut a.log, title), '.html'
	} else {
		export_markdown(mut a.log, title), '.md'
	}
	path := os.join_path(a.cwd, 'fullagent-report-${a.session_id}${suffix}')
	os.write_file(path, text) or { return error('cannot write ${path}: ${err}') }
	a.log.append('report.exported', {
		'path':   json2.Any(path)
		'format': json2.Any(fmt)
	}, AppendOpts{ actor: 'human' })
	return path
}

pub fn (mut a Agent) get_forecast() string {
	f := forecast(mut a.log)
	return format_forecast(&f)
}

// -- sessions ----------------------------------------------------------------------

pub struct SessionRow {
pub:
	branch     string
	session_id string
	events     int
	head       int
	started    f64
}

// sessions_catalog is every branch that carries a session, newest first.
pub fn (mut a Agent) sessions_catalog() []SessionRow {
	mut catalog := []SessionRow{}
	for branch in a.log.branches() {
		events := a.log.events(branch)
		mut session_id := ''
		mut started := 0.0
		for e in events {
			if e.typ == 'session.start' {
				session_id = jstr(e.data, 'session_id')
				started = e.ts
			}
		}
		catalog << SessionRow{
			branch:     branch
			session_id: session_id
			events:     events.len
			head:       a.log.head(branch)
			started:    started
		}
	}
	catalog.sort_with_compare(fn (x &SessionRow, y &SessionRow) int {
		if x.started != y.started {
			return if x.started > y.started { -1 } else { 1 }
		}
		return if x.branch < y.branch {
			-1
		} else if x.branch > y.branch { 1 } else { 0 }
	})
	return catalog
}

// resume_session checks a branch out and rebuilds the conversation from the
// fold.
//
// The full history — tool calls, verdicts, snapshots — stays in the log. Only
// the model-visible context is rebuilt, from the user and assistant messages.
pub fn (mut a Agent) resume_session(branch string) !int {
	branches := a.log.branches()
	if branch !in branches {
		return error("unknown branch '${branch}' — known: " + branches.join(', '))
	}
	a.log.checkout(branch)
	st := a.state()
	mut session_id := ''
	for e in a.log.events(branch) {
		if e.typ == 'session.start' {
			id := jstr(e.data, 'session_id')
			if id != '' {
				session_id = id
			}
		}
	}
	if session_id != '' {
		a.session_id = session_id
	}
	a.log.session = a.session_id
	a.messages = []
	a.reseat_system_prompt(map[string]string{}, false)
	a.messages << st.messages
	a.turns = []
	a.focus_history = []
	a.log.append('session.resumed', {
		'branch':     json2.Any(branch)
		'session_id': json2.Any(a.session_id)
		'messages':   json2.Any(st.messages.len)
	}, AppendOpts{ actor: 'human' })
	return st.messages.len
}

// save_session writes the model-visible conversation beside the log.
pub fn (mut a Agent) save_session() ?string {
	dir := os.join_path(a.home, 'sessions')
	os.mkdir_all(dir) or { return none }
	path := os.join_path(dir, '${a.session_id}.json')
	// the messages are snapshotted once: a turn thread keeps appending to
	// them, and serialising a growing list is how a save file ends up torn
	messages := a.messages.clone()
	data := json2.encode(json2.Any({
		'session_id': json2.Any(a.session_id)
		'model_id':   json2.Any(a.cfg.model_id)
		'saved_at':   json2.Any(fmt_clock(now_ts()))
		'messages':   json2.Any(messages.map(json2.Any(it.to_json())))
	}))
	atomic_write_text(path, data) or { return none }
	return path
}

// -- time travel --------------------------------------------------------------------

// nearest_snapshot is the snapshot whose captured state matches 'as of seq'.
//
// A snapshot.taken event at seq N records the world immediately BEFORE the
// write it precedes — the state as of N-1. So the state as of S is the newest
// snapshot with seq <= S+1.
fn (mut a Agent) nearest_snapshot(upto_seq int) ?Event {
	mut best := ?Event(none)
	for ev in a.log.events_upto(a.log.branch, upto_seq + 1) {
		if ev.typ == 'snapshot.taken' {
			best = ev
		}
	}
	return best
}

// rewind_to returns the filesystem AND the agent's state to step N.
//
// The old branch stays fully intact: rewinding moves a head, it does not
// destroy history.
pub fn (mut a Agent) rewind_to(seq int) (int, int) {
	if snap := a.nearest_snapshot(seq) {
		a.store.materialise(jstr(snap.data, 'tree'))
	}
	new_head := a.log.rewind(seq, a.log.branch)
	st := fold_window(mut a.log, a.log.branch, new_head, -1)
	a.messages = []
	a.reseat_system_prompt(map[string]string{}, false)
	a.messages << st.messages
	return new_head, st.messages.len
}

// revert_files_to returns only the filesystem to step N.
//
// The agent keeps its memory of what happened, which is exactly what the
// dead-end ledger needs: the files go back, the lesson stays.
pub fn (mut a Agent) revert_files_to(seq int) map[string]json2.Any {
	snap := a.nearest_snapshot(seq) or {
		return {
			'error': json2.Any('no snapshot at or before seq ${seq}')
		}
	}
	tree := jstr(snap.data, 'tree')
	result := a.store.materialise(tree)
	sealed := {
		'to_seq':        json2.Any(seq)
		'tree':          json2.Any(tree)
		'restored':      json2.Any(result.restored)
		'removed':       json2.Any(result.removed)
		'missing_blobs': json2.Any(result.missing_blobs)
		'error':         json2.Any(result.error)
	}
	a.log.append('kernel.revert', sealed, AppendOpts{ actor: 'human' })
	return sealed
}

// fork_timeline branches at the current head and continues on the fork.
pub fn (mut a Agent) fork_timeline(name string) string {
	branch := a.log.fork(-1, name)
	a.log.checkout(branch)
	a.log.append('session.start', {
		'session_id': json2.Any(a.session_id)
		'branch':     json2.Any(branch)
	}, AppendOpts{})
	return branch
}
