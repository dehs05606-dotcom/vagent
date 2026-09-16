module vagent

import math
import x.json2

// causal.v — causal discovery and do()-interventions from the event log.
//
// Correlation says web_search and success move together; causation says
// USING web_search CHANGES success. This tells them apart, from the agent's
// own history:
//
//   features    every turn becomes one observation: mechanical features
//               (used the web? how many tools, how many writes, how many
//               errors) and an outcome
//   discovery   pairwise association is TESTED, not trusted: an edge
//               survives only if it holds after stratifying on the observed
//               confounders — the backdoor test, discretized. Spurious
//               links die here.
//   effect      the do(x) estimate: the stratified mean difference in the
//               outcome between x=1 and x=0 WITHIN each confounder
//               stratum, weighted by stratum size. Honest about small
//               samples: too little data is reported as unmeasured rather
//               than guessed.
//   verdict     CAUSAL (survived adjustment), SPURIOUS (died under
//               stratification), or UNMEASURED.
//
// The arithmetic is deterministic and spends no tokens.

// below this a stratum is too thin to trust
const min_stratum = 3
// below this nothing is claimed at all
const min_total_obs = 12

// pearson is the correlation coefficient, and 0 for degenerate input.
pub fn pearson(xs []f64, ys []f64) f64 {
	n := min_int(xs.len, ys.len)
	if n < 2 {
		return 0.0
	}
	mut sx := 0.0
	mut sy := 0.0
	for i in 0 .. n {
		sx += xs[i]
		sy += ys[i]
	}
	mx := sx / f64(n)
	my := sy / f64(n)
	mut num := 0.0
	mut dxx := 0.0
	mut dyy := 0.0
	for i in 0 .. n {
		dx := xs[i] - mx
		dy := ys[i] - my
		num += dx * dy
		dxx += dx * dx
		dyy += dy * dy
	}
	den := math.sqrt(dxx * dyy)
	return if den != 0 { num / den } else { 0.0 }
}

// CausalObservation is one turn distilled into features and an outcome.
//
// The original called it Observation; feedback.py has an Observation of its
// own, and this port is one flat V module.
pub struct CausalObservation {
pub:
	features map[string]f64
	// 0..1 success
	outcome f64
}

pub struct CausalEdge {
pub:
	cause string
	// always the outcome variable
	effect      string
	association f64
	// the effect after backdoor adjustment
	adjusted f64
	// CAUSAL | SPURIOUS | UNMEASURED
	verdict string
	n       int
}

pub fn (e &CausalEdge) to_json() map[string]json2.Any {
	return {
		'cause':           json2.Any(e.cause)
		'association':     json2.Any(round_to(e.association, 3))
		'adjusted_effect': json2.Any(round_to(e.adjusted, 3))
		'verdict':         json2.Any(e.verdict)
		'n':               json2.Any(e.n)
	}
}

struct CausalTurn {
mut:
	web        f64
	tools      f64
	writes     f64
	errors     f64
	outcome    f64
	has_score  bool
}

// observations_from_log folds turns into observations. The features are
// mechanical; the outcome is the scorecard when there is one, and derived
// from whether the turn errored when there is not.
pub fn observations_from_log(mut log EventLog) []CausalObservation {
	mut turns := []CausalTurn{}
	mut current := CausalTurn{}
	mut open := false
	for ev in log.events(log.branch) {
		if ev.typ == 'user.message' {
			if open {
				turns << current
			}
			current = CausalTurn{}
			open = true
			continue
		}
		if !open {
			continue
		}
		match ev.typ {
			'tool.call' {
				current.tools += 1.0
				name := jstr(ev.data, 'name')
				if name == 'web_search' || name == 'web_fetch' {
					current.web = 1.0
				}
				if name == 'write_file' || name == 'edit_file' {
					current.writes += 1.0
				}
			}
			'tool.result' {
				if jstr(ev.data, 'status') == 'error' {
					current.errors += 1.0
				}
			}
			'turn.scorecard' {
				current.outcome = jf64(ev.data, 'score') / 100.0
				current.has_score = true
			}
			else {}
		}
	}
	if open {
		turns << current
	}

	mut out := []CausalObservation{}
	for t in turns {
		mut outcome := t.outcome
		if !t.has_score {
			outcome = if t.errors == 0 && t.tools > 0 {
				1.0
			} else if t.errors == 0 {
				0.4
			} else {
				0.0
			}
		}
		out << CausalObservation{
			features: {
				'web':    t.web
				'tools':  min_f64(t.tools, 20.0) / 20.0
				'writes': min_f64(t.writes, 10.0) / 10.0
				'errors': min_f64(t.errors, 5.0) / 5.0
			}
			outcome:  outcome
		}
	}
	return out
}

@[heap]
pub struct CausalEngine {
pub mut:
	log &EventLog
}

pub fn new_causal_engine(log &EventLog) &CausalEngine {
	return &CausalEngine{
		log: unsafe { log }
	}
}

// -- the backdoor test --------------------------------------------------------

// strata splits observations by (cause bin, confounder quartiles).
//
// Quartile bins hold a continuous confounder tightly enough that its
// residual cannot masquerade as the cause.
fn strata_of(obs []CausalObservation, cause string, confounders []string) map[string][]CausalObservation {
	mut quartiles := map[string][]f64{}
	for c in confounders {
		mut vals := obs.map(it.features[c] or { 0.0 })
		vals.sort()
		if vals.len == 0 {
			quartiles[c] = [0.0, 0.0, 0.0]
			continue
		}
		quartiles[c] = [vals[vals.len / 4], vals[vals.len / 2], vals[3 * vals.len / 4]]
	}
	mut out := map[string][]CausalObservation{}
	for o in obs {
		mut key := []string{}
		for c in confounders {
			v := o.features[c] or { 0.0 }
			q := quartiles[c]
			bin := if v <= q[0] {
				0
			} else if v <= q[1] {
				1
			} else if v <= q[2] {
				2
			} else {
				3
			}
			key << bin.str()
		}
		cause_bin := if (o.features[cause] or { 0.0 }) > 0.5 { 1 } else { 0 }
		full := '${cause_bin}|' + key.join(',')
		out[full] << o
	}
	return out
}

// effect is the discrete backdoor-adjusted effect of `cause` on the outcome,
// with the number of usable observations behind it.
pub fn (mut e CausalEngine) effect(obs []CausalObservation, cause string, confounders []string, has_confounders bool) (f64, int) {
	if obs.len < min_total_obs {
		return 0.0, 0
	}
	mut features_seen := map[string]bool{}
	for o in obs {
		for k, _ in o.features {
			features_seen[k] = true
		}
	}
	mut candidates := if has_confounders {
		confounders.filter(it != cause)
	} else {
		mut keys := features_seen.keys()
		keys.sort()
		keys.filter(it != cause)
	}

	// adjust on the two most strongly associated confounders — enough to
	// kill common confounding without fragmenting the strata
	mut chosen := []string{}
	if candidates.len > 0 {
		ys := obs.map(it.outcome)
		mut scored := []Scored2{}
		for c in candidates {
			xs := obs.map(if (it.features[c] or { 0.0 }) > 0.5 { 1.0 } else { 0.0 })
			scored << Scored2{
				name:  c
				score: math_abs(pearson(xs, ys))
			}
		}
		scored.sort(a.score > b.score)
		for s in scored[..min_int(2, scored.len)] {
			if s.score > 0.1 {
				chosen << s.name
			}
		}
	}

	strata := if chosen.len > 0 {
		strata_of(obs, cause, chosen)
	} else {
		mut simple := map[string][]CausalObservation{}
		for o in obs {
			bin := if (o.features[cause] or { 0.0 }) > 0.5 { 1 } else { 0 }
			simple['${bin}|'] << o
		}
		simple
	}

	// BACKDOOR ADJUSTMENT — compare WITHIN each stratum, then weight by
	// stratum size. Pooling the arms across strata would smuggle the
	// confounder straight back in, which is Simpson's paradox.
	mut on_arms := map[string][]CausalObservation{}
	mut off_arms := map[string][]CausalObservation{}
	for key, group in strata {
		bin := key.all_before('|')
		ckey := key.all_after('|')
		if bin == '1' {
			on_arms[ckey] << group
		} else {
			off_arms[ckey] << group
		}
	}
	mut effect_sum := 0.0
	mut weight_sum := 0
	mut usable := 0
	for ckey, on in on_arms {
		off := off_arms[ckey] or { []CausalObservation{} }
		if on.len < 2 || off.len < 2 {
			// an arm too thin to compare
			continue
		}
		mut on_total := 0.0
		for o in on {
			on_total += o.outcome
		}
		mut off_total := 0.0
		for o in off {
			off_total += o.outcome
		}
		n_stratum := on.len + off.len
		diff := on_total / f64(on.len) - off_total / f64(off.len)
		effect_sum += f64(n_stratum) * diff
		weight_sum += n_stratum
		usable += n_stratum
	}
	if weight_sum < min_total_obs {
		return 0.0, 0
	}
	return effect_sum / f64(weight_sum), usable
}

struct Scored2 {
	name  string
	score f64
}

// -- discovery ----------------------------------------------------------------

// discover tests every feature against the outcome and classifies each by
// whether its association survives adjustment.
pub fn (mut e CausalEngine) discover(obs []CausalObservation, has_obs bool) []CausalEdge {
	observations := if has_obs { obs.clone() } else { observations_from_log(mut e.log) }
	if observations.len == 0 {
		return []
	}
	ys := observations.map(it.outcome)
	mut seen := map[string]bool{}
	for o in observations {
		for k, _ in o.features {
			seen[k] = true
		}
	}
	mut causes := seen.keys()
	causes.sort()

	mut edges := []CausalEdge{}
	for cause in causes {
		xs := observations.map(it.features[cause] or { 0.0 })
		association := pearson(xs, ys)
		if math_abs(association) < 0.08 {
			// nothing to explain
			continue
		}
		adjusted, usable := e.effect(observations, cause, [], false)
		verdict := if usable == 0 {
			'UNMEASURED'
		} else if (association > 0) == (adjusted > 0) && math_abs(adjusted) >= 0.05 {
			'CAUSAL'
		} else {
			'SPURIOUS'
		}
		edge := CausalEdge{
			cause:       cause
			effect:      'outcome'
			association: association
			adjusted:    adjusted
			verdict:     verdict
			n:           observations.len
		}
		edges << edge
		e.log.append('causal.edge', edge.to_json(), AppendOpts{})
	}
	edges.sort_with_compare(fn (a &CausalEdge, b &CausalEdge) int {
		x := math_abs(a.adjusted)
		y := math_abs(b.adjusted)
		if x > y {
			return -1
		}
		if x < y {
			return 1
		}
		return 0
	})
	return edges
}

// do estimates the effect of FORCING a cause on or off.
pub fn (mut e CausalEngine) do_intervention(cause string, enable bool) map[string]json2.Any {
	obs := observations_from_log(mut e.log)
	effect, usable := e.effect(obs, cause, [], false)
	sign := if enable { effect } else { -effect }
	report := {
		'intervention':              json2.Any(cause)
		'set_to':                    json2.Any(if enable { 1 } else { 0 })
		'estimated_outcome_change':  json2.Any(round_to(sign, 4))
		'usable_observations':       json2.Any(usable)
		'trustworthy':               json2.Any(usable >= 2 * min_stratum)
	}
	e.log.append('causal.intervention', report, AppendOpts{})
	return report
}

pub fn (e &CausalEngine) format(edges []CausalEdge) string {
	if edges.len == 0 {
		return 'not enough history for causal analysis yet'
	}
	mut lines := ['CAUSAL ANALYSIS — outcome: turn success',
		'  cause      association  adjusted  verdict']
	for edge in edges {
		lines << '  ' + pad_width(edge.cause, 10) +
			' ${edge.association:+.2f}        ${edge.adjusted:+.2f}      ${edge.verdict} (n=${edge.n})'
	}
	return lines.join('\n')
}
