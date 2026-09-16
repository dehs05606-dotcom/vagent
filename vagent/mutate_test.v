module vagent

import os

const mutate_src = 'def add(a, b):
    if a > 0:
        return a + b
    return a - b
'

fn mutate_dir(name string) string {
	dir := os.join_path(os.temp_dir(), 'vagent-mutate-${name}-${os.getpid()}')
	os.rmdir_all(dir) or {}
	os.mkdir_all(dir) or { panic(err) }
	return dir
}

fn test_mutant_generation_is_real_ast_surgery() {
	if _ := find_python() {
	} else {
		// the generator borrows CPython's parser; with no interpreter there
		// is nothing to borrow, and saying so beats a fabricated pass
		eprintln('mutate: no python interpreter — skipping')
		return
	}
	mutants := generate_mutants(mutate_src, max_mutants) or { panic(err) }
	assert mutants.len >= 3, mutants.len.str()

	mut kinds := map[string]bool{}
	for m in mutants {
		kinds[m.kind] = true
		// every mutant differs from the original — an identical "mutant"
		// would be scored as survived and quietly lower the score
		assert m.source.trim_space() != mutate_src.trim_space()
		assert m.description.contains('site #')
	}
	assert kinds['operator_flip']
	assert kinds['condition_negate']
	assert kinds['return_break']

	// the flips really changed the operator and the condition
	flips := mutants.filter(it.kind == 'operator_flip')
	assert flips.filter(it.source.contains('a - b')).len > 0
	negs := mutants.filter(it.kind == 'condition_negate')
	assert negs.filter(it.source.contains('not a > 0')).len > 0
	breaks := mutants.filter(it.kind == 'return_break')
	assert breaks.filter(it.source.contains('return None')).len > 0
}

fn test_the_cap_bounds_a_run() {
	if _ := find_python() {
	} else {
		return
	}
	mutants := generate_mutants(mutate_src, 2) or { panic(err) }
	assert mutants.len <= 2
}

fn test_a_file_that_does_not_parse_yields_no_mutants() {
	if _ := find_python() {
	} else {
		return
	}
	assert generate_mutants('def broken(:\n', max_mutants) or { panic(err) } == []
	assert generate_mutants('', max_mutants) or { panic(err) } == []
}

fn test_a_suite_that_catches_bugs_kills_mutants_and_the_file_is_restored() {
	if _ := find_python() {
	} else {
		return
	}
	python := find_python() or { return }
	dir := mutate_dir('run')
	defer {
		os.rmdir_all(dir) or {}
	}
	target := os.join_path(dir, 'calc.py')
	os.write_file(target, mutate_src) or { panic(err) }
	suite := os.join_path(dir, 'test_calc.py')
	// the suite pins both branches, so flipping the operator in either one
	// is caught
	os.write_file(suite, 'import sys\nsys.path.insert(0, ${quote_py(dir)})\n' + 'from calc import add\nassert add(2, 3) == 5\nassert add(-1, 3) == -4\n') or { panic(err) }

	mut log := new_event_log(tmp_log_path('mut1'), 'main', 'test')
	mut t := new_mutation_tester(log, '${quote_arg(python)} ${quote_arg(suite)}', target)
	report := t.run(target, max_mutants)

	assert report.total >= 3, report.total.str()
	assert report.killed >= 1, report.to_json().str()
	assert report.score >= 0.0 && report.score <= 1.0
	assert report.killed + report.survived + report.errors == report.total

	// the original file comes back byte for byte, whatever happened
	assert os.read_file(target) or { '' } == mutate_src

	// every mutant carries a verdict, and none is left pending
	for r in report.results {
		assert r.status in ['killed', 'survived', 'error'], r.status
	}

	kinds := t.reports()
	assert kinds.len == 1
	assert jint(kinds[0], 'total') == report.total
	status := t.format_status()
	assert status.contains('MUTATION TESTING')
	assert status.contains('killed ${report.killed}/${report.total}')
}

fn test_a_suite_that_notices_nothing_scores_zero() {
	if _ := find_python() {
	} else {
		return
	}
	python := find_python() or { return }
	dir := mutate_dir('weak')
	defer {
		os.rmdir_all(dir) or {}
	}
	target := os.join_path(dir, 'calc.py')
	os.write_file(target, mutate_src) or { panic(err) }
	// a suite that imports the module and asserts nothing about it
	suite := os.join_path(dir, 'test_weak.py')
	os.write_file(suite, 'import sys\nsys.path.insert(0, ${quote_py(dir)})\nimport calc\n') or {
		panic(err)
	}

	mut log := new_event_log(tmp_log_path('mut2'), 'main', 'test')
	mut t := new_mutation_tester(log, '${quote_arg(python)} ${quote_arg(suite)}', target)
	report := t.run(target, max_mutants)
	// every mutant survives, which is exactly what the score is for
	assert report.killed == 0, report.to_json().str()
	assert report.survived == report.total
	assert report.score == 0.0
	assert os.read_file(target) or { '' } == mutate_src
}

fn test_a_missing_file_is_reported_not_invented() {
	mut log := new_event_log(tmp_log_path('mut3'), 'main', 'test')
	mut t := new_mutation_tester(log, 'true', '')
	report := t.run(os.join_path(os.temp_dir(), 'vagent-no-such-file.py'), max_mutants)
	assert report.total == 0
	assert report.score == 0.0
	// nothing ran, so nothing was sealed
	assert log.head('main') == -1
	assert t.format_status().contains('no runs yet')
}

fn test_a_suite_that_cannot_run_is_an_error_not_a_kill() {
	if _ := find_python() {
	} else {
		return
	}
	dir := mutate_dir('broken')
	defer {
		os.rmdir_all(dir) or {}
	}
	target := os.join_path(dir, 'calc.py')
	os.write_file(target, mutate_src) or { panic(err) }

	mut log := new_event_log(tmp_log_path('mut4'), 'main', 'test')
	// exit 127 is the shell's "command not found", which says nothing
	// about the mutant; counting it as killed would inflate the score
	mut t := new_mutation_tester(log, 'exit 127', target)
	report := t.run(target, 3)
	assert report.total > 0
	assert report.errors == report.total, report.to_json().str()
	assert report.killed == 0
	assert report.score == 0.0
	assert os.read_file(target) or { '' } == mutate_src
}

// quote_py renders a path as a Python string literal for the generated suite.
fn quote_py(s string) string {
	return '"' + s.replace('\\', '\\\\').replace('"', '\\"') + '"'
}
