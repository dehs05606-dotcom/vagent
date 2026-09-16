module vagent

import x.json2

// formal.v — temporal-logic model checking for plans and traces.
//
// Prompt advice says "always snapshot before delete"; a model checker PROVES
// it. This checks event traces — real history, or the hypothetical executions
// a plan permits — against temporal properties, and returns a formal verdict
// with a counterexample when one fails. There is no model anywhere in the
// loop.
//
// A practical LTL subset, each property a pure predicate over traces:
//
//     Never(a)              a must not occur at any position
//     Before(a, b)          every a must be preceded by a b
//     AlwaysAfter(a, b)     every a must eventually be followed by b
//     AlwaysBetween(a, b)   between two b's there must be an a — a snapshot
//                           between any write and the next turn, say
//
// A trace is a list of predicate sets. plan_traces() enumerates the concrete
// executions a compiled plan can produce, and verify_trace() checks REAL
// kernel event logs, so the same checker that gates the future audits the
// past.
//
// The default property set encodes the system's own constitution: no naked
// writes, writes serialise, and a write is always eventually verified.

// the plan-enumeration ceiling, guarding against combinatorial blow-up
const max_traces = 64

// -- properties ---------------------------------------------------------------

// Never refuses a predicate outright.
pub struct Never {
pub:
	a string
}

// Before requires every `a` to be preceded by a `b` somewhere earlier.
pub struct Before {
pub:
	a string
	b string
}

// AlwaysAfter requires every `a` to be followed by a `b` before the trace
// ends. It is a liveness property: a write that is never verified fails it
// even though nothing bad has happened yet.
pub struct AlwaysAfter {
pub:
	a string
	b string
}

// AlwaysBetween requires an `a` between any two `b` markers.
pub struct AlwaysBetween {
pub:
	a string
	b string
}

// WritesSerialise is write-exclusivity as a temporal property: no two writes
// without a verify between them.
pub struct WritesSerialise {}

pub type Property = AlwaysAfter | AlwaysBetween | Before | Never | WritesSerialise

// check returns the counterexample, or none when the trace satisfies the
// property.
pub fn (p Property) check(trace []map[string]bool) ?string {
	match p {
		Never {
			for i, s in trace {
				if s[p.a] {
					return '${p.a} occurs at position ${i}'
				}
			}
		}
		Before {
			mut seen_b := false
			for i, s in trace {
				if s[p.b] {
					seen_b = true
				}
				if s[p.a] && !seen_b {
					return '${p.a} at position ${i} without prior ${p.b}'
				}
			}
		}
		AlwaysAfter {
			for i, s in trace {
				if !s[p.a] {
					continue
				}
				mut followed := false
				for j in i + 1 .. trace.len {
					if trace[j][p.b] {
						followed = true
						break
					}
				}
				if !followed {
					return '${p.a} at position ${i} never followed by ${p.b}'
				}
			}
		}
		AlwaysBetween {
			mut last_b := -1
			for i, s in trace {
				if !s[p.b] {
					continue
				}
				if last_b >= 0 {
					mut between := false
					for j in last_b + 1 .. i {
						if trace[j][p.a] {
							between = true
							break
						}
					}
					if !between {
						return 'no ${p.a} between ${p.b} at positions ${last_b}..${i}'
					}
				}
				last_b = i
			}
		}
		WritesSerialise {
			mut unverified := false
			for i, s in trace {
				if s['verify'] {
					unverified = false
				}
				if s['write'] {
					if unverified {
						return 'write at position ${i} follows an unverified write'
					}
					unverified = true
				}
			}
		}
	}
	return none
}

pub fn (p Property) name() string {
	return match p {
		Never { 'never(${p.a})' }
		Before { 'before(${p.a}, ${p.b})' }
		AlwaysAfter { 'always_after(${p.a}, ${p.b})' }
		AlwaysBetween { 'always_between(${p.a}, ${p.b})' }
		WritesSerialise { 'writes_serialise' }
	}
}

// default_properties is the constitution, mechanically enforced on every plan.
pub fn default_properties() []Property {
	return [
		// no naked writes: the snapshot comes first, or there is nothing
		// to roll back to
		Property(Before{'write', 'snapshot'}),
		Property(Before{'delete', 'snapshot'}),
		// writes serialise
		Property(WritesSerialise{}),
		// and a write is always eventually checked
		Property(AlwaysAfter{'write', 'verify'}),
	]
}

// -- trace construction --------------------------------------------------------

const write_tool_names = ['write_file', 'edit_file', 'create_directory']

// trace_from_events folds a real kernel event stream into a predicate trace.
// An event that carries no predicate contributes no position, so the trace is
// about what happened rather than how much was logged.
pub fn trace_from_events(events []Event) []map[string]bool {
	mut trace := []map[string]bool{}
	for ev in events {
		mut preds := map[string]bool{}
		d := ev.data.clone()
		match ev.typ {
			'snapshot.taken' {
				preds['snapshot'] = true
			}
			'tool.call' {
				name := jstr(d, 'name')
				if name in write_tool_names {
					preds['write'] = true
				} else if name == 'delete_path' {
					preds['delete'] = true
				}
			}
			'tool.result' {
				name := jstr(d, 'name')
				if name in write_tool_names || name == 'delete_path' {
					preds['verify'] = true
				}
			}
			'judge.verdict' {
				preds['verify'] = true
			}
			'budget.event' {
				preds['pause'] = true
			}
			else {}
		}
		if preds.len > 0 {
			trace << preds.clone()
		}
	}
	return trace
}

// plan_traces enumerates the executions a compiled plan can produce.
//
// Each item contributes its own predicates plus the snapshot and verify the
// kernel would mechanically insert around a write. Only ONE representative
// ordering per wave is enumerated today — the items in a wave are
// independent by construction, so their order cannot change which predicates
// appear — and the trace count is capped so that adding richer orderings
// later cannot blow the checker up.
pub fn plan_traces(waves [][]PlanItem) [][]map[string]bool {
	mut per_wave := [][][]map[string]bool{}
	for wave in waves {
		mut seq := []map[string]bool{}
		for item in wave {
			writer := item.paths.len > 0
			if writer {
				seq << {
					'snapshot': true
				}
			}
			mut kind := if writer {
				{
					'write': true
				}
			} else {
				{
					'read': true
				}
			}
			if item.task.to_lower().starts_with('delete') {
				kind = {
					'delete': true
				}
			}
			seq << kind.clone()
			if writer {
				seq << {
					'verify': true
				}
			}
		}
		per_wave << [seq]
	}

	mut traces := [][]map[string]bool{len: 1}
	for variants in per_wave {
		mut next := [][]map[string]bool{}
		for t in traces {
			for v in variants {
				mut joined := t.clone()
				joined << v
				next << joined
			}
		}
		traces = next.clone()
		if traces.len > max_traces {
			traces = traces[..max_traces].clone()
		}
	}
	return traces
}

// -- the checker ----------------------------------------------------------------

pub struct TraceViolation {
pub:
	property string
	trace    string
	why      string
}

pub fn (v &TraceViolation) to_json() map[string]json2.Any {
	return {
		'property': json2.Any(v.property)
		'trace':    json2.Any(v.trace)
		'why':      json2.Any(v.why)
	}
}

pub struct VerificationResult {
pub mut:
	ok bool
	// traces examined
	checked    int
	violations []TraceViolation
}

pub fn (r &VerificationResult) to_json() map[string]json2.Any {
	return {
		'ok':         json2.Any(r.ok)
		'checked':    json2.Any(r.checked)
		'violations': json2.Any(r.violations.map(json2.Any(it.to_json())))
	}
}

@[heap]
pub struct ModelChecker {
pub mut:
	log        &EventLog
	properties []Property
}

pub fn new_model_checker(log &EventLog, properties []Property) &ModelChecker {
	return &ModelChecker{
		log:        unsafe { log }
		properties: properties.clone()
	}
}

// new_constitutional_checker is the checker armed with the default property
// set — the system's own constitution.
pub fn new_constitutional_checker(log &EventLog) &ModelChecker {
	return new_model_checker(log, default_properties())
}

pub fn (mut m ModelChecker) verify_trace(trace []map[string]bool, label string) VerificationResult {
	mut violations := []TraceViolation{}
	for prop in m.properties {
		why := prop.check(trace) or { continue }
		violations << TraceViolation{
			property: prop.name()
			trace:    label
			why:      why
		}
	}
	if violations.len > 0 {
		m.log.append('verify.violation', {
			'label':      json2.Any(label)
			'violations': json2.Any(violations.map(json2.Any(it.to_json())))
		}, AppendOpts{})
	}
	return VerificationResult{
		ok:         violations.len == 0
		checked:    1
		violations: violations
	}
}

// verify_plan requires EVERY execution the plan permits to satisfy every
// property. A single counterexample rejects the plan.
pub fn (mut m ModelChecker) verify_plan(waves [][]PlanItem) VerificationResult {
	traces := plan_traces(waves)
	mut all_violations := []TraceViolation{}
	for i, tr in traces {
		r := m.verify_trace(tr, 'plan-trace-${i}')
		all_violations << r.violations
	}
	result := VerificationResult{
		ok:         all_violations.len == 0
		checked:    traces.len
		violations: all_violations
	}
	m.log.append('verify.plan', result.to_json(), AppendOpts{})
	return result
}

// audit_log checks the REAL history: did the system itself ever violate its
// own constitution?
pub fn (mut m ModelChecker) audit_log() VerificationResult {
	trace := trace_from_events(m.log.events(m.log.branch))
	return m.verify_trace(trace, 'history')
}
