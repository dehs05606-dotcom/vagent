module vagent

import x.json2

// a scripted generator: the default draft works, and the named ones are the
// poisoned or broken drafts each gate exists to catch
fn scripted_synth_generator(spec &SynthSpec) string {
	match spec.name {
		'slugify' {
			return 'import os\ndef slugify(text):\n' + '    return exec(\x27raise SystemExit\x27)\n'
		}
		'dunder' {
			return 'def dunder(x):\n    return x.__class__.__mro__\n'
		}
		'two_defs' {
			return 'def two_defs(a):\n    return a\ndef helper(b):\n    return b\n'
		}
		'wrongmath' {
			return 'def wrongmath(n):\n    return n + 1000\n'
		}
		'misnamed' {
			return 'def something_else(n):\n    return n\n'
		}
		'looper' {
			return 'def looper(n):\n    while True:\n        pass\n'
		}
		else {
			return 'def ${spec.name}(n):\n    return str(int(n) * 2)\n'
		}
	}
}

fn synth_have_python() bool {
	if _ := find_python() {
		return true
	}
	eprintln('synth: no python interpreter — skipping')
	return false
}

fn doubling_spec() SynthSpec {
	return SynthSpec{
		name:        'double_it'
		description: 'doubles a number string'
		examples:    [
			SynthExample{
				args: {
					'n': json2.Any('4')
				}
				want: json2.Any('8')
			},
			SynthExample{
				args: {
					'n': json2.Any('21')
				}
				want: json2.Any('42')
			},
		]
	}
}

fn one_example(name string, arg string, value json2.Any, want json2.Any) SynthSpec {
	return SynthSpec{
		name:        name
		description: 'x'
		examples:    [
			SynthExample{
				args: {
					arg: value
				}
				want: want
			},
		]
	}
}

fn test_a_proven_draft_becomes_a_tool_that_really_works() {
	if !synth_have_python() {
		return
	}
	mut log := new_event_log(tmp_log_path('syn1'), 'main', 'test')
	mut s := new_program_synthesizer(log, scripted_synth_generator)

	result := s.synthesize(doubling_spec())
	assert result.ok, result.reason
	assert result.passed == 2
	assert result.total == 2
	assert 'double_it' in s.registry

	tool := s.registry['double_it'] or { panic('registered tool vanished') }
	// not merely registered — callable, and correct on an input the
	// examples never mentioned
	assert tool.handler({
		'n': json2.Any('5')
	}, no_sink) == '10'
	assert tool.description.starts_with('[synthesized]')
	assert 'n' in jmap(tool.parameters, 'properties')
	assert jstrs(tool.parameters, 'required') == ['n']
}

fn test_a_smuggled_exec_dies_at_the_gate_without_running() {
	if !synth_have_python() {
		return
	}
	mut log := new_event_log(tmp_log_path('syn2'), 'main', 'test')
	mut s := new_program_synthesizer(log, scripted_synth_generator)
	bad := s.synthesize(one_example('slugify', 'text', json2.Any('A'), json2.Any('a')))
	assert !bad.ok
	assert bad.reason.contains('forbidden'), bad.reason
	assert 'slugify' !in s.registry
	// the draft never executed: had it, the SystemExit would have taken
	// the process with it
	assert s.synthesized.len == 0
}

fn test_dunder_access_is_refused() {
	if !synth_have_python() {
		return
	}
	mut log := new_event_log(tmp_log_path('syn3'), 'main', 'test')
	mut s := new_program_synthesizer(log, scripted_synth_generator)
	du := s.synthesize(one_example('dunder', 'x', json2.Any(1), json2.Any(1)))
	assert !du.ok
	assert du.reason.contains('dunder'), du.reason
}

fn test_a_draft_must_be_exactly_one_function_with_the_right_name() {
	if !synth_have_python() {
		return
	}
	mut log := new_event_log(tmp_log_path('syn4'), 'main', 'test')
	mut s := new_program_synthesizer(log, scripted_synth_generator)

	two := s.synthesize(one_example('two_defs', 'a', json2.Any(1), json2.Any(1)))
	assert !two.ok
	assert two.reason.contains('exactly one function'), two.reason

	wrong := s.synthesize(one_example('misnamed', 'n', json2.Any(1), json2.Any(1)))
	assert !wrong.ok
	assert wrong.reason.contains('must be named'), wrong.reason
}

fn test_failing_examples_block_registration() {
	if !synth_have_python() {
		return
	}
	mut log := new_event_log(tmp_log_path('syn5'), 'main', 'test')
	mut s := new_program_synthesizer(log, scripted_synth_generator)
	wm := s.synthesize(one_example('wrongmath', 'n', json2.Any(1), json2.Any(2)))
	assert !wm.ok
	assert wm.reason.contains('failed examples'), wm.reason
	// the examples are the contract, and it was not met
	assert wm.passed == 0
	assert wm.total == 1
	assert 'wrongmath' !in s.registry
}

fn test_a_draft_that_never_terminates_fails_instead_of_freezing() {
	if !synth_have_python() {
		return
	}
	mut log := new_event_log(tmp_log_path('syn6'), 'main', 'test')
	mut s := new_program_synthesizer(log, scripted_synth_generator)
	// the AST gate cannot prove termination — `while True:` is legal
	// syntax — so the wall clock is what catches this
	looper := s.synthesize(one_example('looper', 'n', json2.Any(1), json2.Any(1)))
	assert !looper.ok
	assert looper.reason.contains('timed out'), looper.reason
	assert 'looper' !in s.registry
}

fn test_a_bad_name_or_no_examples_is_refused_before_drafting() {
	mut log := new_event_log(tmp_log_path('syn7'), 'main', 'test')
	mut s := new_program_synthesizer(log, scripted_synth_generator)

	bad_name := s.synthesize(one_example('Bad-Name', 'a', json2.Any(1), json2.Any(1)))
	assert !bad_name.ok
	assert bad_name.reason == 'bad tool name'

	no_examples := s.synthesize(SynthSpec{
		name:        'noexamples'
		description: 'x'
	})
	assert !no_examples.ok
	assert no_examples.reason.contains('example is required')

	// neither reached the generator, so nothing was drafted or sealed
	assert log.head('main') == -1

	assert valid_synth_name('double_it')
	assert !valid_synth_name('Bad-Name')
	assert !valid_synth_name('ab')
	assert !valid_synth_name('9lives')
}

fn test_the_lineage_is_sealed() {
	if !synth_have_python() {
		return
	}
	mut log := new_event_log(tmp_log_path('syn8'), 'main', 'test')
	mut s := new_program_synthesizer(log, scripted_synth_generator)
	s.synthesize(doubling_spec())
	s.synthesize(one_example('wrongmath', 'n', json2.Any(1), json2.Any(2)))

	types := log.events('main').map(it.typ)
	assert 'synth.tool.drafted' in types
	assert 'synth.tool.tested' in types
	assert 'synth.tool.registered' in types
	// the failed attempt is on the record too, with its count
	tested := log.events('main').filter(it.typ == 'synth.tool.tested')
	assert tested.len == 2
	assert jbool(tested[0].data, 'ok')
	assert !jbool(tested[1].data, 'ok')
}

fn test_calling_a_synthesized_tool_reports_its_own_failures() {
	if !synth_have_python() {
		return
	}
	// a proven tool can still be called with the wrong arguments later;
	// that is an error message, not a crash
	out := call_synthesized('double_it', 'def double_it(n):\n    return str(int(n) * 2)\n', {
		'n': json2.Any('nope')
	})
	assert out.starts_with('ERROR:'), out
	assert out.contains('ValueError'), out
}
