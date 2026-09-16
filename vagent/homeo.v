module vagent

import x.json2

// homeo.v — homeostasis: the agent that maintains itself.
//
// A body does not wait to die of a fever, it regulates. The subsystems get
// the same treatment:
//
//   vitals   mechanical measurements over a sliding window of the event
//            log — tool error rate, mean tool latency, loop alerts,
//            context churn, budget breaches
//   rules    each vital has a healthy range; a breach is a SYMPTOM with a
//            named repair
//   check    measure, repair what breached, then RE-MEASURE the vital the
//            repair was supposed to fix
//
// That last step is the point. A repair that does not move its vital is
// recorded as having had no effect: homeostasis is measured, not assumed.
//
// Repairs are injected, so the core stays pure and the tests run entirely
// offline. A symptom with no wired cure is reported and left alone — the
// system says what is wrong rather than inventing a fix.

// window is how many recent events count as "now".
pub const homeo_window = 120
pub const error_rate_max = 0.35
pub const latency_max_ms = 20_000.0
pub const loop_alerts_max = 3

pub struct Vital {
pub:
	name    string
	value   f64
	healthy bool
	unit    string
}

pub fn (v &Vital) to_json() map[string]json2.Any {
	return {
		'name':    json2.Any(v.name)
		'value':   json2.Any(round_to(v.value, 3))
		'healthy': json2.Any(v.healthy)
		'unit':    json2.Any(v.unit)
	}
}

pub struct RepairRecord {
pub:
	symptom string
	action  string
	helped  bool
	before  f64
	after   f64
}

// Repair is one wired cure. The name is carried explicitly rather than read
// off the function, because V has no `__name__` and a repair that cannot say
// what it did is not much of an audit trail.
pub struct Repair {
pub:
	action string
	run    fn () !bool = unsafe { nil }
}

pub struct CheckReport {
pub mut:
	vitals  []Vital
	repairs []RepairRecord
}

pub fn (r &CheckReport) healthy() bool {
	for v in r.vitals {
		if !v.healthy {
			return false
		}
	}
	return true
}

pub fn (r &CheckReport) format() string {
	mut bad := 0
	for v in r.vitals {
		if !v.healthy {
			bad++
		}
	}
	head := if r.healthy() { 'ALL VITALS NORMAL' } else { '${bad} SYMPTOM(S)' }
	mut lines := ['HOMEOSTASIS — ${head}']
	for v in r.vitals {
		icon := if v.healthy { '✓' } else { '✗' }
		lines << '  ${icon} ${v.name:-16} ${v.value:.3f}${v.unit}'
	}
	for rec in r.repairs {
		outcome := if rec.helped { 'helped' } else { 'NO EFFECT' }
		lines << '  🔧 ${rec.action} for ${rec.symptom} — ${outcome} (${rec.before:.2f} → ${rec.after:.2f})'
	}
	return lines.join('\n')
}

@[heap]
pub struct Homeostasis {
pub mut:
	log &EventLog
	// symptom name -> cure
	repairs     map[string]Repair
	last_report CheckReport
	has_report  bool
}

pub fn new_homeostasis(log &EventLog, repairs map[string]Repair) &Homeostasis {
	return &Homeostasis{
		log:     unsafe { log }
		repairs: repairs.clone()
	}
}

// -- vitals ------------------------------------------------------------------

pub fn (mut h Homeostasis) vitals() []Vital {
	all := h.log.events(h.log.branch)
	events := all[max_int(0, all.len - homeo_window)..]

	mut tool_results := 0
	mut errors := 0
	mut total_duration := 0.0
	mut loop_alerts := 0
	mut compactions := 0
	mut budget_breaches := 0
	for e in events {
		match e.typ {
			'tool.result' {
				tool_results++
				if jstr(e.data, 'status') == 'error' {
					errors++
				}
				total_duration += jf64(e.data, 'duration')
			}
			'loop.alert' {
				loop_alerts++
			}
			'context.compacted' {
				compactions++
			}
			'budget.event' {
				if jstr(e.data, 'kind') == 'exceeded' {
					budget_breaches++
				}
			}
			else {}
		}
	}
	error_rate := if tool_results > 0 { f64(errors) / f64(tool_results) } else { 0.0 }
	mean_ms := if tool_results > 0 { total_duration / f64(tool_results) * 1000.0 } else { 0.0 }

	return [
		Vital{
			name:    'tool_error_rate'
			value:   error_rate
			healthy: error_rate <= error_rate_max
		},
		Vital{
			name:    'tool_latency_ms'
			value:   mean_ms
			healthy: mean_ms <= latency_max_ms
			unit:    'ms'
		},
		Vital{
			name:    'loop_alerts'
			value:   f64(loop_alerts)
			healthy: loop_alerts <= loop_alerts_max
		},
		Vital{
			name:    'context_churn'
			value:   f64(compactions)
			healthy: compactions <= 10
		},
		Vital{
			name:    'budget_breaches'
			value:   f64(budget_breaches)
			healthy: budget_breaches == 0
		},
	]
}

// -- the loop ----------------------------------------------------------------

// check_and_repair is one homeostatic cycle: measure, repair what breaches,
// re-measure what was repaired.
pub fn (mut h Homeostasis) check_and_repair() CheckReport {
	mut report := CheckReport{
		vitals: h.vitals()
	}
	mut updated := report.vitals.clone()
	for i, vital in report.vitals {
		if vital.healthy {
			continue
		}
		repair := h.repairs[vital.name] or {
			// no known cure — say so rather than pretend
			continue
		}
		mut ran := false
		if !isnil(repair.run) {
			// a crashing cure is a cure that did not work, not a crashed check
			ran = repair.run() or { false }
		}
		after := h.recheck(vital.name) or { vital }
		helped := ran && after.healthy
		rec := RepairRecord{
			symptom: vital.name
			action:  repair.action
			helped:  helped
			before:  vital.value
			after:   after.value
		}
		report.repairs << rec
		h.log.append('homeo.repair', {
			'symptom': json2.Any(rec.symptom)
			'action':  json2.Any(rec.action)
			'helped':  json2.Any(rec.helped)
			'before':  json2.Any(round_to(rec.before, 3))
			'after':   json2.Any(round_to(rec.after, 3))
		}, AppendOpts{})
		updated[i] = after
	}
	report.vitals = updated
	h.last_report = report
	h.has_report = true
	h.log.append('homeo.check', {
		'healthy': json2.Any(report.healthy())
		'vitals':  json2.Any(report.vitals.map(json2.Any(it.to_json())))
		'repairs': json2.Any(report.repairs.len)
	}, AppendOpts{ actor: 'kernel' })
	return report
}

fn (mut h Homeostasis) recheck(vital_name string) ?Vital {
	for v in h.vitals() {
		if v.name == vital_name {
			return v
		}
	}
	return none
}
