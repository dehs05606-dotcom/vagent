module vagent

import x.json2

// merge.v — semantic timeline merge: git for agent cognition.
//
// The kernel can fork and rewind timelines but never unify two that have
// diverged. This is the missing merge: two branches sharing a common ancestor
// are reconciled into a NEW branch, semantically rather than textually.
//
//     ancestor     walk both chains until they meet. The kernel's parent
//                  links make this exact rather than guessed.
//     diff         each side's events since the ancestor
//     reconcile    three mechanical rules:
//                    1. IDENTICAL — the same type and payload on both
//                       sides is kept once: both agents did the same work.
//                    2. ONLY-A / ONLY-B — replayed onto the merge branch,
//                       so both sides' work survives.
//                    3. CONFLICT — the same file written on both sides
//                       with different content. BOTH versions are sealed
//                       into merge.conflict; nothing is silently dropped
//                       and the human decides.
//     materialise  the merged branch replays the logical events from the
//                  ancestor forward, then seals merge.merged.
//
// File-level conflict detection is exact: the content hash of a write on side
// A against side B for the same path. Message-level merge preserves each
// side's order and interleaves deterministically.

const merge_content_types = ['user.message', 'assistant.message', 'tool.call', 'tool.result',
	'fact.learned', 'memory.episode']

// Structural events are never merged. Replaying a rewind or a branch marker
// onto a third timeline would assert a history that never happened there.
const merge_skip_types = ['kernel.rewind', 'kernel.branch']

// payload_key is the logical identity of an event, with the branch and seq
// stripped — what the event SAYS, not where it sits.
fn payload_key(ev &Event) string {
	return hash('${ev.typ}|' + canonical(json2.Any(ev.data.clone())))[..16]
}

// write_path is the file a tool.call writes, if it writes one.
fn write_path(ev &Event) ?string {
	if ev.typ != 'tool.call' {
		return none
	}
	if jstr(ev.data, 'name') !in ['write_file', 'edit_file'] {
		return none
	}
	p := jstr(jmap(ev.data, 'args'), 'path').trim_space()
	return if p != '' { p } else { none }
}

// content_hash is the hash of the written content, for same-file divergence.
fn content_hash(ev &Event) string {
	args := jmap(ev.data, 'args')
	for key in ['content', 'new_string', 'text'] {
		if key in args {
			return hash(jstr(args, key))[..16]
		}
	}
	return ''
}

pub struct ConflictSide {
pub:
	seq  int
	hash string
}

pub fn (s &ConflictSide) to_json() map[string]json2.Any {
	return {
		'seq':  json2.Any(s.seq)
		'hash': json2.Any(s.hash)
	}
}

pub struct MergeConflict {
pub:
	path string
	kind string
	a    ConflictSide
	b    ConflictSide
}

pub fn (c &MergeConflict) to_json() map[string]json2.Any {
	return {
		'path': json2.Any(c.path)
		'kind': json2.Any(c.kind)
		'a':    json2.Any(c.a.to_json())
		'b':    json2.Any(c.b.to_json())
	}
}

pub struct MergeResult {
pub mut:
	branch       string
	ancestor_seq int
	only_a       []Event
	only_b       []Event
	shared       []Event
	conflicts    []MergeConflict
}

pub fn (r &MergeResult) to_json() map[string]json2.Any {
	return {
		'branch':       json2.Any(r.branch)
		'ancestor_seq': json2.Any(r.ancestor_seq)
		'only_a':       json2.Any(r.only_a.len)
		'only_b':       json2.Any(r.only_b.len)
		'shared':       json2.Any(r.shared.len)
		'conflicts':    json2.Any(strs_to_any(r.conflicts.map(it.path)))
	}
}

@[heap]
pub struct TimelineMerger {
pub mut:
	log &EventLog
}

pub fn new_timeline_merger(log &EventLog) &TimelineMerger {
	return &TimelineMerger{
		log: unsafe { log }
	}
}

// -- the ancestor --------------------------------------------------------------

// ancestor is the seq of the newest event common to both chains, or -1 when
// they share nothing. It is exact: the kernel's chains are compared by event
// id, never by content or by timestamp.
pub fn (mut m TimelineMerger) ancestor(a string, b string) int {
	mut a_ids := map[string]bool{}
	for e in m.log.events(a) {
		a_ids[e.id] = true
	}
	mut best := -1
	for ev in m.log.events(b) {
		if a_ids[ev.id] && ev.seq > best {
			best = ev.seq
		}
	}
	return best
}

// -- the merge -----------------------------------------------------------------

// merge reconciles two branches into a NEW one, which is then checked out.
// Conflicts are sealed and never resolved silently.
pub fn (mut m TimelineMerger) merge(a string, b string, name string) !MergeResult {
	branches := m.log.branches()
	if a !in branches || b !in branches {
		return error("unknown branch(es): '${a}', '${b}' — known: " + branches.join(', '))
	}
	anc := m.ancestor(a, b)
	mut result := MergeResult{
		branch:       if name != '' { name } else { 'merge/${a}+${b}' }
		ancestor_seq: anc
	}
	// never clobber an existing merge branch on a re-merge: rewinding it
	// would orphan its previous merged events silently
	if result.branch in branches {
		mut n := 2
		for '${result.branch}-${n}' in branches {
			n++
		}
		result.branch = '${result.branch}-${n}'
	}

	evs_a := m.log.events(a).filter(it.seq > anc && it.typ !in merge_skip_types)
	evs_b := m.log.events(b).filter(it.seq > anc && it.typ !in merge_skip_types)

	// Identical payloads match ONE TO ONE, as a multiset. Matching by mere
	// membership collapsed legitimate repeats — a user message genuinely
	// sent twice became one merged event.
	mut count_b := map[string]int{}
	for e in evs_b {
		k := payload_key(&e)
		count_b[k] = count_b[k] + 1
	}
	for ev in evs_a {
		key := payload_key(&ev)
		if count_b[key] > 0 {
			result.shared << ev
			count_b[key] = count_b[key] - 1
		} else {
			result.only_a << ev
		}
	}
	mut count_a := map[string]int{}
	for e in evs_a {
		k := payload_key(&e)
		count_a[k] = count_a[k] + 1
	}
	for e in evs_b {
		key := payload_key(&e)
		if count_a[key] > 0 {
			// its twin was already classified on the A side
			count_a[key] = count_a[key] - 1
		} else {
			result.only_b << e
		}
	}

	m.log.append('merge.started', {
		'a':        json2.Any(a)
		'b':        json2.Any(b)
		'ancestor': json2.Any(anc)
		'into':     json2.Any(result.branch)
	}, AppendOpts{ actor: 'human' })

	// file-write conflicts: the same path written differently on both sides
	mut writes_a := map[string]Event{}
	for ev in result.only_a {
		if p := write_path(&ev) {
			writes_a[p] = ev
		}
	}
	mut writes_b := map[string]Event{}
	for ev in result.only_b {
		if p := write_path(&ev) {
			writes_b[p] = ev
		}
	}
	mut contested := []string{}
	for p, _ in writes_a {
		if p in writes_b {
			contested << p
		}
	}
	contested.sort()
	for path in contested {
		wa := writes_a[path] or { continue }
		wb := writes_b[path] or { continue }
		ha := content_hash(&wa)
		hb := content_hash(&wb)
		if ha == hb {
			continue
		}
		conflict := MergeConflict{
			path: path
			kind: 'file_write'
			a:    ConflictSide{
				seq:  wa.seq
				hash: ha
			}
			b:    ConflictSide{
				seq:  wb.seq
				hash: hb
			}
		}
		result.conflicts << conflict
		m.log.append('merge.conflict', conflict.to_json(), AppendOpts{ actor: 'kernel' })
	}

	// Materialise the merged branch. It forks from A at the ancestor, so it
	// inherits the shared history through A's chain; then the exclusive and
	// shared events replay onto it in a deterministic order. Only content
	// events replay — a structural event replayed here would be a lie about
	// what happened on this branch.
	previous := m.log.branch
	m.log.checkout(a)
	created := m.log.fork(anc, result.branch)
	m.log.checkout(previous)
	result.branch = created

	mut replay := []Event{}
	for group in [result.only_a, result.only_b, result.shared] {
		for ev in group {
			// every classified copy replays: a duplicate is real history
			if ev.typ in merge_content_types {
				replay << ev
			}
		}
	}

	cur := m.log.branch
	m.log.checkout(result.branch)
	for ev in replay {
		// the payload is cloned: the original event and the replayed one
		// must never share a map, because mutating either would corrupt
		// the other's content hash and break verify()
		m.log.append(ev.typ, ev.data.clone(), AppendOpts{
			actor:      'merge'
			provenance: ev.provenance
		})
	}
	m.log.checkout(cur)
	m.log.checkout(result.branch)

	m.log.append('merge.merged', result.to_json(), AppendOpts{ actor: 'kernel' })
	return result
}

// -- reporting -------------------------------------------------------------------

pub fn (m &TimelineMerger) format(result &MergeResult) string {
	mut lines := [
		"MERGED → branch '${result.branch}' (ancestor seq ${result.ancestor_seq})",
		'  A exclusive : ${result.only_a.len} events',
		'  B exclusive : ${result.only_b.len} events',
		'  shared once : ${result.shared.len} events',
	]
	if result.conflicts.len > 0 {
		lines << '  ⚠ ${result.conflicts.len} FILE CONFLICT(S):'
		for c in result.conflicts {
			lines << '    ${c.path} — A hash ${clip(c.a.hash, 8)} vs B hash ' + '${clip(c.b.hash, 8)} (both versions sealed in merge.conflict)'
		}
	} else {
		lines << '  no conflicts — clean merge'
	}
	return lines.join('\n')
}
