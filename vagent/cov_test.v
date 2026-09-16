module vagent

import os

fn cov_fixture() (string, string) {
	dir := os.join_path(os.temp_dir(), 'vagent-cov-${os.getpid()}-${rand_suffix()}')
	os.rmdir_all(dir) or {}
	os.mkdir_all(dir) or { panic(err) }
	// two branches: one the driver takes, one it never does
	target := os.join_path(dir, 'branchy.py')
	os.write_file(target, "def pick(x):\n    if x > 0:\n        return 'pos'\n    else:\n        return 'neg'\n\n\ndef unused():\n    return 'never'\n") or {
		panic(err)
	}
	return dir, target
}

fn cov_line_of(path string, needle string) int {
	for i, line in split_lines(os.read_file(path) or { '' }) {
		if line.contains(needle) {
			return i + 1
		}
	}
	return -1
}

fn test_coverage_measures_the_branch_that_ran_and_the_one_that_did_not() {
	if _ := find_python() {
	} else {
		eprintln('no python: skipping the measurement tests')
		return
	}
	dir, target := cov_fixture()
	defer {
		os.rmdir_all(dir) or {}
	}
	driver := os.join_path(dir, 'drive_pos.py')
	os.write_file(driver, 'import sys\nsys.path.insert(0, ${quote_py(dir)})\nimport branchy\nbranchy.pick(5)\n') or {
		panic(err)
	}

	mut log := new_event_log(os.join_path(dir, 'cov.jsonl'), 'main', 'test')
	mut eng := new_coverage_engine(log)
	res := eng.measure(target, driver)
	assert res.error == '', res.error
	assert res.total > 0
	assert res.hit > 0
	// the unused function and the else branch are both missed
	assert res.percent > 0.0 && res.percent < 100.0, '${res.percent}'
	pos := cov_line_of(target, "'pos'")
	neg := cov_line_of(target, "'neg'")
	assert pos !in res.missed, '${res.missed}'
	assert neg in res.missed, '${res.missed}'

	// exercising both branches raises the number
	both := os.join_path(dir, 'drive_both.py')
	os.write_file(both, 'import sys\nsys.path.insert(0, ${quote_py(dir)})\nimport branchy\nbranchy.pick(5)\nbranchy.pick(-1)\n') or {
		panic(err)
	}
	res2 := eng.measure(target, both)
	assert res2.percent > res.percent, '${res.percent} -> ${res2.percent}'
	assert neg !in res2.missed

	// a subject that raises still yields coverage rather than an error
	boom := os.join_path(dir, 'drive_boom.py')
	os.write_file(boom, 'import sys\nsys.path.insert(0, ${quote_py(dir)})\nimport branchy\nbranchy.pick(1)\nraise RuntimeError("boom")\n') or {
		panic(err)
	}
	res3 := eng.measure(target, boom)
	assert res3.error == '', res3.error
	assert res3.hit > 0

	// every run is sealed in the log
	assert eng.results().len == 3
	assert eng.format_status().contains('COVERAGE')
	assert eng.format_status().contains('branchy.py')
}

fn test_a_missing_target_is_an_error_not_a_percentage() {
	dir, _ := cov_fixture()
	defer {
		os.rmdir_all(dir) or {}
	}
	mut log := new_event_log(os.join_path(dir, 'cov.jsonl'), 'main', 'test')
	mut eng := new_coverage_engine(log)
	res := eng.measure(os.join_path(dir, 'nope.py'), 'x.py')
	assert res.error == 'not a file'
	assert res.total == 0
	// it never guesses: no result event, and the status still reads
	assert eng.results().len == 0
	assert eng.format_status().contains('no runs yet')
}

fn test_the_result_payload_caps_its_missed_list() {
	mut r := CoverageResult{
		path:  '/x.py'
		total: 200
		hit:   0
	}
	for i in 1 .. 121 {
		r.missed << i
	}
	r.percent = 33.333333
	j := r.to_json()
	assert jarr(j, 'missed').len == 50
	assert jf64(j, 'percent') == 33.3
	assert jint(j, 'total') == 200
}

fn test_round_to_matches_pythons_round() {
	assert round_to(33.33333, 1) == 33.3
	assert round_to(2.5, 0) == 3.0
	assert round_to(-2.5, 0) == -3.0
	assert round_to(0.125, 2) == 0.13
	assert round_to(100.0, 1) == 100.0
}

fn test_quote_arg_survives_a_hostile_argument() {
	assert quote_arg('a b') == "'a b'"
	assert quote_arg("it's") == "'it'\\''s'"
	out := os.execute('printf %s ' + quote_arg("a b'c\$d"))
	assert out.output == "a b'c\$d", out.output
}

fn quote_py(s string) string {
	return "'" + s.replace('\\', '\\\\').replace("'", "\\'") + "'"
}

fn rand_suffix() string {
	return u64(now_ts() * 1000.0).str()
}
