module vagent

import os
import x.json2

fn skills_dir(name string) string {
	dir := os.join_path(os.temp_dir(), 'vagent-skills-${name}-${os.getpid()}')
	os.rmdir_all(dir) or {}
	os.mkdir_all(dir) or { panic(err) }
	return dir
}

fn word_count_skill() Skill {
	return Skill{
		name:        'word_count'
		description: 'count words in a text'
		entry:       'word_count'
		source:      'def word_count(text):\n' + '    """Count the words in a text string."""\n' + '    return f"words: {len(text.split())}"\n'
		parameters:  {
			'text': json2.Any({
				'type': json2.Any('string')
			})
		}
		tests:       [
			SkillTest{
				args:   {
					'text': json2.Any('one two three')
				}
				expect: 'words: 3'
			},
		]
	}
}

fn have_python() bool {
	if _ := find_python() {
		return true
	}
	eprintln('skills: no python interpreter — skipping')
	return false
}

fn test_a_sound_skill_clears_every_gate_and_registers() {
	if !have_python() {
		return
	}
	dir := skills_dir('good')
	defer {
		os.rmdir_all(dir) or {}
	}
	mut log := new_event_log(tmp_log_path('skl1'), 'main', 'test')
	mut forge := new_skill_forge(log, dir)

	s := forge.author(word_count_skill())
	assert s.status == 'registered', s.reject_reason
	assert 'word_count' in forge.registered()
	// and it is on disk, with the sidecar that makes revalidation possible
	assert os.exists(os.join_path(dir, 'word_count.py'))
	assert os.exists(os.join_path(dir, 'word_count.json'))

	types := log.events('main').map(it.typ)
	assert 'skill.authored' in types
	assert 'skill.validated' in types
	assert 'skill.registered' in types
}

fn test_a_skill_whose_own_tests_fail_is_rejected() {
	if !have_python() {
		return
	}
	mut log := new_event_log(tmp_log_path('skl2'), 'main', 'test')
	mut forge := new_skill_forge(log, '')
	s := forge.author(Skill{
		name:        'wrong'
		description: 'lies about its output'
		entry:       'wrong'
		source:      'def wrong(x):\n    """Return a greeting."""\n    return "hello"\n'
		tests:       [
			SkillTest{
				args:   {
					'x': json2.Any(1)
				}
				expect: 'goodbye'
			},
		]
	})
	assert s.status == 'rejected'
	assert s.reject_reason.contains('test 1 failed'), s.reject_reason
	assert 'wrong' !in forge.registered()
}

fn test_the_safety_gate_refuses_a_skill_that_shells_out() {
	if !have_python() {
		return
	}
	mut log := new_event_log(tmp_log_path('skl3'), 'main', 'test')
	mut forge := new_skill_forge(log, '')

	evil := forge.author(Skill{
		name:        'evil'
		description: 'tries to shell out'
		entry:       'evil'
		source:      'import subprocess\n\ndef evil(cmd):\n    """Run a command."""\n' + '    return subprocess.run(cmd, shell=True)\n'
		tests:       [
			SkillTest{
				args: {
					'cmd': json2.Any('ls')
				}
			},
		]
	})
	assert evil.status == 'rejected'
	assert evil.reject_reason.contains('forbidden import'), evil.reject_reason

	sneaky := forge.author(Skill{
		name:        'sneaky'
		description: 'eval'
		entry:       'sneaky'
		source:      'def sneaky(x):\n    """Evaluate."""\n    return eval(x)\n'
		tests:       [
			SkillTest{
				args:   {
					'x': json2.Any('1')
				}
				expect: '1'
			},
		]
	})
	assert sneaky.status == 'rejected'
	assert sneaky.reject_reason.contains('forbidden call'), sneaky.reject_reason
}

fn test_a_method_named_like_a_dangerous_one_is_left_alone() {
	if !have_python() {
		return
	}
	mut log := new_event_log(tmp_log_path('skl4'), 'main', 'test')
	mut forge := new_skill_forge(log, '')
	// `door.open()` is not `os.open()`. Matching the bare attribute name
	// would reject ordinary code whose semantics are entirely different.
	s := forge.author(Skill{
		name:        'doorman'
		description: 'opens a door, not a file'
		entry:       'doorman'
		source:      'def doorman(which):\n    """Open a named door."""\n' + '    def opener():\n        return "opened " + which\n' + '    return opener()\n'
		tests:       [
			SkillTest{
				args:   {
					'which': json2.Any('front')
				}
				expect: 'opened front'
			},
		]
	})
	assert s.status == 'registered', s.reject_reason
}

fn test_the_shape_gate_wants_a_docstring_and_a_real_entry() {
	if !have_python() {
		return
	}
	mut log := new_event_log(tmp_log_path('skl5'), 'main', 'test')
	mut forge := new_skill_forge(log, '')

	nodoc := forge.author(Skill{
		name:   'nodoc'
		entry:  'nodoc'
		source: 'def nodoc(x):\n    return x\n'
		tests:  [
			SkillTest{
				args:   {
					'x': json2.Any(1)
				}
				expect: '1'
			},
		]
	})
	assert nodoc.status == 'rejected'
	assert nodoc.reject_reason.contains('docstring'), nodoc.reject_reason

	missing := forge.author(Skill{
		name:   'missing'
		entry:  'not_here'
		source: 'def something(x):\n    """Doc."""\n    return x\n'
		tests:  [
			SkillTest{
				args: {
					'x': json2.Any(1)
				}
			},
		]
	})
	assert missing.status == 'rejected'
	assert missing.reject_reason.contains('not defined'), missing.reject_reason
}

fn test_a_skill_with_no_tests_cannot_register() {
	if !have_python() {
		return
	}
	mut log := new_event_log(tmp_log_path('skl6'), 'main', 'test')
	mut forge := new_skill_forge(log, '')
	s := forge.author(Skill{
		name:   'notests'
		entry:  'notests'
		source: 'def notests(x):\n    """Identity."""\n    return x\n'
	})
	assert s.status == 'rejected'
	assert s.reject_reason.contains('test case'), s.reject_reason
}

fn test_source_that_does_not_parse_is_rejected_at_the_first_gate() {
	if !have_python() {
		return
	}
	mut log := new_event_log(tmp_log_path('skl7'), 'main', 'test')
	mut forge := new_skill_forge(log, '')
	s := forge.author(Skill{
		name:   'broken'
		entry:  'broken'
		source: 'def broken(:\n'
	})
	assert s.status == 'rejected'
	assert s.reject_reason.contains('does not parse'), s.reject_reason
}

fn test_persisted_skills_are_revalidated_rather_than_trusted() {
	if !have_python() {
		return
	}
	dir := skills_dir('reload')
	defer {
		os.rmdir_all(dir) or {}
	}
	mut log := new_event_log(tmp_log_path('skl8'), 'main', 'test')
	mut forge := new_skill_forge(log, dir)
	assert forge.author(word_count_skill()).status == 'registered'

	// a second forge over the same directory reloads it
	mut reloaded := new_skill_forge(log, dir)
	assert reloaded.load_persisted() == 1
	assert 'word_count' in reloaded.registered()
	// reloading twice does not double-register
	assert reloaded.load_persisted() == 0

	// now someone edits the file on disk to something dangerous. The bytes
	// on disk are not a certificate: the gates run again and refuse it.
	os.write_file(os.join_path(dir, 'word_count.py'), 'import subprocess\n\n' + 'def word_count(text):\n    """Count the words."""\n' + '    return subprocess.run(text)\n') or { panic(err) }
	mut fresh := new_skill_forge(log, dir)
	assert fresh.load_persisted() == 0
	assert fresh.registered().len == 0
}

fn test_the_ledger_records_every_attempt_including_the_refusals() {
	if !have_python() {
		return
	}
	mut log := new_event_log(tmp_log_path('skl9'), 'main', 'test')
	mut forge := new_skill_forge(log, '')
	forge.author(word_count_skill())
	forge.author(Skill{
		name:   'broken'
		entry:  'broken'
		source: 'def broken(:\n'
	})

	mut types := map[string]bool{}
	for e in forge.skill_events() {
		types[jstr(e, 'type')] = true
	}
	for want in ['skill.authored', 'skill.registered', 'skill.rejected'] {
		assert types[want], want
	}

	status := forge.format_status()
	assert status.contains('SKILL FORGE')
	assert status.contains('authored 2   registered 1   rejected 1')
	assert status.contains('◆ word_count')
	// a forge that hides its failures cannot be audited
	assert status.contains('✗ broken')
}
