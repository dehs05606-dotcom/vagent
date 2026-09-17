module vagent

import x.json2

// slash_tools.v — /synth, /ci, /tune, /dual, /predict, /race, /fabric,
// /auto, /prompt.
//
// /prompt is the one command in this file that can quietly change what the
// model is told, so it is the one that talks most: switching to a prompt
// that does not carry the specification is a legitimate choice and says so
// out loud, because nothing else in the session would.

// cmd_synth synthesizes a tool from a JSON spec: name, description,
// examples ([{"args": {...}, "want": ...}]).
fn (mut a Agent) cmd_synth(arg string) SlashResult {
	usage := 'usage: /synth {"name": "f", "description": "...", "examples": [{"args": {"x": 1}, "want": 2}]}'
	parsed := json2.decode[json2.Any](arg.trim_space()) or { return error_result(usage) }
	if parsed !is map[string]json2.Any {
		return error_result(usage)
	}
	spec_map := parsed as map[string]json2.Any
	mut examples := []SynthExample{}
	raw := spec_map['examples'] or { json2.Any([]json2.Any{}) }
	if raw is []json2.Any {
		for e in raw {
			if e is map[string]json2.Any {
				args := e['args'] or { json2.Any(map[string]json2.Any{}) }
				examples << SynthExample{
					args: if args is map[string]json2.Any {
						args.clone()
					} else {
						map[string]json2.Any{}
					}
					want: e['want'] or { json2.Any('') }
				}
			}
		}
	}
	result := a.synth.synthesize(SynthSpec{
		name:        jstr(spec_map, 'name')
		description: jstr(spec_map, 'description')
		examples:    examples
	})
	head := if result.ok { '✓ ' } else { 'ERROR: ' }
	return info_result(head + result.reason, if result.ok { c_green } else { c_red })
}

fn (mut a Agent) cmd_ci(arg string) SlashResult {
	sub := arg.trim_space().to_lower()
	if sub == 'start' {
		a.ci.start()
		return info_result('🌊 CI pilot watching ${a.ci.root} (every ${a.ci.poll:.0f}s)', c_green)
	}
	if sub == 'stop' {
		a.ci.stop_watching()
		return info_result('CI pilot stopped', c_yellow)
	}
	return info_result(a.ci.status(), c_cyan)
}

// tune_objective scores one tuner configuration.
//
// The original wrote this as a closure that also assigned the trial's effort
// onto the live config as a side effect. That assignment is overwritten a
// few lines later by the winning configuration, so it changed nothing — and
// dropping it keeps the objective a pure function of its argument, which is
// what an optimiser's objective should be.
fn tune_objective(config map[string]string) f64 {
	effort_score := match config['effort'] or { '' } {
		'low' { 0.45 }
		'medium' { 0.7 }
		'high' { 0.85 }
		else { 0.5 }
	}
	steps_score := match config['worker_steps'] or { '' } {
		'low' { 0.9 }
		'medium' { 1.0 }
		'high' { 0.8 }
		else { 0.9 }
	}
	return effort_score * steps_score
}

fn (mut a Agent) cmd_tune(arg string) SlashResult {
	// a non-numeric argument is the default, not an error: the original
	// caught the ValueError and carried on with 12 trials.
	mut n := parse_int_strict(arg.trim_space()) or { 12 }
	if n < 4 {
		n = 4
	}
	if n > 40 {
		n = 40
	}
	a.tuner.objective = tune_objective
	report := a.tuner.run(n) or { return error_result(err.msg()) }
	best := a.tuner.best() or {
		return info_result('🎛 tuned ${report.trials} trials — no trial scored', c_yellow)
	}
	if e := best.config['effort'] {
		a.cfg.effort = e
	}
	return info_result('🎛 tuned ${report.trials} trials — best ${best.score:.2f} with ${best.config} (applied)', c_green)
}

fn (mut a Agent) cmd_dual(arg string) SlashResult {
	s := arg.trim_space()
	if s == '' || s.to_lower() == 'stats' {
		return info_result(a.dual.format_stats(), c_cyan)
	}
	return SlashResult{
		job:     'dual'
		job_arg: s
	}
}

fn (mut a Agent) cmd_predict_impact(arg string) SlashResult {
	path := arg.trim_space()
	if path == '' {
		return error_result('usage: /predict <file path>')
	}
	impact := a.world.predict_impact(path)
	return info_result(impact.format(), c_cyan)
}

fn (a &Agent) cmd_race(arg string) SlashResult {
	task := arg.trim_space()
	if task == '' {
		return error_result('usage: /race <task>')
	}
	return SlashResult{
		job:     'race'
		job_arg: task
	}
}

// cmd_fabric drives the bitemporal knowledge graph: ask, assert, or see
// history.
fn (mut a Agent) cmd_fabric(arg string) SlashResult {
	parts := arg.fields()
	if parts.len == 0 {
		return info_result('usage: /fabric ask <s> <p> | assert <s> <p> <o> | history <s> <p>', c_dim)
	}
	sub := parts[0].to_lower()
	if sub == 'ask' && parts.len >= 3 {
		answer := a.fabric.ask_now(parts[1], parts[2])
		shown := if answer != '' { answer } else { 'unknown' }
		return info_result('${parts[1]} ${parts[2]} = ${shown}', c_cyan)
	}
	if sub == 'assert' && parts.len >= 4 {
		a.fabric.assert_fact(parts[1], parts[2], parts[3..].join(' '), AssertOpts{}) or {
			return error_result(err.msg())
		}
		return info_result('asserted', c_green)
	}
	if sub == 'history' && parts.len >= 3 {
		return info_result(a.fabric.history(parts[1], parts[2]), c_cyan)
	}
	return error_result('usage: /fabric ask|assert|history …')
}

// cmd_auto toggles or inspects the AutoPilot self-routing brain.
fn (mut a Agent) cmd_auto(arg string) SlashResult {
	sub := arg.trim_space().to_lower()
	if sub == 'on' {
		a.autopilot.enabled = true
		return info_result('✓ autopilot ON — the agent will auto-enable goal mode / real-time web as each turn needs them', c_green)
	}
	if sub == 'off' {
		a.autopilot.enabled = false
		return info_result('autopilot OFF — manual control only', c_dim)
	}
	if sub == '' || sub == 'status' {
		state := if a.autopilot.enabled { 'ON' } else { 'OFF' }
		return info_result('autopilot: ${state}\n' + '  auto-enables, per turn:\n' + '  ⚡ goal mode      — verifiable mission detected (auto-drafted contract)\n' + '  ⚡ real-time web  — live-data question detected\n' + '  toggle: /auto on · /auto off', c_cyan)
	}
	return error_result('usage: /auto [on|off|status]')
}

// cmd_prompt selects which system prompt the model gets (systemprompt.v is
// the single source). 'main' is the compact prompt; 'master' is the extended
// specification prompt.
fn (mut a Agent) cmd_prompt(arg string) SlashResult {
	sub := arg.trim_space().to_lower()
	if sub == '' || sub == 'list' || sub == 'status' {
		current := a.cfg.prompt
		mut lines := ['system prompt: ${current}  (source: systemprompt.v)']
		for name in prompt_names() {
			mark := if name == current { '●' } else { '○' }
			text := prompt_get(name)
			carries := if master_spec.trim_space() != '' && text.contains(master_spec) {
				'carries the spec'
			} else if master_spec.trim_space() != '' {
				'NO SPEC'
			} else {
				''
			}
			lines << '  ${mark} ${name:-8} ${thousands(text.len):9} chars  ${carries}'
		}
		// a missing master spec is otherwise invisible: 'master' simply
		// serves the compact prompt and nothing says so
		lines << ''
		lines << spec_status()
		lines << 'switch: /prompt main · /prompt master'
		return info_result(lines.join('\n'), c_cyan)
	}
	if sub == 'reload' {
		return error_result('there is nothing to reload: the specification is compiled into systemprompt.v, not read from a file. Edit the SPEC constant and rebuild.')
	}
	if sub !in prompt_names() {
		return error_result("unknown prompt '${sub}' — available: " + prompt_names().join(', '))
	}
	mut lines := []SlashLine{}
	// selecting a prompt that does not carry the specification is a
	// legitimate choice and must not be a silent one: it is the one switch
	// that turns the whole specification off for the sovereign agent, and
	// nothing said so before.
	if master_spec.trim_space() != '' && !prompt_get(sub).contains(master_spec) {
		lines << error_line("NOTE: '${sub}' does not carry your specification (${thousands(spec_chars())} chars). The sovereign agent will run without it; sub-agents still carry it. Use /prompt master to put it back.")
	}
	a.cfg.prompt = sub
	a.cfg.save()
	// re-seat the live conversation's system prompt through the gate
	a.reseat_system_prompt(map[string]string{}, false)
	size := a.base_prompt().len
	lines << info_line('✓ system prompt → ${sub} (${thousands(size)} chars) — applies from the next model call', c_green)
	return SlashResult{
		lines: lines
	}
}
