module vagent

import time
import x.json2

// slash_state.v — the commands that read or move the event log:
// /workflow, /export, /health, /notify, /resume, /state, /rewind, /revert,
// /fork, /why, /impact, /forge.
//
// These are the verbs that make the log visible. Two of them (/rewind and
// /revert) also move it, and both keep the original's discipline: with no
// argument they show you the sequence numbers instead of guessing one, and a
// non-numeric argument is refused rather than read as zero.

fn (mut a Agent) cmd_workflow(arg string) SlashResult {
	sub_raw, rest := split_command(arg)
	sub := if sub_raw == '' { 'list' } else { sub_raw }
	if sub == 'list' {
		return info_result(a.workflows.format_list(), c_cyan)
	}
	if sub == 'run' {
		if rest == '' {
			return error_result('usage: /workflow run <name>')
		}
		report := a.workflows.run(rest, 240.0) or {
			return error_result(err.msg())
		}
		colour := if report.state == 'DONE' { c_green } else { c_red }
		return SlashResult{
			lines: [
				info_line("⚙ running workflow '${rest}' …", c_dim),
				info_line(a.workflows.format_report(&report), colour),
			]
		}
	}
	if sub == 'delete' {
		gone := a.workflows.delete(rest) or { false }
		if gone {
			return info_result("✓ workflow '${rest}' deleted", c_yellow)
		}
		return error_result("no such workflow: '${rest}'")
	}
	return error_result('workflow subcommands: list · run <name> · delete <name>')
}

fn (mut a Agent) cmd_export(arg string) SlashResult {
	raw := arg.trim_space().to_lower()
	if raw !in ['', 'md', 'markdown', 'html'] {
		return error_result('usage: /export [md|html]')
	}
	fmt := if raw == 'html' { 'html' } else { 'md' }
	path := a.export_report(fmt) or { return error_result('cannot write report: ${err.msg()}') }
	return info_result('✓ audit report exported → ${path}', c_green)
}

fn (a &Agent) cmd_health() SlashResult {
	mut lines := ['PROVIDER HEALTH']
	lines << '  failovers this session : ${a.failovers}'
	if a.model_errors.len > 0 {
		mut names := a.model_errors.keys()
		names.sort()
		for m in names {
			lines << '  model errors           : ${m} × ${a.model_errors[m]}'
		}
	} else {
		lines << '  model errors           : none'
	}
	fb := jstr(a.cfg.extra, 'failover_model')
	target := if fb != '' { fb } else { 'auto (same provider first)' }
	lines << '  failover target        : ${target}'
	lines << '  set explicit target    : edit config.json -> "failover_model"'
	return info_result(lines.join('\n'), c_cyan)
}

fn (mut a Agent) cmd_notify(arg string) SlashResult {
	state := a.notifier.configure(arg) or { return error_result(err.msg()) }
	return info_result('✓ notifications → ${state}', c_green)
}

fn (mut a Agent) cmd_resume(arg string) SlashResult {
	branch := arg.trim_space()
	if branch == '' {
		catalog := a.sessions_catalog()
		if catalog.len == 0 {
			return info_result('no sessions found', c_dim)
		}
		mut lines := ['SESSIONS — /resume <branch> to continue one:']
		mut shown := catalog.len
		if shown > 12 {
			shown = 12
		}
		for c in catalog[..shown] {
			stamp := if c.started > 0 {
				time.unix(i64(c.started)).local().custom_format('MM-DD HH:mm')
			} else {
				'?'
			}
			sid := if c.session_id != '' { c.session_id } else { '?' }
			lines << '  ◆ ${c.branch:-14} session ${sid} · ${c.events} events · ${stamp}'
		}
		return info_result(lines.join('\n'), c_cyan)
	}
	n := a.resume_session(branch) or { return error_result(err.msg()) }
	return info_result("✓ resumed branch '${branch}' — ${n} message(s) restored from the event log", c_green)
}

fn (mut a Agent) cmd_state() SlashResult {
	st := a.state()
	goal := a.goal.status()
	mut lines := [
		'branch: ${st.branch}   head seq: ${st.head_seq}   events: ${a.log.len()}',
		'cost: ${st.cost_summary()}',
		'tool calls: ${st.tool_calls}   errors: ${st.tool_errors}   commands: ${st.commands_run}',
		'autonomy: L${st.autonomy}',
	]
	if st.files_touched.len > 0 {
		lines << 'files touched: ' + st.touched_files().join(', ')
	}
	if goal.active {
		mut proven := 0
		for c in goal.clauses {
			if c.state == 'PROVEN' {
				proven++
			}
		}
		pct := (1.0 - goal.distance) * 100.0
		lines << 'goal: ${goal.statement} — ${proven}/${goal.clauses.len} clauses (${pct:.0f}% done)'
	}
	if st.dead_ends.len > 0 {
		lines << 'dead ends: ${st.dead_ends.len}'
	}
	if st.verdicts.len > 0 {
		mut passed := 0
		for v in st.verdicts {
			if jbool(v, 'passed') {
				passed++
			}
		}
		lines << 'judge verdicts: ${passed}/${st.verdicts.len} passed'
	}
	if st.episodes.len > 0 {
		lines << 'memory episodes: ${st.episodes.len}'
	}
	return info_result(lines.join('\n'), c_cyan)
}

// event_preview is the one-line gist of an event, as /rewind and /why show
// it: the text of a message, the name of a tool call, nothing otherwise.
fn event_preview(ev &Event, cap int) string {
	mut s := ''
	if ev.typ in ['user.message', 'assistant.message'] {
		s = jstr(ev.data, 'text')
	} else if ev.typ in ['tool.call', 'tool.result'] {
		s = jstr(ev.data, 'name')
	}
	if s.len > cap {
		s = s[..cap]
	}
	return s
}

fn (mut a Agent) cmd_rewind(arg string) SlashResult {
	if arg == '' {
		all := a.log.events(a.log.branch)
		mut start := all.len - 12
		if start < 0 {
			start = 0
		}
		evs := all[start..]
		if evs.len == 0 {
			return info_result('log is empty', c_dim)
		}
		mut lines := ['recent events (pick a seq, then /rewind <seq>):']
		for ev in evs {
			lines << '  ${ev.seq:4}  ${ev.typ:-20} ${event_preview(ev, 50)}'
		}
		return info_result(lines.join('\n'), c_dim)
	}
	seq := parse_int_strict(arg) or {
		return error_result('usage: /rewind <seq>  (see /rewind for seqs)')
	}
	new_head, kept := a.rewind_to(seq)
	return info_result('✓ rewound to seq ${new_head} — ${kept} message(s) kept (tool-call context is dropped)', c_green)
}

fn (mut a Agent) cmd_fork(arg string) SlashResult {
	branch := a.fork_timeline(arg)
	return info_result("✓ forked timeline → branch '${branch}' (now continuing on it)", c_green)
}

// cmd_revert is §9.1: files only return to seq N — the agent KEEPS its
// memory. This is what feeds the Dead-End Ledger.
fn (mut a Agent) cmd_revert(arg string) SlashResult {
	if arg == '' {
		return error_result('usage: /revert <seq>  (see /rewind for seqs)')
	}
	seq := parse_int_strict(arg) or { return error_result('usage: /revert <seq>') }
	result := a.revert_files_to(seq)
	if 'error' in result {
		return error_result(jstr(result, 'error'))
	}
	return info_result('✓ files reverted to seq ${seq} — ${jint(result, 'restored')} restored, ${jint(result, 'removed')} removed (agent memory kept)', c_green)
}

// cmd_why is Appendix A `argus why`: walk the causation chain from an event
// back to the human instruction that caused it.
fn (mut a Agent) cmd_why(arg string) SlashResult {
	if arg == '' {
		return error_result('usage: /why <seq>  (see /rewind for seqs)')
	}
	seq := parse_int_strict(arg) or { return error_result('usage: /why <seq>') }
	evs := a.log.events(a.log.branch)
	mut target := Event{}
	mut found := false
	for e in evs {
		if e.seq == seq {
			target = e
			found = true
			break
		}
	}
	if !found {
		return error_result('no event at seq ${seq}')
	}
	chain := a.log.why(target.id, 50)
	mut lines := ['causal chain for seq ${seq} (${target.typ}):']
	for i, ev in chain {
		indent := '  '.repeat(i)
		clause := if cid := ev.correlation_id { '  [clause ${cid}]' } else { '' }
		lines << '${indent}← seq ${ev.seq} ${ev.typ} (${ev.actor}) ${event_preview(ev, 40)}${clause}'
	}
	return info_result(lines.join('\n'), c_cyan)
}

// cmd_impact is §15.2, the killer query: blast radius of changing a symbol.
// Indexing a tree is slow, so it runs as a job off the event thread.
fn (a &Agent) cmd_impact(arg string) SlashResult {
	symbol, rest := split_command(arg)
	if symbol == '' {
		return error_result('usage: /impact <symbol> [path]')
	}
	path := if rest != '' { rest } else { '.' }
	return SlashResult{
		lines:   [info_line('⠹ indexing ${path}…', c_dim)]
		job:     'impact'
		job_arg: '${symbol}\t${path}'
	}
}

fn (mut a Agent) cmd_forge(arg string) SlashResult {
	if arg.trim_space().to_lower() == 'drift' {
		delta := a.forge.drift() or { return info_result('✓ no environment drift detected', c_green) }
		return info_result('⚠ environment drift: ${delta.changed}', c_yellow)
	}
	d := a.forge.probe()
	mut lines := [
		'environment digest: ${jstr(d, 'digest')}',
		'  os ${jstr(d, 'os')} ${jstr(d, 'arch')}   runtime ${jstr(d, 'runtime')}',
		'  cwd ${jstr(d, 'cwd')}',
		'  lockfile ${if jstr(d, 'lockfile_hash') != '' { jstr(d, 'lockfile_hash') } else { 'none' }}',
	]
	tools := d['tools'] or { json2.Any(map[string]json2.Any{}) }
	if tools is map[string]json2.Any {
		if tools.len > 0 {
			mut names := tools.keys()
			names.sort()
			mut parts := []string{}
			for k in names {
				v := (tools[k] or { json2.Any('') }).str()
				first := v.fields()
				parts << '${k}=${if first.len > 0 { first[0] } else { '?' }}'
			}
			lines << '  tools: ' + parts.join(', ')
		}
	}
	return info_result(lines.join('\n'), c_cyan)
}
