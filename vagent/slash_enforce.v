module vagent

import os
import x.json2

// slash_enforce.v — /enforce, /covenant, /recall, /mission, /crew, /council,
// /analyze, /graph, /mutate.
//
// /enforce and /covenant are the two windows onto the boundary: what is in
// force, what it has stopped, what is owed, and whether the rules still
// agree with the prompt they were parsed from. Neither of them changes
// anything — they only let you see what is already true.

fn (mut a Agent) cmd_enforce(arg string) SlashResult {
	sub := arg.trim_space().to_lower()

	if sub == '' || sub == 'status' {
		errs := a.charter.errors()
		return info_result(a.charter.report(), if errs.len > 0 { c_yellow } else { c_cyan })
	}
	if sub == 'witness' {
		return info_result(a.charter.witness.report([], false), c_cyan)
	}
	if sub == 'grants' {
		return info_result(a.charter.consent.report(), c_cyan)
	}
	if sub == 'audit' {
		report := audit(a.covenant, a.tools, true, [])
		return info_result(report.describe(), c_cyan)
	}
	if sub == 'owed' {
		blocker := a.charter.blocker()
		body := if blocker != '' { blocker } else { '✓ nothing is owed' }
		return info_result(body, if blocker != '' { c_yellow } else { c_green })
	}
	if sub == 'integrity' {
		report := a.integrity.verify(master_spec, a.covenant, '')
		return info_result(report.describe(), if report.ok() { c_green } else { c_yellow })
	}
	return error_result("unknown /enforce subcommand '${sub}' — status · audit · owed · integrity · witness · grants")
}

// cmd_covenant inspects the specification where it is actually enforced:
// the action boundary. Nothing here changes the prompt.
fn (mut a Agent) cmd_covenant(arg string) SlashResult {
	sub_raw, rest := partition_space(arg.trim_space())
	sub := sub_raw.to_lower()

	if sub == '' || sub == 'report' || sub == 'status' {
		mut lines := [info_line(a.covenant.report(), c_cyan)]
		mut unarmed := []string{}
		for n, t in a.tools {
			if !t.guarded {
				unarmed << n
			}
		}
		unarmed.sort()
		unnamed := unnamed_tools(a.tools)
		mut body := ['tools: ${a.tools.len - unarmed.len}/${a.tools.len} armed']
		if unarmed.len > 0 {
			body << '  !! UNGUARDED: ${unarmed.join(', ')}'
		}
		if unnamed.len > 0 && a.covenant.guards().len > 0 {
			body << '  ${unnamed.len} tool(s) have no effects the boundary can read, so path/content clauses do not reach them:'
			mut shown := unnamed.len
			if shown > 20 {
				shown = 20
			}
			body << '  ' + unnamed[..shown].join(', ') + if unnamed.len > 20 { ' …' } else { '' }
			body << '  constrain one by name with `@enforce forbid_tool: <name>`'
		}
		lines << info_line(body.join('\n'), if unarmed.len > 0 { c_yellow } else { c_cyan })
		if a.covenant.errors.len > 0 {
			lines << error_line('${a.covenant.errors.len} @enforce rule(s) are malformed and enforce NOTHING — fix them in the SPEC constant in systemprompt.v, then rebuild')
		}
		return SlashResult{
			lines: lines
		}
	}

	if sub == 'clauses' {
		needle := rest.trim_space().to_lower()
		mut rows := []Clause{}
		for c in a.covenant.clauses {
			if needle == '' || c.id.to_lower().contains(needle)
				|| c.title.to_lower().contains(needle) {
				rows << c
			}
		}
		if rows.len == 0 {
			return info_result('no clause matches', c_yellow)
		}
		mut shown := rows.len
		if shown > 200 {
			shown = 200
		}
		mut lines := []string{}
		for c in rows[..shown] {
			mark := if c.enforced() { '●' } else { '○' }
			lines << '  ${mark} ${c.id:-16} ${c.fingerprint()}  ${cap_at(c.title, 60)}'
		}
		if rows.len > 200 {
			lines << '  … ${thousands(rows.len - 200)} more'
		}
		return info_result(lines.join('\n'), c_cyan)
	}

	if sub == 'test' {
		// dry-run a call against the boundary without executing it
		tool, payload := partition_space(rest.trim_space())
		if tool == '' {
			return error_result('usage: /covenant test <tool> {"path": …}')
		}
		mut args := map[string]json2.Any{}
		if payload.trim_space() != '' {
			parsed := json2.decode[json2.Any](payload) or {
				return error_result('args must be JSON: ${err.msg()}')
			}
			if parsed is map[string]json2.Any {
				args = parsed.clone()
			} else {
				return error_result('args must be a JSON object')
			}
		}
		effects := derive(tool, args)
		mut lines := ['effects derived from this call:']
		if effects.len == 0 {
			lines << '  (none — this tool has no named effects)'
		}
		for e in effects {
			where := if e.path != '' { ' ${e.path}' } else { '' }
			lines << '  ${e.kind:-7}${where:-40} ${e.reason}'
		}
		mut out := [info_line(lines.join('\n'), c_cyan)]
		breach := a.covenant.gate(tool, args)
		if breach != '' {
			out << error_line(breach)
		} else {
			out << info_line('✓ no clause refuses this call', c_green)
		}
		return SlashResult{
			lines: out
		}
	}

	return error_result("unknown /covenant subcommand '${sub}' — report · clauses [filter] · test <tool> <json>")
}

// partition_space is Python's `s.partition(" ")`: split on the FIRST single
// space, not on a run of whitespace. /covenant relies on the difference,
// because the tail is a JSON payload that may start with its own spacing.
fn partition_space(s string) (string, string) {
	i := s.index(' ') or { return s, '' }
	return s[..i], s[i + 1..]
}

// -- /recall, /mission ---------------------------------------------------------

// cmd_recall is semantic (meaning-based) recall over the episodic corpus.
fn (mut a Agent) cmd_recall(arg string) SlashResult {
	query := arg.trim_space()
	if query == '' {
		s := a.semantic.stats()
		return info_result('semantic memory: ${s.items} items indexed ${s.kinds} — usage: /recall <question>', c_cyan)
	}
	hits := a.semantic.recall(query, 5, 0.10)
	if hits.len == 0 {
		return info_result('no memories similar to: ${query}', c_dim)
	}
	mut lines := ['SEMANTIC RECALL — ${query}']
	for h in hits {
		lines << '  [${h.kind} ${h.similarity:.2f}] ${h.text}'
	}
	return info_result(lines.join('\n'), c_cyan)
}

// cmd_mission is daemon mission control: /mission start <stmt> | task1 |
// task2, /mission tick <id>, /mission list, /mission abandon <id>.
fn (mut a Agent) cmd_mission(arg string) SlashResult {
	sub_raw, rest := split_command(arg)
	sub := if sub_raw == '' { 'list' } else { sub_raw }
	if sub == 'list' || sub == 'status' {
		return info_result(a.daemon.format_status(), c_cyan)
	}
	if sub == 'start' {
		usage := 'usage: /mission start <statement> | task1 | task2 | …'
		if rest == '' {
			return error_result(usage)
		}
		mut segs := []string{}
		for s in rest.split('|') {
			t := s.trim_space()
			if t != '' {
				segs << t
			}
		}
		if segs.len == 0 {
			return error_result(usage)
		}
		statement := segs[0]
		tasks := if segs.len > 1 { segs[1..] } else { [statement] }
		m := a.daemon.start(statement, tasks)
		return info_result('✓ mission ${m.mission_id} started — ${m.steps.len} step(s). Advance with /mission tick ${m.mission_id}', c_green)
	}
	if sub == 'tick' {
		mid := rest.trim_space()
		if mid == '' {
			return error_result('usage: /mission tick <mission_id>')
		}
		r := a.daemon.tick(mid)
		if jstr(r, 'error') != '' {
			return error_result('${jstr(r, 'state')} ${jstr(r, 'error')}'.trim_space())
		}
		step := if 'step' in r { jint(r, 'step').str() } else { '?' }
		state := if 'state' in r { jstr(r, 'state') } else { '?' }
		progress := jf64_or(r, 'progress', 0.0) * 100.0
		return info_result('mission ${mid}: step ${step} → ${state}  progress ${progress:.0f}%\n  ${cap_at(jstr(r, 'result'), 200)}', c_cyan)
	}
	if sub == 'abandon' {
		mid := rest.trim_space()
		if a.daemon.abandon(mid, 'abandoned by user') {
			return info_result('✓ mission ${mid} abandoned', c_yellow)
		}
		return error_result("cannot abandon mission '${mid}'")
	}
	return error_result('usage: /mission [start|tick|list|abandon] …')
}

// -- /crew ---------------------------------------------------------------------

// cmd_crew drives the persistent subagents:
//
//	/crew                        roster + states
//	/crew spawn <role> <task>    launch a background subagent
//	/crew send <id> <message>    follow-up into its context
//	/crew wait [id,…]            collect results (blocking)
//	/crew close <id> · /crew resume <id>
fn (mut a Agent) cmd_crew(arg string) SlashResult {
	sub_raw, rest := split_command(arg)
	sub := if sub_raw == '' { 'status' } else { sub_raw }

	if sub == 'status' || sub == 'list' {
		return info_result(a.crew.format_status(), c_cyan)
	}
	if sub == 'spawn' {
		role, task := split_command_raw(rest)
		if role == '' || task == '' {
			return error_result('usage: /crew spawn <role> <task>  (roles: coder researcher tester reviewer analyst)')
		}
		ctx := a.scout_context(0)
		read_only := a.autonomy <= 1
		agent := a.crew.spawn(task,
			role:      role
			context:   ctx
			read_only: read_only
		) or { return error_result(err.msg()) }
		return info_result("⚡ subagent [${agent.id}] '${agent.nickname}' (${agent.role}) launched in background — /crew wait collects it", c_green)
	}
	if sub == 'send' {
		id, message := split_command_raw(rest)
		if id == '' || message == '' {
			return error_result('usage: /crew send <id> <message>')
		}
		agent := a.crew.send(id, message, false) or { return error_result(err.msg()) }
		return info_result("✓ message → [${agent.id}] '${agent.nickname}' (state: ${agent.state})", c_green)
	}
	if sub == 'wait' {
		mut ids := []string{}
		for s in rest.split(',') {
			t := s.trim_space()
			if t != '' {
				ids << t
			}
		}
		return SlashResult{
			lines:   [info_line('⏳ waiting for subagents…', c_dim)]
			job:     'crew_wait'
			job_arg: ids.join(',')
		}
	}
	if sub == 'close' {
		agent := a.crew.close(rest) or { return error_result(err.msg()) }
		return info_result("✓ [${agent.id}] '${agent.nickname}' closed", c_yellow)
	}
	if sub == 'resume' {
		agent := a.crew.resume(rest) or { return error_result(err.msg()) }
		return info_result("✓ [${agent.id}] '${agent.nickname}' resumed (${agent.state})", c_green)
	}
	return error_result('crew subcommands: spawn · send · wait · close · resume · status')
}

// -- /council, /analyze, /graph, /mutate ---------------------------------------

// cmd_council convenes an adversarial debate: /council <proposition>.
fn (mut a Agent) cmd_council(arg string) SlashResult {
	question := arg.trim_space()
	if question == '' {
		return info_result(a.council.format_status(), c_pink)
	}
	v := a.council.convene(question)
	mut lines := [info_line('⚖ convening council on: ${question} …', c_dim)]
	if !v.ok {
		lines << error_line('council failed: ${v.error}')
		return SlashResult{
			lines: lines
		}
	}
	mut body := [
		'COUNCIL VERDICT — winner: ${v.winner.to_upper()}  (confidence ${v.confidence:.0f}%)',
		'  reason: ${v.reason}',
	]
	for role, text in v.positions {
		body << '  [${role}] ${cap_at(text, 200)}'
	}
	lines << info_line(body.join('\n'), c_pink)
	return SlashResult{
		lines: lines
	}
}

// cmd_analyze runs static analysis: /analyze <path> — taint, complexity,
// cycles.
fn (mut a Agent) cmd_analyze(arg string) SlashResult {
	raw := arg.trim_space()
	path := if raw != '' { raw } else { '.' }
	p := resolve_path(path)
	result := if os.is_file(p) {
		a.static.analyze_file(p)
	} else {
		a.static.analyze_tree(p, '*.py', 100)
	}
	return info_result(a.static.format_report(&result), c_cyan)
}

// cmd_graph drives the knowledge graph:
// /graph [index <path>|query <name>|impact <name>].
fn (mut a Agent) cmd_graph(arg string) SlashResult {
	sub, rest := split_command(arg)
	if sub == '' || sub == 'status' {
		return info_result(a.kgraph.format_status(), c_cyan)
	}
	if sub == 'index' {
		root := resolve_path(if rest != '' { rest } else { '.' })
		mut files := []string{}
		if os.is_file(root) {
			files << root
		} else {
			mut found := []string{}
			for f in walk_files(root, 0) {
				if f.ends_with('.py') {
					found << f
				}
			}
			found.sort()
			files = found[..int_min(found.len, 200)].clone()
		}
		mut sources := map[string]string{}
		for f in files {
			text := os.read_file(f) or { continue }
			sources[os.file_name(f).all_before_last('.')] = text
		}
		n := a.kgraph.index_code(sources) or { return error_result(err.msg()) }
		a.kgraph.index_log()
		return info_result('✓ indexed ${sources.len} module(s) → ${n} entities\n${a.kgraph.format_status()}', c_green)
	}
	if sub == 'query' {
		if rest == '' {
			return error_result('usage: /graph query <name>')
		}
		hits := a.kgraph.find(rest, '')
		if hits.len == 0 {
			return info_result("no entity matching '${rest}' — /graph index first", c_dim)
		}
		mut lines := []string{}
		for e in hits[..int_min(hits.len, 20)] {
			lines << '${e.kind} ${e.id}  (${e.name})'
			out := a.kgraph.out_of(e.id, '')
			for r in out[..int_min(out.len, 8)] {
				lines << '    --${r.rel}--> ${r.dst}'
			}
			into := a.kgraph.into(e.id, '')
			for r in into[..int_min(into.len, 8)] {
				lines << '    <--${r.rel}-- ${r.src}'
			}
		}
		return info_result(lines.join('\n'), c_cyan)
	}
	if sub == 'impact' {
		if rest == '' {
			return error_result('usage: /graph impact <name>')
		}
		hits := a.kgraph.find(rest, '')
		if hits.len == 0 {
			return info_result("no entity matching '${rest}' — /graph index first", c_dim)
		}
		mut lines := []string{}
		for e in hits[..int_min(hits.len, 5)] {
			dep := a.kgraph.impact(e.id)
			lines << '${e.id}: ${dep.len} dependent(s)'
			for d in dep[..int_min(dep.len, 20)] {
				lines << '    ${d}'
			}
		}
		return info_result(lines.join('\n'), c_yellow)
	}
	return error_result('usage: /graph [index <path>|query <name>|impact <name>]')
}

// cmd_mutate runs mutation testing: /mutate <file> <suite-command>. The
// suite runs against AST-generated mutants; survivors are holes in the
// tests.
fn (mut a Agent) cmd_mutate(arg string) SlashResult {
	path, suite := split_command_raw(arg)
	if path == '' || suite == '' {
		if a.mutator != unsafe { nil } {
			return info_result(a.mutator.format_status(), c_yellow)
		}
		return error_result("usage: /mutate <file> <suite-command>  (e.g. /mutate src/x.py 'python -m pytest -q tests/')")
	}
	if !os.is_file(resolve_path(path)) {
		return error_result('not a file: ${path}')
	}
	return SlashResult{
		lines:   [info_line('⚙ mutating ${path} — suite: ${suite} …', c_dim)]
		job:     'mutate'
		job_arg: '${path}\t${suite}'
	}
}
