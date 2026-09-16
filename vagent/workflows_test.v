module vagent

import os
import x.json2

__global (
	workflow_touch_path string
)

fn scripted_step_executor(step &WorkflowStep, n int) !map[string]json2.Any {
	if step.task.contains('fail') {
		return {
			'status':  json2.Any('error')
			'summary': json2.Any('exploded')
		}
	}
	if step.task.contains('raise') {
		return error('the executor itself broke')
	}
	if step.task.contains('create') {
		os.write_file(workflow_touch_path, 'shipped') or {}
	}
	return {
		'status':  json2.Any('done')
		'summary': json2.Any('completed: ' + clip_plain(step.task, 40))
	}
}

fn wf_root(name string) string {
	dir := os.join_path(os.temp_dir(), 'vagent-wf-${name}-${os.getpid()}')
	os.rmdir_all(dir) or {}
	os.mkdir_all(dir) or { panic(err) }
	return dir
}

fn wf_engine(name string) (&WorkflowEngine, string) {
	root := wf_root(name)
	workflow_touch_path = os.join_path(root, 'ok.txt')
	mut log := new_event_log(tmp_log_path('wfl-${name}'), 'main', 'test')
	mut judge := new_judge(log)
	return new_workflow_engine(log, os.join_path(root, 'workflows'), scripted_step_executor, judge), root
}

fn ship_workflow(root string) Workflow {
	return workflow_from_json({
		'name':        json2.Any('ship')
		'description': json2.Any('build and verify')
		'steps':       json2.Any([
			json2.Any({
				'task':  json2.Any('create the artifact')
				'role':  json2.Any('coder')
				'phase': json2.Any(1)
			}),
			json2.Any({
				'task':   json2.Any('check it exists')
				'role':   json2.Any('tester')
				'phase':  json2.Any(2)
				'expect': json2.Any({
					'type': json2.Any('file_exists')
					'path': json2.Any(os.join_path(root, 'ok.txt'))
				})
			}),
			json2.Any({
				'task':  json2.Any('review it')
				'role':  json2.Any('reviewer')
				'phase': json2.Any(2)
			}),
		])
	}) or { panic(err) }
}

fn test_a_definition_is_validated_before_it_is_ever_saved() {
	workflow_from_json({
		'name':  json2.Any('x')
		'steps': json2.Any([]json2.Any{})
	}) or {
		assert err.msg().contains('at least one step')
		workflow_from_json({
			'name':  json2.Any('bad name!')
			'steps': json2.Any([
				json2.Any({
					'task': json2.Any('t')
				}),
			])
		}) or {
			assert err.msg().contains('invalid workflow name')
			return
		}
		assert false, 'a bad name must be refused'
	}
	assert false, 'an empty workflow must be refused'
}

fn test_a_step_must_carry_a_task_and_a_sane_expect() {
	step_from_json(json2.Any({
		'task': json2.Any('   ')
	})) or {
		assert err.msg().contains("non-empty 'task'")
		step_from_json(json2.Any({
			'task':   json2.Any('t')
			'expect': json2.Any('not a dict')
		})) or {
			assert err.msg().contains('predicate dict')
			step_from_json(json2.Any({
				'task':  json2.Any('t')
				'phase': json2.Any('soon')
			})) or {
				assert err.msg().contains('must be an integer')
				return
			}
			assert false, 'a non-integer phase must be refused'
		}
		assert false, 'a non-dict expect must be refused'
	}
	assert false, 'an empty task must be refused'
}

fn test_a_step_defaults_are_filled_in_rather_than_guessed_at() {
	s := step_from_json(json2.Any({
		'task': json2.Any('do it')
	})) or { panic(err) }
	assert s.role == 'coder'
	assert s.model == ''
	assert s.phase == 0
	// no expect means the step is not machine-checked, which is different
	// from checking nothing
	assert s.expect == none
	// and a negative phase is clamped rather than reordering the run
	neg := step_from_json(json2.Any({
		'task':  json2.Any('do it')
		'phase': json2.Any(-5)
	})) or { panic(err) }
	assert neg.phase == 0
}

fn test_save_load_and_list_round_trip() {
	mut engine, root := wf_engine('rt')
	defer {
		os.rmdir_all(root) or {}
	}
	wf := ship_workflow(root)
	engine.save(&wf) or { panic(err) }
	assert engine.list() == ['ship']

	loaded := engine.load('ship') or { panic(err) }
	assert loaded.steps.len == 3
	assert loaded.description == 'build and verify'
	expect := loaded.steps[1].expect or { panic('the expect predicate was lost') }.clone()
	assert jstr(expect, 'type') == 'file_exists'
	assert loaded.steps[1].phase == 2
}

fn test_a_clean_run_finishes_every_step_in_phase_order() {
	mut engine, root := wf_engine('ok')
	defer {
		os.rmdir_all(root) or {}
	}
	wf := ship_workflow(root)
	engine.save(&wf) or { panic(err) }

	report := engine.run('ship', 10.0) or { panic(err) }
	assert report.state == 'DONE', report.to_json().str()
	assert report.steps.len == 3
	for s in report.steps {
		assert s.status == 'done', s.to_json().str()
	}
	// phase 1 really ran before phase 2's check
	assert report.steps[0].step == 1
	assert report.steps[1].check != ''
}

fn test_a_failed_expect_blocks_the_run_at_that_step() {
	mut engine, root := wf_engine('strict')
	defer {
		os.rmdir_all(root) or {}
	}
	wf := workflow_from_json({
		'name':  json2.Any('strict')
		'steps': json2.Any([
			json2.Any({
				'task': json2.Any('do work')
				'role': json2.Any('coder')
			}),
			json2.Any({
				'task':   json2.Any('impossible check')
				'role':   json2.Any('tester')
				'expect': json2.Any({
					'type': json2.Any('file_exists')
					'path': json2.Any(os.join_path(root, 'missing.txt'))
				})
			}),
			json2.Any({
				'task': json2.Any('never reached')
				'role': json2.Any('reviewer')
			}),
		])
	}) or { panic(err) }
	engine.save(&wf) or { panic(err) }

	report := engine.run('strict', 10.0) or { panic(err) }
	assert report.state == 'BLOCKED', report.to_json().str()
	assert report.steps[1].status == 'blocked'
	assert report.steps[1].summary.contains('EXPECT FAILED')
	// the third step never ran — a blocked step is not skipped past
	assert report.steps.len == 2
}

fn test_an_executor_failure_blocks_the_run_too() {
	mut engine, root := wf_engine('boom')
	defer {
		os.rmdir_all(root) or {}
	}
	wf := workflow_from_json({
		'name':  json2.Any('boom')
		'steps': json2.Any([
			json2.Any({
				'task': json2.Any('fail hard')
			}),
			json2.Any({
				'task': json2.Any('never reached')
			}),
		])
	}) or { panic(err) }
	engine.save(&wf) or { panic(err) }
	report := engine.run('boom', 10.0) or { panic(err) }
	assert report.state == 'BLOCKED'
	assert report.steps.len == 1
	assert report.steps[0].status == 'error'

	// an executor that fails outward is the step's failure, not the
	// engine's
	raiser := workflow_from_json({
		'name':  json2.Any('raiser')
		'steps': json2.Any([
			json2.Any({
				'task': json2.Any('raise something')
			}),
		])
	}) or { panic(err) }
	engine.save(&raiser) or { panic(err) }
	second := engine.run('raiser', 10.0) or { panic(err) }
	assert second.state == 'BLOCKED'
	assert second.steps[0].summary.contains('executor itself broke')
}

fn test_a_traversing_name_cannot_read_or_delete_outside_the_directory() {
	mut engine, root := wf_engine('safe')
	defer {
		os.rmdir_all(root) or {}
	}
	// this file sits outside the workflows directory and must stay there
	outside := os.join_path(root, 'secret.json')
	os.write_file(outside, '{"name": "secret", "steps": [{"task": "t"}]}') or { panic(err) }

	engine.load('../secret') or {
		assert err.msg().contains('invalid workflow name'), err.msg()
		engine.delete('../secret') or {
			assert err.msg().contains('invalid workflow name'), err.msg()
			assert os.exists(outside), 'the file outside the directory was deleted'
			return
		}
		assert false, 'a traversing delete must be refused'
	}
	assert false, 'a traversing load must be refused'
}

fn test_an_unknown_workflow_names_what_is_saved() {
	mut engine, root := wf_engine('unknown')
	defer {
		os.rmdir_all(root) or {}
	}
	wf := ship_workflow(root)
	engine.save(&wf) or { panic(err) }
	engine.load('nope') or {
		assert err.msg().contains("unknown workflow 'nope'")
		assert err.msg().contains('ship'), err.msg()
		return
	}
	assert false, 'an unknown workflow must be refused'
}

fn test_a_malformed_file_on_disk_is_reported_not_run() {
	mut engine, root := wf_engine('malformed')
	defer {
		os.rmdir_all(root) or {}
	}
	os.mkdir_all(engine.dir) or { panic(err) }
	os.write_file(os.join_path(engine.dir, 'broken.json'), '{not json') or { panic(err) }
	engine.load('broken') or {
		assert err.msg().contains('malformed'), err.msg()
		// and the listing still renders, marking the bad one
		assert engine.format_list().contains('✗ broken')
		return
	}
	assert false, 'a malformed workflow must be refused'
}

fn test_everything_is_sealed_and_rendered() {
	mut engine, root := wf_engine('seal')
	defer {
		os.rmdir_all(root) or {}
	}
	wf := ship_workflow(root)
	engine.save(&wf) or { panic(err) }
	report := engine.run('ship', 10.0) or { panic(err) }

	types := engine.log.events('main').map(it.typ)
	assert types.filter(it == 'workflow.start').len == 1
	assert types.filter(it == 'workflow.done').len == 1
	assert types.filter(it == 'workflow.step').len == 3
	assert 'workflow.saved' in types

	listing := engine.format_list()
	assert listing.contains('SAVED WORKFLOWS')
	assert listing.contains('◆ ship — 3 step(s)')
	assert listing.contains('⊛expect')

	text := engine.format_report(&report)
	assert text.contains('WORKFLOW ship — ✓ DONE')
	assert text.contains('✓ step 1 (coder)')

	assert engine.delete('ship') or { false }
	assert !(engine.delete('ship') or { true })
	assert engine.list().len == 0
	assert engine.format_list().contains('no saved workflows')
}
