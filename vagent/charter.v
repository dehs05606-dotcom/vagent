module vagent

import x.json2

// charter.v — one boundary, assembled in a defined order.
//
// There are eighteen modules that each refuse something, and wiring them
// into the agent by hand, one call at a time, in whatever order they were
// written, is a real problem rather than a tidiness one:
//
//   * ORDER WAS ACCIDENTAL. Whether a call is refused for leaving src/ or
//     for crossing a file budget decides which message the agent sees, and
//     the agent's next attempt depends on which refusal it got. An accident
//     in source order became behaviour.
//   * NARROWING WAS PARTIAL. Exemptions and consent narrowed the Covenant's
//     violations, because that is where they were plumbed in. A horizon
//     breach or an egress refusal had no route to a granted exception, so
//     "allow this once" worked for some clauses and silently did not for
//     others.
//   * COVERAGE WAS UNPROVABLE. Each subsystem had its own counters and no
//     one place knew whether all of them had run for a given call.
//
// The Charter is the composition root. It owns every enforcement subsystem,
// runs them in ONE declared order, applies narrowing uniformly to whatever
// they produce, attaches the remedy, and witnesses the single decision that
// comes out. The agent asks one question and gets one answer.
//
//   ORDER OF JUDGEMENT — declared here, not inherited from source layout:
//
//     0. sanctum       would this rewrite the rules doing the judging?
//                      Not a clause, not narrowable, consulted first, and
//                      in force even with no specification at all.
//     1. sequence      preconditions: is this act even in the right order?
//     2. covenant      is the act itself permitted?
//     3. provenance    is the content's origin permitted?
//     4. egress        may this leave the machine?
//     5. horizon       does it fit what this window still allows?
//
//   Then, over whatever those produced:
//
//     6. exemptions    declared exceptions in the specification
//     7. consent       bounded grants a human gave
//     8. remedy        what would have been allowed
//     9. witness       the decision, allowed or refused, into the chain
//
// The order runs cheapest-and-most-fundamental first, and puts narrowing
// AFTER judgement rather than inside it: a rule decides what it decides, and
// forgiveness is applied to the result, in one place, where it can be
// audited. Nothing is forgiven twice and nothing is missed.
//
// DONE is separate from ALLOWED. An obligation and an `after` sequence rule
// do not refuse work — the discharging act is itself work — so they answer
// blocker() rather than gate(). Progress is refused, never the step that
// would make progress possible.

// CharterVerdict is the single answer to "may this call proceed?".
//
// The original called it Verdict; judge.py has a Verdict of its own, and
// this port is one flat V module, so the boundary's verdict carries the
// boundary's name.
pub struct CharterVerdict {
pub:
	allowed bool = true
	reason  string
	// which subsystem refused
	source     string
	violations []Violation
	breaches   []Breach
	overspend  []Overspend
	forgiven   int
}

@[heap]
pub struct Charter {
pub mut:
	log  &EventLog
	spec string

	// The invariant that is not a clause: the boundary's own code and the
	// specification in force cannot be rewritten by what they bind.
	// Constructed before everything else and consulted before every clause,
	// so it holds even with no specification at all.
	sanctum &Sanctum

	// judgement
	sequence   &Timeline
	covenant   &Covenant
	provenance &Lineage
	egress     &Perimeter
	horizon    &Horizon
	ration     &Ration

	// narrowing
	exemptions &Exemptions
	consent    &Consent

	// obligations (done-gating, never work-gating)
	obligations &Ledger

	// adherence, as distinct from enforcement
	conform  &Conform
	critic   &Critic
	feedback &Feedback

	// evidence
	witness   &Witness
	integrity &Integrity

	// post-commit review, when a snapshot store is available
	sentinel     &Sentinel = unsafe { nil }
	has_sentinel bool

	refused int
	allowed int
mut:
	spec_source string
}

pub struct CharterOpts {
pub:
	spec        string
	spec_source string
	// the directory the boundary's own sources live in, for the sanctum
	package_dir string
	store       ?SnapshotStore
	// the project root obligations are resolved against
	root string
}

pub fn new_charter(log &EventLog, opts CharterOpts) &Charter {
	spec := opts.spec
	mut c := &Charter{
		log:         unsafe { log }
		spec:        spec
		spec_source: opts.spec_source
		sanctum:     new_sanctum(log, opts.spec_source, opts.package_dir)
		sequence:    new_timeline(log, spec)
		covenant:    new_covenant(log, spec)
		provenance:  new_lineage(log, spec)
		egress:      new_perimeter(log, spec)
		horizon:     new_horizon(log, spec)
		ration:      new_ration(log, spec)
		exemptions:  new_exemptions(log, spec)
		consent:     new_consent(log)
		obligations: new_ledger(log, spec, opts.root)
		conform:     new_conform(log, spec, default_attempts)
		critic:      new_critic(log, spec)
		feedback:    new_feedback(log)
		witness:     new_witness(log)
		integrity:   new_integrity(log)
	}
	c.integrity.seal(spec, opts.spec_source, c.covenant)
	if store := opts.store {
		c.sentinel = new_sentinel(log, c.covenant, store)
		c.has_sentinel = true
	}
	return c
}

// -- binding -----------------------------------------------------------------

// bind rebinds every subsystem to one specification, TOGETHER.
//
// Rebinding them one at a time is how the prompt and the boundary drift
// apart, so there is deliberately no way to rebind just one.
pub fn (mut c Charter) bind(spec string, spec_source string) {
	c.spec = spec
	c.sequence.bind(spec)
	c.covenant.bind(spec)
	c.provenance.bind(spec)
	c.egress.bind(spec)
	c.horizon.bind(spec)
	c.ration.bind(spec)
	c.exemptions.bind(spec)
	c.obligations.bind(spec)
	c.conform.bind(spec)
	c.critic.bind(spec)
	c.integrity.seal(spec, spec_source, c.covenant)
	if spec_source != '' {
		c.sanctum.spec_source = spec_source
		c.spec_source = spec_source
	}
	c.sanctum.seal()
}

// -- the single gate ---------------------------------------------------------

// gate answers "may this call proceed?" with one verdict and one witnessed
// decision.
pub fn (mut c Charter) gate(tool string, args map[string]json2.Any) CharterVerdict {
	effects := derive(tool, args)
	command := jstr(args, 'command')

	// 0: the invariant. Before any clause, and never narrowed — an
	// exception to "do not rewrite your own rules" is indistinguishable from
	// the act it would forgive.
	sealed := c.sanctum.gate(tool, args)
	if sealed != '' {
		c.refused++
		c.witness.refuse(tool, ['sanctum'])
		return CharterVerdict{
			allowed: false
			reason:  sealed
			source:  'sanctum'
		}
	}

	mut forgiven := 0

	// 1-3: the stages that produce Violations, in the declared order
	for stage in ['sequence', 'covenant', 'provenance', 'egress'] {
		mut found := []Violation{}
		match stage {
			'sequence' {
				for u in c.sequence.check(tool, args) {
					found << Violation{
						clause: u.clause
						kind:   'sequence'
						detail: u.detail
					}
				}
			}
			'covenant' {
				found = c.covenant.check(tool, args)
			}
			'provenance' {
				for t in c.provenance.check(tool, args) {
					found << Violation{
						clause: t.clause
						kind:   'origin'
						detail: t.describe()
						path:   t.path
					}
				}
			}
			'egress' {
				for b in c.egress.check(tool, args) {
					found << Violation{
						clause: b.clause
						kind:   b.kind
						detail: b.detail
					}
				}
			}
			else {}
		}
		if found.len == 0 {
			continue
		}
		// 6-7: narrowing, applied uniformly to whatever was produced
		before := found.len
		mut kept := c.exemptions.narrow(found, tool, effects)
		kept = c.consent.narrow(kept, tool, command)
		forgiven += before - kept.len
		if kept.len == 0 {
			continue
		}
		mut reason := c.cite(stage, kept)
		// 8: what would have been allowed
		reason = annotate(reason, kept, c.covenant.guards(), [], [])
		c.refused++
		// 9: the decision, into the chain
		c.witness.refuse(tool, kept.map(it.clause))
		return CharterVerdict{
			allowed:    false
			reason:     reason
			source:     stage
			violations: kept
			forgiven:   forgiven
		}
	}

	// 5: the horizon, whose breaches are not violations and are narrowed
	// through the same two stages by clause
	breaches := c.horizon.project(tool, args)
	if breaches.len > 0 {
		mut as_violations := breaches.map(Violation{
			clause: it.clause
			kind:   'horizon'
			detail: it.describe()
		})
		before := as_violations.len
		mut kept := c.exemptions.narrow(as_violations, tool, effects)
		kept = c.consent.narrow(kept, tool, command)
		forgiven += before - kept.len
		if kept.len > 0 {
			kept_clauses := kept.map(it.clause)
			live := breaches.filter(it.clause in kept_clauses)
			mut reason := c.cite('horizon', kept)
			reason = annotate(reason, [], c.covenant.guards(), live, [])
			c.refused++
			c.witness.refuse(tool, kept_clauses)
			return CharterVerdict{
				allowed:  false
				reason:   reason
				source:   'horizon'
				breaches: live
				forgiven: forgiven
			}
		}
	}

	c.allowed++
	c.witness.allow(tool)
	return CharterVerdict{
		forgiven: forgiven
	}
}

fn (c &Charter) cite(source string, found []Violation) string {
	if source == 'covenant' {
		return c.covenant.cite(found)
	}
	head := match source {
		'sequence' { 'OutOfOrder: something must happen before this call.' }
		'provenance' { 'OriginRefused: this write reuses content from a forbidden origin.' }
		'egress' { 'EgressRefused: this call would leave the machine in a way the specification forbids.' }
		'horizon' { 'HorizonExceeded: this call would cross a limit in the specification.' }
		else { 'Refused by the specification.' }
	}
	mut lines := [head]
	for v in found {
		clause := if v.clause != '' { v.clause } else { '?' }
		if v.detail.starts_with('${clause}:') {
			lines << '  ${v.detail}'
		} else {
			lines << '  ${clause}: ${v.detail}'
		}
	}
	return lines.join('\n')
}

// -- model calls -------------------------------------------------------------

// afford answers "may this MODEL call be made?".
//
// Budgets are about requests, not tool calls, so they are asked separately
// rather than folded into a gate that never sees a token count.
pub fn (mut c Charter) afford(estimate Estimate) CharterVerdict {
	over := c.ration.project(estimate)
	if over.len == 0 {
		return CharterVerdict{}
	}
	mut lines := ['RationExceeded: this call would cross a budget in the specification.']
	for o in over {
		lines << '  ${o.describe()}'
	}
	reason := annotate(lines.join('\n'), [], [], [], over)
	c.witness.refuse('model.call', over.map(it.clause))
	c.refused++
	return CharterVerdict{
		allowed:   false
		reason:    reason
		source:    'ration'
		overspend: over
	}
}

// -- after the fact ----------------------------------------------------------

// settled records a call that stood, and reviews what it actually did.
//
// It returns a refusal string when post-commit review reverted the call, or
// '' when it stands. Spend and debts are recorded only for a call that
// SURVIVES review — charging a reverted write to the budget would make the
// window disagree with the tree.
pub fn (mut c Charter) settled(tool string, args map[string]json2.Any, result string, snapshot_tree string, snapshot_paths []string) string {
	if c.has_sentinel && snapshot_tree != '' {
		review := c.sentinel.review(tool, snapshot_tree, snapshot_paths)
		if !review.clean() {
			c.witness.refuse(tool, review.violations.map(it.clause))
			return review.detail
		}
	}
	c.horizon.spend(tool, args)
	c.obligations.record(tool, args)
	if result != '' {
		c.provenance.observe(tool, args, result) or {}
	}
	return ''
}

// salient is the clauses this request touches, to place at the end of the
// context.
//
// It is empty when nothing is implicated: a block announcing that no rules
// apply would be a sentence this package invented, and it would read as
// permission.
pub fn (mut c Charter) salient(request string, tools []string) string {
	if c.covenant.clauses.len == 0 {
		return ''
	}
	return salience_block(c.covenant.clauses, request, SalienceOpts{
		tools:   tools
		weights: c.feedback.weights()
	})
}

// shape checks a draft against the output contract, asking for another if it
// does not meet it. Bounded, and honest when it never does.
pub fn (mut c Charter) shape(draft string, regenerate Regenerator) Outcome {
	return c.conform.run(draft, regenerate)
}

// critique reads the draft against the prose clauses it touches.
//
// It is separate from shape(): conform decides everything a regex can, and
// this runs on what is left. A finding here is never a refusal — it becomes
// an instruction for the same bounded retry.
pub fn (mut c Charter) critique(draft string, ask AskFn) Critique {
	rules := uniq_strings(c.conform.rules.map(it.clause))
	return c.critic.review(draft, c.covenant.clauses, ask, rules, max_critic_clauses)
}

// attest_reply checks the reply's claims against the sealed record.
//
// Everything else governs what the agent DOES; this is the only thing that
// looks at what it SAYS it did, which is where a specification is most
// casually broken. It reports and never rewrites the reply.
pub fn (mut c Charter) attest_reply(reply string) Attestation {
	att := attest(reply, mut c.log)
	seal_attestation(mut c.log, &att)
	if att.contradicted().len > 0 {
		c.witness.refuse('assistant.reply', att.contradicted().map('claim:${it.kind}'))
	}
	return att
}

pub fn (mut c Charter) open_turn() {
	c.horizon.open_turn()
	c.ration.open_turn()
}

// -- done, as distinct from allowed -------------------------------------------

// blocker is why the work cannot be called finished, or ''.
//
// Obligations and `after` rules never refuse a step: the act that discharges
// them is itself a step. They refuse DONE.
pub fn (mut c Charter) blocker() string {
	mut live := []string{}
	for part in [c.obligations.blocker(), c.sequence.blocker()] {
		if part != '' {
			live << part
		}
	}
	return live.join('\n')
}

// -- observation --------------------------------------------------------------

// errors is every malformed rule across every subsystem, in one list — a rule
// that enforces nothing is invisible unless someone looks.
pub fn (c &Charter) errors() []string {
	mut out := []string{}
	out << c.covenant.errors
	out << c.sequence.errors
	out << c.provenance.errors
	out << c.egress.errors
	out << c.horizon.errors
	out << c.ration.errors
	out << c.exemptions.errors
	out << c.obligations.errors
	out << c.conform.errors
	return out
}

pub fn (mut c Charter) report() string {
	mut blocks := [
		c.integrity.verify(c.spec, c.covenant, c.spec_source).describe(),
		c.sanctum.report(),
		'charter: ${c.allowed} allowed · ${c.refused} refused',
		c.covenant.report(),
		c.sequence.report(),
		c.provenance.report(),
		c.egress.report(),
		c.horizon.report(),
		c.ration.report(),
		c.exemptions.report(),
		c.consent.report(),
		c.obligations.report(),
		c.conform.report(),
		c.critic.report(),
		c.feedback.report(),
		c.witness.report([], false),
	]
	errs := c.errors()
	if errs.len > 0 {
		blocks << 'malformed rules (these enforce NOTHING):\n' +
			errs.map('  !! ${it}').join('\n')
	}
	blocker := c.blocker()
	if blocker != '' {
		blocks << blocker
	}
	return blocks.join('\n\n')
}
