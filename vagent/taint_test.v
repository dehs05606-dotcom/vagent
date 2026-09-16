module vagent

import os

fn taint_project(name string) string {
	root := os.join_path(os.temp_dir(), 'vagent-taint-${name}-${os.getpid()}')
	os.rmdir_all(root) or {}
	os.mkdir_all(root) or { panic(err) }
	return root
}

fn test_a_tainted_value_reaching_a_sink_is_found_with_its_path() {
	root := taint_project('t1')
	defer {
		os.rmdir_all(root) or {}
	}
	path := os.join_path(root, 'vuln.py')
	os.write_file(path, 'import os\n\ncmd = os.getenv("CMD")\nos.system(cmd)\n') or { panic(err) }

	mut log := new_event_log(os.join_path(root, 'log.jsonl'), 'main', 'test')
	mut a := new_static_analyzer(log)
	res := a.analyze_file(path)
	assert res.error == '', res.error
	assert res.taint.len == 1, '${res.taint.len}'
	f := res.taint[0]
	assert f.source == 'os.getenv'
	assert f.sink == 'os.system'
	assert f.source_line == 3
	assert f.line == 4
	assert 'cmd' in f.path
	assert log.events('main').map(it.typ).contains('analysis.taint')

	text := a.format_report(&res)
	assert text.contains('STATIC ANALYSIS')
	assert text.contains('os.getenv@3 → os.system@4')
}

fn test_clean_code_produces_no_taint_finding() {
	root := taint_project('t2')
	defer {
		os.rmdir_all(root) or {}
	}
	path := os.join_path(root, 'clean.py')
	os.write_file(path, 'def add(a, b):\n    return a + b\n') or { panic(err) }
	mut log := new_event_log(os.join_path(root, 'log.jsonl'), 'main', 'test')
	mut a := new_static_analyzer(log)
	res := a.analyze_file(path)
	assert res.error == ''
	assert res.taint.len == 0
	assert res.complexity.len == 1
	assert res.complexity[0].name == 'add'
	assert res.complexity[0].complexity == 1
	assert res.complexity[0].args == 2
}

fn test_complexity_counts_branches_and_names_the_hotspots() {
	root := taint_project('t3')
	defer {
		os.rmdir_all(root) or {}
	}
	mut body := 'def branchy(x):\n'
	for i in 0 .. 12 {
		body += '    if x == ${i}:\n        return ${i}\n'
	}
	body += '    return -1\n\ndef simple():\n    return 1\n'
	path := os.join_path(root, 'complex.py')
	os.write_file(path, body) or { panic(err) }

	mut log := new_event_log(os.join_path(root, 'log.jsonl'), 'main', 'test')
	mut a := new_static_analyzer(log)
	res := a.analyze_file(path)
	assert res.error == ''
	branchy := res.complexity.filter(it.name == 'branchy')[0]
	assert branchy.complexity == 13, '${branchy.complexity}'
	assert res.hotspots.len == 1
	assert res.hotspots[0].function == 'branchy'
	// the simple one is not a hotspot
	assert !res.hotspots.any(it.function == 'simple')
	assert log.events('main').map(it.typ).contains('analysis.complexity')
}

fn test_an_import_cycle_between_modules_is_detected() {
	root := taint_project('t4')
	defer {
		os.rmdir_all(root) or {}
	}
	os.write_file(os.join_path(root, 'alpha.py'), 'import beta\n\ndef a():\n    return beta.b()\n') or {
		panic(err)
	}
	os.write_file(os.join_path(root, 'beta.py'), 'import alpha\n\ndef b():\n    return alpha.a()\n') or {
		panic(err)
	}
	os.write_file(os.join_path(root, 'lonely.py'), 'def c():\n    return 1\n') or { panic(err) }

	mut log := new_event_log(os.join_path(root, 'log.jsonl'), 'main', 'test')
	mut a := new_static_analyzer(log)
	res := a.analyze_tree(root, '*.py', 100)
	assert res.error == '', res.error
	assert res.files == 3
	assert res.cycles.len == 1, '${res.cycles}'
	mut names := res.cycles[0].clone()
	names.sort()
	assert names == ['alpha', 'beta']
	assert log.events('main').map(it.typ).contains('analysis.cycles')
	assert a.format_report(&res).contains('import cycles: 1')
}

fn test_a_missing_file_is_an_error_not_an_empty_result() {
	root := taint_project('t5')
	defer {
		os.rmdir_all(root) or {}
	}
	mut log := new_event_log(os.join_path(root, 'log.jsonl'), 'main', 'test')
	mut a := new_static_analyzer(log)
	res := a.analyze_file(os.join_path(root, 'nope.py'))
	assert res.error.contains('not a file')
	assert res.taint.len == 0
	// "no findings" and "not analysed" must not print the same way
	assert a.format_report(&res).contains('not a file')
	assert !a.format_report(&res).contains('taint findings: 0')

	empty := a.analyze_tree(os.join_path(root, 'nowhere'), '*.py', 10)
	assert empty.error.contains('nothing to analyse')
}

fn test_a_file_that_does_not_parse_yields_nothing_rather_than_a_crash() {
	root := taint_project('t6')
	defer {
		os.rmdir_all(root) or {}
	}
	path := os.join_path(root, 'broken.py')
	os.write_file(path, 'def f(:\n    this is not python\n') or { panic(err) }
	mut log := new_event_log(os.join_path(root, 'log.jsonl'), 'main', 'test')
	mut a := new_static_analyzer(log)
	res := a.analyze_file(path)
	assert res.error == ''
	assert res.taint.len == 0
	assert res.complexity.len == 0
}
