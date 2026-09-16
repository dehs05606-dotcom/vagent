module vagent

import x.json2

// replay.v — re-deriving the decisions, to prove they were the right ones.
//
// witness.v proves the enforcement RECORD is complete and unedited. That is
// a real property and it is not the one an operator actually wants, because
// a chain records what was decided, not whether the decision was correct.
// Both of these produce a perfect, intact, gap-free chain:
//
//     a boundary that judged every call correctly
//     a boundary whose rules were wrong, or were not the rules you think
//
// The chain cannot tell them apart. It commits to "write_file was refused by
// clause 1" — never to the fact that clause 1, applied to those arguments,
// actually refuses. A guard with an inverted comparison, a specification
// quietly different from the one you read, a subsystem that returned early
// on an exception: each produces decisions that chain perfectly and are
// wrong.
//
// So replay closes the last gap by RE-DERIVING. Every tool call in the log
// is judged again, now, from a specification you supply, and the fresh
// verdict is compared to the one that was recorded:
//
//     AGREED       re-judging produces the recorded verdict
//     DIVERGED     it does not — the rules today would decide differently
//     UNWITNESSED  the call has no decision at all: enforcement did not run
//
// DIVERGED is the interesting one, and it is deliberately not called
// "wrong": it has two causes and replay cannot distinguish them from the log
// alone. Either the rules CHANGED since the call (expected, and often fine),
// or they did not and the decision does not follow from them. Which it is
// depends on whether the specification is the same one, and integrity.v
// answers that. Naming a cause it cannot establish would be the overreach
// this package refuses everywhere else.
//
// The point of all this: enforcement stops being something you trust because
// the code looks right. Hand someone the log and the specification and they
// can derive every decision themselves, on their own machine, with no access
// to the process that made them.

pub const replay_agreed = 'agreed'
pub const replay_diverged = 'diverged'
pub const replay_unwitnessed = 'unwitnessed'

pub struct ReplayRow {
pub:
	seq       int
	tool      string
	state     string
	recorded  string
	rederived string
	clauses   []string
}

pub fn (r &ReplayRow) to_json() map[string]json2.Any {
	return {
		'seq':       json2.Any(r.seq)
		'tool':      json2.Any(r.tool)
		'state':     json2.Any(r.state)
		'recorded':  json2.Any(r.recorded)
		'rederived': json2.Any(r.rederived)
		'clauses':   json2.Any(r.clauses.map(json2.Any(it)))
	}
}

pub fn (r &ReplayRow) describe() string {
	if r.state == replay_unwitnessed {
		return 'seq ${r.seq} ${r.tool}: no decision was recorded — enforcement did not run for this call'
	}
	tail := if r.clauses.len > 0 { ' (${r.clauses.join(", ")})' } else { '' }
	return 'seq ${r.seq} ${r.tool}: recorded ${r.recorded}, re-deriving gives ${r.rederived}${tail}'
}

pub struct ReplayResult {
pub mut:
	rows         []ReplayRow
	agreed       int
	diverged     int
	unwitnessed  int
	chain_intact bool = true
}

pub fn (r &ReplayResult) ok() bool {
	return r.chain_intact && r.diverged == 0 && r.unwitnessed == 0
}

pub fn (r &ReplayResult) problems() []ReplayRow {
	return r.rows.filter(it.state != replay_agreed)
}

pub fn (r &ReplayResult) describe() string {
	if r.rows.len == 0 {
		return 'replay: no gated calls in this log'
	}
	mut head := 'replay: ${r.rows.len} call(s) re-derived · ${r.agreed} agreed · ' +
		'${r.diverged} diverged · ${r.unwitnessed} unwitnessed'
	if !r.chain_intact {
		head += '\n  !! the witness chain itself is broken — the record was edited, so agreement below proves nothing'
	}
	if r.ok() {
		return head + '\n  every recorded decision follows from these rules'
	}
	problems := r.problems()
	mut lines := [head]
	for row in problems[..min_int(20, problems.len)] {
		lines << '  !! ${row.describe()}'
	}
	if problems.len > 20 {
		lines << '  … and ${problems.len - 20} more'
	}
	if r.diverged > 0 {
		lines << '  a divergence means the rules today decide differently — either they changed since, or the decision did not follow from them. integrity.v says which.'
	}
	return lines.join('\n')
}

struct GatedCall {
	seq  int
	tool string
	args map[string]json2.Any
}

fn gated_calls(mut log EventLog) []GatedCall {
	mut out := []GatedCall{}
	for ev in log.events(log.branch) {
		if ev.typ != 'tool.call' {
			continue
		}
		name := jstr(ev.data, 'name')
		if name == '' {
			continue
		}
		out << GatedCall{
			seq:  ev.seq
			tool: name
			args: jmap(ev.data, 'args')
		}
	}
	return out
}

// replay_decisions re-judges every gated call in `log` under `spec`.
//
// The original called it replay(); kernel.v already has a replay() that
// walks the events of a branch, and this port is one flat V module, so the
// re-derivation carries the longer name.
//
// It deliberately rebuilds the subsystems from scratch rather than reusing a
// live Charter: reusing the object that made the decisions would be the same
// process vouching for itself, which is what this module exists to avoid.
pub fn replay_decisions(mut log EventLog, spec string, chain []map[string]json2.Any, has_chain bool) ReplayResult {
	mut res := ReplayResult{}

	mut decisions := chain.clone()
	if !has_chain {
		decisions = []map[string]json2.Any{}
		for ev in log.events(log.branch) {
			if ev.typ == 'witness.decision' {
				decisions << ev.data.clone()
			}
		}
	}
	res.chain_intact = if decisions.len > 0 { witness_check(decisions).intact } else { true }

	// the recorded verdicts, in order, by tool
	mut pending := map[string][]map[string]json2.Any{}
	for d in decisions {
		tool := jstr(d, 'tool')
		pending[tool] << d.clone()
	}

	// a fresh boundary, built only from the specification
	mut cov := new_covenant(log, spec)
	mut seq := new_timeline(log, spec)
	mut lin := new_lineage(log, spec)
	mut per := new_perimeter(log, spec)
	mut hor := new_horizon(log, spec)

	for call in gated_calls(mut log) {
		if pending[call.tool].len == 0 {
			res.rows << ReplayRow{
				seq:   call.seq
				tool:  call.tool
				state: replay_unwitnessed
			}
			res.unwitnessed++
			continue
		}
		d := pending[call.tool][0].clone()
		pending[call.tool].delete(0)

		mut clauses := []string{}
		seq_found := seq.check(call.tool, call.args)
		if seq_found.len > 0 {
			clauses = seq_found.map(it.clause)
		}
		if clauses.len == 0 {
			cov_found := cov.check(call.tool, call.args)
			if cov_found.len > 0 {
				clauses = cov_found.map(it.clause)
			}
		}
		if clauses.len == 0 {
			lin_found := lin.check(call.tool, call.args)
			if lin_found.len > 0 {
				clauses = lin_found.map(it.clause)
			}
		}
		if clauses.len == 0 {
			per_found := per.check(call.tool, call.args)
			if per_found.len > 0 {
				clauses = per_found.map(it.clause)
			}
		}
		if clauses.len == 0 {
			hor_found := hor.project(call.tool, call.args)
			if hor_found.len > 0 {
				clauses = hor_found.map(it.clause)
			}
		}
		rederived := if clauses.len > 0 { verdict_refused } else { verdict_allowed }
		was := jstr(d, 'verdict')

		if rederived == was {
			res.rows << ReplayRow{
				seq:       call.seq
				tool:      call.tool
				state:     replay_agreed
				recorded:  was
				rederived: rederived
				clauses:   clauses
			}
			res.agreed++
		} else {
			res.rows << ReplayRow{
				seq:       call.seq
				tool:      call.tool
				state:     replay_diverged
				recorded:  was
				rederived: rederived
				clauses:   clauses
			}
			res.diverged++
		}
	}
	return res
}

// replay_independent verifies with no EventLog at all — decisions, calls and
// a specification.
//
// This is the form you hand to someone who does not trust the process that
// produced the record: three plain values, and a verdict they can compute
// themselves.
pub fn replay_independent(decisions []map[string]json2.Any, calls []GatedCall, spec string) ReplayResult {
	mut scratch := new_event_log(tmp_log_path('replay-independent-${now_ts():.0f}'), 'main',
		'replay')
	for call in calls {
		scratch.append('tool.call', {
			'name': json2.Any(call.tool)
			'args': json2.Any(call.args.clone())
		}, AppendOpts{})
	}
	return replay_decisions(mut scratch, spec, decisions, true)
}

// make_gated_call builds the plain call value replay_independent takes.
pub fn make_gated_call(seq int, tool string, args map[string]json2.Any) GatedCall {
	return GatedCall{
		seq:  seq
		tool: tool
		args: args.clone()
	}
}
