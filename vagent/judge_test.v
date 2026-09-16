module vagent

import os
import x.json2

fn judge_dir(name string) string {
	dir := os.join_path(os.temp_dir(), 'vagent-judge-${os.getpid()}', name)
	os.rmdir_all(dir) or {}
	os.mkdir_all(dir) or { panic(err) }
	return dir
}

fn new_test_judge(name string) (&EventLog, Judge) {
	mut log := new_event_log(tmp_log_path('${name}.jsonl'), 'main', '')
	return log, new_judge(log)
}

fn test_file_predicates() {
	dir := judge_dir('files')
	f := os.join_path(dir, 'src.py')
	os.write_file(f, 'def verify_token(leeway=0):\n    return True\n') or { panic(err) }

	assert check_file_exists(f).passed
	assert !check_file_exists(os.join_path(dir, 'nope')).passed

	hit := check_file_contains(f, 'def verify_token')
	assert hit.passed
	assert hit.detail.contains(':1'), hit.detail
	assert !check_file_contains(f, 'def missing').passed

	m := check_file_matches(f, r'def \w+\(')
	assert m.passed, m.detail
	assert !check_file_matches(f, r'class \w+').passed
	// a bad pattern is a failed verdict, not a crash
	bad := check_file_matches(f, '(unclosed')
	assert !bad.passed
	assert bad.detail.contains('invalid pattern')
}

fn test_ast_assert_finds_defs_and_parameters() {
	dir := judge_dir('ast')
	f := os.join_path(dir, 'src.py')
	os.write_file(f, 'import os\n\n\nclass Thing:\n    def method(self, a, b=2):\n' +
		'        pass\n\n\ndef verify_token(token, leeway=0, *args, **kw):\n' +
		'    return True\n') or { panic(err) }

	ok := check_ast_assert(f, 'verify_token', 'def', '')
	assert ok.passed, ok.detail
	assert ok.detail.contains(':9'), ok.detail

	assert check_ast_assert(f, 'verify_token', 'def', 'leeway').passed
	assert check_ast_assert(f, 'verify_token', 'def', 'token').passed
	assert check_ast_assert(f, 'verify_token', 'def', 'kw').passed
	missing_param := check_ast_assert(f, 'verify_token', 'def', 'nope')
	assert !missing_param.passed
	assert missing_param.detail.contains('has no parameter'), missing_param.detail

	assert check_ast_assert(f, 'Thing', 'class', '').passed
	assert check_ast_assert(f, 'method', 'def', 'b').passed
	assert !check_ast_assert(f, 'Thing', 'def', '').passed
	assert !check_ast_assert(f, 'nothing', 'def', '').passed

	// has_parameter makes no sense for a class, and says so
	cls := check_ast_assert(f, 'Thing', 'class', 'x')
	assert !cls.passed
	assert cls.detail.contains('not supported for'), cls.detail
}

fn test_ast_assert_handles_multiline_signatures() {
	dir := judge_dir('ast2')
	f := os.join_path(dir, 'wrap.py')
	os.write_file(f, 'def build(\n    first: int,\n    second: str = "x",\n' +
		') -> None:\n    pass\n') or { panic(err) }
	assert check_ast_assert(f, 'build', 'def', 'first').passed
	assert check_ast_assert(f, 'build', 'def', 'second').passed
	assert !check_ast_assert(f, 'build', 'def', 'third').passed
}

fn test_diff_assert_forbid_and_require() {
	dir := judge_dir('diff')
	f := os.join_path(dir, 'a.py')
	os.write_file(f, 'def f():\n    return 1\n') or { panic(err) }

	clean := check_diff_assert(f, [r'print\(', 'TODO'], [r'def \w+'])
	assert clean.passed, clean.detail

	os.write_file(f, 'def f():\n    print("debug")\n    return 1\n') or { panic(err) }
	dirty := check_diff_assert(f, [r'print\('], [])
	assert !dirty.passed
	assert dirty.detail.contains('forbidden pattern'), dirty.detail

	absent := check_diff_assert(f, [], ['class Missing'])
	assert !absent.passed
	assert absent.detail.contains('required pattern'), absent.detail
}

fn test_file_unchanged_detects_edits() {
	dir := judge_dir('unchanged')
	f := os.join_path(dir, 'lock.txt')
	os.write_file(f, 'pinned\n') or { panic(err) }
	baseline := hash('pinned\n')

	assert check_file_unchanged(f, baseline).passed
	os.write_file(f, 'pinned\nplus-one\n') or { panic(err) }
	changed := check_file_unchanged(f, baseline)
	assert !changed.passed
	assert changed.detail.contains('changed'), changed.detail
}

fn test_exit_code_and_output_predicates() {
	assert check_exit_code('exit 0', 0, 10).passed
	assert !check_exit_code('exit 1', 0, 10).passed
	assert check_exit_code('exit 3', 3, 10).passed

	out := check_command_output_contains('echo hello-world', 'hello-world', 10)
	assert out.passed, out.detail
	assert !check_command_output_contains('echo hello', 'goodbye', 10).passed
}

fn test_tool_delta_counts_error_lines() {
	clean := check_tool_delta('echo "all good"', 0, 10)
	assert clean.passed, clean.detail

	dirty := check_tool_delta('echo "src/x.py:12: error: bad type"', 0, 10)
	assert !dirty.passed
	assert dirty.detail.contains('1 errors'), dirty.detail

	allowed := check_tool_delta('echo "src/x.py:12: error: bad type"', 1, 10)
	assert allowed.passed, allowed.detail
}

fn test_judge_seals_every_verdict() {
	mut log, mut j := new_test_judge('verdicts')
	defer {
		log.close()
	}
	j.check({
		'type': json2.Any('file_exists')
		'path': json2.Any('/definitely/missing')
	})
	j.check({
		'type': json2.Any('exit_code')
		'command': json2.Any('exit 0')
	})
	verdicts := fold(mut log, '').verdicts
	assert verdicts.len == 2
	recent := j.recent_verdicts(2)
	// newest first
	assert jstr(recent[0], 'kind') == 'exit_code'
	assert jbool(recent[0], 'passed')
	assert !jbool(recent[1], 'passed')
}

fn test_invalid_predicates_never_pass() {
	mut log, mut j := new_test_judge('invalid')
	defer {
		log.close()
	}
	assert !j.check(map[string]json2.Any{}).passed
	assert !j.check({
		'type': json2.Any('nonsense')
	}).passed
	assert !j.check({
		'type': json2.Any('file_contains')
	}).passed

	// an empty `text` would match any file at all — it must be refused
	dir := judge_dir('empty')
	f := os.join_path(dir, 'x.txt')
	os.write_file(f, 'anything') or { panic(err) }
	empty := j.check({
		'type': json2.Any('file_contains')
		'path': json2.Any(f)
		'text': json2.Any('')
	})
	assert !empty.passed
	assert empty.detail.contains('would match any file'), empty.detail
}

fn test_check_all_requires_every_predicate() {
	mut log, mut j := new_test_judge('all')
	defer {
		log.close()
	}
	ok, verdicts := j.check_all([
		{
			'type':    json2.Any('exit_code')
			'command': json2.Any('exit 0')
		},
		{
			'type':    json2.Any('exit_code')
			'command': json2.Any('exit 1')
		},
	])
	assert !ok
	assert verdicts.len == 2
	assert verdicts[0].passed && !verdicts[1].passed
}

fn test_structured_failure_extracts_location() {
	mut log, mut j := new_test_judge('failure')
	defer {
		log.close()
	}
	v := Verdict{
		passed:   false
		kind:     'file_contains'
		detail:   "'def foo' not found at src/x.py:42"
		evidence: 'some line'
	}
	f := j.failure(v, 'while proving C1')
	assert jstr(f, 'kind') == 'ASSERTION'
	assert jstr(f, 'location') == 'src/x.py:42', jstr(f, 'location')
	assert jstr(f, 'context') == 'while proving C1'
	assert jstr(f, 'suggested_next').contains('do not retry')

	exc := j.failure(Verdict{ passed: false, kind: 'exit_code', detail: 'boom' }, '')
	assert jstr(exc, 'kind') == 'EXCEPTION'
}

fn test_flake_detection_records_a_fact() {
	mut log, mut j := new_test_judge('flake')
	defer {
		log.close()
	}
	// a command that fails the first time and passes afterwards
	dir := judge_dir('flake')
	marker := os.join_path(dir, 'ran')
	cmd := 'if [ -f ${marker} ]; then exit 0; else touch ${marker}; exit 1; fi'
	v := j.check_with_retry({
		'type':    json2.Any('exit_code')
		'command': json2.Any(cmd)
	}, 3)
	assert v.passed
	assert v.kind == 'flake'
	assert v.detail.contains('FLAKE detected'), v.detail
	facts := fold(mut log, '').facts
	assert facts.len == 1
	assert jstr(facts[0], 'kind') == 'flake'
}

fn test_evidence_is_bounded() {
	dir := judge_dir('evidence')
	f := os.join_path(dir, 'big.txt')
	os.write_file(f, 'needle ' + 'x'.repeat(5000)) or { panic(err) }
	v := check_file_contains(f, 'needle')
	assert v.passed
	assert v.evidence.len <= evidence_limit + 3, '${v.evidence.len}'
}
