module vagent

import compress.zlib
import crypto.sha256
import os
import x.json2

// snapshots.v — content-addressed, deduplicated file snapshots (§8.3).
//
// Axiom A2: every mutation is reversible. No byte is written by a mutating
// tool without a committed recovery path. This module is that recovery path.
//
// Design:
//   * Blobs are zlib-compressed and addressed by sha256(bytes) — identical
//     content collapses automatically, so a 100-step session editing the
//     same files stores each unique version once.
//   * A snapshot is a TREE: a manifest mapping absolute path -> blob hash.
//     Trees are stored as JSON objects in the same CAS.
//   * The log records a 'snapshot.taken' event (tree hash + paths + the seq
//     of the action it precedes), so rewind/revert are folds: find the
//     newest snapshot at/below the target seq and materialise its tree.
//   * diff(tree_a, tree_b) computes added/removed/modified — the
//     confirmation delta shown before a rewind (§9.2 step 4).
//
// Layout under <root>/objects/:
//     xx/<hash>   compressed blobs (file contents and tree manifests)

fn hash_bytes(data []u8) string {
	return sha256.sum(data).hex()
}

// SnapshotStore is content-addressed blob + tree storage. It is stateless
// beyond the disk.
pub struct SnapshotStore {
pub:
	root    string
	objects string
}

pub fn new_snapshot_store(root string) SnapshotStore {
	objects := os.join_path(root, 'objects')
	os.mkdir_all(objects) or {}
	return SnapshotStore{
		root:    root
		objects: objects
	}
}

// -- blobs -------------------------------------------------------------------

fn (s &SnapshotStore) obj_path(h string) string {
	return os.join_path(s.objects, h[..2], h[2..])
}

// put_blob stores bytes, deduplicated by content hash, and returns the hash.
pub fn (mut s SnapshotStore) put_blob(data []u8) string {
	h := hash_bytes(data)
	p := s.obj_path(h)
	if !os.exists(p) {
		os.mkdir_all(os.dir(p)) or { return h }
		compressed := zlib.compress(data) or { return h }
		// atomic: a crash never leaves a torn blob
		tmp := p + '.tmp'
		os.write_file_array(tmp, compressed) or { return h }
		os.mv(tmp, p) or {
			os.rm(tmp) or {}
		}
	}
	return h
}

pub fn (s &SnapshotStore) get_blob(h string) ?[]u8 {
	if h.len < 3 {
		return none
	}
	p := s.obj_path(h)
	if !os.exists(p) {
		return none
	}
	raw := os.read_bytes(p) or { return none }
	return zlib.decompress(raw) or { return none }
}

// -- trees -------------------------------------------------------------------

pub struct Snapshot {
pub:
	tree string
	// absolute path -> blob hash; an empty hash means the file did NOT
	// exist when the snapshot was taken, which is part of the state
	paths map[string]string
}

// take snapshots the given file paths NOW and returns the tree manifest.
//
// Missing files are recorded with an empty hash (their absence is part of
// the state — restoring the tree removes files created later). Directories
// are not snapshotted as content; only regular files.
pub fn (mut s SnapshotStore) take(paths []string) Snapshot {
	mut manifest := map[string]string{}
	for raw in paths {
		key := resolve_path(raw)
		if os.is_file(key) {
			data := os.read_bytes(key) or {
				manifest[key] = ''
				continue
			}
			manifest[key] = s.put_blob(data)
		} else {
			manifest[key] = ''
		}
	}
	tree_hash := s.put_blob(encode_manifest(manifest).bytes())
	return Snapshot{
		tree:  tree_hash
		paths: manifest
	}
}

// encode_manifest renders a manifest with sorted keys, so identical
// manifests always collapse to the same blob.
fn encode_manifest(manifest map[string]string) string {
	mut obj := map[string]json2.Any{}
	for k, v in manifest {
		obj[k] = if v == '' { json2.null } else { json2.Any(v) }
	}
	return canonical(json2.Any(obj))
}

// load_tree loads a tree manifest by its hash.
pub fn (s &SnapshotStore) load_tree(tree_hash string) ?map[string]string {
	data := s.get_blob(tree_hash) or { return none }
	obj := decode_obj(data.bytestr())
	if obj.len == 0 && data.bytestr().trim_space() != '{}' {
		return none
	}
	mut manifest := map[string]string{}
	for k, v in obj {
		manifest[k] = if v is json2.Null { '' } else { v.str() }
	}
	return manifest
}

pub struct MaterialiseResult {
pub:
	restored      int
	removed       int
	missing_blobs int
	error         string
}

// materialise restores the filesystem to a tree's state.
//
// Files present in the tree are restored from blobs; paths recorded as
// absent are deleted if they now exist (they were created after the
// snapshot).
pub fn (mut s SnapshotStore) materialise(tree_hash string) MaterialiseResult {
	manifest := s.load_tree(tree_hash) or {
		short := if tree_hash.len >= 10 { tree_hash[..10] } else { tree_hash }
		return MaterialiseResult{
			error: 'tree ${short} does not resolve'
		}
	}
	mut restored := 0
	mut removed := 0
	mut missing := 0
	for key, blob in manifest {
		if blob == '' {
			// the file did not exist at snapshot time
			if os.exists(key) {
				if os.is_dir(key) {
					os.rmdir_all(key) or { continue }
				} else {
					os.rm(key) or { continue }
				}
				removed++
			}
			continue
		}
		data := s.get_blob(blob) or {
			missing++
			continue
		}
		parent := os.dir(key)
		if parent != '' {
			os.mkdir_all(parent) or {
				missing++
				continue
			}
		}
		// Append, don't replace, the suffix: paths with no existing
		// extension (Makefile, LICENSE, …) would otherwise collide with
		// their own temp file and clobber the destination before the
		// rename.
		tmp := key + '.snap-tmp'
		os.write_file_array(tmp, data) or {
			missing++
			continue
		}
		os.mv(tmp, key) or {
			os.rm(tmp) or {}
			missing++
			continue
		}
		restored++
	}
	return MaterialiseResult{
		restored:      restored
		removed:       removed
		missing_blobs: missing
	}
}

pub struct TreeDiff {
pub:
	added    []string
	removed  []string
	modified []string
}

// diff lists the paths added / removed / modified going from tree A to tree
// B. An empty hash means the path did not exist at snapshot time.
pub fn (s &SnapshotStore) diff(tree_a string, tree_b string) TreeDiff {
	a := s.load_tree(tree_a) or { map[string]string{} }
	b := s.load_tree(tree_b) or { map[string]string{} }
	mut added := []string{}
	mut removed := []string{}
	mut modified := []string{}
	for p, hb in b {
		if hb != '' && (a[p] or { '' }) == '' {
			added << p
		}
	}
	for p, ha in a {
		if ha == '' {
			continue
		}
		hb := b[p] or { '' }
		if hb == '' {
			if p in b {
				removed << p
			} else {
				removed << p
			}
			continue
		}
		if ha != hb {
			modified << p
		}
	}
	added.sort()
	removed.sort()
	modified.sort()
	return TreeDiff{
		added:    added
		removed:  removed
		modified: modified
	}
}

// -- GC ----------------------------------------------------------------------

// reachable_hashes lists every blob/tree hash referenced by any snapshot
// event (I9).
pub fn (s &SnapshotStore) reachable_hashes(mut log EventLog) map[string]bool {
	mut keep := map[string]bool{}
	for snap in fold(mut log, '').snapshots {
		tree := jstr(snap, 'tree')
		if tree == '' {
			continue
		}
		keep[tree] = true
		manifest := s.load_tree(tree) or { continue }
		for _, h in manifest {
			if h != '' {
				keep[h] = true
			}
		}
	}
	return keep
}

// gc is mark-and-sweep: delete blobs no reachable snapshot references. It
// never collects a blob a reachable event still points at (I9).
pub fn (mut s SnapshotStore) gc(mut log EventLog) int {
	keep := s.reachable_hashes(mut log)
	mut deleted := 0
	if !os.exists(s.objects) {
		return 0
	}
	for sub in os.ls(s.objects) or { [] } {
		sub_path := os.join_path(s.objects, sub)
		if !os.is_dir(sub_path) {
			continue
		}
		for name in os.ls(sub_path) or { [] } {
			f := os.join_path(sub_path, name)
			if name.ends_with('.tmp') {
				// abandoned atomic-write leftovers — sweep them too,
				// otherwise they accumulate forever
				os.rm(f) or { continue }
				deleted++
				continue
			}
			if sub + name !in keep {
				os.rm(f) or { continue }
				deleted++
			}
		}
	}
	return deleted
}
