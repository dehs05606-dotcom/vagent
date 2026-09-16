module vagent

import x.json2

const sequence_spec = '§20 A file is read before it is rewritten
@sequence before write src/** require read same

§21 Touching src/ obliges a test run before done
@sequence after write src/** require run pytest
'

fn seq_args(pairs map[string]string) map[string]json2.Any {
	mut out := map[string]json2.Any{}
	for k, v in pairs {
		out[k] = json2.Any(v)
	}
	return out
}

fn seq_call(mut log EventLog, name string, args map[string]json2.Any) {
	log.append('tool.call', {
		'name': json2.Any(name)
		'args': json2.Any(args.clone())
	}, AppendOpts{})
}

fn test_the_spec_parses_into_exactly_its_rules() {
	t := new_timeline(new_event_log(tmp_log_path('seq0'), 'main', 'test'), sequence_spec)
	assert t.rules.len == 2
	assert t.errors.len == 0
	assert t.rules[0].when == seq_before && t.rules[0].target == 'same'
	assert t.rules[1].when == seq_after && t.rules[1].req == 'run'
}

fn test_the_precondition_refuses_a_blind_overwrite() {
	mut log := new_event_log(tmp_log_path('seq1'), 'main', 'test')
	mut t := new_timeline(log, sequence_spec)
	blind := seq_args({
		'path':    'src/app.py'
		'content': 'x = 1'
	})
	blocked := t.gate('write_file', blind)
	assert blocked != ''
	assert blocked.contains('20'), blocked
	assert blocked.contains('must be read before'), blocked

	// reading it first satisfies the rule
	seq_call(mut log, 'read_file', seq_args({
		'path': 'src/app.py'
	}))
	assert t.gate('write_file', blind) == ''

	// and the read is not consumed: twice is still fine
	seq_call(mut log, 'write_file', blind)
	assert t.gate('write_file', blind) == ''

	// a different file is still unread
	assert t.gate('write_file', seq_args({
		'path':    'src/other.py'
		'content': 'y'
	})) != ''

	// 'same' binds to the path actually being written
	seq_call(mut log, 'read_file', seq_args({
		'path': 'src/other.py'
	}))
	assert t.gate('write_file', seq_args({
		'path':    'src/other.py'
		'content': 'y'
	})) == ''

	// the shell route is judged identically
	assert t.gate('run_command', seq_args({
		'command': 'echo x > src/third.py'
	})) != ''

	// refusals are sealed
	assert log.events('main').map(it.typ).contains('sequence.blocked')
}

fn test_the_postcondition_blocks_done_not_the_write() {
	mut log := new_event_log(tmp_log_path('seq2'), 'main', 'test')
	mut t := new_timeline(log, sequence_spec)
	seq_call(mut log, 'read_file', seq_args({
		'path': 'src/app.py'
	}))
	seq_call(mut log, 'write_file', seq_args({
		'path':    'src/app.py'
		'content': 'x'
	}))
	blocker := t.blocker()
	assert blocker != ''
	assert blocker.contains('21'), blocker
	assert blocker.contains('must run after that change'), blocker
}

fn test_a_run_before_the_change_does_not_satisfy_a_post_rule() {
	mut log := new_event_log(tmp_log_path('seq3'), 'main', 'test')
	mut t := new_timeline(log, sequence_spec)
	seq_call(mut log, 'run_command', seq_args({
		'command': 'pytest -q'
	}))
	seq_call(mut log, 'write_file', seq_args({
		'path':    'src/a.py'
		'content': 'x'
	}))
	assert t.blocker() != '', 'a pre-change test run satisfied a post rule'

	// running it afterwards does satisfy it
	seq_call(mut log, 'run_command', seq_args({
		'command': 'pytest -q'
	}))
	assert t.blocker() == ''
}

fn test_a_read_invalidated_by_a_later_unauthored_write_is_re_armed() {
	mut log := new_event_log(tmp_log_path('seq4'), 'main', 'test')
	mut t := new_timeline(log, '§20 read first\n@sequence before write src/** require read same\n')
	write := seq_args({
		'path':    'src/a.py'
		'content': 'x'
	})
	seq_call(mut log, 'read_file', seq_args({
		'path': 'src/a.py'
	}))
	assert t.gate('write_file', write) == ''

	// something else rewrote it after the read
	seq_call(mut log, 'run_command', seq_args({
		'command': 'echo z > src/a.py'
	}))
	again := t.gate('write_file', write)
	assert again != ''
	assert again.contains('read it again'), again

	// the agent's own write does not re-arm it: it supplied that content
	seq_call(mut log, 'read_file', seq_args({
		'path': 'src/a.py'
	}))
	seq_call(mut log, 'write_file', write)
	assert t.gate('write_file', write) == ''
}

fn test_rules_that_never_trigger_stay_quiet() {
	mut log := new_event_log(tmp_log_path('seq5'), 'main', 'test')
	mut t := new_timeline(log, sequence_spec)
	assert t.gate('run_command', seq_args({
		'command': 'ls -la'
	})) == ''
	assert t.gate('read_file', seq_args({
		'path': 'src/app.py'
	})) == ''
}

fn test_no_rules_means_no_interference() {
	mut t := new_timeline(new_event_log(tmp_log_path('seq6'), 'main', 'test'), '')
	assert t.gate('write_file', seq_args({
		'path':    'anything'
		'content': 'x'
	})) == ''
	assert t.blocker() == ''
	assert t.report().contains('no @sequence rules')
}

fn test_malformed_rules_are_reported_never_guessed_at() {
	mut t := new_timeline(new_event_log(tmp_log_path('seq7'), 'main', 'test'), '§22 x\n@sequence sideways write a require read b\n' +
		'§23 y\n@sequence before write a\n' + '§24 z\n@sequence before write a require run same\n')
	assert t.errors.len == 3, '${t.errors}'
	assert t.rules.len == 0
	assert t.errors[2].contains('meaningless')
}

fn test_path_normalisation_and_globbing() {
	assert seq_norm('src/./a/../b.py') == 'src/b.py'
	assert seq_norm('a/b/../../c') == 'c'
	assert seq_norm('') == ''
	assert seq_glob('src/app.py', 'src/**')
	assert seq_glob('src/deep/nested/app.py', 'src/**')
	assert !seq_glob('lib/app.py', 'src/**')
	assert seq_glob('src/app.py', 'src/*.py')
}

fn test_the_report_lists_the_rules_and_what_is_outstanding() {
	mut log := new_event_log(tmp_log_path('seq8'), 'main', 'test')
	mut t := new_timeline(log, sequence_spec)
	seq_call(mut log, 'write_file', seq_args({
		'path':    'src/a.py'
		'content': 'x'
	}))
	text := t.report()
	assert text.contains('2 rule(s)')
	assert text.contains('1 outstanding')
	assert text.contains('before  write src/** require read same')
	assert text.contains('○ 21:')
}
