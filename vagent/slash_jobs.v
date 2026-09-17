module vagent

import x.json2

// slash_jobs.v — the commands that cannot run on the event thread.
//
// The Python original handed each of these to `_bg`, a daemon thread with a
// guarded body. Here the router names the job instead of closing over one,
// and the UI calls `slash_job` on a worker. Same split of responsibility,
// but the work is a plain function of (agent, argument), so a test can run
// a job directly and read what it produced.
//
// `_bg` also existed to make failures visible: a bare thread's default
// excepthook prints to stderr, which is invisible under the prompt's own
// redraw, so a crash looked like a command that did nothing. The V analogue
// is that every job below returns its failure as an error line rather than
// propagating it.

// slash_job_names is every job the router can ask for. A name that is not
// here is a bug in the router, and the runner says so rather than silently
// doing nothing — which is the exact failure mode `_bg` was written to stop.
pub const slash_job_names = ['impact', 'judge', 'compile', 'evolve', 'debate', 'market', 'verify',
	'roleforge', 'dual', 'race', 'crew_wait', 'mutate']

pub fn (mut a Agent) slash_job(name string, arg string) SlashResult {
	match name {
		'impact' { return a.job_impact(arg) }
		'judge' { return a.job_judge(arg) }
		'compile' { return a.job_compile(arg) }
		'evolve' { return a.job_evolve(arg) }
		'debate' { return a.job_debate(arg) }
		'market' { return a.job_market(arg) }
		'verify' { return a.job_verify(arg) }
		'roleforge' { return a.job_roleforge(arg) }
		'dual' { return a.job_dual(arg) }
		'race' { return a.job_race(arg) }
		'crew_wait' { return a.job_crew_wait(arg) }
		'mutate' { return a.job_mutate(arg) }
		else { return error_result('no such background job: ${name}') }
	}
}

fn (mut a Agent) job_impact(arg string) SlashResult {
	parts := arg.split('\t')
	symbol := parts[0]
	path := if parts.len > 1 { parts[1] } else { '.' }
	a.nexus.index(path, 0)
	return info_result(a.nexus.format_impact(symbol), c_fg)
}

fn (mut a Agent) job_judge(arg string) SlashResult {
	parsed := json2.decode[json2.Any](arg) or {
		return error_result('invalid JSON predicate: ${err.msg()}')
	}
	if parsed !is map[string]json2.Any {
		return error_result('invalid JSON predicate')
	}
	predicate := parsed as map[string]json2.Any
	verdict := a.judge.check(predicate.clone())
	icon := if verdict.passed { '✓' } else { '✗' }
	colour := if verdict.passed { c_green } else { c_red }
	mut lines := [info_line('${icon} [${verdict.kind}] ${verdict.detail}', colour)]
	if verdict.evidence != '' {
		lines << info_line('  evidence: ${cap_at(verdict.evidence, 200)}', c_dim)
	}
	return SlashResult{
		lines: lines
	}
}

fn (mut a Agent) job_compile(goal string) SlashResult {
	plan := a.compiler.compile(goal)
	mut lines := [info_line(a.compiler.format(&plan), c_fg)]
	if plan.waves.len == 0 {
		return SlashResult{
			lines: lines
		}
	}
	lines << info_line('⚙ executing ${plan.waves.len} wave(s)…', c_pink)
	result := a.compiler.execute(&plan) or {
		lines << error_line(err.msg())
		return SlashResult{
			lines: lines
		}
	}
	errors := jint(result, 'error')
	lines << info_line('✓ ${jint(result, 'items')} items · ${jint(result, 'done')} done · ${jint(result, 'blocked')} blocked · ${errors} error', if errors == 0 {
		c_green
	} else {
		c_yellow
	})
	return SlashResult{
		lines: lines
	}
}

fn (mut a Agent) job_evolve(role string) SlashResult {
	mut lines := [
		info_line('🧬 evolving — benchmark runs are real worker calls…', c_pink),
	]
	gen := a.evolution.evolve(role)
	lines << info_line(a.evolution.format(&gen), if gen.deployed { c_green } else { c_yellow })
	return SlashResult{
		lines: lines
	}
}

fn (mut a Agent) job_debate(question string) SlashResult {
	mut lines := [
		info_line('⚔ tournament — ${a.debate.models.join(', ')}', c_pink),
	]
	result := a.debate.run(question, 3)
	lines << info_line(a.debate.format(&result), c_fg)
	return SlashResult{
		lines: lines
	}
}

fn (mut a Agent) job_market(arg string) SlashResult {
	mut tasks := []string{}
	for t in arg.split('|') {
		s := t.trim_space()
		if s != '' {
			tasks << s
		}
	}
	mut lines := [
		info_line('💰 ${tasks.len} contract(s) up for auction…', c_pink),
	]
	contracts := a.market.run(tasks)
	lines << info_line(a.market.format(contracts), c_fg)
	return SlashResult{
		lines: lines
	}
}

fn (mut a Agent) job_verify(goal string) SlashResult {
	plan := a.compiler.compile(goal)
	r := a.formal.verify_plan(plan.waves)
	mut body := [
		'FORMAL — ${if r.ok { 'PASS' } else { 'REJECTED' }} (${r.checked} traces)',
	]
	for v in r.violations {
		body << '  ⚠ ${v.property}: ${v.why}'
	}
	return info_result(body.join('\n'), if r.ok { c_green } else { c_red })
}

fn (mut a Agent) job_roleforge(mission string) SlashResult {
	status, msg := a.roleforge.forge(mission)
	return info_result(msg, if status == 'sealed' { c_green } else { c_yellow })
}

fn (mut a Agent) job_dual(question string) SlashResult {
	r := a.dual.ask(question)
	return info_result('[system ${r.system} · conf ${r.confidence:.2f} · ${r.elapsed_ms}ms]\n${r.answer}', c_cyan)
}

fn (mut a Agent) job_race(task string) SlashResult {
	result := a.racer.race(task, 420.0)
	return info_result(a.racer.format(&result), if result.winner != '' { c_green } else { c_yellow })
}

fn (mut a Agent) job_crew_wait(arg string) SlashResult {
	mut ids := []string{}
	for s in arg.split(',') {
		t := s.trim_space()
		if t != '' {
			ids << t
		}
	}
	states := a.crew.wait(ids, 300.0) or { return error_result(err.msg()) }
	mut agents := []&CrewAgent{}
	mut names := states.keys()
	names.sort()
	for id in names {
		if ag := a.crew.get(id) {
			agents << ag
		}
	}
	return SlashResult{
		lines: [
			info_line('states: ${states}', c_cyan),
			info_line(a.crew.format(agents), c_fg),
		]
	}
}

fn (mut a Agent) job_mutate(arg string) SlashResult {
	parts := arg.split('\t')
	if parts.len < 2 {
		return error_result('usage: /mutate <file> <suite-command>')
	}
	path := parts[0]
	suite := parts[1]
	mut tester := new_mutation_tester(a.log, suite, '')
	report := tester.run(path, max_mutants)
	a.mutator = tester
	mut lines := [
		'MUTATION — ${report.path}',
		'  score ${report.score * 100:.0f}%   killed ${report.killed}   survived ${report.survived}   errors ${report.errors}   total ${report.total}',
	]
	for r in report.results {
		if r.status == 'survived' {
			lines << '    ⚠ SURVIVED [${r.kind}] ${r.description}'
		}
	}
	return info_result(lines.join('\n'), c_yellow)
}
