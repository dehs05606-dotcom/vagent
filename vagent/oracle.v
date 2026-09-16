module vagent

import os
import x.json2

// oracle.v — self-improvement (§21).
//
// No model training, no fine-tuning. Improvement through structured
// accumulated experience mined from the event log corpus.
//
//   * analyze()     — post-run report: wasted steps, dead ends hit, facts
//                     learned, calibration error, cost by clause.
//   * calibrate()   — estimated vs actual per node kind; the planner's
//                     forecasts converge because every forecast is recorded.
//   * learn_fact()  — extract project facts into memory/facts.md
//                     (human-readable, git-trackable).
//   * constitution  — a user-editable standing-rules file always present in
//                     L0. Human-authored, human-owned, NEVER auto-modified;
//                     the Oracle may only PROPOSE an amendment.

pub struct OracleReport {
pub:
	events            int
	tool_calls        int
	tool_errors       int
	wasted_steps      int
	dead_ends_hit     int
	facts_learned     int
	cost_usd          f64
	cost_by_clause    map[string]f64
	calibration_error f64
	has_calibration   bool
	verdicts          int
	loop_alerts       int
}

pub struct Calibration2 {
pub:
	n              int
	mean_abs_error f64
	has_error      bool
	by_kind        map[string]f64
}

// Oracle is post-run analysis + calibration + facts + constitution.
pub struct Oracle {
pub mut:
	log        &EventLog
	memory_dir string
}

pub fn new_oracle(log &EventLog, memory_dir string) Oracle {
	if memory_dir != '' {
		os.mkdir_all(memory_dir) or {}
	}
	return Oracle{
		log:        unsafe { log }
		memory_dir: memory_dir
	}
}

// -- post-run analysis (§24.1) ----------------------------------------------

// analyze mines the current session's log into a structured report.
pub fn (mut o Oracle) analyze() OracleReport {
	st := fold(mut o.log, '')
	events := o.log.events('')
	mut wasted := 0
	mut cost_by_clause := map[string]f64{}
	mut unattributed_usd := 0.0

	for ev in events {
		if ev.typ == 'tool.result' && jstr(ev.data, 'status') == 'error' {
			wasted++
		}
		if ev.typ != 'cost.incurred' {
			continue
		}
		usd := jf64(ev.data, 'usd')
		if cid := ev.correlation_id {
			cost_by_clause[cid] = (cost_by_clause[cid] or { 0.0 }) + usd
		} else {
			// keep the unattributed tail visible instead of dropping it on
			// the floor — without this sentinel the report claims cost_usd
			// equals the sum of cost_by_clause, which is a lie whenever any
			// cost event has no correlation_id (a preflight probe, an idle
			// tick)
			unattributed_usd += usd
		}
	}
	if unattributed_usd > 0 {
		cost_by_clause['__unattributed__'] = unattributed_usd
	}
	cal := o.calibrate()
	return OracleReport{
		events:            o.log.len()
		tool_calls:        st.tool_calls
		tool_errors:       st.tool_errors
		wasted_steps:      wasted
		dead_ends_hit:     st.dead_ends.len
		facts_learned:     st.facts.len
		cost_usd:          st.cost_usd
		cost_by_clause:    cost_by_clause
		calibration_error: cal.mean_abs_error
		has_calibration:   cal.has_error
		verdicts:          st.verdicts.len
		loop_alerts:       st.loop_alerts.len
	}
}

pub fn (mut o Oracle) format_report() string {
	a := o.analyze()
	mut lines := [
		'ORACLE — post-run analysis',
		'  events ${a.events}   tool calls ${a.tool_calls}   errors ${a.tool_errors}',
		'  wasted steps ${a.wasted_steps}   dead ends hit ${a.dead_ends_hit}   ' +
		'facts learned ${a.facts_learned}',
		'  cost \$${a.cost_usd:.4f}   verdicts ${a.verdicts}   loop alerts ${a.loop_alerts}',
	]
	if a.cost_by_clause.len > 0 {
		lines << '  cost by clause:'
		mut ids := a.cost_by_clause.keys()
		ids.sort()
		for cid in ids {
			lines << '    ${cid}: \$${a.cost_by_clause[cid]:.4f}'
		}
	}
	if a.has_calibration {
		lines << '  calibration mean abs error: ${a.calibration_error:.2f}'
	}
	return lines.join('\n')
}

// -- calibration (§24.2) ------------------------------------------------------

// calibrate compares estimated vs actual per node kind. Real
// self-improvement without training: the system's PREDICTIONS get
// measurably better because it has a ground-truth record of every
// prediction it made.
pub fn (mut o Oracle) calibrate() Calibration2 {
	samples := fold(mut o.log, '').calibration
	if samples.len == 0 {
		return Calibration2{}
	}
	mut total := 0.0
	mut by_kind_sum := map[string]f64{}
	mut by_kind_n := map[string]int{}
	for s in samples {
		err := math_abs_f(jf64(s, 'est') - jf64(s, 'actual'))
		total += err
		mut kind := jstr(s, 'kind')
		if kind == '' {
			kind = '?'
		}
		by_kind_sum[kind] = (by_kind_sum[kind] or { 0.0 }) + err
		by_kind_n[kind] = (by_kind_n[kind] or { 0 }) + 1
	}
	mut by_kind := map[string]f64{}
	for k, sum in by_kind_sum {
		by_kind[k] = sum / f64(by_kind_n[k] or { 1 })
	}
	return Calibration2{
		n:              samples.len
		mean_abs_error: total / f64(samples.len)
		has_error:      true
		by_kind:        by_kind
	}
}

fn math_abs_f(x f64) f64 {
	return if x < 0 { -x } else { x }
}

pub fn (mut o Oracle) record_calibration(kind string, est f64, actual f64) {
	o.log.append('calibration.sample', {
		'kind':   json2.Any(kind)
		'est':    json2.Any(est)
		'actual': json2.Any(actual)
	}, AppendOpts{ actor: 'oracle' })
}

// -- facts (§24.1) -------------------------------------------------------------

pub fn (mut o Oracle) learn_fact(fact string, kind string) {
	o.log.append('fact.learned', {
		'fact': json2.Any(fact)
		'kind': json2.Any(if kind != '' { kind } else { 'project' })
	}, AppendOpts{ actor: 'oracle' })
}

// write_facts_md writes learned facts to memory/facts.md — human-readable
// and git-trackable. Returns the path, or '' when there is no memory dir.
pub fn (mut o Oracle) write_facts_md() string {
	if o.memory_dir == '' {
		return ''
	}
	facts := fold(mut o.log, '').facts
	path := os.join_path(o.memory_dir, 'facts.md')
	mut lines := ['# Learned project facts', '',
		'_Machine-written by the Oracle. Human-editable._', '']
	for f in facts {
		mut kind := jstr(f, 'kind')
		if kind == '' {
			kind = 'project'
		}
		lines << '- [${kind}] ${jstr(f, "fact")}'
	}
	atomic_write_text(path, lines.join('\n') + '\n') or { return '' }
	return path
}

// -- constitution (§24.4) --------------------------------------------------------

pub fn (o &Oracle) constitution_path() string {
	if o.memory_dir == '' {
		return ''
	}
	return os.join_path(os.dir(o.memory_dir), 'constitution.md')
}

// read_constitution returns the standing-rules file, always present in L0,
// or '' when it does not exist yet.
pub fn (o &Oracle) read_constitution() string {
	p := o.constitution_path()
	if p == '' {
		return ''
	}
	return read_text_or_empty(p)
}

// propose_constitution_amendment lets the Oracle PROPOSE an amendment; only
// a human may accept it. The proposal is sealed as an event, never applied
// to the file.
pub fn (mut o Oracle) propose_constitution_amendment(text string) string {
	o.log.append('goal.amendment', {
		'kind':      json2.Any('CONSTITUTION')
		'rationale': json2.Any(text)
		'verdict':   json2.Any('pending')
	}, AppendOpts{ actor: 'oracle' })
	return 'proposed (pending human approval)'
}
