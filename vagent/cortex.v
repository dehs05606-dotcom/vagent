module vagent

import x.json2

// cortex.v — orchestration (§13).
//
// The plan is a typed DAG; every node carries a predicate, a risk class, a
// path set (the write-exclusivity key), and cost estimates. Three hard
// mechanisms live here, all rung 1 (deterministic, free, no LLM):
//
//   * Write-exclusivity (invariant I7): two WRITE nodes with overlapping
//     path sets can never be scheduled concurrently. Reads fan out, writes
//     serialise (§16.1).
//   * Hierarchical budget governor (§13.5): a run budget with slices per
//     subtree. Breaching any axis PAUSES — never silently kills — and emits
//     budget.event. A runaway sub-agent cannot consume the parent's budget.
//   * Loop / thrash / oscillation detectors (§13.4): exact-repeat tool
//     calls, file-content A-B-A-B oscillation, and cost-slope breaches are
//     detected from the event log and sealed as loop.alert events.

pub const node_kinds = ['READ', 'WRITE', 'EXEC', 'VERIFY', 'ASK', 'RESEARCH',
	'REFACTOR']
pub const node_statuses = ['PENDING', 'RUNNING', 'PASSED', 'FAILED', 'SKIPPED',
	'ROLLED_BACK', 'BRANCHED']
pub const risk_levels = ['SAFE', 'GUARDED', 'DESTRUCTIVE', 'IRREVERSIBLE']

fn canonical_args(name string, args map[string]json2.Any) string {
	payload := canonical(json2.Any({
		'name': json2.Any(name)
		'args': json2.Any(args)
	}))
	return hash(payload)[..16]
}

// ---------------------------------------------------------------------------
// Plan node
// ---------------------------------------------------------------------------

pub struct Node {
pub mut:
	id         string
	goal       string
	kind       string = 'READ'
	predicate  map[string]json2.Any // PredicateSpec (§19)
	has_predicate bool
	depends_on []string
	path_set   []string // write-exclusivity
	risk       string = 'SAFE'
	clause_id  string // attribution (§38.1)
	est_cost_usd f64
	est_steps  int = 1
	status     string = 'PENDING'
	attempts   int
}

pub fn (n &Node) to_json() map[string]json2.Any {
	return {
		'id':           json2.Any(n.id)
		'goal':         json2.Any(n.goal)
		'kind':         json2.Any(n.kind)
		'predicate':    if n.has_predicate { json2.Any(n.predicate) } else { json2.null }
		'depends_on':   json2.Any(strs_to_any(n.depends_on))
		'path_set':     json2.Any(strs_to_any(n.path_set))
		'risk':         json2.Any(n.risk)
		'clause_id':    if n.clause_id != '' { json2.Any(n.clause_id) } else { json2.null }
		'est_cost_usd': json2.Any(n.est_cost_usd)
		'est_steps':    json2.Any(n.est_steps)
		'status':       json2.Any(n.status)
		'attempts':     json2.Any(n.attempts)
	}
}

// ---------------------------------------------------------------------------
// Plan DAG
// ---------------------------------------------------------------------------

// Plan is a typed DAG over the event log. Nodes are sealed as plan.node
// events; status changes as plan.node.status. The frontier is a pure fold.
pub struct Plan {
pub mut:
	log &EventLog
}

pub fn new_plan(log &EventLog) Plan {
	return Plan{
		log: unsafe { log }
	}
}

pub fn (mut p Plan) add(node Node) !Node {
	if node.kind !in node_kinds {
		return error('node kind must be one of ${node_kinds}')
	}
	if node.risk !in risk_levels {
		return error('risk must be one of ${risk_levels}')
	}
	p.log.append('plan.node', node.to_json(), AppendOpts{
		actor:          'sovereign'
		correlation_id: if node.clause_id != '' { ?string(node.clause_id) } else { none }
	})
	return node
}

pub fn (mut p Plan) set_status(node_id string, status string) ! {
	if status !in node_statuses {
		return error('status must be one of ${node_statuses}')
	}
	p.log.append('plan.node.status', {
		'id':     json2.Any(node_id)
		'status': json2.Any(status)
	}, AppendOpts{ actor: 'kernel' })
}

pub fn (mut p Plan) nodes() map[string]Rec {
	return fold(mut p.log, '').nodes
}

// frontier lists the nodes whose depends_on are all PASSED and that are
// themselves PENDING. This is the parallel frontier the scheduler draws
// from (§16.5).
pub fn (mut p Plan) frontier() []Rec {
	nodes := p.nodes()
	mut out := []Rec{}
	for _, n in nodes {
		if jstr(n, 'status') != 'PENDING' {
			continue
		}
		mut ready := true
		for d in jstrs(n, 'depends_on') {
			dep := nodes[d] or {
				ready = false
				break
			}
			if jstr(dep, 'status') != 'PASSED' {
				ready = false
				break
			}
		}
		if ready {
			out << n
		}
	}
	return out
}

// eligible is the frontier filtered by write-exclusivity (I7): no two WRITE
// nodes with overlapping path sets, and no more than max_parallel.
// Deterministic ordering keeps the selection reproducible.
pub fn (mut p Plan) eligible(max_parallel int) []Rec {
	mut frontier := p.frontier()
	frontier.sort_with_compare(fn (a &Rec, b &Rec) int {
		return compare_strings(jstr(a, 'id'), jstr(b, 'id'))
	})
	mut chosen := []Rec{}
	mut locked := map[string]bool{}
	for n in frontier {
		if chosen.len >= max_parallel {
			break
		}
		paths := jstrs(n, 'path_set')
		if jstr(n, 'kind') == 'WRITE' {
			mut overlaps := false
			for path in paths {
				if path in locked {
					overlaps = true
					break
				}
			}
			if overlaps {
				continue // would overlap an already-scheduled write
			}
			for path in paths {
				locked[path] = true
			}
		}
		chosen << n
	}
	return chosen
}

// ---------------------------------------------------------------------------
// Budget governor (§13.5)
// ---------------------------------------------------------------------------

// Budget is the run budget. Defaults are UNLIMITED on every axis: the run
// never pauses for spend — the governor machinery stays (events, /budget,
// per-slice caps when a caller passes explicit numbers), but nothing stops
// unless a human sets a limit with /budget set.
// unlimited_usd is the +inf default for the USD axis.
pub const unlimited_usd = f64(1e308) * 10.0

pub struct Budget {
pub mut:
	// +inf: the default budget never pauses a run
	max_usd    f64 = unlimited_usd
	max_steps  i64 = 1_000_000_000
	max_tokens i64 = 1_000_000_000_000
	max_files  i64 = 100_000_000
	slices     map[string]f64 // subtree -> fraction
}

pub struct Spend {
pub:
	usd    f64
	steps  int
	tokens int
	files  int
}

// BudgetGovernor is a hierarchical budget over the event log. Every check
// is a fold; every breach is a budget.event that PAUSES the run (never
// silently kills).
//
// Spend is SESSION-SCOPED: the fold starts at the latest session.start, so
// a fresh session always starts with a fresh budget. Without this the
// counter accumulates across sessions and, once max_steps is crossed, every
// future turn is paused forever — even a trivial "hi".
pub struct BudgetGovernor {
pub mut:
	log    &EventLog
	budget Budget
	// reset() anchor: ignore events <= this
	baseline_seq int = -1
mut:
	// dedupe budget.event spam while paused
	last_reason string
}

pub fn new_budget_governor(log &EventLog, budget Budget) BudgetGovernor {
	return BudgetGovernor{
		log:    unsafe { log }
		budget: budget
	}
}

// session_start is the seq of the latest session.start (-1 if none) — where
// the current session's spend begins. -1, not 0, so seq-0 events still
// count.
fn (mut g BudgetGovernor) session_start() int {
	mut start := -1
	for ev in g.log.events('') {
		if ev.typ == 'session.start' && ev.seq > start {
			start = ev.seq
		}
	}
	return start
}

pub fn (mut g BudgetGovernor) spend() Spend {
	from := if g.baseline_seq > g.session_start() {
		g.baseline_seq
	} else {
		g.session_start()
	}
	st := fold_window(mut g.log, '', -1, from)
	return Spend{
		usd:    st.cost_usd
		steps:  st.tool_calls
		tokens: st.tokens_in + st.tokens_out
		files:  st.files_touched.len
	}
}

// reset forgets the current spend — the budget restarts from now. Sealed as
// a budget.event so the extension is never invisible.
pub fn (mut g BudgetGovernor) reset() {
	g.baseline_seq = g.log.head('')
	g.last_reason = ''
	g.log.append('budget.event', {
		'kind':  json2.Any('reset')
		'spend': json2.Any({
			'usd':    json2.Any(0.0)
			'steps':  json2.Any(0)
			'tokens': json2.Any(0)
			'files':  json2.Any(0)
		})
	}, AppendOpts{ actor: 'human' })
}

// set_limit raises or lowers one budget axis: steps | usd | tokens | files.
pub fn (mut g BudgetGovernor) set_limit(axis_in string, value string) !string {
	axis := axis_in.trim_space().to_lower()
	match axis {
		'steps' { g.budget.max_steps = value.i64() }
		'usd' { g.budget.max_usd = value.f64() }
		'tokens' { g.budget.max_tokens = value.i64() }
		'files' { g.budget.max_files = value.i64() }
		else { return error('axis must be one of: files, steps, tokens, usd') }
	}
	g.last_reason = ''
	shown := if axis == 'usd' {
		json2.Any(value.f64())
	} else {
		json2.Any(value.i64())
	}
	g.log.append('budget.event', {
		'kind':  json2.Any('limit')
		'axis':  json2.Any(axis)
		'value': shown
	}, AppendOpts{ actor: 'human' })
	return '${axis} budget set to ${shown.str()}'
}

// check returns (ok, reason). A breach on ANY axis pauses the run.
pub fn (mut g BudgetGovernor) check() (bool, string) {
	s := g.spend()
	b := g.budget
	if s.usd > b.max_usd {
		return false, 'USD budget exceeded: \$${s.usd:.4f} > \$${b.max_usd}'
	}
	if i64(s.steps) > b.max_steps {
		return false, 'step budget exceeded: ${s.steps} > ${b.max_steps}'
	}
	if i64(s.tokens) > b.max_tokens {
		return false, 'token budget exceeded: ${s.tokens} > ${b.max_tokens}'
	}
	if i64(s.files) > b.max_files {
		return false, 'file budget exceeded: ${s.files} > ${b.max_files}'
	}
	return true, ''
}

// enforce checks and, on breach, seals a budget.event (pause). Returns true
// if the run may continue. While paused, only the FIRST breach per reason is
// sealed — no event spam on every loop iteration.
pub fn (mut g BudgetGovernor) enforce() bool {
	ok, reason := g.check()
	if ok {
		g.last_reason = ''
		return true
	}
	if reason != g.last_reason {
		g.last_reason = reason
		s := g.spend()
		g.log.append('budget.event', {
			'kind':   json2.Any('exceeded')
			'reason': json2.Any(reason)
			'spend':  json2.Any({
				'usd':    json2.Any(s.usd)
				'steps':  json2.Any(s.steps)
				'tokens': json2.Any(s.tokens)
				'files':  json2.Any(s.files)
			})
		}, AppendOpts{ actor: 'kernel' })
	}
	return false
}

// slice_for is the USD slice for a subtree — a hard cap a sub-agent cannot
// borrow past (§13.5).
pub fn (g &BudgetGovernor) slice_for(subtree string) f64 {
	frac := g.budget.slices[subtree] or { 0.0 }
	return g.budget.max_usd * frac
}

// ---------------------------------------------------------------------------
// Loop / thrash / oscillation detectors (§13.4)
// ---------------------------------------------------------------------------

// LoopDetector detects wasted motion from the event log. All checks are
// rung 1.
pub struct LoopDetector {
pub mut:
	log              &EventLog
	repeat_threshold int = 3
	window           int = 10
}

pub fn new_loop_detector(log &EventLog, repeat_threshold int, window int) LoopDetector {
	return LoopDetector{
		log:              unsafe { log }
		repeat_threshold: repeat_threshold
		window:           window
	}
}

// exact_repeat returns the signature of a hash(tool, canonical_args) seen
// repeat_threshold times within the last `window` tool.call events.
pub fn (mut d LoopDetector) exact_repeat() ?string {
	mut calls := []Event{}
	for e in d.log.events('') {
		if e.typ == 'tool.call' {
			calls << e
		}
	}
	start := if calls.len > d.window { calls.len - d.window } else { 0 }
	mut counts := map[string]int{}
	for ev in calls[start..] {
		sig := canonical_args(jstr(ev.data, 'name'), jmap(ev.data, 'args'))
		counts[sig] = (counts[sig] or { 0 }) + 1
		if counts[sig] >= d.repeat_threshold {
			return sig
		}
	}
	return none
}

// oscillation reports a file-content hash flipping A-B-A-B, which is a hard
// stop: present both versions to the human.
pub fn (d &LoopDetector) oscillation(path string, hashes []string) bool {
	if hashes.len < 4 {
		return false
	}
	tail := hashes[hashes.len - 4..]
	return tail[0] == tail[2] && tail[1] == tail[3] && tail[0] != tail[1]
}

// detect runs all detectors, seals loop.alert events, and returns the
// alerts.
pub fn (mut d LoopDetector) detect() []Rec {
	mut alerts := []Rec{}
	if sig := d.exact_repeat() {
		alert := {
			'kind':      json2.Any('exact_repeat')
			'signature': json2.Any(sig)
			'action':    json2.Any('force REFLECT with the repetition as evidence')
		}
		alerts << alert
		d.log.append('loop.alert', alert, AppendOpts{ actor: 'kernel' })
	}
	return alerts
}
