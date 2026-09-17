module vagent

import x.json2

// slash_gov.v — the commands that govern the run rather than drive it:
// /budget, /constitution, /replay, /memory, /judge.
//
// The budget governor's defaults are "no ceiling", and it says so out loud
// rather than showing an enormous number and letting the reader work out
// whether it means anything. A limit only exists once a human sets one.

// budget_axis is how a limit is shown: the sentinel defaults are no limit at
// all, and printing 1000000000 in their place would read as a cap that is
// merely large. The original printed Python's float('inf') the same way.
fn budget_axis(value i64, sentinel i64) string {
	return if value >= sentinel { '∞' } else { value.str() }
}

fn (mut a Agent) cmd_budget(arg string) SlashResult {
	parts := arg.fields()
	if parts.len > 0 {
		sub := parts[0].to_lower()
		if sub == 'reset' {
			a.budget_gov.reset()
			return info_result('budget spend reset — the governor counts from now', c_green)
		}
		if sub in ['steps', 'usd', 'tokens', 'files'] && parts.len >= 2 {
			msg := a.budget_gov.set_limit(sub, parts[1]) or {
				return error_result('bad value: ${err.msg()}')
			}
			return info_result(msg, c_green)
		}
		if sub in ['extend', 'set'] && parts.len >= 3
			&& parts[1].to_lower() in ['steps', 'usd', 'tokens', 'files'] {
			msg := a.budget_gov.set_limit(parts[1].to_lower(), parts[2]) or {
				return error_result('bad value: ${err.msg()}')
			}
			return info_result(msg, c_green)
		}
		return error_result('usage: /budget [reset | steps N | usd X | tokens N | files N]')
	}
	s := a.budget_gov.spend()
	b := a.budget_gov.budget
	ok, reason := a.budget_gov.check()
	usd_cap := if b.max_usd >= unlimited_usd { '∞' } else { '${b.max_usd}' }
	mut lines := [
		'budget ${if ok { 'OK' } else { 'BREACHED' }}',
		'  usd    \$${s.usd:.4f} / \$${usd_cap}',
		'  steps  ${s.steps} / ${budget_axis(b.max_steps, 1_000_000_000)}',
		'  tokens ${s.tokens} / ${budget_axis(b.max_tokens, 1_000_000_000_000)}',
		'  files  ${s.files} / ${budget_axis(b.max_files, 100_000_000)}',
		'  spend is UNLIMITED by default — set a cap with /budget steps N · /budget usd X · /budget reset',
	]
	if !ok {
		lines << '  ⚠ ${reason}'
	}
	return info_result(lines.join('\n'), if ok { c_green } else { c_red })
}

fn (mut a Agent) cmd_constitution(arg string) SlashResult {
	sub := arg.trim_space().to_lower()
	path := a.oracle.constitution_path()
	if sub == 'edit' {
		if path == '' {
			return error_result('no memory dir configured')
		}
		return SlashResult{
			lines: [
				info_line('constitution file: ${path}', c_dim),
				info_line("edit it directly — it is human-owned and never auto-modified. It is always present in the agent's context.", c_cyan),
			]
		}
	}
	text := a.oracle.read_constitution()
	if text.trim_space() != '' {
		return info_result('CONSTITUTION (standing rules):\n' + text, c_cyan)
	}
	return info_result('constitution is empty — create ${path} with your standing rules', c_dim)
}

// cmd_replay plays the session log back as a text film (§26).
fn (mut a Agent) cmd_replay() SlashResult {
	mut lines := ['REPLAY — the session as a film:']
	for ev in replay(mut a.log, a.log.branch) {
		d := ev.data.clone()
		match ev.typ {
			'user.message' {
				lines << '  [${ev.seq}] ❯ ${cap_at(jstr(d, 'text'), 60)}'
			}
			'assistant.message' {
				lines << '  [${ev.seq}] ◆ ${cap_at(jstr(d, 'text'), 60)}'
			}
			'tool.call' {
				lines << '  [${ev.seq}] ⚙ ${jstr(d, 'name')}'
			}
			'tool.result' {
				icon := if jstr(d, 'status') == 'done' { '✓' } else { '✗' }
				lines << '  [${ev.seq}] ${icon} ${jstr(d, 'name')} (${jstr(d, 'status')})'
			}
			'snapshot.taken' {
				lines << '  [${ev.seq}] 📸 snapshot ${cap_at(jstr(d, 'tree'), 10)}'
			}
			'clause.proven' {
				lines << '  [${ev.seq}] ★ clause ${jstr(d, 'clause')} PROVEN'
			}
			'goal.closed' {
				lines << '  [${ev.seq}] ■ GOAL ${jstr(d, 'state')}'
			}
			'cost.incurred' {
				lines << '  [${ev.seq}] \$ cost ${jint(d, 'tokens_in')}→${jint(d, 'tokens_out')} tok'
			}
			else {}
		}
	}
	return info_result(lines.join('\n'), c_cyan)
}

// cap_at truncates on BYTES, as Python's slice of a str does here. The
// original sliced characters; both are only ever used for a preview, and
// slicing bytes cannot split a V string's backing array the way an index
// past the end would.
fn cap_at(s string, n int) string {
	return if s.len > n { s[..n] } else { s }
}

fn (mut a Agent) cmd_memory() SlashResult {
	return info_result(a.memory.context_block(5), c_cyan)
}

// judge_shorthand_keys maps a predicate type to the argument key its
// one-line form fills in. A type that is not here has no shorthand.
const judge_shorthand_keys = {
	'exit_code':               'command'
	'file_exists':             'path'
	'file_contains':           'path'
	'file_matches':            'path'
	'command_output_contains': 'command'
}

fn (mut a Agent) cmd_judge(arg string) SlashResult {
	s := arg.trim_space()
	mut predicate := map[string]json2.Any{}
	if s.starts_with('{') {
		parsed := json2.decode[json2.Any](s) or {
			return error_result('invalid JSON predicate: ${err.msg()}')
		}
		if parsed is map[string]json2.Any {
			predicate = parsed.clone()
		} else {
			return error_result('invalid JSON predicate: a predicate must be an object')
		}
	} else if s != '' {
		ptype, value := split_command_raw(s)
		key := judge_shorthand_keys[ptype] or {
			return error_result('predicate types: exit_code · file_exists · file_contains · file_matches · command_output_contains')
		}
		predicate['type'] = json2.Any(ptype)
		predicate[key] = json2.Any(value)
	} else {
		return error_result('usage: /judge <type> <arg>  or  /judge {"type": "file_exists", "path": "…"}')
	}
	return SlashResult{
		job:     'judge'
		job_arg: json2.encode(json2.Any(predicate))
	}
}

// split_command_raw is split_command without the lowercasing: a predicate
// type is matched exactly, and a path in the tail keeps its case.
fn split_command_raw(text string) (string, string) {
	s := text.trim_space()
	mut i := 0
	for i < s.len && !s[i].is_space() {
		i++
	}
	return s[..i], s[i..].trim_space()
}
