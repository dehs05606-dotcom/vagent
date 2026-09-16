module vagent

import os

struct SentinelFixture {
mut:
	root  string
	src   string
	file  string
	log   &EventLog
	store SnapshotStore
}

fn sentinel_fixture(name string) SentinelFixture {
	root := os.join_path(os.temp_dir(), 'vagent-sentinel-${name}-${os.getpid()}')
	os.rmdir_all(root) or {}
	src := os.join_path(root, 'src')
	os.mkdir_all(src) or { panic(err) }
	file := os.join_path(src, 'a.py')
	os.write_file(file, 'x = 1\n') or { panic(err) }
	return SentinelFixture{
		root:  root
		src:   src
		file:  file
		log:   new_event_log(os.join_path(root, 'log.jsonl'), 'main', 'test')
		store: new_snapshot_store(os.join_path(root, 'store'))
	}
}

fn confining_spec(src string) string {
	return '§1 Writes stay under ${src}\n@enforce confine_paths: ${src}\n\n' +
		'§2 No secrets in source\n' +
		'@enforce forbid_content: (?i)api[_-]?key\\s*=\\s*["\\\'][A-Za-z0-9]\n'
}

fn test_a_compliant_change_stands() {
	mut f := sentinel_fixture('s1')
	defer {
		os.rmdir_all(f.root) or {}
	}
	cov := new_covenant(f.log, confining_spec(f.src))
	mut sen := new_sentinel(f.log, cov, f.store)

	watched := [f.file]
	snap := f.store.take(watched)
	os.write_file(f.file, 'x = 2\n') or { panic(err) }
	r := sen.review('run_command', snap.tree, watched)
	assert r.clean()
	assert !r.reverted
	assert os.read_file(f.file) or { '' } == 'x = 2\n'
	assert r.observed.any(it.kind == effect_write)
}

fn test_a_step_that_declared_nothing_is_still_judged_by_what_it_wrote() {
	mut f := sentinel_fixture('s2')
	defer {
		os.rmdir_all(f.root) or {}
	}
	cov := new_covenant(f.log, confining_spec(f.src))
	mut sen := new_sentinel(f.log, cov, f.store)
	watched := [f.file]

	// the gate saw only `run_command python build.py`; the clause is broken
	// by what the script wrote, which exists only afterwards
	snap := f.store.take(watched)
	os.write_file(f.file, 'API_KEY = "sk-abc1"\n') or { panic(err) }
	r := sen.review('run_command', snap.tree, watched)
	assert !r.clean()
	assert r.reverted
	assert r.violations.any(it.clause == '2')
	// the write did not get to stand
	assert os.read_file(f.file) or { '' } == 'x = 1\n'
	assert r.unrevertable.len == 0
	assert r.detail.contains('was reverted')
	assert sen.reverts == 1
}

fn test_a_deletion_is_observed_and_undone() {
	mut f := sentinel_fixture('s3')
	defer {
		os.rmdir_all(f.root) or {}
	}
	cov := new_covenant(f.log, '§3 Nothing is ever deleted\n@enforce forbid_effect: delete\n')
	mut sen := new_sentinel(f.log, cov, f.store)
	watched := [f.file]
	snap := f.store.take(watched)
	os.rm(f.file) or { panic(err) }
	r := sen.review('run_command', snap.tree, watched)
	assert !r.clean()
	assert r.reverted
	assert r.observed.any(it.kind == effect_delete)
	assert os.is_file(f.file), 'the revert did not restore the file'
}

fn test_a_write_outside_the_snapshot_is_detected_but_honestly_not_undone() {
	mut f := sentinel_fixture('s4')
	defer {
		os.rmdir_all(f.root) or {}
	}
	cov := new_covenant(f.log, confining_spec(f.src))
	mut sen := new_sentinel(f.log, cov, f.store)
	watched := [f.file]
	outside := os.join_path(f.root, 'outside.py')

	snap := f.store.take(watched)
	os.write_file(outside, 'API_KEY = "sk-zzz9"\n') or { panic(err) }
	r := sen.review('run_command', snap.tree, [f.file, outside])
	assert !r.clean(), 'an unsnapshotted write went unnoticed'
	assert os.real_path(outside) in r.unrevertable, '${r.unrevertable}'
	assert r.detail.contains('NOT REVERTED')
	// still there, and the report says so rather than claiming otherwise
	assert os.is_file(outside)
	assert sen.undetected_escapes == 1
}

fn test_an_empty_specification_reverts_nothing() {
	mut f := sentinel_fixture('s5')
	defer {
		os.rmdir_all(f.root) or {}
	}
	mut sen := new_sentinel(f.log, new_covenant(f.log, ''), f.store)
	watched := [f.file]
	snap := f.store.take(watched)
	os.write_file(f.file, 'anything at all\n') or { panic(err) }
	r := sen.review('write_file', snap.tree, watched)
	assert r.clean()
	assert !r.reverted
	assert os.read_file(f.file) or { '' } == 'anything at all\n'
}

fn test_the_ledger_is_sealed_and_the_stats_count() {
	mut f := sentinel_fixture('s6')
	defer {
		os.rmdir_all(f.root) or {}
	}
	cov := new_covenant(f.log, confining_spec(f.src))
	mut sen := new_sentinel(f.log, cov, f.store)
	watched := [f.file]
	snap := f.store.take(watched)
	os.write_file(f.file, 'API_KEY = "sk-abc1"\n') or { panic(err) }
	sen.review('run_command', snap.tree, watched)

	kinds := f.log.events('main').map(it.typ)
	assert 'sentinel.violation' in kinds
	assert 'sentinel.reverted' in kinds
	st := sen.stats()
	assert jint(st, 'reviews') == 1
	assert jint(st, 'reverts') == 1
	assert jint(st, 'unrevertable') == 0
}

fn test_an_unchanged_file_produces_no_effect_at_all() {
	mut f := sentinel_fixture('s7')
	defer {
		os.rmdir_all(f.root) or {}
	}
	mut sen := new_sentinel(f.log, new_covenant(f.log, ''), f.store)
	watched := [f.file]
	snap := f.store.take(watched)
	r := sen.review('run_command', snap.tree, watched)
	assert r.observed.len == 0
	assert r.clean()
}
