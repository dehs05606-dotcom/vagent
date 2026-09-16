module vagent

import os
import time

__global (
	ci_runs [][]string
)

fn ci_stub_runner(tests []string) !(bool, string) {
	ci_runs << tests.clone()
	mut ok := true
	for t in tests {
		if t.contains('billing') {
			ok = false
		}
	}
	msg := if ok { '1 passed' } else { '1 failed' }
	return ok, msg
}

fn ci_project(name string) string {
	// the watched project lives in a subdir — the log stays OUTSIDE it, or
	// the watch loop sees every run of its own as a change
	base := os.join_path(os.temp_dir(), 'vagent-ci-${name}-${os.getpid()}')
	os.rmdir_all(base) or {}
	root := os.join_path(base, 'proj')
	os.mkdir_all(os.join_path(root, 'app')) or { panic(err) }
	os.mkdir_all(os.join_path(root, 'tests')) or { panic(err) }
	os.write_file(os.join_path(root, 'app', 'parser.py'), 'def parse(): pass\n') or { panic(err) }
	os.write_file(os.join_path(root, 'app', 'billing.py'), 'def charge(): pass\n') or {
		panic(err)
	}
	os.write_file(os.join_path(root, 'tests', 'test_parser.py'), 'from app.parser import parse\n') or {
		panic(err)
	}
	os.write_file(os.join_path(root, 'tests', 'test_billing.py'), 'from app.billing import charge\n') or {
		panic(err)
	}
	os.write_file(os.join_path(root, 'README.md'), 'project\n') or { panic(err) }
	return root
}

fn test_changed_files_map_to_their_tests_three_ways() {
	root := ci_project('map')
	defer {
		os.rmdir_all(os.dir(root)) or {}
	}
	mut ci := new_ci_pilot(new_event_log(tmp_log_path('ci1'), 'main', 'test'), root,
		ci_stub_runner, 0.05)

	// a name twin, and nothing else: test_billing.py mentions neither
	// 'parser' nor the app/ directory
	assert ci.impacted_tests(['app/parser.py']) == ['tests/test_parser.py']
	assert 'tests/test_billing.py' in ci.impacted_tests(['app/billing.py'])
	// a file with no test anywhere maps to nothing
	assert ci.impacted_tests(['README.md']) == []
	// a same-directory test is picked up too
	assert 'tests/test_parser.py' in ci.impacted_tests(['tests/helpers.py'])
}

fn test_a_cycle_runs_only_the_impacted_tests_and_tracks_the_streaks() {
	root := ci_project('cycle')
	defer {
		os.rmdir_all(os.dir(root)) or {}
	}
	ci_runs = [][]string{}
	mut ci := new_ci_pilot(new_event_log(tmp_log_path('ci2'), 'main', 'test'), root,
		ci_stub_runner, 0.05)

	// the first look only establishes the baseline
	assert ci.check_once() == none

	// a change with no tests is noted but never fails the build
	os.write_file(os.join_path(root, 'README.md'), 'project v2 with more words\n') or {
		panic(err)
	}
	first := ci.check_once() or { panic('no record') }
	assert first.passed
	assert first.tests == []
	assert ci.streak_green == 1
	assert ci_runs.len == 0

	// a parser change runs its test: green
	os.write_file(os.join_path(root, 'app', 'parser.py'), 'def parse(): return 42\n') or {
		panic(err)
	}
	second := ci.check_once() or { panic('no record') }
	assert second.tests == ['tests/test_parser.py'], '${second.tests}'
	assert second.passed
	assert ci.streak_green == 2

	// a billing change fails: red streak, and the runner's output is kept
	os.write_file(os.join_path(root, 'app', 'billing.py'), 'def charge(): raise RuntimeError\n') or {
		panic(err)
	}
	third := ci.check_once() or { panic('no record') }
	assert !third.passed
	assert third.output.contains('failed')
	assert ci.streak_red == 1
	assert ci.streak_green == 0

	// no change, no run
	assert ci.check_once() == none
	assert ci.records.len == 3
}

fn test_a_same_second_rewrite_of_the_same_length_is_still_seen() {
	root := ci_project('samesec')
	defer {
		os.rmdir_all(os.dir(root)) or {}
	}
	mut ci := new_ci_pilot(new_event_log(tmp_log_path('ci3'), 'main', 'test'), root,
		ci_stub_runner, 0.05)
	ci.check_once()
	// identical length, written immediately: whole-second mtimes cannot
	// tell these apart, which is why the signature hashes recent files
	os.write_file(os.join_path(root, 'app', 'parser.py'), 'def parse(): pAss\n') or { panic(err) }
	rec := ci.check_once() or { panic('the rewrite went unnoticed') }
	assert 'app/parser.py' in rec.changed
}

fn test_a_deleted_file_is_a_change() {
	root := ci_project('gone')
	defer {
		os.rmdir_all(os.dir(root)) or {}
	}
	mut ci := new_ci_pilot(new_event_log(tmp_log_path('ci4'), 'main', 'test'), root,
		ci_stub_runner, 0.05)
	ci.check_once()
	os.rm(os.join_path(root, 'README.md')) or { panic(err) }
	rec := ci.check_once() or { panic('no record') }
	assert 'README.md' in rec.changed
}

fn test_a_broken_runner_reports_rather_than_stopping_the_watch() {
	root := ci_project('broken')
	defer {
		os.rmdir_all(os.dir(root)) or {}
	}
	mut ci := new_ci_pilot(new_event_log(tmp_log_path('ci5'), 'main', 'test'), ci_boom_runner_root(root),
		ci_boom_runner, 0.05)
	ci.check_once()
	os.write_file(os.join_path(root, 'app', 'parser.py'), 'def parse(): return 7\n') or {
		panic(err)
	}
	rec := ci.check_once() or { panic('no record') }
	assert !rec.passed
	assert rec.output.contains('runner failed')
	assert ci.streak_red == 1
}

fn ci_boom_runner_root(root string) string {
	return root
}

fn ci_boom_runner(tests []string) !(bool, string) {
	return error('pytest not installed')
}

fn test_the_background_watch_fires_on_a_real_change() {
	root := ci_project('watch')
	defer {
		os.rmdir_all(os.dir(root)) or {}
	}
	ci_runs = [][]string{}
	mut log := new_event_log(tmp_log_path('ci6'), 'main', 'test')
	mut ci := new_ci_pilot(log, root, ci_stub_runner, 0.05)
	ci.start()
	time.sleep(100 * time.millisecond)
	os.write_file(os.join_path(root, 'app', 'parser.py'), 'def parse(): return 1\n') or {
		panic(err)
	}
	deadline := time.now().add(8 * time.second)
	for time.now() < deadline && ci.records.len < 1 {
		time.sleep(50 * time.millisecond)
	}
	ci.stop_watching()
	assert ci.records.len >= 1, '${ci.records.len}'
	assert ci_runs.len >= 1

	kinds := log.events('main').map(it.typ)
	assert 'ci.watch' in kinds
	assert 'ci.run' in kinds
	assert 'ci.streak' in kinds
	assert ci.status().contains('CI PILOT')
	assert ci.status().contains('stopped')
}
