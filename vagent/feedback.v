module vagent

import math
import x.json2

// feedback.v — the measurement is allowed to change the delivery.
//
// adherence.v produces a number per clause. Without this, nothing reads it:
// the system can say "clause [OUT] holds 33% of the time" and then deliver
// the specification on the next turn exactly as before, having learned
// nothing. A measurement nothing acts on is a report, and this project had
// too many of those already.
//
// Closing the loop is the point, and the mechanism has to be narrow or it
// becomes a second author of the specification. So exactly one thing moves:
//
//     WHICH clauses salience.v restates at the end of the context.
//
// That is it. No clause is rewritten, reworded, strengthened, softened,
// dropped or reordered, and the specification is still delivered whole and
// verbatim every time. What changes is which of the author's own sentences
// get the second, high-attention position — and the ones that get it are the
// ones measurement says are being missed.
//
//     [OUT]  33% followed  ->  weight 1.8   restated first, almost always
//     [SQL] 100% followed  ->  weight 0.7   already held; give the room to
//                                           something that needs it
//
// The asymmetry is deliberate. Attention at the end of the context is a
// fixed budget: every clause that takes a slot denies it to another.
// Spending it on rules the model already follows is the one certain waste.
//
// WHAT KEEPS THIS FROM DRIFTING:
//
//   * BOUNDED. Weights are clamped. A clause that keeps failing rises to a
//     ceiling and stops; a rule that is never followed usually needs
//     rewriting by a person, not more prominence.
//   * EVIDENCE-GATED. A weight moves only on a real measurement with a
//     minimum number of probes. One bad turn is not evidence.
//   * DECAYING. Old measurements lose influence, so a clause fixed last
//     week stops being treated as broken.
//   * REVERSIBLE AND VISIBLE. Every weight is folded from sealed events, so
//     it can be read, explained and reset.
//   * IT NEVER SUPPRESSES. The floor is above zero: a well-followed clause
//     is deprioritised, never removed. Measurement can be wrong, and a rule
//     dropped because it looked fine is a rule nobody is watching.

pub const min_probes = 3
pub const feedback_floor = 0.6
pub const feedback_ceiling = 2.0
pub const feedback_half_life = 7.0 * 86_400.0

pub struct Observation {
pub:
	clause   string
	followed int
	probes   int
	at       f64
}

pub fn (o &Observation) rate() f64 {
	return if o.probes > 0 { f64(o.followed) / f64(o.probes) } else { 1.0 }
}

pub fn (o &Observation) to_json() map[string]json2.Any {
	return {
		'clause':   json2.Any(o.clause)
		'followed': json2.Any(o.followed)
		'probes':   json2.Any(o.probes)
		'at':       json2.Any(o.at)
	}
}

// feedback_decay is how much a measurement of this age still counts.
pub fn feedback_decay(age f64) f64 {
	if age <= 0 {
		return 1.0
	}
	return math.pow(0.5, age / feedback_half_life)
}

@[heap]
pub struct Feedback {
pub mut:
	log &EventLog
}

pub fn new_feedback(log &EventLog) &Feedback {
	return &Feedback{
		log: unsafe { log }
	}
}

// -- recording ---------------------------------------------------------------

// observe seals an adherence report and returns how many clauses it recorded.
//
// Only MEASURED clauses are recorded. An unscorable clause produced no
// evidence, and treating "could not be checked" as "followed" would quietly
// deprioritise every prose rule in the specification — which is most of it.
pub fn (mut f Feedback) observe(report &AdherenceReport) int {
	mut n := 0
	now := now_ts()
	for score in report.measured() {
		probes := score.scorable().len
		if probes < min_probes {
			continue
		}
		obs := Observation{
			clause:   score.clause
			followed: score.followed()
			probes:   probes
			at:       now
		}
		f.log.append('feedback.observed', obs.to_json(), AppendOpts{ actor: 'kernel' })
		n++
	}
	return n
}

// reset discards the influence of every past measurement.
pub fn (mut f Feedback) reset() {
	f.log.append('feedback.reset', map[string]json2.Any{}, AppendOpts{ actor: 'human' })
}

// -- the fold ----------------------------------------------------------------

pub fn (mut f Feedback) observations() []Observation {
	mut out := []Observation{}
	for ev in f.log.events(f.log.branch) {
		match ev.typ {
			'feedback.reset' {
				out = []Observation{}
			}
			'feedback.observed' {
				out << Observation{
					clause:   jstr(ev.data, 'clause')
					followed: jint(ev.data, 'followed')
					probes:   jint(ev.data, 'probes')
					at:       jf64(ev.data, 'at')
				}
			}
			else {}
		}
	}
	return out
}

// rates is the decay-weighted adherence rate per clause.
pub fn (mut f Feedback) rates() map[string]f64 {
	now := now_ts()
	mut num := map[string]f64{}
	mut den := map[string]f64{}
	for o in f.observations() {
		w := feedback_decay(now - o.at) * f64(o.probes)
		if w <= 0 {
			continue
		}
		num[o.clause] = num[o.clause] + o.rate() * w
		den[o.clause] = den[o.clause] + w
	}
	mut out := map[string]f64{}
	for c, n in num {
		d := den[c]
		if d > 0 {
			out[c] = n / d
		}
	}
	return out
}

// weights is the salience multiplier per clause: worse adherence, more
// prominence. Linear between the floor and the ceiling, so the mapping is
// explainable without reading this code — 100% followed sits at the floor,
// 0% at the ceiling.
pub fn (mut f Feedback) weights() map[string]f64 {
	mut out := map[string]f64{}
	for c, rate in f.rates() {
		out[c] = round_to(feedback_ceiling - (feedback_ceiling - feedback_floor) * rate,
			3)
	}
	return out
}

pub fn (mut f Feedback) weight(clause_id string) f64 {
	w := f.weights()
	return if clause_id in w { w[clause_id] } else { 1.0 }
}

// -- observation -------------------------------------------------------------

pub fn (mut f Feedback) report() string {
	rates := f.rates()
	if rates.len == 0 {
		return 'feedback: no measurement yet — every clause is weighted equally (run /enforce adherence)'
	}
	weights := f.weights()
	days := feedback_half_life / 86400.0
	mut lines := [
		'feedback: ${rates.len} clause(s) measured · weights ${feedback_floor}–${feedback_ceiling}, half-life ${days:.0f}d',
	]
	mut clauses := rates.keys()
	clauses.sort_with_compare(fn [rates] (a &string, b &string) int {
		ra := rates[*a]
		rb := rates[*b]
		if ra < rb {
			return -1
		}
		if ra > rb {
			return 1
		}
		return compare_strings(a, b)
	})
	for c in clauses {
		w := weights[c]
		bar := if w > 1.05 { 'boosted' } else if w < 0.95 { 'eased' } else { 'neutral' }
		lines << '  ' + pad_width(c, 14) + pad_left('${rates[c] * 100.0:.0f}%', 5) +
			' followed  weight ' + pad_left('${w:.2f}', 5) + '  ' + bar
	}
	lines << '  only WHICH clauses are restated changes; the specification is delivered whole and unedited'
	return lines.join('\n')
}
