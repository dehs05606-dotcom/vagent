module vagent

import os
import x.json2

// sentinel.v — what actually happened, and undoing it when it should not have.
//
// The boundary in covenant.v judges an INTENTION: the arguments of a pending
// call, before it runs. That is the right place to refuse, and it catches
// everything whose effects can be read off the call itself.
//
// It cannot catch what a call does once it is running. `run_command` with
// `python build.py` declares nothing about the files the script writes;
// `make install`, a formatter, a code generator, a test that writes fixtures
// — each is one opaque step whose real effects exist only after the fact. A
// containment clause refuses the unreadable ones outright, but the readable
// ones pass the gate honestly and may still land somewhere the specification
// forbids.
//
// So the Sentinel judges the other end: not what was asked for, but what
// occurred.
//
//   before   the snapshot the kernel already takes for every mutating call
//   after    the same paths, re-read once the call has returned
//   diff     the real added / removed / modified set
//   verdict  the SAME clauses, applied to observed effects
//
// and when a clause is broken the write does not stand: the snapshot is
// materialised, the tree returns to its pre-call state, and the reversion is
// sealed with the clauses that caused it.
//
// That is the difference between a rule and a boundary in time. Blocking
// says the agent cannot do the thing. Reverting says that even having done
// it, it did not get to keep it — which is the property that survives a step
// whose effects nobody could predict.
//
// WHAT THIS DOES NOT COVER, stated plainly, because a half-guarantee that
// reads like a whole one is worse than none:
//
//   * Reversion is bounded by the snapshot. A write outside the snapshotted
//     set is DETECTED — the clauses are checked against every observed
//     effect — but cannot be rolled back, because no prior state was
//     recorded. review() reports those separately as `unrevertable` rather
//     than counting them as undone.
//   * Effects outside the filesystem — a network call, a database write, a
//     spawned daemon — are neither observed nor reversible here.

// how many bytes of a changed file are read back for clause matching
const sentinel_max_content = 200_000

pub struct Review {
pub mut:
	observed   []Effect
	violations []Violation
	reverted   bool
	// observed paths with no recorded prior state: detected, not undone
	unrevertable []string
	detail       string
}

pub fn (r &Review) clean() bool {
	return r.violations.len == 0
}

pub fn (r &Review) to_json() map[string]json2.Any {
	return {
		'observed':     json2.Any(r.observed.len)
		'violations':   json2.Any(r.violations.map(json2.Any(it.to_json())))
		'reverted':     json2.Any(r.reverted)
		'unrevertable': json2.Any(r.unrevertable.map(json2.Any(it)))
	}
}

@[heap]
pub struct Sentinel {
pub mut:
	log      &EventLog
	covenant &Covenant
	store    SnapshotStore
	reviews  int
	reverts  int
	// violations that could not be undone
	undetected_escapes int
}

pub fn new_sentinel(log &EventLog, covenant &Covenant, store SnapshotStore) &Sentinel {
	return &Sentinel{
		log:      unsafe { log }
		covenant: unsafe { covenant }
		store:    store
	}
}

// -- observation -------------------------------------------------------------

// observe is the effects that really occurred, read from the filesystem.
//
// It is derived from the recorded prior tree AND the paths the caller names,
// so a write nobody declared is still seen — that is the whole point.
pub fn (mut s Sentinel) observe(tree_before string, paths []string) []Effect {
	before := s.store.load_tree(tree_before) or { map[string]string{} }
	mut watched := []string{}
	for p, _ in before {
		watched << p
	}
	for p in paths {
		watched << os.real_path(resolve_path(p))
	}
	watched = uniq_strings(watched)
	watched.sort()

	mut effects := []Effect{}
	for path in watched {
		// the manifest records an absent file as an empty hash: its absence
		// is part of the state
		recorded := path in before
		existed := recorded && before[path] != ''
		exists := os.is_file(path)
		if !exists && existed {
			effects << Effect{
				kind:   effect_delete
				path:   path
				reason: 'observed after the call'
			}
			continue
		}
		if !exists {
			continue
		}
		raw_all := os.read_bytes(path) or { continue }
		raw := if raw_all.len > sentinel_max_content {
			raw_all[..sentinel_max_content].clone()
		} else {
			raw_all
		}
		digest := s.store.put_blob(raw)
		if existed && before[path] == digest {
			// unchanged
			continue
		}
		effects << Effect{
			kind:    effect_write
			path:    path
			content: raw.bytestr()
			reason:  'observed after the call'
		}
	}
	return effects
}

// -- the verdict -------------------------------------------------------------

// review judges a completed call by what it did, and undoes it if a clause
// was broken. `tree_before` is the snapshot taken before the call.
pub fn (mut s Sentinel) review(tool string, tree_before string, paths []string) Review {
	s.reviews++
	observed := s.observe(tree_before, paths)
	violations := s.covenant.check_effects(observed)
	mut review := Review{
		observed:   observed
		violations: violations
	}
	if violations.len == 0 {
		return review
	}

	recorded := s.store.load_tree(tree_before) or { map[string]string{} }
	mut escaped := []string{}
	for e in observed {
		if e.path != '' && e.path !in recorded {
			escaped << e.path
		}
	}
	escaped = uniq_strings(escaped)
	escaped.sort()
	review.unrevertable = escaped

	s.log.append('sentinel.violation', {
		'tool':         json2.Any(tool)
		'violations':   json2.Any(violations.map(json2.Any(it.to_json())))
		'observed':     json2.Any(observed.len)
		'unrevertable': json2.Any(review.unrevertable.map(json2.Any(it)))
	}, AppendOpts{ actor: 'kernel' })

	restored := s.store.materialise(tree_before)
	review.reverted = true
	s.reverts++
	if review.unrevertable.len > 0 {
		s.undetected_escapes++
	}
	s.log.append('sentinel.reverted', {
		'tool':         json2.Any(tool)
		'tree':         json2.Any(tree_before)
		'restored':     json2.Any(restored.restored)
		'unrevertable': json2.Any(review.unrevertable.map(json2.Any(it)))
	}, AppendOpts{ actor: 'kernel' })

	plural := if violations.len > 1 { 's' } else { '' }
	mut lines := [
		'CovenantViolation (after the fact): this call ran, broke ${violations.len} clause${plural}, and was reverted.',
	]
	for v in violations {
		lines << '  ${v.clause}: ${v.detail}'
	}
	if review.unrevertable.len > 0 {
		head := review.unrevertable[..min_int(5, review.unrevertable.len)]
		lines << '  NOT REVERTED (outside the snapshot, no prior state recorded): ${head.join(", ")}'
	}
	review.detail = lines.join('\n')
	return review
}

pub fn (s &Sentinel) stats() map[string]json2.Any {
	return {
		'reviews':      json2.Any(s.reviews)
		'reverts':      json2.Any(s.reverts)
		'unrevertable': json2.Any(s.undetected_escapes)
	}
}
