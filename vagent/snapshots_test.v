module vagent

import os
import x.json2

fn snap_dirs(name string) (string, string) {
	base := os.join_path(os.temp_dir(), 'vagent-snap-${os.getpid()}', name)
	os.rmdir_all(base) or {}
	work := os.join_path(base, 'work')
	os.mkdir_all(work) or { panic(err) }
	return os.join_path(base, 'store'), work
}

fn test_snapshot_take_dedup_diff_and_materialise() {
	store_root, work := snap_dirs('roundtrip')
	mut store := new_snapshot_store(store_root)
	f1 := os.join_path(work, 'a.txt')
	f2 := os.join_path(work, 'b.txt')
	os.write_file(f1, 'version one') or { panic(err) }

	// take: an existing file and a missing one
	snap1 := store.take([f1, f2])
	assert (snap1.paths[f1] or { '' }) != ''
	assert (snap1.paths[f2] or { 'x' }) == '' // absence is part of the state

	// dedup: identical content -> identical blob hash
	h1 := store.put_blob('version one'.bytes())
	assert h1 == snap1.paths[f1] or { '' }

	// mutate both files, take a second snapshot
	os.write_file(f1, 'version two') or { panic(err) }
	os.write_file(f2, 'created later') or { panic(err) }
	snap2 := store.take([f1, f2])

	// the diff sees the modification and the addition
	d := store.diff(snap1.tree, snap2.tree)
	assert f1 in d.modified, '${d}'
	assert f2 in d.added, '${d}'

	// materialise snap1: f1 reverts, f2 (absent in snap1) is removed
	res := store.materialise(snap1.tree)
	assert os.read_file(f1)! == 'version one'
	assert !os.exists(f2)
	assert res.restored == 1 && res.removed == 1, '${res}'

	// forward travel works too
	store.materialise(snap2.tree)
	assert os.read_file(f1)! == 'version two'
	assert os.read_file(f2)! == 'created later'
}

fn test_extensionless_paths_are_not_clobbered() {
	store_root, work := snap_dirs('noext')
	mut store := new_snapshot_store(store_root)
	// a path with no extension used to collide with its own temp file
	mk := os.join_path(work, 'Makefile')
	os.write_file(mk, 'all:\n\techo hi\n') or { panic(err) }
	snap := store.take([mk])
	os.write_file(mk, 'broken') or { panic(err) }
	res := store.materialise(snap.tree)
	assert res.restored == 1, '${res}'
	assert os.read_file(mk)! == 'all:\n\techo hi\n'
}

fn test_unresolvable_tree_reports_an_error() {
	store_root, _ := snap_dirs('missing')
	mut store := new_snapshot_store(store_root)
	res := store.materialise('deadbeefdeadbeef')
	assert res.error.contains('does not resolve'), res.error
	assert res.restored == 0
}

fn test_gc_keeps_referenced_blobs_and_sweeps_orphans() {
	store_root, work := snap_dirs('gc')
	mut store := new_snapshot_store(store_root)
	f1 := os.join_path(work, 'a.txt')
	os.write_file(f1, 'version two') or { panic(err) }
	snap := store.take([f1])

	mut log := new_event_log(tmp_log_path('snap-gc.jsonl'), 'main', '')
	defer {
		log.close()
	}
	log.append('snapshot.taken', {
		'tree':  json2.Any(snap.tree)
		'paths': json2.Any(strs_to_any(snap.paths.keys()))
	}, AppendOpts{})

	orphan := store.put_blob('unreferenced garbage'.bytes())
	deleted := store.gc(mut log)
	assert deleted >= 1
	assert store.get_blob(orphan) == none
	assert store.get_blob(snap.paths[f1] or { '' }) != none

	// the referenced tree still materialises after GC
	os.rm(f1) or { panic(err) }
	store.materialise(snap.tree)
	assert os.read_file(f1)! == 'version two'
}

fn test_blobs_round_trip_binary_content() {
	store_root, _ := snap_dirs('binary')
	mut store := new_snapshot_store(store_root)
	mut data := []u8{}
	for i in 0 .. 512 {
		data << u8(i % 256)
	}
	h := store.put_blob(data)
	back := store.get_blob(h) or { panic('blob vanished') }
	assert back == data
}

fn test_forge_digest_is_stable_and_detects_drift() {
	base := os.join_path(os.temp_dir(), 'vagent-forge-${os.getpid()}')
	os.rmdir_all(base) or {}
	os.mkdir_all(base) or { panic(err) }
	mut log := new_event_log(tmp_log_path('forge.jsonl'), 'main', '')
	defer {
		log.close()
	}
	mut forge := new_forge(log, base)

	d1 := forge.probe()
	assert jstr(d1, 'digest').len == 16
	assert jstr(d1, 'os') != ''
	assert jstr(d1, 'runtime') != ''

	// an identical environment -> an identical digest, and no drift
	d2 := forge.probe()
	assert jstr(d1, 'digest') == jstr(d2, 'digest')
	assert forge.drift() == none

	// a material change (a lockfile appears) -> drift detected
	os.write_file(os.join_path(base, 'requirements.txt'), 'requests==2.32.0\n') or {
		panic(err)
	}
	d3 := forge.probe()
	assert jstr(d3, 'digest') != jstr(d1, 'digest')
	delta := forge.drift() or { panic('drift was not detected') }
	mut saw_lockfile := false
	for c in delta.changed {
		if c.contains('lockfile') {
			saw_lockfile = true
		}
	}
	assert saw_lockfile, '${delta.changed}'
	assert delta.from == jstr(d1, 'digest')
	assert delta.to == jstr(d3, 'digest')

	// every digest is sealed in the log
	assert fold(mut log, '').env_digests.len == 3
}
