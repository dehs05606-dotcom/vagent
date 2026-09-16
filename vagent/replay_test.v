module vagent

import os
import x.json2

const replay_spec = '§1 Writes stay under src/ and tests/
@enforce confine_paths: src, tests

§2 Nothing is ever deleted
@enforce forbid_effect: delete
'

fn rp_args(pairs map[string]string) map[string]json2.Any {
	mut out := map[string]json2.Any{}
	for k, v in pairs {
		out[k] = json2.Any(v)
	}
	return out
}

fn replay_calls() [][]json2.Any {
	return [
		[json2.Any('write_file'), json2.Any(rp_args({
			'path':    'src/a.py'
			'content': 'x = 1'
		}))],
		[json2.Any('write_file'), json2.Any(rp_args({
			'path':    '/etc/passwd'
			'content': 'root'
		}))],
		[json2.Any('run_command'), json2.Any(rp_args({
			'command': 'pytest -q'
		}))],
		[json2.Any('delete_path'), json2.Any(rp_args({
			'path': 'src/a.py'
		}))],
		[json2.Any('run_command'), json2.Any(rp_args({
			'command': 'echo x > /etc/y'
		}))],
	]
}

struct ReplayFixture {
mut:
	root string
	log  &EventLog
	ch   &Charter
}

fn replay_fixture(name string) ReplayFixture {
	root := os.join_path(os.temp_dir(), 'vagent-replay-${name}-${os.getpid()}')
	os.rmdir_all(root) or {}
	os.mkdir_all(root) or { panic(err) }
	mut log := new_event_log(os.join_path(root, 'log.jsonl'), 'main', 'test')
	mut ch := new_charter(log, CharterOpts{
		spec: replay_spec
		root: root
	})
	ch.open_turn()
	for call in replay_calls() {
		tool := call[0].str()
		args := call[1].as_map()
		log.append('tool.call', {
			'name': json2.Any(tool)
			'args': json2.Any(args.clone())
		}, AppendOpts{})
		ch.gate(tool, args)
	}
	return ReplayFixture{
		root: root
		log:  log
		ch:   ch
	}
}

fn test_a_faithful_record_re_derives_to_itself() {
	mut f := replay_fixture('rp1')
	defer {
		os.rmdir_all(f.root) or {}
	}
	r := replay_decisions(mut f.log, replay_spec, [], false)
	assert r.ok(), r.describe()
	assert r.agreed == replay_calls().len
	assert r.diverged == 0
	assert r.describe().contains('every recorded decision follows')
}

fn test_a_different_specification_diverges() {
	mut f := replay_fixture('rp2')
	defer {
		os.rmdir_all(f.root) or {}
	}
	loose := '§1 nothing is forbidden here\n'
	r := replay_decisions(mut f.log, loose, [], false)
	assert !r.ok()
	assert r.diverged == 3, r.describe()
	for row in r.problems() {
		assert row.recorded == verdict_refused
		assert row.rederived == verdict_allowed
	}
	assert r.describe().contains('rules today decide differently')

	// a stricter specification diverges the other way
	strict := '§9 nothing may be written at all\n@enforce forbid_effect: write\n'
	s := replay_decisions(mut f.log, strict, [], false)
	assert s.diverged > 0
	assert s.problems().any(it.recorded == verdict_allowed && it.rederived == verdict_refused)
}

fn test_a_call_nobody_judged_is_found() {
	root := os.join_path(os.temp_dir(), 'vagent-replay-rp3-${os.getpid()}')
	os.rmdir_all(root) or {}
	os.mkdir_all(root) or { panic(err) }
	defer {
		os.rmdir_all(root) or {}
	}
	mut log := new_event_log(os.join_path(root, 'log.jsonl'), 'main', 'test')
	mut ch := new_charter(log, CharterOpts{
		spec: replay_spec
		root: root
	})
	args := rp_args({
		'path':    'src/a.py'
		'content': 'x'
	})
	log.append('tool.call', {
		'name': json2.Any('write_file')
		'args': json2.Any(args.clone())
	}, AppendOpts{})
	ch.gate('write_file', args)
	// this one bypassed the gate entirely
	log.append('tool.call', {
		'name': json2.Any('delete_path')
		'args': json2.Any(rp_args({
			'path': 'src/a.py'
		}))
	}, AppendOpts{})

	r := replay_decisions(mut log, replay_spec, [], false)
	assert r.unwitnessed == 1
	assert !r.ok()
	assert r.describe().contains('enforcement did not run')
}

fn test_a_broken_chain_invalidates_agreement() {
	mut f := replay_fixture('rp4')
	defer {
		os.rmdir_all(f.root) or {}
	}
	decisions := f.ch.witness.export()
	mut tampered := decisions.clone()
	tampered[1]['verdict'] = json2.Any(verdict_allowed)
	r := replay_decisions(mut f.log, replay_spec, tampered, true)
	assert !r.chain_intact
	assert !r.ok()
	assert r.describe().contains('proves nothing')
}

fn test_verification_works_with_no_access_to_the_process() {
	mut f := replay_fixture('rp5')
	defer {
		os.rmdir_all(f.root) or {}
	}
	decisions := f.ch.witness.export()
	mut plain := []GatedCall{}
	for i, call in replay_calls() {
		plain << make_gated_call(i, call[0].str(), call[1].as_map())
	}
	r := replay_independent(decisions, plain, replay_spec)
	assert r.ok(), r.describe()
	// and it catches the wrong specification just the same
	assert !replay_independent(decisions, plain, '§1 nothing is forbidden here\n').ok()
}

fn test_an_empty_log_is_honest_about_being_empty() {
	root := os.join_path(os.temp_dir(), 'vagent-replay-rp6-${os.getpid()}')
	os.rmdir_all(root) or {}
	os.mkdir_all(root) or { panic(err) }
	defer {
		os.rmdir_all(root) or {}
	}
	mut log := new_event_log(os.join_path(root, 'log.jsonl'), 'main', 'test')
	r := replay_decisions(mut log, replay_spec, [], false)
	assert r.describe().contains('no gated calls')
	assert r.ok()
}
