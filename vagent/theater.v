module vagent

import x.json2

// theater.v — the time-travel debugger for agent cognition.
//
// The kernel records everything; the theater makes it navigable like film:
//
//     frames          every event is a frame, and frame(seq) reconstructs
//                     the ENTIRE agent state at that instant — the
//                     conversation so far, the cost, the tool calls, the
//                     files touched, the goal
//     why             the causal envelope already sealed in every event
//                     renders as an indented proof tree. "Why did the agent
//                     do X?" is answered from evidence rather than
//                     reconstructed afterwards.
//     diff            the state at a against the state at b: exactly what
//                     changed between two moments
//     counterfactual  fork the timeline at a seq and replay it with that
//                     one event REMOVED. "What if the agent had not made
//                     that call?" The counterfactual branch is real: it can
//                     be checked out, resumed, merged. The divergence
//                     report says what actually changed.
//
// Everything is a pure fold. No model is consulted, and the answers are
// deterministic — which is the whole point of asking the log rather than
// asking the agent.

// the ceiling on a counterfactual replay, so a long timeline cannot turn one
// question into an unbounded rewrite
const max_cf_replay = 400

// the causal-chain depth a `why` walks back, matching the kernel's own
const why_chain_depth = 50

pub struct FrameState {
pub mut:
	messages      int
	tool_calls    int
	tool_errors   int
	cost_usd      f64
	files_touched []string
	goal          ?Rec
}

// TheaterFrame is the agent's world at one seq.
pub struct TheaterFrame {
pub mut:
	seq     int
	typ     string
	summary string
	state   FrameState
}

pub fn (f &TheaterFrame) format() string {
	mut lines := [
		'FRAME seq ${f.seq} — ${f.typ}',
		'  ${f.summary}',
	]
	lines << '  conversation: ${f.state.messages} msgs · tool calls: ' + '${f.state.tool_calls} · errors: ${f.state.tool_errors} · ' + 'cost: \$${f.state.cost_usd:.4f}'
	if f.state.files_touched.len > 0 {
		mut files := f.state.files_touched.clone()
		files.sort()
		if files.len > 10 {
			files = files[..10].clone()
		}
		lines << '  files touched: ' + files.join(', ')
	}
	if goal := f.state.goal {
		lines << '  goal: ' + clip_plain(jstr(goal, 'statement'), 80)
	}
	return lines.join('\n')
}

pub struct StripFrame {
pub:
	seq     int
	typ     string
	actor   string
	summary string
}

pub fn (f &StripFrame) to_json() map[string]json2.Any {
	return {
		'seq':     json2.Any(f.seq)
		'type':    json2.Any(f.typ)
		'actor':   json2.Any(f.actor)
		'summary': json2.Any(f.summary)
	}
}

@[heap]
pub struct Theater {
pub mut:
	log &EventLog
}

pub fn new_theater(log &EventLog) &Theater {
	return &Theater{
		log: unsafe { log }
	}
}

// -- frames ---------------------------------------------------------------------

// frames is every event as a slim frame — the scrubber strip.
pub fn (mut t Theater) frames(branch string) []StripFrame {
	mut out := []StripFrame{}
	for ev in t.log.events(branch) {
		out << StripFrame{
			seq:     ev.seq
			typ:     ev.typ
			actor:   ev.actor
			summary: frame_summary(&ev)
		}
	}
	return out
}

// frame reconstructs the full state AT seq, inclusive.
pub fn (mut t Theater) frame(seq int) ?TheaterFrame {
	mut target := ?Event(none)
	for ev in t.log.events(t.log.branch) {
		if ev.seq == seq {
			target = ev
			break
		}
	}
	found := target or { return none }
	st := fold_window(mut t.log, t.log.branch, seq, -1)
	mut files := []string{}
	for path, _ in st.files_touched {
		files << path
	}
	files.sort()
	return TheaterFrame{
		seq:     seq
		typ:     found.typ
		summary: frame_summary(&found)
		state:   FrameState{
			messages:      st.messages.len
			tool_calls:    st.tool_calls
			tool_errors:   st.tool_errors
			cost_usd:      st.cost_usd
			files_touched: files
			goal:          st.goal
		}
	}
}

// -- why ------------------------------------------------------------------------

// why is the causal proof tree behind the event at seq, read out of the
// sealed envelope rather than inferred.
pub fn (mut t Theater) why(seq int) string {
	mut target := ?Event(none)
	for ev in t.log.events(t.log.branch) {
		if ev.seq == seq {
			target = ev
			break
		}
	}
	found := target or { return 'no event at seq ${seq}' }
	// 50 is the kernel's own default depth for a causal walk: deep enough
	// that a real chain reaches its root, bounded so a cycle cannot hang it
	chain := t.log.why(found.id, why_chain_depth)
	mut lines := ['WHY seq ${seq} (${found.typ}) — causal chain, root cause last:']
	for i, ev in chain {
		summary := frame_summary(&ev)
		suffix := if summary != '' { ' · ${summary}' } else { '' }
		lines << '  '.repeat(i + 1) + '← seq ${ev.seq} ${ev.typ} (${ev.actor})${suffix}'
	}
	return lines.join('\n')
}

// -- diff -----------------------------------------------------------------------

// diff is what changed between two moments, at the level of the fold.
pub fn (mut t Theater) diff(a int, b int) string {
	sa := fold_window(mut t.log, t.log.branch, a, -1)
	sb := fold_window(mut t.log, t.log.branch, b, -1)
	added := if sb.messages.len > sa.messages.len {
		sb.messages[sa.messages.len..].clone()
	} else {
		[]Message{}
	}
	mut new_files := []string{}
	for path, _ in sb.files_touched {
		if path !in sa.files_touched {
			new_files << path
		}
	}
	new_files.sort()
	mut files_line := '  files      ${sa.files_touched.len} → ${sb.files_touched.len}'
	if new_files.len > 0 {
		mut head := new_files.clone()
		if head.len > 5 {
			head = head[..5].clone()
		}
		files_line += '  (+' + head.join(', ') + ')'
	}
	mut lines := [
		'DIFF seq ${a} → seq ${b}',
		'  messages  ${sa.messages.len} → ${sb.messages.len} (+${added.len})',
		'  tool calls ${sa.tool_calls} → ${sb.tool_calls}',
		'  errors     ${sa.tool_errors} → ${sb.tool_errors}',
		'  cost       \$${sa.cost_usd:.4f} → \$${sb.cost_usd:.4f}',
		files_line,
	]
	mut tail := added.clone()
	if tail.len > 3 {
		tail = tail[tail.len - 3..].clone()
	}
	for m in tail {
		lines << '    + [${m.role}] ' + clip_plain(m.text(), 100)
	}
	return lines.join('\n')
}

// -- counterfactual ---------------------------------------------------------------

pub struct Divergence {
pub:
	messages_with      int
	messages_without   int
	tool_calls_with    int
	tool_calls_without int
	files_with         []string
	files_without      []string
}

pub fn (d &Divergence) to_json() map[string]json2.Any {
	return {
		'messages_with':      json2.Any(d.messages_with)
		'messages_without':   json2.Any(d.messages_without)
		'tool_calls_with':    json2.Any(d.tool_calls_with)
		'tool_calls_without': json2.Any(d.tool_calls_without)
		'files_with':         json2.Any(strs_to_any(d.files_with))
		'files_without':      json2.Any(strs_to_any(d.files_without))
	}
}

pub struct CounterfactualReport {
pub:
	branch          string
	removed_seq     int
	removed_type    string
	removed_summary string
	events_replayed int
	divergence      Divergence
}

pub fn (r &CounterfactualReport) to_json() map[string]json2.Any {
	return {
		'branch':          json2.Any(r.branch)
		'removed_seq':     json2.Any(r.removed_seq)
		'removed_type':    json2.Any(r.removed_type)
		'removed_summary': json2.Any(r.removed_summary)
		'events_replayed': json2.Any(r.events_replayed)
		'divergence':      json2.Any(r.divergence.to_json())
	}
}

// counterfactual forks the timeline at seq and replays everything after it
// with the event at seq REMOVED.
//
// The result is a real branch: it can be checked out, resumed and merged
// like any other timeline, which is what separates this from a simulation.
pub fn (mut t Theater) counterfactual(seq int, name string) !CounterfactualReport {
	mut target := ?Event(none)
	for ev in t.log.events(t.log.branch) {
		if ev.seq == seq {
			target = ev
			break
		}
	}
	found := target or { return error('no event at seq ${seq}') }

	mut branch := if name != '' { name } else { 'cf/${seq}-${found.typ}' }
	// never clobber an existing branch: a second counterfactual at the same
	// seq would silently rewind the first one's head
	existing := t.log.branches()
	if branch in existing {
		mut n := 2
		for '${branch}-${n}' in existing {
			n++
		}
		branch = '${branch}-${n}'
	}

	// the state WITH the event, for the comparison
	before := fold_window(mut t.log, t.log.branch, seq, -1)
	original_branch := t.log.branch

	// Fork from the event BEFORE the removed one. fork_at rather than fork,
	// because removing the very first event leaves nothing to hang from and
	// a default-to-head fork would produce a branch containing exactly the
	// history the caller asked to remove.
	created := t.log.fork_at(seq - 1, branch)
	branch = created

	mut replayed := 0
	source := t.log.events(original_branch)
	t.log.checkout(branch)
	for ev in source {
		if ev.seq <= seq || ev.typ in ['kernel.rewind', 'kernel.branch'] {
			continue
		}
		if replayed >= max_cf_replay {
			break
		}
		t.log.append(ev.typ, ev.data.clone(), AppendOpts{
			actor:      'cf'
			provenance: ev.provenance
		})
		replayed++
	}
	t.log.checkout(original_branch)

	after := fold(mut t.log, branch)
	report := CounterfactualReport{
		branch:          branch
		removed_seq:     seq
		removed_type:    found.typ
		removed_summary: frame_summary(&found)
		events_replayed: replayed
		divergence:      Divergence{
			messages_with:      before.messages.len
			messages_without:   after.messages.len
			tool_calls_with:    before.tool_calls
			tool_calls_without: after.tool_calls
			files_with:         first_files(before.files_touched)
			files_without:      first_files(after.files_touched)
		}
	}
	t.log.append('theater.counterfactual', report.to_json(), AppendOpts{ actor: 'human' })
	return report
}

fn first_files(touched map[string]bool) []string {
	mut out := []string{}
	for path, _ in touched {
		out << path
	}
	out.sort()
	if out.len > 10 {
		out = out[..10].clone()
	}
	return out
}

pub fn (t &Theater) format_cf(report &CounterfactualReport) string {
	d := report.divergence
	return [
		'COUNTERFACTUAL — removed seq ${report.removed_seq} (${report.removed_type})',
		'  event: ${report.removed_summary}',
		"  branch '${report.branch}' carries the world without it " + '(${report.events_replayed} events replayed)',
		'  messages: with ${d.messages_with} → without ${d.messages_without}',
		'  tool calls: ${d.tool_calls_with} → ${d.tool_calls_without}',
		'  files: with ${d.files_with.len} → without ${d.files_without.len}',
		'  checkout with: /branch ${report.branch}',
	].join('\n')
}

// frame_summary is the one-line essence of an event, for frames and whys.
fn frame_summary(ev &Event) string {
	d := ev.data.clone()
	match ev.typ {
		'user.message', 'assistant.message' {
			return clip_plain(jstr(d, 'text'), 100)
		}
		'tool.call' {
			return jstr(d, 'name') + ' ' + clip_plain(canonical(jget(d, 'args')), 80)
		}
		'tool.result' {
			return jstr(d, 'name') + ' → ' + jstr(d, 'status')
		}
		'goal.set' {
			return clip_plain(jstr(d, 'statement'), 100)
		}
		'fact.learned' {
			return clip_plain(jstr(d, 'fact'), 100)
		}
		'crew.done' {
			return '[' + jstr(d, 'role') + '] ' + clip_plain(jstr(d, 'summary'), 80)
		}
		else {
			return ''
		}
	}
}
