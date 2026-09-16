module vagent

import os
import x.json2

fn world_project(name string) string {
	base := os.join_path(os.temp_dir(), 'vagent-world-${name}-${os.getpid()}')
	os.rmdir_all(base) or {}
	root := os.join_path(base, 'proj')
	os.mkdir_all(os.join_path(root, 'src')) or { panic(err) }
	os.write_file(os.join_path(root, 'src', 'core.py'), 'VALUE = 1\n') or { panic(err) }
	os.write_file(os.join_path(root, 'src', 'api.py'), 'from core import VALUE\n\ndef get():\n    return VALUE\n') or {
		panic(err)
	}
	os.write_file(os.join_path(root, 'src', 'cli.py'), 'import api\n\ndef main():\n    return api.get()\n') or {
		panic(err)
	}
	return root
}

fn test_the_static_scan_finds_the_impact_edges() {
	root := world_project('w1')
	defer {
		os.rmdir_all(os.dir(root)) or {}
	}
	mut w := new_world_model(new_event_log(tmp_log_path('world1'), 'main', 'test'), root)
	// touching core affects api, and touching api affects cli
	assert w.edge('src/core.py', 'src/api.py') != none
	assert w.edge('src/api.py', 'src/cli.py') != none
	// the direction is IMPACT, not import: api imports core, so the edge
	// runs from core to api
	assert w.edge('src/api.py', 'src/core.py') == none
}

fn test_planted_breakage_is_recovered_from_history() {
	root := world_project('w2')
	defer {
		os.rmdir_all(os.dir(root)) or {}
	}
	mut w := new_world_model(new_event_log(tmp_log_path('world2'), 'main', 'test'), root)

	// touching core.py broke api.py four times out of five. The static scan
	// already charged this edge once, so `seen` starts at two.
	for i in 0 .. 5 {
		failures := if i < 4 { ['src/api.py'] } else { []string{} }
		w.observe_turn(['src/core.py'], failures, [])
	}
	e := w.edge('src/core.py', 'src/api.py') or { panic('no edge') }
	assert e.seen == 7, '${e.seen}'
	assert e.broken == 4, '${e.broken}'
	// Laplace-smoothed (4+1)/(7+2) — honestly near the planted 80%, and
	// never claiming certainty from seven samples
	assert math_abs(e.risk() - 5.0 / 9.0) < 1e-9, '${e.risk()}'
}

fn test_prediction_ranks_by_probability_and_decays_with_distance() {
	root := world_project('w3')
	defer {
		os.rmdir_all(os.dir(root)) or {}
	}
	mut w := new_world_model(new_event_log(tmp_log_path('world3'), 'main', 'test'), root)
	for i in 0 .. 5 {
		failures := if i < 4 { ['src/api.py'] } else { []string{} }
		w.observe_turn(['src/core.py'], failures, [])
	}
	impact := w.predict_impact('src/core.py')
	top := impact.ranked[0]
	assert top.path == 'src/api.py'
	assert top.via == 'direct'
	cli := impact.ranked.filter(it.path == 'src/cli.py')[0]
	assert cli.probability < top.probability, 'the hop decay did not apply'
	assert cli.via == '2 hops'
	text := impact.format()
	assert text.contains('IMPACT — touching src/core.py')
	assert text.contains('src/api.py')
	assert text.contains('█')
}

fn test_learning_from_the_log_charges_the_edges_a_turn_touched() {
	root := world_project('w4')
	defer {
		os.rmdir_all(os.dir(root)) or {}
	}
	mut log := new_event_log(tmp_log_path('world4'), 'main', 'test')
	mut w := new_world_model(log, root)
	before := w.edge('src/core.py', 'src/api.py') or { panic('no edge') }

	log.append('user.message', {
		'text': json2.Any('go')
	}, AppendOpts{})
	log.append('tool.call', {
		'name': json2.Any('edit_file')
		'args': json2.Any({
			'path': json2.Any('src/core.py')
		})
	}, AppendOpts{})
	log.append('tool.result', {
		'name':   json2.Any('write_file')
		'status': json2.Any('error')
	}, AppendOpts{})
	log.append('user.message', {
		'text': json2.Any('go 2')
	}, AppendOpts{})

	assert w.learn_from_log() == 1
	after := w.edge('src/core.py', 'src/api.py') or { panic('no edge') }
	assert after.seen > before.seen

	// the break is NOT charged here, and that is the original's behaviour:
	// a turn's failure list is the files that turn CHANGED, so an edge is
	// only charged when a changed file is itself a dependant of another
	// changed file. core.py failing says nothing about api.py.
	assert after.broken == before.broken
}

fn test_an_unknown_path_predicts_nothing_cleanly() {
	mut w := new_world_model(new_event_log(tmp_log_path('world5'), 'main', 'test'), '')
	empty := w.predict_impact('nowhere/x.py')
	assert empty.ranked.len == 0
	assert empty.format().contains('no known dependants')
	assert jint(w.stats(), 'edges') == 0
}

fn test_the_ledger_records_both_learning_and_prediction() {
	root := world_project('w6')
	defer {
		os.rmdir_all(os.dir(root)) or {}
	}
	mut log := new_event_log(tmp_log_path('world6'), 'main', 'test')
	mut w := new_world_model(log, root)
	w.observe_turn(['src/core.py'], ['src/api.py'], [])
	w.predict_impact('src/core.py')
	kinds := log.events('main').map(it.typ)
	assert 'world.learn' in kinds
	assert 'world.impact' in kinds
	assert jint(w.stats(), 'edges') >= 2
}

fn test_a_single_observation_is_honestly_unsure() {
	fresh := Edge{
		src: 'a'
		dst: 'b'
	}
	// one sighting, no breaks: a third, not zero
	assert math_abs(fresh.risk() - 1.0 / 3.0) < 1e-9
	always := Edge{
		src:    'a'
		dst:    'b'
		seen:   10
		broken: 10
	}
	// ten for ten still is not certainty
	assert always.risk() < 1.0
	assert always.risk() > 0.9
}
