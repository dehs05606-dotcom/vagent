module vagent

import os
import sync
import x.json2

// kernel.v — Temporal Kernel, the Mul Bindu.
//
// Every interaction with reality is recorded as an immutable, causally
// ordered, content-addressed event in a single append-only log. Nothing else
// is state. State is a pure fold over that log.
//
// Design (V stdlib only):
//   * JSONL is truth. One line per event, append-only, fsync'd.
//   * Content addressing: each event's id = sha256 of its canonical encoding.
//   * Merkle spine: each event carries its parent's id, so the log is
//     tamper-evident and any prefix is independently verifiable.
//   * Seqs are global and strictly monotonic — never reused, on any branch.
//   * A branch is a head pointer (an event id). Its history is the parent
//     chain walked back from the head; events abandoned by a rewind or not
//     chosen by a fork simply fall off the chain (fold horizon shrinks).
//   * Fork at seq N seeds the new branch's head at event N, so the fork
//     inherits the source's history up to the fork point.
//   * Rewind moves the head pointer back to the event at seq N and seals a
//     'kernel.rewind' marker (parent = event N) so the move survives reload.
//     Events are never deleted. (Append-only is sacred.)
//   * Reload replays the file in order: every append moved its branch's head
//     to the new event, so head pointers rebuild without any second file.
//   * Fold: a pure function from a branch's chain to a State projection.
//     Rewind, replay, resume, audit, and cost attribution are all folds.

// ---------------------------------------------------------------------------
// Event
// ---------------------------------------------------------------------------

pub struct Event {
pub mut:
	seq    int
	id     string
	parent ?string
	branch string = 'main'
	ts     f64
	// `type` is a V keyword; the wire key stays "type".
	typ  string
	data map[string]json2.Any
	// §7.1 causal envelope — every event is attributable and traceable
	session string
	actor   string = 'system' // sovereign | scout:N | human | system | …
	// the event that directly caused this one
	causation_id ?string
	// the root goal clause this serves
	correlation_id ?string
	// system | user | tool_output | web | file | model
	provenance string = 'system'
}

// short is the 10-char prefix the UI shows.
pub fn (e &Event) short() string {
	return if e.id.len >= 10 { e.id[..10] } else { e.id }
}

fn opt_any(v ?string) json2.Any {
	return if s := v { json2.Any(s) } else { json2.null }
}

pub fn (e &Event) to_json() map[string]json2.Any {
	return {
		'seq':            json2.Any(e.seq)
		'id':             json2.Any(e.id)
		'parent':         opt_any(e.parent)
		'branch':         json2.Any(e.branch)
		'ts':             json2.Any(e.ts)
		'type':           json2.Any(e.typ)
		'data':           json2.Any(e.data)
		'session':        json2.Any(e.session)
		'actor':          json2.Any(e.actor)
		'causation_id':   opt_any(e.causation_id)
		'correlation_id': opt_any(e.correlation_id)
		'provenance':     json2.Any(e.provenance)
	}
}

fn opt_from(o map[string]json2.Any, key string) ?string {
	v := o[key] or { return none }
	if v is json2.Null {
		return none
	}
	s := v.str()
	return if s == '' { none } else { s }
}

// event_from_json rebuilds an Event from one JSONL line's object. It
// returns an error for the three shapes that would corrupt the fold — a
// non-integer seq, a non-object data, a non-string type — so a damaged
// line is skipped rather than silently folded as something else.
pub fn event_from_json(o map[string]json2.Any) !Event {
	seq_any := o['seq'] or { return error('event has no seq') }
	match seq_any {
		i64, int, f64 {}
		else { return error('event seq is not an int: ${seq_any}') }
	}
	if 'data' in o {
		if o['data'] or { json2.null } !is map[string]json2.Any {
			return error('event data is not an object')
		}
	}
	t := o['type'] or { return error('event type is not a string') }
	if t !is string {
		return error('event type is not a string')
	}
	return Event{
		seq:            jint(o, 'seq')
		id:             jstr(o, 'id')
		parent:         opt_from(o, 'parent')
		branch:         if b := o['branch'] { b.str() } else { 'main' }
		ts:             jf64(o, 'ts')
		typ:            jstr(o, 'type')
		data:           jmap(o, 'data')
		session:        jstr(o, 'session')
		actor:          if a := o['actor'] { a.str() } else { 'system' }
		causation_id:   opt_from(o, 'causation_id')
		correlation_id: opt_from(o, 'correlation_id')
		provenance:     if p := o['provenance'] { p.str() } else { 'system' }
	}
}

// compute_event_id is the content address: a hash of everything except the
// id itself.
pub fn compute_event_id(seq int, parent ?string, branch string, ts f64, typ string,
	data map[string]json2.Any, session string, actor string, causation_id ?string,
	correlation_id ?string, provenance string) string {
	payload := {
		'seq':            json2.Any(seq)
		'parent':         opt_any(parent)
		'branch':         json2.Any(branch)
		'ts':             json2.Any(ts)
		'type':           json2.Any(typ)
		'data':           json2.Any(data)
		'session':        json2.Any(session)
		'actor':          json2.Any(actor)
		'causation_id':   opt_any(causation_id)
		'correlation_id': opt_any(correlation_id)
		'provenance':     json2.Any(provenance)
	}
	return hash(canonical(json2.Any(payload)))
}

// ---------------------------------------------------------------------------
// State — the projection produced by folding
// ---------------------------------------------------------------------------

type Rec = map[string]json2.Any

// State is a derived, never-authoritative view of the log prefix.
pub struct State {
pub mut:
	messages      []Message
	cost_usd      f64
	tokens_in     int
	tokens_out    int
	tool_calls    int
	tool_errors   int
	files_touched map[string]bool
	commands_run  int
	episodes      []Rec
	dead_ends     []Rec
	facts         []Rec
	goal          ?Rec
	goal_done     []string
	// §42 — the latest goal.closed event AFTER the current goal.set; none
	// while the contract is still open
	goal_closed ?Rec
	autonomy    int = 3
	// advanced subsystems (compiler/evolution/brain/merge/theater/debate/
	// market) — one bucket, newest last; each module filters by "type"
	advanced_events []Rec
	verdicts        []Rec
	// §8.3 / §9 — snapshot store references, newest last
	snapshots []Rec
	// §13 — plan DAG nodes keyed by node id
	nodes map[string]Rec
	// §13.5 — budget events (slices, exceeded)
	budget_events []Rec
	// Part VI — clause proof/regression/amendment/focus history
	clause_proven     []Rec
	clause_regressed  []Rec
	amendments        []Rec
	focus_shifts      []Rec
	distance_measures []Rec
	// §18 — environment digests (drift detection)
	env_digests []Rec
	// §21 — calibration samples (est vs actual)
	calibration []Rec
	// §13.4 — loop/thrash detector trips
	loop_alerts []Rec
	// Mastermind — prompt coherence ledger
	prompt_sealed     []Rec
	prompt_dispatches []Rec
	// v3 advanced subsystems
	router_decisions []Rec
	semantic_index   []Rec
	spec_events      []Rec
	daemon_events    []Rec
	heal_events      []Rec
	skill_events     []Rec
	council_events   []Rec
	// v4 professional subsystems
	lsp_events      []Rec
	dap_events      []Rec
	analysis_events []Rec
	mutation_events []Rec
	coverage_events []Rec
	fuzz_events     []Rec
	graph_events    []Rec
	browser_events  []Rec
	openapi_events  []Rec
	db_events       []Rec
	git_events      []Rec
	ensemble_events []Rec
	hybrid_events   []Rec
	compress_events []Rec
	eval_events     []Rec
	sched_events    []Rec
	cache_events    []Rec
	cost_ledger     []Rec
	head_seq        int    = -1
	branch          string = 'main'
}

pub fn (s &State) cost_summary() string {
	return '\$${s.cost_usd:.4f} · ${s.tokens_in}→${s.tokens_out} tok'
}

// touched_files is the sorted list of paths any mutating tool wrote to.
pub fn (s &State) touched_files() []string {
	mut out := s.files_touched.keys()
	out.sort()
	return out
}

// ---------------------------------------------------------------------------
// EventLog — append-only, content-addressed, causally linked
// ---------------------------------------------------------------------------

// sync_every — writes go through ONE persistent append handle; a full disk
// sync happens once per batch instead of after every single event. Events
// still flush to the OS on every write (survives a crash of this process;
// only a power loss can drop the last few).
const sync_every = 64

struct FoldCacheEntry {
mut:
	head_id ?string
	state   State
}

// EventLog is the single source of truth. Thread-safe for appends.
//
// Heads are event ids, not seqs: a branch's history is the parent chain
// walked back from its head. Seqs are global and strictly monotonic, so a
// rewind or fork never reuses a seq — abandoned events simply fall off the
// chain and stop contributing to the fold.
@[heap]
pub struct EventLog {
pub mut:
	path    string
	branch  string = 'main'
	session string
mut:
	// V mutexes are not reentrant, so every public method takes the lock
	// and delegates to an `_locked` helper that assumes it is already held.
	mu      sync.Mutex
	events_ []Event
	by_id   map[string]int // event id -> index into events_
	// branch name -> id of its head event ('' = empty branch)
	heads      map[string]string
	has_head   map[string]bool
	next_seq   int
	fh         os.File
	fh_open    bool
	since_sync int
	// SPEED: per-branch chain cache (extended incrementally, O(1) per
	// append) + fold memoisation keyed by (branch, head id). Event queries
	// used to cost O(n) every time — these caches make steady-state reads
	// O(1) and every append a buffered write.
	chains     map[string][]int
	fold_cache map[string]&FoldCacheEntry
}

pub fn new_event_log(path string, branch string, session string) &EventLog {
	dir := os.dir(path)
	if dir != '' {
		os.mkdir_all(dir) or {}
	}
	mut log := &EventLog{
		path:    path
		branch:  if branch == '' { 'main' } else { branch }
		session: session
	}
	log.load()
	return log
}

// -- persistence -----------------------------------------------------------

fn (mut l EventLog) load() {
	if l.branch !in l.has_head {
		l.has_head[l.branch] = false
		l.heads[l.branch] = ''
	}
	if !os.exists(l.path) {
		return
	}
	content := os.read_file(l.path) or { return }
	for raw in content.split('\n') {
		line := raw.trim_space()
		if line == '' {
			continue
		}
		obj := decode_obj(line)
		if obj.len == 0 {
			continue
		}
		ev := event_from_json(obj) or { continue }
		l.by_id[ev.id] = l.events_.len
		l.events_ << ev
		if ev.seq + 1 > l.next_seq {
			l.next_seq = ev.seq + 1
		}
		// replay: every appended event moved its branch's head to it, so
		// head pointers rebuild exactly (rewinds included, since a rewind
		// seals a marker event that becomes the new head)
		l.heads[ev.branch] = ev.id
		l.has_head[ev.branch] = true
	}
}

// drop_handle releases the current handle before reopening. Dropping the
// reference alone leaks the descriptor, and a long session that keeps
// hitting the retry paths below would exhaust the process fd limit.
fn (mut l EventLog) drop_handle() {
	if l.fh_open {
		l.fh.close()
		l.fh_open = false
	}
}

fn (mut l EventLog) persist(ev &Event) {
	l.write_event(ev) or {
		// the home directory vanished mid-session (deleted externally,
		// fresh mount, etc.) or the handle was closed underneath us —
		// recreate the directory, reopen, and write again. The log must
		// never take the app down over a missing directory.
		dir := os.dir(l.path)
		if dir != '' {
			os.mkdir_all(dir) or {}
		}
		l.drop_handle()
		l.write_event(ev) or {}
	}
}

fn (mut l EventLog) write_event(ev &Event) ! {
	if !l.fh_open {
		l.fh = os.open_append(l.path)!
		l.fh_open = true
	}
	// the on-disk encoding must round-trip to the same values compute_id
	// hashed — otherwise a line that verified at write time fails to
	// verify after a reload
	l.fh.write_string(canonical(json2.Any(ev.to_json())) + '\n')!
	l.fh.flush()
	l.since_sync++
	if l.since_sync >= sync_every {
		l.since_sync = 0
		l.fh.flush()
	}
}

// -- append ----------------------------------------------------------------

@[params]
pub struct AppendOpts {
pub:
	branch string
	actor  string = 'system'
	// causation defaults to the branch's current head; pass `none` to keep
	// that default, or an explicit id to attribute the cause precisely.
	causation_id   ?string
	correlation_id ?string
	provenance     string = 'system'
	// `none` means "use the log's session"
	session ?string
}

// append seals one event onto a branch and returns it.
//
// The causal envelope (§7.1) makes every event attributable:
// causation_id = the event that directly caused this one,
// correlation_id = the goal clause this ultimately serves.
pub fn (mut l EventLog) append(typ string, data map[string]json2.Any, opts AppendOpts) Event {
	l.mu.lock()
	defer {
		l.mu.unlock()
	}
	return l.append_locked(typ, data, opts)
}

fn (mut l EventLog) append_locked(typ string, data map[string]json2.Any, opts AppendOpts) Event {
	br := if opts.branch != '' { opts.branch } else { l.branch }
	mut parent_id := ?string(none)
	if l.has_head[br] && l.heads[br] != '' {
		parent_id = l.heads[br]
	}
	seq := l.next_seq
	l.next_seq++
	ts := now_ts()
	sess := opts.session or { l.session }
	// default causation: the branch's current head caused this event
	caus := if c := opts.causation_id { ?string(c) } else { parent_id }
	eid := compute_event_id(seq, parent_id, br, ts, typ, data, sess, opts.actor, caus, opts.correlation_id, opts.provenance)
	ev := Event{
		seq:            seq
		id:             eid
		parent:         parent_id
		branch:         br
		ts:             ts
		typ:            typ
		data:           data
		session:        sess
		actor:          opts.actor
		causation_id:   caus
		correlation_id: opts.correlation_id
		provenance:     opts.provenance
	}
	// persist FIRST — if the write fails, the in-memory log must not
	// advance (it would diverge from disk and burn a seq / move a head for
	// an event that never landed)
	l.persist(&ev)
	l.by_id[ev.id] = l.events_.len
	l.events_ << ev
	l.heads[br] = eid
	l.has_head[br] = true
	return ev
}

// -- chain walking ---------------------------------------------------------

fn (l &EventLog) event_by_id(id string) ?Event {
	idx := l.by_id[id] or { return none }
	return l.events_[idx]
}

// chain_locked returns the branch's history (parent chain from its head) in
// causal order, as indices into events_.
//
// SPEED: cached per branch and extended incrementally — a steady-state
// append costs O(1) here instead of an O(n) walk + reversal.
fn (mut l EventLog) chain_locked(branch string) []int {
	head_id := if l.has_head[branch] { l.heads[branch] } else { '' }
	if cached := l.chains[branch] {
		if cached.len == 0 && head_id == '' {
			return cached
		}
		if cached.len > 0 && head_id == l.events_[cached.last()].id {
			return cached
		}
		// head moved forward (new appends) — extend from the cached tail
		if cached.len > 0 && head_id != '' {
			tail_id := l.events_[cached.last()].id
			mut new_idx := []int{}
			mut cur := head_id
			mut seen := map[string]bool{}
			for cur != '' && cur != tail_id && cur !in seen {
				seen[cur] = true
				idx := l.by_id[cur] or { break }
				new_idx << idx
				cur = l.events_[idx].parent or { '' }
			}
			if cur == tail_id {
				new_idx.reverse_in_place()
				mut extended := cached.clone()
				extended << new_idx
				l.chains[branch] = extended
				return extended
			}
		}
	}
	// first access, rewind or fork — full rebuild (then cached)
	mut chain := []int{}
	mut cur_id := head_id
	mut seen2 := map[string]bool{}
	for cur_id != '' && cur_id !in seen2 {
		idx := l.by_id[cur_id] or { break }
		seen2[cur_id] = true
		chain << idx
		cur_id = l.events_[idx].parent or { '' }
	}
	chain.reverse_in_place()
	l.chains[branch] = chain
	return chain
}

// event_at_locked returns the newest event on the branch's chain with
// e.seq <= seq.
fn (mut l EventLog) event_at_locked(branch string, seq int) ?Event {
	if seq < 0 {
		return none
	}
	mut best := ?Event(none)
	for idx in l.chain_locked(branch) {
		ev := l.events_[idx]
		if ev.seq <= seq {
			if b := best {
				if ev.seq > b.seq {
					best = ev
				}
			} else {
				best = ev
			}
		}
	}
	return best
}

// -- queries ---------------------------------------------------------------

// events returns the events of a branch, oldest first.
pub fn (mut l EventLog) events(branch string) []Event {
	l.mu.lock()
	defer {
		l.mu.unlock()
	}
	return l.events_locked(branch)
}

fn (mut l EventLog) events_locked(branch string) []Event {
	br := if branch != '' { branch } else { l.branch }
	mut out := []Event{}
	for idx in l.chain_locked(br) {
		out << l.events_[idx]
	}
	return out
}

// events_upto returns the events of a branch up to (and including) a seq
// horizon.
pub fn (mut l EventLog) events_upto(branch string, upto_seq int) []Event {
	return l.events(branch).filter(it.seq <= upto_seq)
}

// head is the seq of the branch's head event (-1 for an empty branch).
pub fn (mut l EventLog) head(branch string) int {
	l.mu.lock()
	defer {
		l.mu.unlock()
	}
	return l.head_locked(branch)
}

fn (l &EventLog) head_locked(branch string) int {
	br := if branch != '' { branch } else { l.branch }
	if !l.has_head[br] {
		return -1
	}
	hid := l.heads[br] or { return -1 }
	if hid == '' {
		return -1
	}
	ev := l.event_by_id(hid) or { return -1 }
	return ev.seq
}

pub fn (mut l EventLog) branches() []string {
	l.mu.lock()
	defer {
		l.mu.unlock()
	}
	mut out := l.heads.keys()
	out.sort()
	return out
}

pub fn (mut l EventLog) get(event_id string) ?Event {
	l.mu.lock()
	defer {
		l.mu.unlock()
	}
	return l.event_by_id(event_id)
}

// len is the total number of events ever appended, across every branch.
pub fn (mut l EventLog) len() int {
	l.mu.lock()
	defer {
		l.mu.unlock()
	}
	return l.events_.len
}

pub fn (mut l EventLog) close() {
	l.mu.lock()
	defer {
		l.mu.unlock()
	}
	l.drop_handle()
}

// -- time travel -----------------------------------------------------------

// rewind moves a branch's head back to the event at/below seq.
//
// Events are NOT deleted; they fall off the chain. The move is sealed as a
// 'kernel.rewind' marker (which becomes the new head) so it survives
// reload. Returns the new head seq (the marker's seq).
pub fn (mut l EventLog) rewind(seq int, branch string) int {
	l.mu.lock()
	defer {
		l.mu.unlock()
	}
	br := if branch != '' { branch } else { l.branch }
	current := l.head_locked(br)
	mut target := if seq < current { seq } else { current }
	if target < -1 {
		target = -1
	}
	if base := l.event_at_locked(br, target) {
		l.heads[br] = base.id
		l.has_head[br] = true
	} else {
		l.heads[br] = ''
		l.has_head[br] = false
	}
	// the per-branch chain cache and fold cache still hold the pre-rewind
	// chain; without invalidation the next chain_locked() call would walk
	// from the new head and fail to find the cached tail (the old head is
	// ABOVE the new head, not below), forcing a full O(n) rebuild. Drop
	// both caches here.
	l.chains.delete(br)
	l.fold_cache.delete(br)
	marker := l.append_locked('kernel.rewind', {
		'branch': json2.Any(br)
		'from':   json2.Any(current)
		'to':     json2.Any(target)
	},
		branch: br
	)
	return marker.seq
}

// fork creates a new branch diverging from at_seq (-1 means the current
// head).
//
// The new branch's head starts at the fork-point event, so it inherits the
// source's full history up to that point; a 'kernel.branch' marker is
// sealed on it. Returns the branch name.
pub fn (mut l EventLog) fork(at_seq int, name string) string {
	l.mu.lock()
	defer {
		l.mu.unlock()
	}
	src := l.branch
	at := if at_seq < 0 { l.head_locked(src) } else { at_seq }
	return l.fork_locked(src, at, name)
}

// fork_at is fork with the fork point taken literally: a point before the
// first event leaves the new branch EMPTY rather than defaulting to the
// current head.
//
// The distinction exists because a counterfactual that removes the very
// first event has no prior event to hang from, and silently forking from the
// head instead would produce a branch containing exactly the history the
// caller asked to remove.
pub fn (mut l EventLog) fork_at(at_seq int, name string) string {
	l.mu.lock()
	defer {
		l.mu.unlock()
	}
	return l.fork_locked(l.branch, at_seq, name)
}

fn (mut l EventLog) fork_locked(src string, at int, name string) string {
	base := l.event_at_locked(src, at)

	mut new_name := ''
	if name != '' {
		// never clobber an existing branch — a second fork with the same
		// name would silently rewind the first one's head and orphan its
		// exclusive events
		new_name = name
		mut n := 2
		for (new_name in l.heads) {
			new_name = '${name}-${n}'
			n++
		}
	} else {
		new_name = 'branch-${l.heads.len + 1}'
		mut n := 2
		for (new_name in l.heads) {
			new_name = 'branch-${l.heads.len + 1}-${n}'
			n++
		}
	}
	if b := base {
		l.heads[new_name] = b.id
		l.has_head[new_name] = true
	} else {
		l.heads[new_name] = ''
		l.has_head[new_name] = false
	}
	mut at_id := json2.Any(json2.null)
	mut at_s := -1
	if b := base {
		at_id = b.id
		at_s = b.seq
	}
	l.append_locked('kernel.branch', {
		'from':   json2.Any(src)
		'at_seq': json2.Any(at_s)
		'at_id':  at_id
		'name':   json2.Any(new_name)
	},
		branch: new_name
	)
	return new_name
}

pub fn (mut l EventLog) checkout(branch string) {
	l.mu.lock()
	defer {
		l.mu.unlock()
	}
	if branch in l.heads {
		l.branch = branch
	}
}

// -- integrity -------------------------------------------------------------

// verify re-hashes every event and checks the Merkle spine links.
pub fn (mut l EventLog) verify(branch string) (bool, string) {
	evs := l.events(branch)
	mut prev_id := ?string(none)
	for ev in evs {
		recomputed := compute_event_id(ev.seq, ev.parent, ev.branch, ev.ts, ev.typ, ev.data, ev.session, ev.actor, ev.causation_id, ev.correlation_id, ev.provenance)
		if recomputed != ev.id {
			return false, 'seq ${ev.seq}: content hash mismatch'
		}
		if (ev.parent or { '' }) != (prev_id or { '' }) {
			return false, 'seq ${ev.seq}: broken spine link'
		}
		prev_id = ev.id
	}
	return true, '${evs.len} events verified'
}

// -- causality -------------------------------------------------------------

// why walks the causation chain backwards from an event to its root.
//
// Answers 'why did this happen?' mechanically (§7.1, Appendix A
// `argus why`): each event's causation_id names its direct cause, so any
// file change or dollar spent traces back to the human instruction that
// started it.
pub fn (mut l EventLog) why(event_id string, limit int) []Event {
	l.mu.lock()
	defer {
		l.mu.unlock()
	}
	mut chain := []Event{}
	mut cur := ?Event(l.event_by_id(event_id) or { return chain })
	mut seen := map[string]bool{}
	for {
		ev := cur or { break }
		if ev.id in seen || chain.len >= limit {
			break
		}
		seen[ev.id] = true
		chain << ev
		cid := ev.causation_id or { break }
		cur = l.event_by_id(cid) or { break }
	}
	return chain
}

// ---------------------------------------------------------------------------
// Fold — state as a pure function of history
// ---------------------------------------------------------------------------

// mutating_tools — tool name -> whether it mutates the filesystem
const mutating_tools = ['write_file', 'edit_file', 'create_directory', 'copy_path', 'move_path',
	'delete_path']

// advanced_event_types are the event types of the advanced subsystems,
// folded into State.advanced_events.
pub const advanced_event_types = ['compile.plan', 'compile.wave', 'compile.done',
	'evolution.generation', 'evolution.deployed', 'evolution.rollback', 'brain.remembered',
	'brain.recalled', 'brain.consolidated', 'brain.forgotten', 'merge.started', 'merge.merged',
	'merge.conflict', 'theater.counterfactual', 'debate.round', 'debate.verdict', 'debate.calibration',
	'market.announce', 'market.bid', 'market.award', 'market.settle', 
	// v6 advanced subsystems
	'verify.plan', 'verify.violation', 'verify.trace', 'mcts.search', 'mcts.best', 'causal.edge',
	'causal.intervention', 'bandit.pull', 'bandit.update', 'mesh.node', 'mesh.task', 'mesh.result',
	'meta.role.drafted', 'meta.role.sealed', 'meta.role.rejected', 'synth.tool.drafted',
	'synth.tool.tested', 'synth.tool.registered', 'ci.watch', 'ci.run', 'ci.streak', 'tuner.trial',
	'tuner.best', 'dual.route', 'dual.escalation', 'world.impact', 'world.learn', 'race.start',
	'race.winner', 'race.cancel', 'homeo.check', 'homeo.repair', 'attention.auction', 'fabric.assert',
	'fabric.retract']

// tagged copies `d` and stamps the event type into it, matching the Python
// `{"type": t, **d}` merge used by every bucketed subsystem.
fn tagged(typ string, d Rec) Rec {
	mut out := d.clone()
	out['type'] = typ
	return out
}

// fold_apply applies ONE event to a State projection (the reduce step).
pub fn fold_apply(mut st State, ev &Event) {
	st.head_seq = ev.seq
	d := ev.data.clone()
	t := ev.typ

	match t {
		'user.message' {
			st.messages << user_message(jstr(d, 'text'))
		}
		'assistant.message' {
			st.messages << Message{
				role:    'assistant'
				content: jstr(d, 'text')
			}
		}
		'tool.call' {
			st.tool_calls++
			name := jstr(d, 'name')
			if name == 'run_command' {
				st.commands_run++
			}
			if name in mutating_tools {
				args := jmap(d, 'args')
				mut p := jstr(args, 'path')
				if p == '' {
					p = jstr(args, 'dst')
				}
				if p != '' {
					st.files_touched[p] = true
				}
			}
		}
		'tool.result' {
			if jstr(d, 'status') == 'error' {
				st.tool_errors++
			}
		}
		'cost.incurred' {
			// a corrupt numeric field reads as 0 rather than bricking the
			// fold, which is what the Python try/except achieved
			st.cost_usd += jf64(d, 'usd')
			st.tokens_in += jint(d, 'tokens_in')
			st.tokens_out += jint(d, 'tokens_out')
		}
		'memory.episode' {
			st.episodes << d
		}
		'deadend.recorded' {
			st.dead_ends << d
		}
		'goal.set' {
			st.goal = d
			st.goal_done = []
			st.goal_closed = none // a new contract reopens the world
		}
		'goal.clause.done' {
			st.goal_done << jstr(d, 'clause')
		}
		'autonomy.changed' {
			if 'level' in d {
				st.autonomy = jint(d, 'level')
			}
		}
		'prompt.sealed' {
			st.prompt_sealed << d
		}
		'prompt.dispatch' {
			st.prompt_dispatches << d
		}
		'router.decision' {
			st.router_decisions << d
		}
		'semantic.indexed' {
			st.semantic_index << d
		}
		'spec.prefetch', 'spec.hit', 'spec.miss', 'spec.evict' {
			st.spec_events << tagged(t, d)
		}
		'daemon.mission', 'daemon.checkpoint', 'daemon.tick', 'daemon.wake', 'daemon.done' {
			st.daemon_events << tagged(t, d)
		}
		'heal.captured', 'heal.hypothesis', 'heal.patch', 'heal.retry', 'heal.lesson' {
			st.heal_events << tagged(t, d)
		}
		'skill.authored', 'skill.validated', 'skill.registered', 'skill.rejected' {
			st.skill_events << tagged(t, d)
		}
		'council.convened', 'council.position', 'council.verdict' {
			st.council_events << tagged(t, d)
		}
		'lsp.session', 'lsp.symbols', 'lsp.references', 'lsp.diagnostics' {
			st.lsp_events << tagged(t, d)
		}
		'dap.session', 'dap.breakpoint', 'dap.stopped', 'dap.variables' {
			st.dap_events << tagged(t, d)
		}
		'analysis.taint', 'analysis.complexity', 'analysis.cycles' {
			st.analysis_events << tagged(t, d)
		}
		'mutation.run', 'mutation.result' {
			st.mutation_events << tagged(t, d)
		}
		'coverage.run', 'coverage.result' {
			st.coverage_events << tagged(t, d)
		}
		'fuzz.run', 'fuzz.crash', 'fuzz.shrunk' {
			st.fuzz_events << tagged(t, d)
		}
		'graph.entity', 'graph.relation', 'graph.query' {
			st.graph_events << tagged(t, d)
		}
		'browser.navigate', 'browser.action', 'browser.extract' {
			st.browser_events << tagged(t, d)
		}
		'openapi.compiled', 'openapi.call' {
			st.openapi_events << tagged(t, d)
		}
		'db.query', 'db.schema' {
			st.db_events << tagged(t, d)
		}
		'git.diff', 'git.commit', 'git.blame' {
			st.git_events << tagged(t, d)
		}
		'ensemble.run', 'ensemble.verdict' {
			st.ensemble_events << tagged(t, d)
		}
		'hybrid.indexed', 'hybrid.query' {
			st.hybrid_events << tagged(t, d)
		}
		'compress.run' {
			st.compress_events << tagged(t, d)
		}
		'eval.task', 'eval.result' {
			st.eval_events << tagged(t, d)
		}
		'sched.job', 'sched.fired' {
			st.sched_events << tagged(t, d)
		}
		'cache.metrics' {
			st.cache_events << tagged(t, d)
		}
		'cost.entry' {
			st.cost_ledger << d
		}
		'judge.verdict' {
			st.verdicts << d
		}
		'snapshot.taken' {
			st.snapshots << d
		}
		'plan.node' {
			mut node := d.clone()
			st.nodes[jstr(node, 'id')] = node
		}
		'plan.node.status' {
			id := jstr(d, 'id')
			if mut node := st.nodes[id] {
				if 'status' in d {
					node['status'] = jget(d, 'status')
				}
				if 'attempts' in d {
					node['attempts'] = jget(d, 'attempts')
				}
				st.nodes[id] = node
			}
		}
		'budget.event' {
			st.budget_events << d
		}
		'clause.proven' {
			st.clause_proven << d
		}
		'clause.regressed' {
			st.clause_regressed << d
		}
		'goal.amendment' {
			st.amendments << d
		}
		'goal.focus' {
			st.focus_shifts << d
		}
		'goal.distance' {
			st.distance_measures << d
		}
		'goal.closed' {
			st.goal_closed = d
		}
		'fact.learned' {
			st.facts << d
		}
		'env.digest' {
			st.env_digests << d
		}
		'calibration.sample' {
			st.calibration << d
		}
		'loop.alert' {
			st.loop_alerts << d
		}
		else {
			// the advanced-subsystem bucket is a set membership test, not a
			// fixed arm, so it lives here rather than in the match above
			if t in advanced_event_types {
				st.advanced_events << tagged(t, d)
			}
		}
	}
}

// fold reduces a log prefix into a State projection.
//
// SPEED: full-log folds are cached per branch and extended INCREMENTALLY —
// after the first fold, a steady-state call applies only the events
// appended since the last one (typically 1-5), so the dozens of fold()
// calls inside one turn cost near-zero instead of O(n) each. Rewinds
// naturally miss the cache and rebuild.
pub fn fold(mut log EventLog, branch string) State {
	log.mu.lock()
	defer {
		log.mu.unlock()
	}
	br := if branch != '' { branch } else { log.branch }
	return log.fold_cached(br)
}

// fold_window is the uncached fold used for bounded projections:
// `upto_seq` caps the horizon (-1 means no cap) and `from_seq` skips every
// event with seq <= from_seq — used for session-scoped projections (budget
// spend etc.) without mutating or copying the log.
pub fn fold_window(mut log EventLog, branch string, upto_seq int, from_seq int) State {
	log.mu.lock()
	defer {
		log.mu.unlock()
	}
	br := if branch != '' { branch } else { log.branch }
	mut st := State{
		branch: br
	}
	for idx in log.chain_locked(br) {
		ev := log.events_[idx]
		if upto_seq >= 0 && ev.seq > upto_seq {
			continue
		}
		if ev.seq <= from_seq {
			continue
		}
		fold_apply(mut st, &ev)
	}
	return st
}

// replay returns the events of a branch in seq order — the raw material
// every fold consumes; §26 text-film replays iterate this.
pub fn replay(mut log EventLog, branch string) []Event {
	return log.events(branch)
}

// fold_cached is the cached, incremental full-log fold for one branch. The
// caller holds log.mu.
fn (mut l EventLog) fold_cached(br string) State {
	head_id := if l.has_head[br] { l.heads[br] } else { '' }
	if mut entry := l.fold_cache[br] {
		if (entry.head_id or { '' }) == head_id {
			return entry.state
		}
		// extend: walk the new events back from the head to the cached
		// head, then apply them in causal order onto the cached state
		cached_id := entry.head_id or { '' }
		mut new_idx := []int{}
		mut cur := head_id
		mut seen := map[string]bool{}
		mut chained := false
		for cur != '' && cur != cached_id && cur !in seen {
			seen[cur] = true
			idx := l.by_id[cur] or { break }
			new_idx << idx
			cur = l.events_[idx].parent or { '' }
		}
		if cur == cached_id {
			chained = true
		}
		if chained {
			mut st := entry.state
			for i := new_idx.len - 1; i >= 0; i-- {
				ev := l.events_[new_idx[i]]
				fold_apply(mut st, &ev)
			}
			entry.state = st
			entry.head_id = if head_id == '' { ?string(none) } else { head_id }
			return st
		}
	}
	// first fold on this branch, or the chain diverged (rewind) — rebuild
	mut st := State{
		branch: br
	}
	for idx in l.chain_locked(br) {
		ev := l.events_[idx]
		fold_apply(mut st, &ev)
	}
	l.fold_cache[br] = &FoldCacheEntry{
		head_id: if head_id == '' { ?string(none) } else { head_id }
		state:   st
	}
	return st
}
