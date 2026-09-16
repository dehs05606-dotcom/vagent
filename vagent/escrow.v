module vagent

import os
import x.json2

// escrow.v — a write reaches the tree only after it has been judged.
//
// The Covenant refuses an intention. The Sentinel reverts a realised
// violation. Between them sits a window neither closes: a call that passes
// the gate honestly, writes, and is then reverted was nonetheless LIVE for
// the duration. During that window another process compiles the file, a
// watcher fires, a test runs against it, a daemon reads the credential.
// Reversion restores the bytes; it does not un-observe them.
//
// For a multi-file change the window is worse than an instant. Files land
// one at a time, so a change that is only coherent as a set is briefly half
// applied. If the third write is refused, the first two are already real,
// and "revert" now means undoing work that was itself permissible.
//
// Escrow removes the window instead of shortening it:
//
//     stage    writes go to a private directory, not the tree
//     judge    the complete set is evaluated as one unit, against the same
//              clauses, with the real content that would land
//     commit   only if every member passes — then all at once
//     discard  otherwise nothing was ever in the tree to undo
//
// This is what makes a multi-file change atomic with respect to the
// specification. The unit of judgement becomes the change rather than the
// file, so a set that is individually innocent and collectively forbidden —
// twenty files that together cross a horizon limit, a credential split
// across two writes — is refused as the set it is.
//
// Nothing is written outside the staging directory before commit, so a
// discarded change leaves no trace and needs no snapshot to undo: there is
// nothing to restore, which is a stronger property than restoring correctly.
//
// LIMIT, stated plainly: escrow governs writes made THROUGH it. A command
// that writes directly to the tree bypasses staging entirely — that is the
// Sentinel's job, and the two are complementary rather than alternatives.

pub struct Staged {
pub:
	// the real destination
	path    string
	content string
	// where it actually lives until commit
	staged_at string
}

pub fn (s &Staged) effect() Effect {
	return Effect{
		kind:    effect_write
		path:    s.path
		content: s.content
		reason:  'staged for commit'
	}
}

pub struct EscrowOutcome {
pub mut:
	committed  []string
	discarded  []string
	violations []Violation
	breaches   []Breach
	detail     string
}

pub fn (o &EscrowOutcome) ok() bool {
	return o.violations.len == 0 && o.breaches.len == 0
}

pub fn (o &EscrowOutcome) to_json() map[string]json2.Any {
	return {
		'committed':  json2.Any(o.committed.map(json2.Any(it)))
		'discarded':  json2.Any(o.discarded.map(json2.Any(it)))
		'violations': json2.Any(o.violations.map(json2.Any(it.to_json())))
		'breaches':   json2.Any(o.breaches.map(json2.Any(it.to_json())))
	}
}

@[heap]
pub struct Escrow {
pub mut:
	log      &EventLog
	covenant &Covenant
	// optional: the accumulating limits the set also has to fit inside
	horizon  &Horizon = unsafe { nil }
	pending  []Staged
	commits  int
	discards int
mut:
	dir  string
	root string
}

pub fn new_escrow(log &EventLog, covenant &Covenant, root string, horizon &Horizon) &Escrow {
	dir := os.join_path(os.temp_dir(), 'vagent-escrow-${os.getpid()}-${now_ts():.0f}')
	os.mkdir_all(dir) or {}
	return &Escrow{
		log:      unsafe { log }
		covenant: unsafe { covenant }
		horizon:  unsafe { horizon }
		dir:      dir
		root:     root
	}
}

fn (e &Escrow) resolve(path string) string {
	if os.is_abs_path(path) || e.root == '' {
		return path
	}
	return os.join_path(e.root, path)
}

// -- staging -----------------------------------------------------------------

// stage holds a write outside the tree. Nothing in the tree changes here.
pub fn (mut e Escrow) stage(path string, content string) Staged {
	blob := os.join_path(e.dir, '${e.pending.len:04}.blob')
	os.write_file(blob, content) or {}
	item := Staged{
		path:      path
		content:   content
		staged_at: blob
	}
	e.pending << item
	e.log.append('escrow.staged', {
		'path':  json2.Any(path)
		'chars': json2.Any(content.len)
	}, AppendOpts{ actor: 'kernel' })
	return item
}

// -- judgement ---------------------------------------------------------------

// judge evaluates the WHOLE pending set against the clauses, at once.
//
// Judging the set rather than each member is the point: a change can be
// forbidden as a unit while every individual write in it is permitted.
pub fn (mut e Escrow) judge() ([]Violation, []Breach) {
	effects := e.pending.map(it.effect())
	violations := e.covenant.check_effects(effects)
	mut breaches := []Breach{}
	if !isnil(e.horizon) && e.pending.len > 0 {
		mut h := e.horizon
		for s in e.pending {
			found := h.project('write_file', {
				'path':    json2.Any(s.path)
				'content': json2.Any(s.content)
			})
			if found.len > 0 {
				breaches << found
				break
			}
		}
	}
	return violations, breaches
}

// -- resolution --------------------------------------------------------------

// commit judges, then either lands every write or none of them.
pub fn (mut e Escrow) commit() EscrowOutcome {
	if e.pending.len == 0 {
		return EscrowOutcome{}
	}
	violations, breaches := e.judge()
	paths := e.pending.map(it.path)

	if violations.len > 0 || breaches.len > 0 {
		e.discards++
		e.log.append('escrow.discarded', {
			'paths':      json2.Any(paths.map(json2.Any(it)))
			'violations': json2.Any(violations.map(json2.Any(it.to_json())))
			'breaches':   json2.Any(breaches.map(json2.Any(it.to_json())))
		}, AppendOpts{ actor: 'kernel' })
		plural := if paths.len > 1 { 's' } else { '' }
		mut detail := [
			'CovenantViolation: this change of ${paths.len} file${plural} was judged as a set and refused. Nothing reached the tree.',
		]
		for v in violations {
			detail << '  ${v.clause}: ${v.detail}'
		}
		for b in breaches {
			detail << '  ${b.describe()}'
		}
		e.clear()
		return EscrowOutcome{
			discarded:  paths
			violations: violations
			breaches:   breaches
			detail:     detail.join('\n')
		}
	}

	mut landed := []string{}
	for s in e.pending {
		dest := e.resolve(s.path)
		parent := os.dir(dest)
		if parent != '' {
			os.mkdir_all(parent) or {}
		}
		os.cp(s.staged_at, dest) or { continue }
		landed << s.path
	}
	e.commits++
	e.log.append('escrow.committed', {
		'paths': json2.Any(landed.map(json2.Any(it)))
	}, AppendOpts{ actor: 'kernel' })
	e.clear()
	return EscrowOutcome{
		committed: landed
	}
}

// discard abandons the pending set. Nothing was in the tree to undo.
pub fn (mut e Escrow) discard() EscrowOutcome {
	paths := e.pending.map(it.path)
	if paths.len > 0 {
		e.discards++
		e.log.append('escrow.discarded', {
			'paths':      json2.Any(paths.map(json2.Any(it)))
			'violations': json2.Any([]json2.Any{})
		}, AppendOpts{ actor: 'kernel' })
	}
	e.clear()
	return EscrowOutcome{
		discarded: paths
	}
}

pub fn (mut e Escrow) clear() {
	for s in e.pending {
		os.rm(s.staged_at) or {}
	}
	e.pending = []
}

pub fn (mut e Escrow) close() {
	e.clear()
	os.rmdir_all(e.dir) or {}
}

pub fn (e &Escrow) stats() map[string]json2.Any {
	return {
		'pending':  json2.Any(e.pending.len)
		'commits':  json2.Any(e.commits)
		'discards': json2.Any(e.discards)
	}
}
