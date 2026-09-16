module vagent

import x.json2

// market.v — the task market: specialists bid, the auctioneer awards.
//
// The crew assigns work by role; the market assigns work by ECONOMICS. This
// is the contract-net protocol, the real thing:
//
//     announce    tasks hit the board and every eligible role examines each
//     bid         each role prices the task as capability × trust ÷ pace:
//                   capability  the fit between the role's tool whitelist
//                               and what the task text actually names —
//                               write? run? research the web?
//                   trust       the role's success rate over its own
//                               settled auctions, starting neutral
//                   pace        a role-specific prior on how much work a
//                               typical task costs it
//     award       the highest bid takes the contract, ONE role per task;
//                 ties break by trust and then by name, so the outcome is
//                 reproducible
//     settle      execution lands, trust moves exponentially from the
//                 OUTCOME, and the gap between the bid and the actual cost
//                 recalibrates the pace prior — the market sharpens with
//                 every auction
//
// Everything is sealed, and the trust table lives in the event log rather
// than in the object, so a market rebuilt over the same log knows exactly
// what the last one learned.

// role pace priors: abstract tool-steps per typical task, lower being faster
const pace_priors = {
	'coder':      1.30
	'tester':     1.10
	'researcher': 0.90
	'reviewer':   0.80
	'analyst':    0.95
	'architect':  1.20
	'debugger':   1.25
	'optimizer':  1.15
	'refactorer': 1.20
	'documenter': 0.85
	'devops':     1.10
	'integrator': 1.25
	'planner':    0.70
}

const market_trust_rate = 0.30 // the EMA update rate on settlement
const market_trust_floor = 0.05
const market_trust_ceil = 0.99
const market_default_trust = 0.5

struct NeedPattern {
	need    string
	pattern string
}

const need_patterns = [
	NeedPattern{'write', r'(?i)\b(write|create|implement|build|refactor|fix|edit|patch)\b'},
	NeedPattern{'run', r'(?i)\b(run|execute|test|benchmark|measure|install|deploy|debug|reproduce|diagnos\w*)\b'},
	NeedPattern{'read', r'(?i)\b(read|review|analy[sz]e|inspect|map|research|plan|document)\b'},
	NeedPattern{'web', r'(?i)\b(web|online|latest|url|http|search)\b'},
]

// which tools each kind of need actually requires. `read` requires none:
// every role can read, so a reading task is open to the whole roster.
const tool_needs = {
	'write': ['write_file', 'edit_file']
	'run':   ['run_command']
	'read':  []string{}
	'web':   ['web_search', 'web_fetch']
}

// task_needs is what the task text demands. A task that names nothing in
// particular is a reading task, which is the one every role can take.
pub fn task_needs(task string) []string {
	mut needs := []string{}
	for np in need_patterns {
		re := compile_regex(np.pattern) or { continue }
		if _ := re.search(task) {
			needs << np.need
		}
	}
	if needs.len == 0 {
		return ['read']
	}
	return needs
}

pub struct Bid {
pub:
	role string
	task string
	// higher is a better claim on the contract
	amount     f64
	trust      f64
	capability f64
	pace       f64
}

pub fn (b &Bid) to_json() map[string]json2.Any {
	return {
		'role':       json2.Any(b.role)
		'amount':     json2.Any(round_to(b.amount, 4))
		'trust':      json2.Any(round_to(b.trust, 3))
		'capability': json2.Any(round_to(b.capability, 3))
		'pace':       json2.Any(round_to(b.pace, 3))
	}
}

pub struct Contract {
pub mut:
	task    string
	awarded string
	bids    []Bid
	// open | running | done | blocked | error
	status string = 'open'
	report map[string]json2.Any
}

pub fn (c &Contract) to_json() map[string]json2.Any {
	return {
		'task':    json2.Any(clip_plain(c.task, 200))
		'awarded': json2.Any(c.awarded)
		'status':  json2.Any(c.status)
		'bids':    json2.Any(c.bids.map(json2.Any(it.to_json())))
		'report':  json2.Any(c.report.clone())
	}
}

// MarketExecutor runs the REAL worker for an awarded contract.
pub type MarketExecutor = fn (task string, role string) !map[string]json2.Any

@[heap]
pub struct TaskMarket {
pub mut:
	log      &EventLog
	executor MarketExecutor = unsafe { nil }
	trust    map[string]f64
	pace     map[string]f64
}

pub fn new_task_market(log &EventLog, executor MarketExecutor) &TaskMarket {
	mut m := &TaskMarket{
		log:      unsafe { log }
		executor: executor
		pace:     pace_priors.clone()
	}
	m.load()
	return m
}

// new_observing_market announces and awards but runs nothing — the caller
// settles each contract itself.
pub fn new_observing_market(log &EventLog) &TaskMarket {
	mut m := &TaskMarket{
		log:  unsafe { log }
		pace: pace_priors.clone()
	}
	m.load()
	return m
}

// -- trust and pace, rebuilt from the log -------------------------------------

fn (mut m TaskMarket) load() {
	for ev in m.log.events(m.log.branch) {
		if ev.typ != 'market.settle' {
			continue
		}
		role := jstr(ev.data, 'role')
		m.trust[role] = jf64_or(ev.data, 'trust', m.trust_of(role))
		p := jf64(ev.data, 'pace')
		if p != 0 {
			m.pace[role] = p
		}
	}
}

pub fn (m &TaskMarket) trust_of(role string) f64 {
	return m.trust[role] or { market_default_trust }
}

pub fn (m &TaskMarket) pace_of(role string) f64 {
	return m.pace[role] or { 1.0 }
}

// -- bidding ------------------------------------------------------------------

// capability is the tool fit between a role's whitelist and what the task
// demands. A web need is a hard gate: a role with no web tools cannot do a
// web task at all, however capable it is otherwise, so it bids nothing rather
// than bidding low and winning on trust.
fn (m &TaskMarket) capability(role string, needs []string) f64 {
	spec := roles[role] or { return 0.0 }
	tools := spec.tools
	if 'web' in needs && !any_in(tool_needs['web'] or { [] }, tools) {
		return 0.0
	}
	mut fit := 0.0
	for need in needs {
		required := tool_needs[need] or { []string{} }
		if required.len == 0 {
			fit += 1.0
		} else if any_in(required, tools) {
			fit += 0.9
		} else {
			// a role missing the tools for part of the task is penalised
			// rather than merely unrewarded
			fit -= 0.25
		}
	}
	divisor := if needs.len > 1 { needs.len } else { 1 }
	return max_f64(0.0, fit / f64(divisor))
}

fn any_in(wanted []string, have []string) bool {
	for w in wanted {
		if w in have {
			return true
		}
	}
	return false
}

// bid prices one task for every role, best first.
pub fn (m &TaskMarket) bid(task string) []Bid {
	needs := task_needs(task)
	mut bids := []Bid{}
	for role, _ in roles {
		cap := m.capability(role, needs)
		if cap <= 0.0 {
			// cannot do it at all
			continue
		}
		trust := m.trust_of(role)
		pace := m.pace_of(role)
		bids << Bid{
			role:       role
			task:       task
			amount:     cap * (0.4 + trust) / pace
			trust:      trust
			capability: cap
			pace:       pace
		}
	}
	bids.sort_with_compare(fn (a &Bid, b &Bid) int {
		if a.amount != b.amount {
			return if a.amount > b.amount { -1 } else { 1 }
		}
		if a.trust != b.trust {
			return if a.trust > b.trust { -1 } else { 1 }
		}
		return if a.role < b.role {
			-1
		} else if a.role > b.role { 1 } else { 0 }
	})
	return bids
}

// -- one auction ----------------------------------------------------------------

// auction is the full contract-net cycle for ONE task.
pub fn (mut m TaskMarket) auction(raw_task string) Contract {
	task := raw_task.trim_space()
	mut contract := Contract{
		task: task
	}
	if task == '' {
		contract.status = 'error'
		contract.report = {
			'summary': json2.Any('empty task')
		}
		return contract
	}
	m.log.append('market.announce', {
		'task': json2.Any(clip_plain(task, 300))
	}, AppendOpts{})
	contract.bids = m.bid(task)
	if contract.bids.len == 0 {
		contract.status = 'error'
		contract.report = {
			'summary': json2.Any('no role can service this task')
		}
		return contract
	}
	for b in contract.bids {
		m.log.append('market.bid', b.to_json(), AppendOpts{})
	}
	winner := contract.bids[0]
	contract.awarded = winner.role
	contract.status = 'running'
	mut beaten := contract.bids[1..].map(it.role)
	if beaten.len > 3 {
		beaten = beaten[..3].clone()
	}
	m.log.append('market.award', {
		'task':   json2.Any(clip_plain(task, 300))
		'role':   json2.Any(winner.role)
		'amount': json2.Any(round_to(winner.amount, 4))
		'beaten': json2.Any(strs_to_any(beaten))
	}, AppendOpts{ actor: 'kernel' })
	if m.executor != unsafe { nil } {
		m.run_and_settle(mut contract)
	}
	return contract
}

// -- settlement and learning ------------------------------------------------------

fn (mut m TaskMarket) run_and_settle(mut contract Contract) {
	// a failing worker never kills the market — the failure IS the outcome
	report := m.executor(contract.task, contract.awarded) or {
		mut failed := map[string]json2.Any{}
		failed['status'] = json2.Any('error')
		failed['summary'] = json2.Any(err.msg())
		failed['tool_calls'] = json2.Any(0)
		failed
	}
	m.settle(mut contract, report)
}

// settle records an outcome and updates the trust and pace priors from it.
pub fn (mut m TaskMarket) settle(mut contract Contract, report map[string]json2.Any) {
	status := jstr(report, 'status')
	contract.report = report.clone()
	contract.status = if status in ['done', 'blocked', 'error'] { status } else { 'error' }

	role := contract.awarded
	cur := m.trust_of(role)
	mut updated := 0.0
	match contract.status {
		'done' {
			updated = cur + (market_trust_ceil - cur) * market_trust_rate
		}
		'blocked' {
			// blocked is not failure: the work was real and something
			// outside the role stopped it, so the dip is small and fixed
			// rather than an exponential slide toward the floor
			updated = max_f64(market_trust_floor, min_f64(market_trust_ceil, cur - 0.05))
		}
		else {
			updated = cur + (market_trust_floor - cur) * market_trust_rate
		}
	}
	m.trust[role] = updated

	// pace recalibration: more tool calls than the prior assumed means the
	// role is slower at this kind of work than the market thought
	calls := jint(report, 'tool_calls')
	if calls > 0 {
		p := m.pace_of(role)
		m.pace[role] = max_f64(0.5, min_f64(2.0, p * 0.7 + 0.3 * (f64(calls) / 10.0)))
	}

	m.log.append('market.settle', {
		'task':    json2.Any(clip_plain(contract.task, 200))
		'role':    json2.Any(role)
		'status':  json2.Any(contract.status)
		'trust':   json2.Any(round_to(updated, 4))
		'pace':    json2.Any(round_to(m.pace_of(role), 4))
		'summary': json2.Any(clip_plain(jstr(report, 'summary'), 300))
	}, AppendOpts{})
}

// -- batches and reporting ----------------------------------------------------------

pub fn (mut m TaskMarket) run(tasks []string) []Contract {
	mut out := []Contract{}
	for t in tasks {
		if t.trim_space() == '' {
			continue
		}
		out << m.auction(t)
	}
	return out
}

pub struct LeaderRow {
pub:
	role  string
	trust f64
	pace  f64
}

// leaderboard is the market's memory, most trusted first.
pub fn (m &TaskMarket) leaderboard() []LeaderRow {
	mut rows := []LeaderRow{}
	for role, _ in roles {
		rows << LeaderRow{
			role:  role
			trust: m.trust_of(role)
			pace:  m.pace_of(role)
		}
	}
	rows.sort_with_compare(fn (a &LeaderRow, b &LeaderRow) int {
		if a.trust != b.trust {
			return if a.trust > b.trust { -1 } else { 1 }
		}
		return if a.role < b.role {
			-1
		} else if a.role > b.role { 1 } else { 0 }
	})
	return rows
}

fn contract_glyph(status string) string {
	return match status {
		'done' { '✓' }
		'blocked' { '◐' }
		'error' { '✗' }
		'running' { '…' }
		'open' { ' ' }
		else { '?' }
	}
}

pub fn (m &TaskMarket) format(contracts []Contract) string {
	mut lines := ['MARKET — ${contracts.len} contract(s)']
	for c in contracts {
		mut head := c.bids.clone()
		if head.len > 3 {
			head = head[..3].clone()
		}
		top := head.map('${it.role}(${it.amount:.2f})').join(', ')
		awarded := if c.awarded != '' { c.awarded } else { '—' }
		lines << '${contract_glyph(c.status)} [${awarded}] ' + clip_plain(c.task, 70)
		if top != '' {
			lines << '    bids: ${top}'
		}
		if c.report.len > 0 {
			lines << '    → ${c.status}: ' + clip_plain(jstr(c.report, 'summary'), 140)
		}
	}
	mut board := m.leaderboard()
	if board.len > 5 {
		board = board[..5].clone()
	}
	lines << '  trust board: ' + board.map('${it.role} ${it.trust:.2f}').join(' · ')
	return lines.join('\n')
}
