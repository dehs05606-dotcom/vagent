module vagent

import x.json2

fn draft_item(task string, role string, paths []string, deps []int) json2.Any {
	mut d := {
		'task': json2.Any(task)
		'role': json2.Any(role)
	}
	if paths.len > 0 {
		d['paths'] = json2.Any(strs_to_any(paths))
	}
	d['depends_on'] = json2.Any(deps.map(json2.Any(it)))
	return json2.Any(d)
}

// the fixture draft is deliberately hostile: a duplicate, two malformed
// entries, a dead dependency and a transitively dead one
fn messy_draft(goal string) []json2.Any {
	return [
		draft_item('Map the module graph', 'architect', [], []),
		// a duplicate of #0 once the task is normalised
		draft_item('map the MODULE graph!!', 'architect', [], []),
		draft_item('', 'coder', [], []),
		json2.Any('not an object'),
		draft_item('Fix the parser bug', 'debugger', [], [0]),
		draft_item('Apply the fix', 'coder', ['src/parser.py'], [4]),
		draft_item('Write parser docs', 'documenter', ['src/parser.py'], [5]),
		// a dependency on an index the draft never produced
		draft_item('Run the test suite', 'tester', [], [99]),
		draft_item('Orphan work', 'analyst', [], [7]),
	]
}

fn empty_draft(goal string) []json2.Any {
	return []
}

fn cyclic_draft(goal string) []json2.Any {
	return [
		draft_item('a', 'coder', [], [1]),
		draft_item('b', 'coder', [], [0]),
		draft_item('c', 'tester', [], []),
	]
}

__global (
	executed_waves [][]PlanItem
)

fn recording_executor(wave []PlanItem) []map[string]json2.Any {
	executed_waves << wave.clone()
	return wave.map(map[string]json2.Any{}({
		'task':   json2.Any(it.task)
		'role':   json2.Any(it.role)
		'status': json2.Any('done')
	}))
}

fn wave_of(plan &CompiledPlan, task string) int {
	for it in plan.items() {
		if it.task == task {
			return it.wave
		}
	}
	return -1
}

fn test_the_optimizer_drops_duplicates_and_malformed_entries() {
	mut log := new_event_log(tmp_log_path('comp1'), 'main', 'test')
	mut c := new_intent_compiler(log, messy_draft)
	plan := c.compile('fix and harden the parser')

	items := plan.items()
	assert items.len == 6, items.map(it.task).str()
	// every drop carries a reason — a silent drop would be unexplainable
	for d in plan.dropped {
		assert jstr(d, 'reason') != '', d.str()
	}
	reasons := plan.dropped.map(jstr(it, 'reason'))
	assert 'duplicate' in reasons, reasons.str()
	assert 'empty task' in reasons, reasons.str()
	assert 'not an object' in reasons, reasons.str()
}

fn test_two_writers_of_one_path_never_share_a_wave() {
	mut log := new_event_log(tmp_log_path('comp2'), 'main', 'test')
	mut c := new_intent_compiler(log, messy_draft)
	plan := c.compile('fix and harden the parser')

	mut waves_with_parser := []int{}
	for i, wave in plan.waves {
		for it in wave {
			if 'src/parser.py' in it.paths {
				waves_with_parser << i
				break
			}
		}
	}
	// the coder and the documenter both write src/parser.py, so they are
	// split across two waves rather than allowed to clobber each other
	assert waves_with_parser.len == 2, waves_with_parser.str()
}

fn test_dependency_order_survives_the_layering() {
	mut log := new_event_log(tmp_log_path('comp3'), 'main', 'test')
	mut c := new_intent_compiler(log, messy_draft)
	plan := c.compile('fix and harden the parser')

	fix := wave_of(plan, 'Fix the parser bug')
	apply := wave_of(plan, 'Apply the fix')
	docs := wave_of(plan, 'Write parser docs')
	assert fix >= 0 && apply >= 0 && docs >= 0
	assert fix < apply, '${fix} < ${apply}'
	assert apply < docs, '${apply} < ${docs}'

	// a dependency naming no surviving item is pruned rather than stalling
	// the item forever, so the test suite still runs
	assert wave_of(plan, 'Run the test suite') >= 0
	assert wave_of(plan, 'Orphan work') >= 0
}

fn test_the_plan_is_sealed_before_anything_runs() {
	mut log := new_event_log(tmp_log_path('comp4'), 'main', 'test')
	mut c := new_intent_compiler(log, messy_draft)
	c.executor = recording_executor
	executed_waves = [][]PlanItem{}

	plan := c.compile('fix and harden the parser')
	mut types := log.events('main').map(it.typ)
	assert types.filter(it == 'compile.plan').len == 1, types.str()
	// nothing has executed yet — the seal comes first
	assert types.filter(it == 'compile.wave').len == 0

	result := c.execute(&plan) or { panic(err) }
	assert (result['items'] or { json2.Any(0) }).int() == 6, result.str()
	assert (result['done'] or { json2.Any(0) }).int() == 6, result.str()
	assert executed_waves.len == plan.waves.len

	types = log.events('main').map(it.typ)
	assert types.filter(it == 'compile.wave').len == plan.waves.len
	assert 'compile.done' in types

	st := fold(mut log, 'main')
	plans := st.advanced_events.filter(jstr(it, 'type') == 'compile.plan')
	assert plans.len > 0
	assert jint(plans[0], 'n_items') == 6
}

fn test_an_empty_draft_compiles_to_an_empty_plan() {
	mut log := new_event_log(tmp_log_path('comp5'), 'main', 'test')
	mut c := new_intent_compiler(log, empty_draft)
	plan := c.compile('nothing')
	assert plan.items().len == 0
	assert plan.waves.len == 0
	// with no executor attached, running is an error rather than a crash
	mut c2 := new_intent_compiler(log, empty_draft)
	c2.execute(&plan) or {
		assert err.msg().contains('no executor')
		return
	}
	assert false, 'a plan with no executor must not run'
}

fn test_a_dependency_cycle_is_cut_and_still_schedules() {
	mut log := new_event_log(tmp_log_path('comp6'), 'main', 'test')
	mut c := new_intent_compiler(log, cyclic_draft)
	plan := c.compile('cyclic')
	assert plan.items().len == 3, plan.to_json().str()
	assert plan.waves.len > 0
}

fn test_the_rendering_names_the_goal_and_its_waves() {
	mut log := new_event_log(tmp_log_path('comp7'), 'main', 'test')
	mut c := new_intent_compiler(log, messy_draft)
	plan := c.compile('fix and harden the parser')
	text := c.format(&plan)
	assert text.contains('COMPILED PLAN')
	assert text.contains('wave 1:')
	assert text.contains('[src/parser.py]')
	assert text.contains('dropped')
}

fn test_a_normalised_task_ignores_case_and_punctuation() {
	assert norm_task('map the MODULE graph!!') == 'map the module graph'
	assert norm_task('  Fix: the-parser (bug)  ') == 'fix the parser bug'
	assert norm_task('!!!') == ''
}

fn test_a_fenced_json_reply_is_still_a_draft() {
	items := parse_draft_array('```json\n[{"task": "a"}]\n```')
	assert items.len == 1
	// an object, not an array, is no plan at all
	assert parse_draft_array('{"task": "a"}').len == 0
	assert parse_draft_array('not json').len == 0
	assert parse_draft_array('').len == 0
}
