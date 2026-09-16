module vagent

import x.json2

fn preds(names []string) map[string]bool {
	mut out := map[string]bool{}
	for n in names {
		out[n] = true
	}
	return out
}

fn tr(steps [][]string) []map[string]bool {
	return steps.map(preds(it))
}

fn violated_by(r &VerificationResult, property string) bool {
	for v in r.violations {
		if v.property == property {
			return true
		}
	}
	return false
}

fn test_a_clean_trace_satisfies_the_whole_constitution() {
	mut log := new_event_log(tmp_log_path('for1'), 'main', 'test')
	mut mc := new_constitutional_checker(log)
	r := mc.verify_trace(tr([['snapshot'], ['write'], ['verify'], ['read']]), 'clean')
	assert r.ok, r.violations.map(it.why).str()
	assert r.checked == 1
	// a satisfied trace seals nothing: there is nothing to report
	assert log.head('main') == -1
}

fn test_a_naked_write_is_caught_with_its_counterexample() {
	mut log := new_event_log(tmp_log_path('for2'), 'main', 'test')
	mut mc := new_constitutional_checker(log)
	r := mc.verify_trace(tr([['write'], ['verify']]), 'naked')
	assert !r.ok
	assert violated_by(&r, 'before(write, snapshot)')
	// the verdict names the position, not just the rule
	assert r.violations[0].why.contains('without prior'), r.violations[0].why
	assert r.violations[0].why.contains('position 0')
	assert r.violations[0].trace == 'naked'
	// and a counterexample is sealed
	assert 'verify.violation' in log.events('main').map(it.typ)

	// a delete is held to the same rule
	assert mc.verify_trace(tr([['delete']]), 'del').violations.len > 0
}

fn test_two_writes_without_a_verify_between_them_are_refused() {
	mut log := new_event_log(tmp_log_path('for3'), 'main', 'test')
	mut mc := new_constitutional_checker(log)
	r := mc.verify_trace(tr([['snapshot'], ['write'], ['write'], ['verify']]), 'double')
	assert violated_by(&r, 'writes_serialise'), r.violations.map(it.property).str()
	// a verify between them clears it
	ok := mc.verify_trace(tr([['snapshot'], ['write'], ['verify'], ['snapshot'], ['write'],
		['verify']]), 'serial')
	assert ok.ok, ok.violations.map(it.why).str()
}

fn test_a_write_that_is_never_verified_fails_liveness() {
	mut log := new_event_log(tmp_log_path('for4'), 'main', 'test')
	mut mc := new_constitutional_checker(log)
	// nothing bad has happened yet, which is exactly the point of a
	// liveness property: the trace ends with the write unaccounted for
	r := mc.verify_trace(tr([['snapshot'], ['write']]), 'liveness')
	assert violated_by(&r, 'always_after(write, verify)')
	assert r.violations.map(it.why).filter(it.contains('never followed by verify')).len == 1
}

fn test_always_between_requires_a_marker_in_the_gap() {
	mut log := new_event_log(tmp_log_path('for5'), 'main', 'test')
	mut mc := new_model_checker(log, [Property(AlwaysBetween{'snapshot', 'turn'})])
	bad := mc.verify_trace(tr([['turn'], ['write'], ['turn']]), 'gap')
	assert !bad.ok
	assert bad.violations[0].why.contains('positions 0..2'), bad.violations[0].why

	good := mc.verify_trace(tr([['turn'], ['snapshot'], ['turn']]), 'gap')
	assert good.ok
	// a single marker has no gap to check
	assert mc.verify_trace(tr([['turn']]), 'one').ok
}

fn test_a_custom_property_composes_like_the_built_ins() {
	mut log := new_event_log(tmp_log_path('for6'), 'main', 'test')
	mut strict := new_model_checker(log, [Property(Never{'pause'})])
	assert strict.verify_trace(tr([['pause']]), 't').violations.len == 1
	assert strict.verify_trace(tr([['write']]), 't').ok
	assert (Property(Never{'pause'})).name() == 'never(pause)'
}

fn test_a_kernel_shaped_plan_verifies() {
	mut log := new_event_log(tmp_log_path('for7'), 'main', 'test')
	mut mc := new_constitutional_checker(log)
	waves := [
		[PlanItem{
			task: 'read the code'
			role: 'reviewer'
		}],
		[PlanItem{
			task:  'write the fix'
			role:  'coder'
			paths: ['src/a.py']
		}],
	]
	r := mc.verify_plan(waves)
	assert r.ok, r.violations.map(it.why).str()
	assert r.checked >= 1
	assert 'verify.plan' in log.events('main').map(it.typ)

	// the kernel's mechanical snapshot and verify really are in the trace
	traces := plan_traces(waves)
	assert traces.len == 1
	flat := traces[0].map(it.keys().join('+'))
	assert flat == ['read', 'snapshot', 'write', 'verify'], flat.str()
}

fn test_the_kernels_inserted_verify_is_what_makes_serialisation_hold() {
	mut log := new_event_log(tmp_log_path('for8'), 'main', 'test')
	mut mc := new_model_checker(log, [Property(WritesSerialise{})])
	waves := [
		[
			PlanItem{
				task:  'write one'
				paths: ['a.py']
			},
			PlanItem{
				task:  'write two'
				paths: ['a.py']
			},
		],
	]
	// two writers to the same path in ONE wave is a plan the lock pass
	// would never emit, but it still satisfies write-exclusivity here,
	// because each write brings its own verify with it. The property is
	// about ordering; it is the kernel's inserted verify that makes it
	// hold, not the wave structure.
	r := mc.verify_plan(waves)
	assert r.ok, r.violations.map(it.why).str()

	// strip the verifies out and the same two writes fail immediately
	bare := mc.verify_trace(tr([['write'], ['write']]), 'bare')
	assert violated_by(&bare, 'writes_serialise')
}

fn test_a_delete_task_contributes_a_delete_rather_than_a_write() {
	waves := [
		[PlanItem{
			task:  'delete the stale fixtures'
			paths: ['fixtures/']
		}],
	]
	traces := plan_traces(waves)
	flat := traces[0].map(it.keys().join('+'))
	assert flat == ['snapshot', 'delete', 'verify'], flat.str()
}

fn test_real_history_folds_into_a_trace_and_audits() {
	mut log := new_event_log(tmp_log_path('for9'), 'main', 'test')
	log.append('snapshot.taken', {
		'tree': json2.Any('t1')
	}, AppendOpts{})
	log.append('tool.call', {
		'name': json2.Any('write_file')
		'args': json2.Any({
			'path': json2.Any('a.py')
		})
	}, AppendOpts{})
	log.append('tool.result', {
		'name':   json2.Any('write_file')
		'status': json2.Any('done')
	}, AppendOpts{})
	log.append('tool.call', {
		'name': json2.Any('delete_path')
		'args': json2.Any({
			'path': json2.Any('b.txt')
		})
	}, AppendOpts{})

	mut mc := new_constitutional_checker(log)
	audit := mc.audit_log()
	assert audit.ok, audit.violations.map(it.why).str()

	// an event carrying no predicate contributes no position
	trace := trace_from_events(log.events('main'))
	assert trace.len == 4
}

fn test_a_delete_with_no_snapshot_is_caught_in_real_history() {
	mut log := new_event_log(tmp_log_path('for10'), 'main', 'test')
	log.append('tool.call', {
		'name': json2.Any('delete_path')
		'args': json2.Any({
			'path': json2.Any('x.txt')
		})
	}, AppendOpts{})
	mut mc := new_constitutional_checker(log)
	bad := mc.audit_log()
	assert !bad.ok
	assert bad.violations.filter(it.why.contains('delete')).len == 1
	assert bad.violations[0].trace == 'history'
}

fn test_an_empty_trace_satisfies_everything_vacuously() {
	mut log := new_event_log(tmp_log_path('for11'), 'main', 'test')
	mut mc := new_constitutional_checker(log)
	r := mc.verify_trace([], 'empty')
	assert r.ok
	// and so does a plan with no waves
	assert mc.verify_plan([]).ok
}
