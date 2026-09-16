module vagent

import x.json2

// goal.v — GOAL MODE, the convergence (Part VI).
//
// "A goal that cannot be failed is not a goal." Here the goal stops being
// text and becomes a first-class, machine-checkable object in the event log:
// clauses with mandatory predicates, weights, anti-clauses, invariant
// clauses, a computed distance, velocity, gravity-driven focus, an amendment
// protocol, and a closing condition no model may declare satisfied.
//
// Hard rules implemented mechanically (rung 1, no LLM):
//   * §37.2  A clause without a machine-checkable predicate is REJECTED at
//            contract load time unless explicitly marked advisory.
//   * §38.1  Every tool call is attributed to a clause (correlation_id).
//            An action serving no open clause is an OrphanAction.
//   * §39.1  distance = 1 - Σ weight_i · confidence_i · proven_i.
//            proven is binary and set ONLY by a Judge predicate result.
//   * §39.3  A run cannot close ACHIEVED if any clause's only evidence is
//            model judgement (confidence < 0.85) without a human waiver.
//   * §37.4  Anti-clauses are re-checked after EVERY write event; a
//            violation emits clause.regressed and the run cannot close.
//   * §42.1  There is no DONE state a model may write. ACHIEVED is computed
//            by the kernel from proof events.
//
// All state is derived by folding the EventLog:
//   goal.set          — the full contract (frozen as an event)
//   clause.proven     — {clause, confidence, evidence_seq, proof_type}
//   clause.regressed  — {clause, reason, seq}
//   clause.waived     — {clause, reason}  (human waiver, recorded)
//   goal.amendment    — {kind, rationale, verdict: pending|accepted|rejected}
//   goal.focus        — {from, to, reason, gravity}
//   goal.distance     — {distance, velocity, seq}
//   goal.closed       — {state: ACHIEVED|PARTIAL|STALLED|BLOCKED|ABANDONED}

pub const clause_kinds = ['OUTCOME', 'ARTIFACT', 'BEHAVIOUR', 'CONSTRAINT',
	'QUALITY', 'KNOWLEDGE']

// proof_confidence_table maps a proof type to the confidence it earns
// (§39.3, honest grading). A clause's contribution to distance is
// weight * confidence, and only once proven binary.
pub const proof_confidence_table = {
	'suite_green':             1.00 // full suite, snapshotted environment
	'human_approval':          1.00 // the human is the highest authority
	'exit_code':               0.95 // single command/test green
	'command_output_contains': 0.95
	'tool_delta':              0.90 // type-check / lint delta clean
	'ast_assert':              0.85 // structure proven, behaviour not
	'file_matches':            0.85
	'diff_assert':             0.85
	'file_unchanged':          0.85
	'file_contains':           0.80
	'file_exists':             0.70 // existence is not correctness
	'model_judgement':         0.50 // capped; can never alone close a run
}

pub const closing_rules = ['ALL', 'WEIGHTED_THRESHOLD', 'ORDERED']

// Terminal states (§42.1)
pub const st_achieved = 'ACHIEVED'
pub const st_partial = 'PARTIAL'
pub const st_stalled = 'STALLED'
pub const st_blocked = 'BLOCKED'
pub const st_abandoned = 'ABANDONED'

// terminal_states is every state a goal.closed event can carry. Once the
// kernel seals one of these, the contract is settled and stops demanding
// attribution (§38.1); without this the orphan gate dead-ends the agent
// forever after a goal completes (e.g. a fully PROVEN contract still blocks
// every shell command).
pub const terminal_states = [st_achieved, st_partial, st_stalled, st_blocked,
	st_abandoned]

// min_proof_confidence is the §39.3 hard rule for closing ACHIEVED.
pub const min_proof_confidence = 0.85

fn contract_id(statement string, clauses []json2.Any) string {
	payload := canonical(json2.Any({
		'statement': json2.Any(statement)
		'clauses':   json2.Any(clauses)
	}))
	return hash(payload)[..8]
}

// proof_confidence is the confidence a clause earns when its proof
// predicate passes.
pub fn proof_confidence(proof map[string]json2.Any) f64 {
	if proof.len == 0 {
		return 0.0
	}
	return proof_confidence_table[jstr(proof, 'type')] or { 0.50 }
}

// ---------------------------------------------------------------------------
// GoalStatus — the live, fold-derived view of the contract
// ---------------------------------------------------------------------------

pub struct ClauseState {
pub mut:
	id        string
	text      string
	kind      string = 'OUTCOME'
	weight    f64
	proof     map[string]json2.Any
	has_proof bool
	advisory  bool
	state     string = 'OPEN' // OPEN | PROVEN | REGRESSED | WAIVED
	// strength of the accepted proof
	confidence      f64
	evidence_seq    int = -1
	attributed_cost f64
}

// GoalStatus is a derived, never-authoritative snapshot of the contract.
pub struct GoalStatus {
pub mut:
	active       bool
	contract_id  string
	statement    string
	clauses      []ClauseState
	anti         []Rec
	invariants   []Rec
	budget       Rec
	closing_rule string = 'ALL'
	threshold    f64 = 1.0
	distance     f64 = 1.0
	// distance reduction per 10 steps
	velocity  f64
	eta_steps int = -1
	// clause id currently under gravity focus
	focus         string
	focus_history []string
	drift         string
	complete      bool
	closed_state  string
}

pub fn (s &GoalStatus) proven_weight() f64 {
	mut total := 0.0
	for c in s.clauses {
		if c.state == 'PROVEN' {
			total += c.weight * c.confidence
		}
	}
	return total
}

// clause resolves a clause by id or by its exact text, case-insensitively.
pub fn (s &GoalStatus) clause(clause_id string) ?ClauseState {
	want := clause_id.to_lower()
	for c in s.clauses {
		if c.id.to_lower() == want || c.text.to_lower() == want {
			return c
		}
	}
	return none
}

// ---------------------------------------------------------------------------
// GoalContract — writes goal events, reads them back via the fold
// ---------------------------------------------------------------------------

// GoalContract defines, tracks and closes a goal over the shared event log.
pub struct GoalContract {
pub mut:
	log       &EventLog
	judge     &Judge = unsafe { nil }
	has_judge bool
}

pub fn new_goal_contract(log &EventLog, judge &Judge) GoalContract {
	return GoalContract{
		log:       unsafe { log }
		judge:     unsafe { judge }
		has_judge: judge != unsafe { nil }
	}
}

// ---------------------------------------------------------------------------
// Contract construction (§37)
// ---------------------------------------------------------------------------

// validate_clauses enforces the Goal Mode rules at load time (Appendix B)
// and returns the normalised clause list, with weights auto-normalised to
// sum to 1.0. Errors name the offending clause.
pub fn validate_clauses(clauses []Rec, anti []Rec, invariants []Rec, closing_rule string) ![]Rec {
	if clauses.len == 0 {
		return error('a contract needs at least one clause')
	}
	if closing_rule !in closing_rules {
		return error('closing_rule must be one of ${closing_rules}')
	}
	mut norm := []Rec{}
	mut total := 0.0
	mut seen_ids := map[string]bool{}

	for i, c in clauses {
		mut cid := jstr(c, 'id')
		if cid == '' {
			cid = 'C${i + 1}'
		}
		text := jstr(c, 'text').trim_space()
		if text == '' {
			return error('clause ${cid}: empty text')
		}
		// proofs and waivers are keyed by clause id — duplicates would make
		// one twin unprovable and waive/prove BOTH together
		if cid.to_lower() in seen_ids {
			return error("duplicate clause id '${cid}' — ids must be unique")
		}
		seen_ids[cid.to_lower()] = true

		mut kind := jstr(c, 'kind').to_upper()
		if kind == '' {
			kind = 'OUTCOME'
		}
		if kind !in clause_kinds {
			return error('clause ${cid}: kind must be one of ${clause_kinds}')
		}
		proof := jmap(c, 'proof')
		advisory := jbool(c, 'advisory')
		if !advisory {
			// §37.2 hard rule: no predicate, no clause
			ptype := jstr(proof, 'type')
			if proof.len == 0 || ptype == '' {
				return error('clause ${cid} has no machine-checkable proof — ' +
					'give it a predicate or mark it advisory')
			}
			if ptype !in proof_confidence_table {
				mut valid := proof_confidence_table.keys()
				valid.sort()
				return error("clause ${cid}: unknown proof type '${ptype}' — valid: ${valid}")
			}
			if ptype == 'model_judgement' {
				return error('clause ${cid}: model_judgement cannot be the only ' +
					'evidence — pair it with a deterministic proof or mark the ' +
					'clause advisory')
			}
		}
		mut weight := 1.0
		if 'weight' in c {
			weight = jf64(c, 'weight')
		}
		if weight < 0 {
			return error('clause ${cid}: negative weight')
		}
		total += weight
		norm << Rec({
			'id':       json2.Any(cid)
			'text':     json2.Any(text)
			'kind':     json2.Any(kind)
			'weight':   json2.Any(weight)
			'proof':    if proof.len > 0 { json2.Any(proof) } else { json2.null }
			'advisory': json2.Any(advisory)
		})
	}
	if total <= 0 {
		return error('clause weights must sum to > 0')
	}
	// auto-normalise weights to 1.0 (Appendix B)
	for mut c in norm {
		c['weight'] = jf64(c, 'weight') / total
	}
	for a in anti {
		if jstr(a, 'text') == '' {
			return error('anti-clause missing text')
		}
	}
	for inv in invariants {
		if jmap(inv, 'check').len == 0 {
			id := if jstr(inv, 'id') != '' { jstr(inv, 'id') } else { '?' }
			return error('invariant ${id}: missing check')
		}
	}
	return norm
}

@[params]
pub struct SetGoalOpts {
pub:
	anti             []Rec
	invariants       []Rec
	budget           Rec
	closing_rule     string = 'ALL'
	threshold        f64 = 1.0
	autonomy_ceiling int = 5
}

// set_goal freezes a contract as an event. From this moment the contract is
// history, not configuration — amendments are separate events (§41).
pub fn (mut g GoalContract) set_goal(statement string, clauses []Rec, opts SetGoalOpts) !Rec {
	norm := validate_clauses(clauses, opts.anti, opts.invariants, opts.closing_rule)!
	norm_any := norm.map(json2.Any(it))
	contract := Rec({
		'id':                json2.Any(contract_id(statement, norm_any))
		'statement':         json2.Any(statement)
		'clauses':           json2.Any(norm_any)
		'anti_clauses':      json2.Any(opts.anti.map(json2.Any(it)))
		'invariant_clauses': json2.Any(opts.invariants.map(json2.Any(it)))
		'budget':            json2.Any(opts.budget)
		'closing_rule':      json2.Any(opts.closing_rule)
		'threshold':         json2.Any(opts.threshold)
		'autonomy_ceiling':  json2.Any(opts.autonomy_ceiling)
		'version':           json2.Any(1)
		'created_ts':        json2.Any(now_ts())
	})
	g.log.append('goal.set', contract, AppendOpts{ actor: 'human', provenance: 'user' })
	return contract
}

// clear deactivates the goal with an empty contract event.
pub fn (mut g GoalContract) clear() {
	g.log.append('goal.set', {
		'statement':         json2.Any('')
		'clauses':           json2.Any([]json2.Any{})
		'anti_clauses':      json2.Any([]json2.Any{})
		'invariant_clauses': json2.Any([]json2.Any{})
		'created_ts':        json2.Any(now_ts())
	}, AppendOpts{ actor: 'human', provenance: 'user' })
}

// ---------------------------------------------------------------------------
// Proofs (§39)
// ---------------------------------------------------------------------------

// prove_clause records a proof for a clause. ONLY a passing Judge predicate
// (or an explicit human approval) may prove a clause — the binary proven
// flag is never set from model output (§39.1).
pub fn (mut g GoalContract) prove_clause(clause_id string, passed bool, proof_type string, evidence_seq int, detail string) bool {
	st := g.status()
	c := st.clause(clause_id) or { return false }
	if !st.active {
		return false
	}
	if !passed {
		// a failed proof is evidence of NOT-done; record as a regression
		// only if the clause was previously proven
		if c.state == 'PROVEN' {
			reason := if detail != '' { detail } else { '${proof_type} proof now fails' }
			g.log.append('clause.regressed', {
				'clause': json2.Any(c.id)
				'reason': json2.Any(reason)
			}, AppendOpts{})
		}
		return false
	}
	confidence := proof_confidence_table[proof_type] or { 0.50 }
	g.log.append('clause.proven', {
		'clause':       json2.Any(c.id)
		'confidence':   json2.Any(confidence)
		'proof_type':   json2.Any(proof_type)
		'evidence_seq': if evidence_seq >= 0 { json2.Any(evidence_seq) } else { json2.null }
		'detail':       json2.Any(detail)
	}, AppendOpts{ actor: 'judge', provenance: 'tool_output' })
	return true
}

// waive records a human waiver — an event, never silent (§39.3).
pub fn (mut g GoalContract) waive(clause_id string, reason string) bool {
	st := g.status()
	c := st.clause(clause_id) or { return false }
	if !st.active {
		return false
	}
	g.log.append('clause.waived', {
		'clause': json2.Any(c.id)
		'reason': json2.Any(reason)
	}, AppendOpts{ actor: 'human', provenance: 'user' })
	return true
}

// prove_by_predicate runs the clause's OWN predicate through the Judge
// (§40.2 VII: the clause and the test are the same object).
pub fn (mut g GoalContract) prove_by_predicate(clause_id string) (bool, string) {
	if !g.has_judge {
		return false, 'no judge attached'
	}
	st := g.status()
	c := st.clause(clause_id) or { return false, 'no such clause: ${clause_id}' }
	if !st.active {
		return false, 'no such clause: ${clause_id}'
	}
	if !c.has_proof {
		return false, 'clause ${c.id} is advisory — no predicate to run'
	}
	verdict := g.judge.check(c.proof)
	ev_seq := g.log.head('')
	g.prove_clause(c.id, verdict.passed, jstr(c.proof, 'type'), ev_seq, verdict.detail)
	return verdict.passed, verdict.detail
}

// ---------------------------------------------------------------------------
// Anti-clauses & invariants (§37.4)
// ---------------------------------------------------------------------------

fn (mut g GoalContract) check_guards(entries []Rec, flag string) []Rec {
	if !g.has_judge {
		return []
	}
	mut violations := []Rec{}
	for entry in entries {
		check := jmap(entry, 'check')
		if check.len == 0 || jstr(check, 'type') == '' {
			continue
		}
		verdict := g.judge.check(check)
		if verdict.passed {
			continue
		}
		id := if jstr(entry, 'id') != '' { jstr(entry, 'id') } else { '?' }
		violations << Rec({
			'clause': json2.Any(id)
			'text':   json2.Any(jstr(entry, 'text'))
			'detail': json2.Any(verdict.detail)
		})
		g.log.append('clause.regressed', {
			'clause': json2.Any(id)
			flag:     json2.Any(true)
			'reason': json2.Any(verdict.detail)
		}, AppendOpts{ actor: 'judge', provenance: 'tool_output' })
	}
	return violations
}

// check_anti_clauses re-checks every anti-clause NOW. Called after every
// write event. An anti-clause's check describes the condition that must
// HOLD; if the predicate fails, the forbidden thing happened -> violation.
pub fn (mut g GoalContract) check_anti_clauses() []Rec {
	st := g.status()
	return g.check_guards(st.anti, 'anti')
}

// check_invariants re-checks invariant clauses (must remain true
// throughout).
pub fn (mut g GoalContract) check_invariants() []Rec {
	st := g.status()
	return g.check_guards(st.invariants, 'invariant')
}

// ---------------------------------------------------------------------------
// Distance, velocity, drift (§39)
// ---------------------------------------------------------------------------

pub fn (mut g GoalContract) distance() f64 {
	return g.status().distance
}

// measure recomputes distance + velocity and seals a goal.distance event
// (§38.3 steps 5-7). Pure arithmetic over the fold — zero tokens.
pub fn (mut g GoalContract) measure() Rec {
	st := g.status()
	if !st.active {
		return Rec({
			'distance': json2.Any(1.0)
			'velocity': json2.Any(0.0)
		})
	}
	measures := fold(mut g.log, '').distance_measures
	mut velocity := 0.0
	if measures.len > 0 {
		last := measures.last()
		mut steps := g.log.head('') - jint(last, 'seq')
		if steps < 1 {
			steps = 1
		}
		velocity = (jf64(last, 'distance') - st.distance) / f64(steps) * 10.0
	}
	record := Rec({
		'distance': json2.Any(st.distance)
		'velocity': json2.Any(velocity)
		'seq':      json2.Any(g.log.head(''))
		'focus':    if st.focus != '' { json2.Any(st.focus) } else { json2.null }
	})
	g.log.append('goal.distance', record, AppendOpts{})
	return record
}

// ---------------------------------------------------------------------------
// Gravity & focus (§40)
// ---------------------------------------------------------------------------

// gravity scores every open clause at rung 1 (§40.1). The highest-gravity
// clause becomes the focus; everything re-aims at it.
pub fn (mut g GoalContract) gravity() map[string]f64 {
	st := g.status()
	regressed := fold(mut g.log, '').clause_regressed
	mut scores := map[string]f64{}
	for c in st.clauses {
		if c.state == 'PROVEN' || c.state == 'WAIVED' {
			scores[c.id] = 0.0
			continue
		}
		feasibility := if c.has_proof { 1.0 } else { 0.3 } // advisory = low pull
		mut est_cost := c.attributed_cost
		if est_cost < 0.05 {
			est_cost = 0.05
		}
		unblocked := 1.0
		// freshness penalty: recently regressed clauses pull less
		mut freshness := 1.0
		for i := regressed.len - 1; i >= 0; i-- {
			if jstr(regressed[i], 'clause') == c.id {
				freshness = 0.5
				break
			}
		}
		scores[c.id] = c.weight * feasibility * (1.0 / est_cost) * unblocked * freshness
	}
	return scores
}

// reaim points the run at the highest-gravity open clause. A focus shift is
// an event, so the attention history is replayable (§40.3).
pub fn (mut g GoalContract) reaim(reason string) ?string {
	st := g.status()
	if !st.active {
		return none
	}
	scores := g.gravity()
	mut best := ''
	mut best_score := 0.0
	// ties break on the clause id, so the choice is reproducible
	mut ids := scores.keys()
	ids.sort()
	for id in ids {
		v := scores[id]
		if v > 0 && (best == '' || v > best_score) {
			best = id
			best_score = v
		}
	}
	if best == '' {
		return none
	}
	if best != st.focus {
		g.log.append('goal.focus', {
			'from':    if st.focus != '' { json2.Any(st.focus) } else { json2.null }
			'to':      json2.Any(best)
			'reason':  json2.Any(reason)
			'gravity': json2.Any(best_score)
		}, AppendOpts{ actor: 'navigator' })
	}
	return best
}

// ---------------------------------------------------------------------------
// Amendments (§41)
// ---------------------------------------------------------------------------

const amendment_kinds = ['ADD_CLAUSE', 'SPLIT', 'REWEIGHT', 'WAIVE',
	'RELAX_PROOF', 'EXTEND_BUDGET']

// propose_amendment records a proposal. The agent may NEVER edit the
// contract — only propose (§41.2). Rejected proposals are kept: they record
// where the agent's understanding diverged from the human's.
pub fn (mut g GoalContract) propose_amendment(kind string, rationale string, impact string) !string {
	if kind !in amendment_kinds {
		return error('amendment kind must be one of ${amendment_kinds}')
	}
	proposal_id := hash('${kind}:${rationale}:${now_ts()}')[..10]
	g.log.append('goal.amendment', {
		'proposal':  json2.Any(proposal_id)
		'kind':      json2.Any(kind)
		'rationale': json2.Any(rationale)
		'impact':    json2.Any(impact)
		'verdict':   json2.Any('pending')
	}, AppendOpts{ actor: 'sovereign', provenance: 'model' })
	return proposal_id
}

// resolve_amendment records a human accepting or rejecting a pending
// amendment (the decision is an event; the pending record is re-emitted
// with its verdict).
pub fn (mut g GoalContract) resolve_amendment(proposal_id string, verdict string) bool {
	if verdict != 'accepted' && verdict != 'rejected' {
		return false
	}
	for am in fold(mut g.log, '').amendments {
		if jstr(am, 'proposal') != proposal_id || jstr(am, 'verdict') != 'pending' {
			continue
		}
		mut record := map[string]json2.Any{}
		for k, v in am {
			if k != 'verdict' {
				record[k] = v
			}
		}
		record['verdict'] = verdict
		record['of_proposal'] = proposal_id
		g.log.append('goal.amendment', record, AppendOpts{
			actor:      'human'
			provenance: 'user'
		})
		return true
	}
	return false
}

// ---------------------------------------------------------------------------
// Closure (§42)
// ---------------------------------------------------------------------------

// closure_check computes the terminal state from proof events — never
// declared by a model (§42.1). Returns (state, reasons).
pub fn (mut g GoalContract) closure_check() (string, []string) {
	st := g.status()
	if !st.active {
		return st_abandoned, ['no active contract']
	}
	mut reasons := []string{}
	mut proven := []ClauseState{}
	mut waived := []ClauseState{}
	mut missing := []ClauseState{}
	mut weak := []ClauseState{}
	mut blocked_shape := false

	for c in st.clauses {
		if c.advisory {
			continue
		}
		match c.state {
			'PROVEN' {
				proven << c
				if c.confidence < min_proof_confidence {
					weak << c
				}
			}
			'WAIVED' {
				waived << c
			}
			else {
				missing << c
				if c.state == 'OPEN' && !c.has_proof {
					blocked_shape = true
				}
			}
		}
	}

	// §39.3 hard rule: no ACHIEVED on model-judgement-only evidence
	if weak.len > 0 {
		reasons << 'weak proof (<0.85 confidence) for: ' + weak.map(it.id).join(', ')
	}
	if missing.len > 0 {
		reasons << 'open clauses: ' + missing.map(it.id).join(', ')
	}

	mut proven_w := 0.0
	for c in proven {
		proven_w += c.weight
	}
	for c in waived {
		proven_w += c.weight
	}

	if missing.len == 0 && weak.len == 0 {
		return st_achieved, reasons
	}
	if st.closing_rule == 'WEIGHTED_THRESHOLD' && proven_w >= st.threshold && weak.len == 0 {
		return st_partial, reasons
	}
	if missing.len == 0 && weak.len > 0 {
		return st_partial, reasons
	}
	if missing.len == 0 {
		return st_stalled, reasons
	}
	return if blocked_shape { st_blocked } else { st_stalled }, reasons
}

pub struct ClosureResult {
pub:
	state   string
	reasons []string
	bundle  string
}

// close performs the closure ritual (§42.2): re-prove every clause from
// scratch, re-check anti-clauses, then compute the terminal state and seal
// a goal.closed event.
pub fn (mut g GoalContract) close(fresh bool) ClosureResult {
	st := g.status()
	if !st.active {
		return ClosureResult{
			state:   st_abandoned
			reasons: ['no active contract']
		}
	}
	if fresh && g.has_judge {
		for c in st.clauses {
			if c.has_proof && !c.advisory {
				g.prove_by_predicate(c.id)
			}
		}
		g.check_anti_clauses()
		g.check_invariants()
	}
	state, reasons := g.closure_check()
	g.log.append('goal.closed', {
		'state':   json2.Any(state)
		'reasons': json2.Any(strs_to_any(reasons))
	}, AppendOpts{ actor: 'kernel' })
	return ClosureResult{
		state:   state
		reasons: reasons
		bundle:  g.evidence_bundle()
	}
}

// evidence_bundle is §42.3 — the deliverable of Goal Mode: a proof per
// clause with event ids, not a paragraph claiming success.
pub fn (mut g GoalContract) evidence_bundle() string {
	st := g.status()
	if !st.active {
		return 'no active contract'
	}
	// The header must agree with the closure state (§42.1), which is
	// stricter than `complete` (it also demands proof confidence).
	state, _ := g.closure_check()
	mut lines := ['GOAL ${state} — contract ${st.contract_id}', '  "${st.statement}"', '']
	for c in st.clauses {
		mark := match c.state {
			'PROVEN' { 'PROVEN' }
			'WAIVED' { 'WAIVED' }
			'REGRESSED' { 'REGRESSED' }
			else { 'OPEN  ' }
		}
		conf := if c.state == 'PROVEN' { 'conf ${c.confidence:.2f}' } else { '        ' }
		ev := if c.evidence_seq >= 0 { 'ev #${c.evidence_seq}' } else { '' }
		lines << ' ${c.id} [${pad_right(c.kind, 9)} w${c.weight:.2f}] ' +
			'${pad_right(c.text, 32)} ${mark} ${conf} ${ev}'
	}
	for a in st.anti {
		id := if jstr(a, 'id') != '' { jstr(a, 'id') } else { '?' }
		lines << ' ${id} [ANTI     ] ${jstr(a, "text")}'
	}
	for inv in st.invariants {
		id := if jstr(inv, 'id') != '' { jstr(inv, 'id') } else { '?' }
		lines << ' ${id} [INVARIANT] ${jstr(inv, "text")}'
	}
	lines << ''
	lines << ' distance ${st.distance:.2f}   velocity ${st.velocity:+.3f}/10 steps'
	if st.focus_history.len > 0 {
		lines << ' focus history  ' + st.focus_history.join(' -> ')
	}
	return lines.join('\n')
}

// pad_right left-aligns `s` in a field of `width`, matching Python's
// `{:<n}` (which never truncates an over-long value).
fn pad_right(s string, width int) string {
	n := s.runes().len
	return if n >= width { s } else { s + ' '.repeat(width - n) }
}

// ---------------------------------------------------------------------------
// Reads (always via the fold)
// ---------------------------------------------------------------------------

// status folds the log and computes the live GoalStatus (§39 formula).
pub fn (mut g GoalContract) status() GoalStatus {
	st := fold(mut g.log, '')
	contract := st.goal or { return GoalStatus{} }
	if jstr(contract, 'statement') == '' && jarr(contract, 'clauses').len == 0 {
		return GoalStatus{}
	}

	// proof history, walked with event seqs: the latest proof per clause
	// wins; a regression AFTER a proof reopens the clause (§42.4). Only
	// events AFTER the current goal.set count — proofs from a previous
	// contract must not leak into this one.
	events := g.log.events('')
	mut last_set_seq := -1
	for ev in events {
		if ev.typ == 'goal.set' {
			last_set_seq = ev.seq
		}
	}
	mut proven_seq := map[string]int{}
	mut proven_data := map[string]Rec{}
	mut regressed_after := map[string]int{}
	mut waived := map[string]bool{}
	mut focus_history := []string{}
	mut closed_fallback := ''

	for ev in events {
		if ev.seq <= last_set_seq {
			continue
		}
		d := ev.data.clone()
		match ev.typ {
			'clause.proven' {
				cid := jstr(d, 'clause')
				proven_seq[cid] = ev.seq
				proven_data[cid] = d
			}
			'clause.regressed' {
				// anti/invariant regressions do not reopen clauses
				if jbool(d, 'anti') || jbool(d, 'invariant') {
					continue
				}
				cid := jstr(d, 'clause')
				prev := regressed_after[cid] or { -1 }
				if ev.seq > prev {
					regressed_after[cid] = ev.seq
				}
			}
			'clause.waived' {
				waived[jstr(d, 'clause')] = true
			}
			'goal.focus' {
				to := jstr(d, 'to')
				if to != '' {
					focus_history << to
				}
			}
			'goal.closed' {
				closed_fallback = jstr(d, 'state')
			}
			else {}
		}
	}

	mut clauses := []ClauseState{}
	for raw_any in jarr(contract, 'clauses') {
		raw := match raw_any {
			map[string]json2.Any { raw_any }
			else { continue }
		}
		cid := jstr(raw, 'id')
		proof := jmap(raw, 'proof')
		mut cs := ClauseState{
			id:        cid
			text:      jstr(raw, 'text')
			kind:      jstr(raw, 'kind')
			weight:    jf64(raw, 'weight')
			proof:     proof
			has_proof: proof.len > 0 && jstr(proof, 'type') != ''
			advisory:  jbool(raw, 'advisory')
		}
		if cs.kind == '' {
			cs.kind = 'OUTCOME'
		}
		if cid in waived {
			cs.state = 'WAIVED'
			cs.confidence = 1.0
		} else if p_seq := proven_seq[cid] {
			if (regressed_after[cid] or { -1 }) > p_seq {
				cs.state = 'REGRESSED'
			} else {
				p := proven_data[cid] or { Rec(map[string]json2.Any{}) }
				cs.state = 'PROVEN'
				cs.confidence = jf64(p, 'confidence')
				cs.evidence_seq = if 'evidence_seq' in p && jget(p, 'evidence_seq') !is json2.Null {
					jint(p, 'evidence_seq')
				} else {
					-1
				}
			}
		}
		clauses << cs
	}

	// §39.1 distance = 1 - Σ weight * confidence * proven
	mut earned := 0.0
	for c in clauses {
		if c.state == 'PROVEN' || c.state == 'WAIVED' {
			earned += c.weight * c.confidence
		}
	}
	mut distance := 1.0 - earned
	if distance < 0.0 {
		distance = 0.0
	}
	if distance > 1.0 {
		distance = 1.0
	}

	// velocity + ETA from sealed goal.distance measures
	measures := st.distance_measures
	velocity := if measures.len > 0 { jf64(measures.last(), 'velocity') } else { 0.0 }
	mut eta := -1
	if velocity > 1e-6 {
		eta = int(distance / (velocity / 10.0))
	}
	focus := if focus_history.len > 0 { focus_history.last() } else { '' }

	// drift: >=30% of attributed cost on the lowest-weight open clause
	mut drift := ''
	mut open_c := clauses.filter(it.state == 'OPEN')
	if open_c.len >= 2 {
		mut total_cost := 0.0
		for c in clauses {
			total_cost += c.attributed_cost
		}
		if total_cost > 0 {
			mut lowest := open_c[0]
			for c in open_c {
				if c.weight < lowest.weight {
					lowest = c
				}
			}
			if lowest.attributed_cost / total_cost >= 0.30 {
				drift = 'spend concentrated on low-weight clause ${lowest.id} ' +
					'(w${lowest.weight:.2f})'
			}
		}
	}

	mut non_advisory := clauses.filter(!it.advisory)
	mut complete := non_advisory.len > 0
	for c in non_advisory {
		if c.state != 'PROVEN' && c.state != 'WAIVED' {
			complete = false
			break
		}
	}

	// Prefer the fold's goal_closed — it only remembers a goal.closed AFTER
	// the current goal.set, so a stale close from a previous contract cannot
	// leak through.
	mut closed_state := closed_fallback
	if gc := st.goal_closed {
		closed_state = jstr(gc, 'state')
	}

	mut anti := []Rec{}
	for a in jarr(contract, 'anti_clauses') {
		if a is map[string]json2.Any {
			anti << a
		}
	}
	mut invariants := []Rec{}
	for i in jarr(contract, 'invariant_clauses') {
		if i is map[string]json2.Any {
			invariants << i
		}
	}

	mut closing_rule := jstr(contract, 'closing_rule')
	if closing_rule == '' {
		closing_rule = 'ALL'
	}
	mut threshold := 1.0
	if 'threshold' in contract {
		threshold = jf64(contract, 'threshold')
	}

	return GoalStatus{
		active:        true
		contract_id:   jstr(contract, 'id')
		statement:     jstr(contract, 'statement')
		clauses:       clauses
		anti:          anti
		invariants:    invariants
		budget:        jmap(contract, 'budget')
		closing_rule:  closing_rule
		threshold:     threshold
		distance:      distance
		velocity:      velocity
		eta_steps:     eta
		focus:         focus
		focus_history: focus_history
		drift:         drift
		complete:      complete
		closed_state:  closed_state
	}
}

// format renders the Goal Compass as text (§43.1).
pub fn (mut g GoalContract) format() string {
	s := g.status()
	if !s.active {
		return 'GOAL: none'
	}
	bar_w := 24
	mut filled := int((1.0 - s.distance) * f64(bar_w) + 0.5)
	if filled < 0 {
		filled = 0
	}
	if filled > bar_w {
		filled = bar_w
	}
	bar := '█'.repeat(filled) + '░'.repeat(bar_w - filled)
	eta := if s.eta_steps >= 0 { '   ETA ~${s.eta_steps} steps' } else { '' }
	mut lines := ['GOAL "${s.statement}"  contract ${s.contract_id}',
		' distance ${s.distance:.2f} [${bar}] ${(1.0 - s.distance) * 100.0:.0f}% proven' +
		'   velocity ${s.velocity:+.3f}/10 steps' + eta]
	for c in s.clauses {
		focus_mark := if c.id == s.focus { '  <-- FOCUS' } else { '' }
		adv := if c.advisory { ' (advisory)' } else { '' }
		conf := if c.state == 'PROVEN' { ' ${c.confidence:.2f}' } else { '' }
		lines << '  ${c.id} w${c.weight:.2f} [${pad_right(c.kind, 9)}] ' +
			'${pad_right(c.text, 30)} ${c.state}${conf}${adv}${focus_mark}'
	}
	for a in s.anti {
		id := if jstr(a, 'id') != '' { jstr(a, 'id') } else { '?' }
		lines << '  ${id} [ANTI] ${jstr(a, "text")}'
	}
	for inv in s.invariants {
		id := if jstr(inv, 'id') != '' { jstr(inv, 'id') } else { '?' }
		lines << '  ${id} [INV ] ${jstr(inv, "text")}'
	}
	if s.focus_history.len > 0 {
		lines << ' focus: ' + s.focus_history.join(' -> ')
	}
	if s.drift != '' {
		lines << ' DRIFT: ${s.drift}'
	}
	return lines.join('\n')
}
