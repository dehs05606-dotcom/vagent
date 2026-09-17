module vagent

import x.json2

// slash_goal.v — /goal, /autonomy, /focus and /render.
//
// The goal grammar is the one piece of the command surface a user types by
// hand under pressure, so its parser is kept whole and kept honest: every
// rejection says what was wrong with the line, and nothing is guessed. A
// clause with no machine-checkable proof is refused rather than quietly
// filed as advisory, because a contract whose clauses cannot be checked is
// decoration.

fn (mut a Agent) cmd_goal(arg string) SlashResult {
	sub_raw, rest := split_command(arg)
	sub := if sub_raw == '' { 'status' } else { sub_raw }

	match sub {
		'', 'status', 'show' {
			return info_result(a.goal.format(), c_cyan)
		}
		'set' {
			return a.goal_set(rest)
		}
		'prove' {
			if rest == '' {
				return error_result('usage: /goal prove <clause-id>  (or /goal prove-all)')
			}
			ok, detail := a.goal.prove_by_predicate(rest)
			mark := if ok { '✓' } else { '✗' }
			colour := if ok { c_green } else { c_red }
			return SlashResult{
				lines: [
					info_line('${mark} ${rest}: ${detail}', colour),
					info_line(a.goal.format(), c_dim),
				]
			}
		}
		'prove-all' {
			st := a.goal.status()
			mut lines := []SlashLine{}
			for c in st.clauses {
				if c.has_proof && !c.advisory {
					ok, detail := a.goal.prove_by_predicate(c.id)
					mark := if ok { '✓' } else { '✗' }
					colour := if ok { c_green } else { c_red }
					lines << info_line('${mark} ${c.id}: ${detail}', colour)
				}
			}
			lines << info_line(a.goal.format(), c_dim)
			return SlashResult{
				lines: lines
			}
		}
		'close' {
			result := a.goal.close(true)
			colour := if result.state == 'ACHIEVED' { c_green } else { c_yellow }
			mut lines := [info_line('GOAL CLOSED: ${result.state}', colour)]
			for r in result.reasons {
				lines << info_line('  - ${r}', c_dim)
			}
			lines << info_line(result.bundle, c_cyan)
			return SlashResult{
				lines: lines
			}
		}
		'waive' {
			// '--reason' splits the line once; everything before it is the
			// clause id, everything after is the justification.
			idx := rest.index('--reason') or { -1 }
			cid := if idx >= 0 { rest[..idx].trim_space() } else { rest.trim_space() }
			mut reason := 'human waiver'
			if idx >= 0 {
				r := rest[idx + '--reason'.len..].trim_space()
				if r != '' {
					reason = r
				}
			}
			if cid == '' {
				return error_result("usage: /goal waive <clause-id> --reason '…'")
			}
			if a.goal.waive(cid, reason) {
				return info_result('✓ clause ${cid} waived (recorded as an event)', c_yellow)
			}
			return error_result('no such clause: ${cid}')
		}
		'clear' {
			a.goal.clear()
			return info_result('✓ goal cleared', c_dim)
		}
		else {
			return error_result('goal subcommands: set · prove · prove-all · close · status · waive · clear')
		}
	}
}

// goal_set parses the TUI goal grammar into a contract:
//
//	/goal set <statement> | <clause> @ <proof-type>:<arg> | …
//
// Prefix a clause with ! for an anti-clause, ~ for an invariant. A clause
// piece may also be raw JSON for full control.
//
// Proof types: exit_code, file_exists, file_contains, file_matches,
// command_output_contains, ast_assert, diff_assert, file_unchanged,
// tool_delta.
fn (mut a Agent) goal_set(rest string) SlashResult {
	if rest == '' {
		return error_result('usage: /goal set <statement> | <clause> @ <type>:<arg> | …\n' + '  e.g. /goal set ship it | tests pass @ exit_code:pytest -q | docs exist @ file_exists:docs.md\n' + '  ! prefix = anti-clause, ~ prefix = invariant')
	}
	mut pieces := []string{}
	for p in rest.split('|') {
		t := p.trim_space()
		if t != '' {
			pieces << t
		}
	}
	if pieces.len == 0 {
		return error_result('goal needs a statement: /goal set <statement> | <clause> @ <type>:<arg>')
	}
	statement := pieces[0]
	mut clauses := []Rec{}
	mut anti := []Rec{}
	mut invariants := []Rec{}

	for i, piece in pieces[1..] {
		n := i + 1
		if piece.starts_with('{') {
			parsed := json2.decode[json2.Any](piece) or {
				return error_result('clause ${n}: invalid JSON — ${err.msg()}')
			}
			if parsed is map[string]json2.Any {
				clauses << Rec(parsed)
			} else {
				return error_result('clause ${n}: invalid JSON — a clause must be an object')
			}
			continue
		}
		is_anti := piece.starts_with('!')
		is_inv := piece.starts_with('~')
		text := piece.trim_left('!~ ').trim_space()
		if !text.contains('@') {
			return error_result("clause ${n} needs a machine-checkable proof: '${text}' @ <type>:<arg>  (or mark it advisory with raw JSON)")
		}
		at := text.index('@') or { -1 }
		ctext := text[..at].trim_space()
		proof_str := text[at + 1..].trim_space()
		proof, perr := parse_proof(proof_str)
		if perr != '' {
			return error_result(perr)
		}
		if is_anti {
			anti << Rec({
				'id':    json2.Any('A${anti.len + 1}')
				'text':  json2.Any(ctext)
				'check': json2.Any(proof)
			})
		} else if is_inv {
			invariants << Rec({
				'id':    json2.Any('I${invariants.len + 1}')
				'text':  json2.Any(ctext)
				'check': json2.Any(proof)
			})
		} else {
			clauses << Rec({
				'id':     json2.Any('C${clauses.len + 1}')
				'text':   json2.Any(ctext)
				'weight': json2.Any(1.0)
				'proof':  json2.Any(proof)
			})
		}
	}
	if clauses.len == 0 {
		return error_result('a goal needs at least one clause with a proof')
	}
	a.goal.set_goal(statement, clauses, anti: anti, invariants: invariants) or {
		return error_result('contract rejected: ${err.msg()}')
	}
	mut head := '✓ goal contract frozen — ${clauses.len} clause(s)'
	if anti.len > 0 {
		head += ', ${anti.len} anti'
	}
	if invariants.len > 0 {
		head += ', ${invariants.len} invariant'
	}
	return SlashResult{
		lines: [
			info_line(head, c_green),
			info_line(a.goal.format(), c_dim),
		]
	}
}

// parse_proof turns '<type>:<arg>' into a predicate. The second return is
// the error message, empty when the parse succeeded — the original returned
// None and printed on the way out, which made the failure path invisible to
// anything but a terminal.
fn parse_proof(s string) (map[string]json2.Any, string) {
	empty := map[string]json2.Any{}
	if !s.contains(':') {
		return empty, "proof needs '<type>:<arg>', got: '${s}'"
	}
	at := s.index(':') or { -1 }
	ptype := s[..at].trim_space()
	arg := s[at + 1..].trim_space()

	if ptype in ['exit_code', 'tool_delta'] {
		return {
			'type':    json2.Any(ptype)
			'command': json2.Any(arg)
			'expect':  json2.Any(0)
		}, ''
	}
	if ptype == 'file_exists' {
		return {
			'type': json2.Any(ptype)
			'path': json2.Any(arg)
		}, ''
	}
	if ptype in ['file_contains', 'file_matches', 'command_output_contains'] {
		if !arg.contains(':') {
			return empty, "${ptype} needs '<path-or-cmd>:<text>'"
		}
		j := arg.index(':') or { -1 }
		a := arg[..j].trim_space()
		b := arg[j + 1..].trim_space()
		key := if ptype.starts_with('file') { 'path' } else { 'command' }
		field2 := if ptype != 'file_matches' { 'text' } else { 'pattern' }
		mut m := map[string]json2.Any{}
		m['type'] = json2.Any(ptype)
		m[key] = json2.Any(a)
		m[field2] = json2.Any(b)
		return m, ''
	}
	if ptype == 'ast_assert' {
		if !arg.contains(':') {
			return empty, "ast_assert needs '<path>:<symbol>'"
		}
		j := arg.index(':') or { -1 }
		return {
			'type':   json2.Any(ptype)
			'path':   json2.Any(arg[..j].trim_space())
			'symbol': json2.Any(arg[j + 1..].trim_space())
		}, ''
	}
	if ptype == 'diff_assert' {
		return {
			'type':   json2.Any(ptype)
			'path':   json2.Any(arg)
			'forbid': json2.Any([]json2.Any{})
		}, ''
	}
	if ptype == 'file_unchanged' {
		if !arg.contains(':') {
			return empty, "file_unchanged needs '<path>:<sha256>'"
		}
		j := arg.index(':') or { -1 }
		return {
			'type':          json2.Any(ptype)
			'path':          json2.Any(arg[..j].trim_space())
			'baseline_hash': json2.Any(arg[j + 1..].trim_space())
		}, ''
	}
	return empty, "unknown proof type: '${ptype}'"
}

// -- /autonomy -----------------------------------------------------------------

fn (mut a Agent) cmd_autonomy(arg string) SlashResult {
	if arg.trim_space() == '' {
		mut cur := ''
		if a.autonomy >= 0 && a.autonomy < autonomy_levels.len {
			cur = autonomy_levels[a.autonomy]
		}
		mut lines := ['current: L${a.autonomy} — ${cur}']
		for level, desc in autonomy_levels {
			lines << '  L${level}  ${desc}'
		}
		return info_result(lines.join('\n'), c_cyan)
	}
	level := parse_int_strict(arg.trim_space()) or {
		return error_result('usage: /autonomy <0-5>')
	}
	desc := a.set_autonomy(level)
	return info_result('✓ autonomy → L${a.autonomy} — ${desc}', c_green)
}

// parse_int_strict is Python's int(): the WHOLE string must be an integer.
// V's `.int()` returns 0 for garbage, which would silently read `/autonomy
// yes` as the observer level instead of rejecting it.
pub fn parse_int_strict(s string) ?int {
	t := s.trim_space()
	if t == '' {
		return none
	}
	mut i := 0
	if t[0] == `-` || t[0] == `+` {
		i = 1
	}
	if i >= t.len {
		return none
	}
	for ; i < t.len; i++ {
		if !t[i].is_digit() {
			return none
		}
	}
	return t.int()
}

// -- /focus --------------------------------------------------------------------

// cmd_focus arms auto-continuation. After each turn the kernel decides —
// mechanically — whether work remains, and the UI submits the next
// continuation turn automatically, until the goal closes, the agent stalls,
// the budget pauses, or N turns land.
fn (mut a Agent) cmd_focus(arg string) SlashResult {
	s := arg.trim_space().to_lower()
	if s == '' || s == 'status' {
		state := if a.focus_remaining > 0 {
			'ARMED — ${a.focus_remaining} auto-turn(s) left'
		} else {
			'off'
		}
		return info_result('🎯 focus mode: ${state}\n' + '  /focus <1-20>  arm, then send your task\n' + '  /focus off     disarm', c_cyan)
	}
	if s == 'off' {
		a.focus_remaining = 0
		return info_result('🎯 focus disarmed', c_yellow)
	}
	raw := parse_int_strict(s) or { return error_result('usage: /focus <1-20> | /focus off') }
	mut n := raw
	if n > 20 {
		n = 20
	}
	if n < 1 {
		n = 1
	}
	a.focus_remaining = n
	a.focus_history.clear()
	goal := a.goal.status()
	hint := if goal.active {
		'an active goal drives continuation — focus stops when every clause is proven or progress stalls'
	} else {
		'no active goal — focus stops when the agent answers without further tool work'
	}
	return info_result('🎯 focus armed: up to ${n} auto-turns. ${hint}. Send your task now.', c_green)
}

// -- /render -------------------------------------------------------------------

// cmd_render toggles rendered-markdown replies: streaming stays in the
// border preview, the finished reply prints as rendered Markdown.
fn (mut a Agent) cmd_render(arg string) SlashResult {
	s := arg.trim_space().to_lower()
	current := jbool(a.cfg.extra, 'render_markdown')
	mut new_state := false
	if s == 'on' || s == 'off' {
		new_state = s == 'on'
	} else if s == '' {
		new_state = !current
	} else {
		return error_result('usage: /render [on|off]')
	}
	a.cfg.extra['render_markdown'] = json2.Any(new_state)
	a.cfg.save()
	tail := if new_state {
		'ON (replies render as rich Markdown)'
	} else {
		'OFF (raw streaming)'
	}
	return info_result('✓ markdown rendering → ${tail}', c_green)
}
