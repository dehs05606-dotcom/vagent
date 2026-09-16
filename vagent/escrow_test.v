module vagent

import os
import x.json2

fn json2_any(s string) json2.Any {
	return json2.Any(s)
}

const escrow_spec = '§1 Writes stay under src
@enforce confine_paths: src

§2 No secrets in source
@enforce forbid_content: (?i)api[_-]?key\\s*=\\s*["\\\'][A-Za-z0-9]
'

fn escrow_root(name string) string {
	root := os.join_path(os.temp_dir(), 'vagent-escrow-${name}-${os.getpid()}')
	os.rmdir_all(root) or {}
	os.mkdir_all(root) or { panic(err) }
	return root
}

fn test_a_clean_set_commits_atomically_and_nothing_lands_before_it() {
	root := escrow_root('e1')
	defer {
		os.rmdir_all(root) or {}
	}
	mut log := new_event_log(os.join_path(root, 'log.jsonl'), 'main', 'test')
	mut e := new_escrow(log, new_covenant(log, escrow_spec), root, unsafe { nil })
	defer {
		e.close()
	}

	e.stage('src/a.py', 'x = 1\n')
	e.stage('src/b.py', 'y = 2\n')
	// nothing has touched the tree yet
	assert !os.exists(os.join_path(root, 'src')), 'staging wrote to the tree'

	out := e.commit()
	assert out.ok()
	assert out.committed == ['src/a.py', 'src/b.py']
	assert os.read_file(os.join_path(root, 'src', 'a.py')) or { '' } == 'x = 1\n'
	assert os.is_file(os.join_path(root, 'src', 'b.py'))
	assert e.pending.len == 0
	assert e.commits == 1
}

fn test_one_bad_member_discards_the_whole_set() {
	root := escrow_root('e2')
	defer {
		os.rmdir_all(root) or {}
	}
	mut log := new_event_log(os.join_path(root, 'log.jsonl'), 'main', 'test')
	mut e := new_escrow(log, new_covenant(log, escrow_spec), root, unsafe { nil })
	defer {
		e.close()
	}

	outside := os.join_path(root, 'outside', 'evil.py')
	e.stage('src/c.py', 'z = 3\n')
	e.stage(outside, 'boom\n')
	out := e.commit()
	assert !out.ok()
	assert out.discarded.len == 2
	// the innocent member never landed either — that is the atomicity
	assert !os.exists(os.join_path(root, 'src', 'c.py')), 'a permitted member landed from a refused set'
	assert !os.exists(outside)
	assert out.detail.contains('judged as a set')
	assert e.discards == 1
}

fn test_content_rules_see_the_real_bytes_that_would_land() {
	root := escrow_root('e3')
	defer {
		os.rmdir_all(root) or {}
	}
	mut log := new_event_log(os.join_path(root, 'log.jsonl'), 'main', 'test')
	mut e := new_escrow(log, new_covenant(log, escrow_spec), root, unsafe { nil })
	defer {
		e.close()
	}
	e.stage('src/conf.py', 'API_KEY = "sk-abc123"\n')
	out := e.commit()
	assert !out.ok()
	assert out.violations.any(it.clause == '2')
	assert !os.exists(os.join_path(root, 'src', 'conf.py'))
}

fn test_a_discarded_set_leaves_nothing_to_undo() {
	root := escrow_root('e4')
	defer {
		os.rmdir_all(root) or {}
	}
	mut log := new_event_log(os.join_path(root, 'log.jsonl'), 'main', 'test')
	mut e := new_escrow(log, new_covenant(log, escrow_spec), root, unsafe { nil })
	defer {
		e.close()
	}
	e.stage('src/d.py', 'd = 1\n')
	out := e.discard()
	assert out.discarded == ['src/d.py']
	assert !os.exists(os.join_path(root, 'src', 'd.py'))
	assert e.pending.len == 0

	// committing nothing is a no-op
	empty := e.commit()
	assert empty.committed.len == 0
	assert empty.ok()
}

fn test_the_set_is_judged_against_the_horizon_too() {
	root := escrow_root('e5')
	defer {
		os.rmdir_all(root) or {}
	}
	mut log := new_event_log(os.join_path(root, 'log.jsonl'), 'main', 'test')
	cov := new_covenant(log, escrow_spec)
	mut hz := new_horizon(log, '§3 A change touches at most 2 files\n@horizon per turn max files_written 2\n')
	hz.open_turn()
	mut e := new_escrow(log, cov, root, hz)
	defer {
		e.close()
	}

	e.stage('src/e.py', 'e = 1\n')
	e.stage('src/f.py', 'f = 1\n')
	first := e.commit()
	assert first.ok(), first.detail

	hz.spend('write_file', {
		'path':    json2_any('src/e.py')
		'content': json2_any('e = 1\n')
	})
	hz.spend('write_file', {
		'path':    json2_any('src/f.py')
		'content': json2_any('f = 1\n')
	})

	e.stage('src/g.py', 'g = 1\n')
	second := e.commit()
	assert !second.ok(), 'the horizon limit was crossed through escrow'
	assert !os.exists(os.join_path(root, 'src', 'g.py'))
	assert second.breaches.len == 1
	assert second.detail.contains('capped at 2')
}

fn test_the_ledger_records_both_outcomes() {
	root := escrow_root('e6')
	defer {
		os.rmdir_all(root) or {}
	}
	mut log := new_event_log(os.join_path(root, 'log.jsonl'), 'main', 'test')
	mut e := new_escrow(log, new_covenant(log, escrow_spec), root, unsafe { nil })
	defer {
		e.close()
	}
	e.stage('src/a.py', 'a = 1\n')
	e.commit()
	e.stage('src/conf.py', 'API_KEY = "sk-abc123"\n')
	e.commit()
	kinds := log.events('main').map(it.typ)
	assert 'escrow.staged' in kinds
	assert 'escrow.committed' in kinds
	assert 'escrow.discarded' in kinds
}

fn test_an_empty_specification_stages_and_commits_freely() {
	root := escrow_root('e7')
	defer {
		os.rmdir_all(root) or {}
	}
	mut log := new_event_log(os.join_path(root, 'log.jsonl'), 'main', 'test')
	mut e := new_escrow(log, new_covenant(log, ''), root, unsafe { nil })
	defer {
		e.close()
	}
	e.stage('anywhere/h.py', 'h = 1\n')
	out := e.commit()
	assert out.ok()
	assert os.is_file(os.join_path(root, 'anywhere', 'h.py'))
	assert jint(e.stats(), 'commits') == 1
}
