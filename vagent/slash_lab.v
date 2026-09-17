module vagent

// slash_lab.v — the advanced-subsystem commands: /compile, /evolve, /brain,
// /merge, /theater, /debate, /market, /tower, /verify, /mcts, /causal,
// /bandit, /mesh, /roleforge.
//
// Anything here that calls a model or indexes a tree is returned as a JOB
// rather than run inline, exactly as the original handed it to `_bg`: the
// event loop stays answerable while a tournament or a benchmark runs.

// -- /compile, /evolve, /brain, /merge -----------------------------------------

// cmd_compile runs the Intent Compiler: goal → optimised ordered waves →
// execute.
fn (a &Agent) cmd_compile(arg string) SlashResult {
	goal := arg.trim_space()
	if goal == '' {
		return error_result('usage: /compile <goal>  — the compiler plans + executes it in ordered waves')
	}
	return SlashResult{
		lines:   [info_line('⚙ compiling…', c_pink)]
		job:     'compile'
		job_arg: goal
	}
}

// cmd_evolve runs the Evolution Engine: mutate → evaluate → deploy one role
// brief. Rollback is immediate; evolving is a job, because each candidate is
// benchmarked with real worker calls.
fn (mut a Agent) cmd_evolve(arg string) SlashResult {
	parts := arg.fields()
	if parts.len > 0 && parts[0].to_lower() == 'rollback' {
		if parts.len < 2 {
			return error_result('usage: /evolve rollback <role>')
		}
		return info_result(a.evolution.rollback(parts[1]), c_cyan)
	}
	role := if parts.len > 0 { parts[0] } else { '' }
	return SlashResult{
		job:     'evolve'
		job_arg: role
	}
}

// cmd_brain queries cognitive memory, puts it to sleep, or reads its stats.
fn (mut a Agent) cmd_brain(arg string) SlashResult {
	sub := arg.trim_space().to_lower()
	if sub == 'sleep' {
		stats := a.brain.sleep()
		return info_result('🧠 slept — merged ${stats.merged} · distilled ${stats.distilled} · promoted ${stats.promoted} · forgotten ${stats.forgotten}', c_pink)
	}
	if sub == '' || sub == 'stats' {
		return info_result(a.brain.format_stats(), c_cyan)
	}
	block := a.brain.context_block(arg, 5)
	body := if block != '' { block } else { 'no live memories match that query' }
	return info_result(body, c_fg)
}

// cmd_merge is a semantic timeline merge of two branches.
fn (mut a Agent) cmd_merge(arg string) SlashResult {
	parts := arg.fields()
	if parts.len < 2 {
		known := a.log.branches().join(', ')
		return error_result('usage: /merge <branchA> <branchB>  (known: ${known})')
	}
	result := a.merger.merge(parts[0], parts[1], '') or { return error_result(err.msg()) }
	colour := if result.conflicts.len > 0 { c_yellow } else { c_green }
	return info_result(a.merger.format(&result), colour)
}

// -- /theater ------------------------------------------------------------------

// cmd_theater is the time-travel debugger: frames, whys, diffs,
// counterfactuals.
fn (mut a Agent) cmd_theater(arg string) SlashResult {
	parts := arg.fields()
	if parts.len == 0 {
		all := a.theater.frames(a.log.branch)
		mut start := all.len - 30
		if start < 0 {
			start = 0
		}
		mut lines := ['THEATER — last frames (scrub with /theater <seq>):']
		for f in all[start..] {
			lines << '  seq ${f.seq:4} ${f.typ:-18} ${cap_at(f.summary, 60)}'
		}
		return info_result(lines.join('\n'), c_cyan)
	}
	head := parts[0].to_lower()
	if head == 'why' && parts.len > 1 {
		seq := parse_int_strict(parts[1]) or { return error_result('seq must be an integer') }
		return info_result(a.theater.why(seq), c_cyan)
	}
	if head in ['cf', 'counterfactual'] && parts.len > 1 {
		seq := parse_int_strict(parts[1]) or { return error_result('seq must be an integer') }
		report := a.theater.counterfactual(seq, '') or { return error_result(err.msg()) }
		return info_result(a.theater.format_cf(&report), c_pink)
	}
	if head == 'diff' && parts.len > 2 {
		x := parse_int_strict(parts[1]) or { return error_result('seqs must be integers') }
		y := parse_int_strict(parts[2]) or { return error_result('seqs must be integers') }
		return info_result(a.theater.diff(x, y), c_cyan)
	}
	seq := parse_int_strict(parts[0]) or {
		return error_result('usage: /theater [seq | why N | diff A B | cf N]')
	}
	frame := a.theater.frame(seq) or { return error_result('no event at that seq') }
	return info_result(frame.format(), c_cyan)
}

// -- /debate, /market, /tower --------------------------------------------------

fn (mut a Agent) cmd_debate(arg string) SlashResult {
	sub, rest := split_command(arg)
	if sub in ['confirm', 'refute'] {
		if rest == '' {
			return error_result('usage: /debate confirm|refute <model-id>')
		}
		trust := if sub == 'confirm' {
			a.debate.confirm(rest)
		} else {
			a.debate.refute(rest)
		}
		mut names := trust.keys()
		names.sort()
		mut parts := []string{}
		for m in names {
			parts << '${m}=${trust[m]:.2f}'
		}
		return info_result('calibration: ' + parts.join(', '), c_cyan)
	}
	question := arg.trim_space()
	if question == '' {
		return error_result('usage: /debate <question>')
	}
	return SlashResult{
		job:     'debate'
		job_arg: question
	}
}

// cmd_market auctions the given tasks to bidding specialists.
fn (a &Agent) cmd_market(arg string) SlashResult {
	mut tasks := []string{}
	for t in arg.split('|') {
		s := t.trim_space()
		if s != '' {
			tasks << s
		}
	}
	if tasks.len == 0 {
		return error_result('usage: /market <task1> | <task2> | …')
	}
	return SlashResult{
		job:     'market'
		job_arg: arg
	}
}

// cmd_tower starts the web control tower: a mission-control dashboard in
// the browser.
fn (mut a Agent) cmd_tower(arg string) SlashResult {
	// a bad port is not an error here, it is the default — the original
	// swallowed the ValueError and carried on with 7860.
	port := parse_int_strict(arg.trim_space()) or { 7860 }
	if a.tower.serving {
		return info_result('control tower already live at ${a.tower.url}', c_cyan)
	}
	url := a.tower.start(port) or { return error_result('control tower failed to start: ${err.msg()}') }
	return info_result('🖥 control tower LIVE at ${url} — event river, timeline scrubber, crew status, live command box', c_green)
}

// -- /verify, /mcts, /causal, /bandit ------------------------------------------

// cmd_verify compiles a plan and model-checks it, or audits the real
// history.
fn (mut a Agent) cmd_verify(arg string) SlashResult {
	if arg.trim_space().to_lower() == 'log' {
		r := a.formal.audit_log()
		mut body := if r.ok {
			'HISTORY AUDIT — CLEAN ✓'
		} else {
			'HISTORY AUDIT — VIOLATIONS FOUND ✗'
		}
		for v in r.violations {
			body += '\n  ⚠ ${v.property}: ${v.why}'
		}
		return info_result(body, if r.ok { c_green } else { c_red })
	}
	goal := arg.trim_space()
	if goal == '' {
		return error_result('usage: /verify <goal> | /verify log')
	}
	return SlashResult{
		job:     'verify'
		job_arg: goal
	}
}

fn (mut a Agent) cmd_mcts(arg string) SlashResult {
	goal := arg.trim_space()
	if goal == '' {
		return error_result('usage: /mcts <item1>; <item2>; …')
	}
	mut items := []string{}
	for s in goal.split(';') {
		t := s.trim_space()
		if t != '' {
			items << t
		}
	}
	a.mcts_items = items
	report := a.mcts.search(items, ['coder', 'architect', 'debugger', 'tester', 'documenter'], 120, 20.0)
	mut lines := [
		'🌳 MCTS — score ${report.best_score:.2f} · ${report.iterations} iterations · ${report.nodes} nodes',
	]
	for i, item in items {
		who := report.best_assignment[i] or { '?' }
		lines << '  [${who}] ${cap_at(item, 70)}'
	}
	return info_result(lines.join('\n'), c_cyan)
}

fn (mut a Agent) cmd_causal(arg string) SlashResult {
	trimmed := arg.trim_space()
	if trimmed.to_lower().starts_with('do ') {
		toks := trimmed.fields()
		// a trailing "on"/"off" token is the switch — never a substring
		// match, because a feature literally named "soft_off" must work
		mut enable := true
		mut cause := ''
		if toks.len > 2 && toks[toks.len - 1] in ['on', 'off'] {
			enable = toks[toks.len - 1] == 'on'
			cause = toks[1..toks.len - 1].join(' ')
		} else {
			cause = toks[1..].join(' ')
		}
		report := a.causal.do_intervention(cause, enable)
		verdict := if jbool(report, 'trustworthy') { 'trustworthy' } else { 'NOT ENOUGH DATA' }
		change := jf64_or(report, 'estimated_outcome_change', 0.0)
		return info_result('do(${cause}) → outcome change ${change:+.3f} (${verdict})', c_cyan)
	}
	edges := a.causal.discover([]CausalObservation{}, false)
	return info_result(a.causal.format(edges), c_cyan)
}

fn (mut a Agent) cmd_bandit(arg string) SlashResult {
	if arg.trim_space() == '' {
		return info_result(a.bandit.format(), c_cyan)
	}
	rec := a.bandit.recommend(arg)
	return info_result('bandit recommends [${rec.arm}] for this ${rec.context} task', c_green)
}

// -- /mesh, /roleforge ---------------------------------------------------------

fn (mut a Agent) cmd_mesh(arg string) SlashResult {
	parts := arg.fields()
	if parts.len == 0 || parts[0].to_lower() == 'serve' {
		port_arg := if parts.len > 1 { parts[1] } else { '0' }
		want := parse_int_strict(port_arg) or {
			return error_result("bad port: '${port_arg}' — usage: /mesh serve [port]")
		}
		port := a.mesh.serve(want) or { return error_result(err.msg()) }
		return info_result("📡 mesh node '${a.mesh.node_id}' serving on port ${port}", c_green)
	}
	head := parts[0].to_lower()
	if head == 'discover' && parts.len > 1 {
		target := parts[1]
		colon := target.index(':') or { -1 }
		host := if colon >= 0 { target[..colon] } else { target }
		port_str := if colon >= 0 { target[colon + 1..] } else { '' }
		port_num := if port_str == '' {
			7861
		} else {
			parse_int_strict(port_str) or {
				return error_result("bad port: '${port_str}' — usage: /mesh discover host:port")
			}
		}
		peer := a.mesh.discover(host, port_num) or {
			return error_result('no ${app_name} mesh at ${target}')
		}
		return info_result('discovered peer ${peer.capabilities}', c_green)
	}
	if head == 'delegate' && parts.len > 1 {
		_, task := split_command(arg)
		reply := a.mesh.delegate(task, '', '')
		return info_result(reply.str(), c_cyan)
	}
	if head == 'status' {
		names := a.mesh.peers.keys()
		shown := if names.len > 0 { names.str() } else { 'none' }
		return info_result('peers: ${shown} · handled ${a.mesh.handled} task(s)', c_cyan)
	}
	return error_result('usage: /mesh [serve [port] | discover host:port | delegate <task> | status]')
}

fn (a &Agent) cmd_roleforge(arg string) SlashResult {
	mission := arg.trim_space()
	if mission == '' {
		return error_result('usage: /roleforge <what specialist do you need and why>')
	}
	return SlashResult{
		job:     'roleforge'
		job_arg: mission
	}
}
