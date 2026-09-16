module vagent

import x.json2

const exemption_spec = '§1 Writes stay under src/ and tests/
@enforce confine_paths: src, tests
@except path CHANGELOG.md
@except path docs/**

§2 No secrets in source
@enforce forbid_content: (?i)api[_-]?key\\s*=\\s*["\\\'][A-Za-z0-9]
@except when tests/fixtures/* SECRET_DETECTION_FIXTURE

§3 Nothing is ever deleted
@enforce forbid_effect: delete
@except tool delete_path
'

fn ex_args(pairs map[string]string) map[string]json2.Any {
	mut out := map[string]json2.Any{}
	for k, v in pairs {
		out[k] = json2.Any(v)
	}
	return out
}

struct ExemptionHarness {
mut:
	cov &Covenant
	ex  &Exemptions
}

fn exemption_harness(name string) ExemptionHarness {
	mut log := new_event_log(tmp_log_path(name), 'main', 'test')
	return ExemptionHarness{
		cov: new_covenant(log, exemption_spec)
		ex:  new_exemptions(log, exemption_spec)
	}
}

fn (mut h ExemptionHarness) judge(tool string, args map[string]json2.Any) []Violation {
	v := h.cov.check(tool, args)
	return h.ex.narrow(v, tool, derive(tool, args))
}

fn test_the_spec_parses_into_exactly_its_exceptions() {
	items, errors := parse_exemptions(exemption_spec)
	assert items.len == 4, '${items.len}'
	assert errors.len == 0, '${errors}'
	assert items[0].clause == '1' && items[0].kind == 'path'
	assert items[2].kind == 'when' && items[2].where == 'tests/fixtures/*'
	assert items[3].kind == 'tool' && items[3].value == 'delete_path'
}

fn test_the_rule_still_holds_where_no_exception_applies() {
	mut h := exemption_harness('ex1')
	assert h.judge('write_file', ex_args({
		'path':    '/etc/passwd'
		'content': 'x'
	})).len > 0
	assert h.judge('run_command', ex_args({
		'command': 'echo x > /etc/y'
	})).len > 0
}

fn test_the_declared_exceptions_are_forgiven_by_any_route() {
	mut h := exemption_harness('ex2')
	assert h.judge('write_file', ex_args({
		'path':    'CHANGELOG.md'
		'content': '## 1.0'
	})).len == 0
	assert h.judge('write_file', ex_args({
		'path':    'docs/guide.md'
		'content': 'hi'
	})).len == 0
	assert h.judge('write_file', ex_args({
		'path':    'docs/deep/nested.md'
		'content': 'hi'
	})).len == 0
	// the shell route is judged the same way, so it is forgiven the same way
	assert h.judge('run_command', ex_args({
		'command': 'echo x > CHANGELOG.md'
	})).len == 0
}

fn test_an_exemption_is_scoped_to_its_own_clause() {
	mut h := exemption_harness('ex3')
	// a secret in CHANGELOG.md: §1 forgives the path, §2 still refuses
	left := h.judge('write_file', ex_args({
		'path':    'CHANGELOG.md'
		'content': 'API_KEY = "sk-abc1"'
	}))
	assert left.len > 0
	for v in left {
		assert v.clause == '2', v.clause
	}
}

fn test_when_scopes_content_forgiveness_to_matching_paths() {
	mut h := exemption_harness('ex4')
	assert h.judge('write_file', ex_args({
		'path':    'tests/fixtures/leak.py'
		'content': 'SECRET_DETECTION_FIXTURE\nAPI_KEY = "sk-a1"'
	})).len == 0

	// the same content outside the fixture directory is still refused
	assert h.judge('write_file', ex_args({
		'path':    'src/leak.py'
		'content': 'SECRET_DETECTION_FIXTURE\nAPI_KEY = "sk-a1"'
	})).len > 0
	// and inside the directory WITHOUT the marker it is still refused
	assert h.judge('write_file', ex_args({
		'path':    'tests/fixtures/other.py'
		'content': 'API_KEY = "sk-a1"'
	})).len > 0
}

fn test_a_tool_exemption_forgives_only_that_tool() {
	mut h := exemption_harness('ex5')
	assert h.judge('delete_path', ex_args({
		'path': 'src/a.py'
	})).len == 0
	// the same effect through the shell is not the exempted tool
	assert h.judge('run_command', ex_args({
		'command': 'rm -f src/a.py'
	})).len > 0
}

fn test_exemptions_never_create_permission() {
	mut log := new_event_log(tmp_log_path('ex6'), 'main', 'test')
	mut naked := new_exemptions(log, '§9 x\n@except path anything/*\n')
	assert naked.narrow([], 'write_file', []).len == 0

	// with no guards at all there is nothing to forgive, and nothing is
	// created either
	mut bare := new_covenant(log, '§9 x\n@except path anything/*\n')
	assert bare.guards().len == 0
	assert naked.narrow(bare.check('write_file', ex_args({
		'path':    '/etc/x'
		'content': 'y'
	})), 'write_file', []).len == 0
}

fn test_every_forgiveness_is_sealed_and_the_report_shows_which_carry_weight() {
	mut log := new_event_log(tmp_log_path('ex7'), 'main', 'test')
	mut cov := new_covenant(log, exemption_spec)
	mut ex := new_exemptions(log, exemption_spec)
	for args in [ex_args({
		'path':    'CHANGELOG.md'
		'content': '## 1.0'
	}), ex_args({
		'path':    'docs/guide.md'
		'content': 'hi'
	})] {
		ex.narrow(cov.check('write_file', args), 'write_file', derive('write_file', args))
	}
	applied := log.events('main').filter(it.typ == 'exemption.applied')
	assert applied.len == ex.applied
	assert ex.applied >= 2
	assert jstr(applied[0].data, 'clause') != ''
	assert jmap(applied[0].data, 'forgave').len > 0

	rep := ex.report()
	assert rep.contains('forgave')
	assert rep.contains('●')
	assert rep.contains('○')
}

fn test_malformed_exceptions_are_reported_never_guessed_at() {
	e := new_exemptions(new_event_log(tmp_log_path('ex8'), 'main', 'test'), '§9 x\n@except sideways foo\n' +
		'§10 y\n@except content [unclosed\n' + '§11 z\n@except when onlyoneword\n')
	assert e.errors.len == 3, '${e.errors}'
	assert e.items.len == 0
	assert e.report() == 'exemptions: none declared'
}
