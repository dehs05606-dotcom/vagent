module vagent

import os
import x.json2

const charter_spec = '§1 Writes stay under src/ and tests/
@enforce confine_paths: src, tests
@except path CHANGELOG.md

§2 No secrets in source
@enforce forbid_content: (?i)api[_-]?key\\s*=\\s*["\\\'][A-Za-z0-9]

§3 Nothing is ever deleted
@enforce forbid_effect: delete

§4 A change touches at most 2 files
@horizon per turn max files_written 2

§5 Every module ships with a test
@oblige on write src/**/*.py require exists tests/test_{stem}.py

§6 The agent reaches only the package index
@egress allow_hosts pypi.org

§7 A turn costs at most one dollar
@ration per turn max cost_usd 1.00
'

fn ch_args(pairs map[string]string) map[string]json2.Any {
	mut out := map[string]json2.Any{}
	for k, v in pairs {
		out[k] = json2.Any(v)
	}
	return out
}

struct CharterFixture {
mut:
	root string
	pkg  string
	ch   &Charter
}

fn charter_fixture(name string, spec string) CharterFixture {
	root := os.join_path(os.temp_dir(), 'vagent-charter-${name}-${os.getpid()}')
	os.rmdir_all(root) or {}
	pkg := os.join_path(root, 'pkg')
	os.mkdir_all(pkg) or { panic(err) }
	for module_name in protected_modules {
		os.write_file(os.join_path(pkg, module_name), '// ${module_name}\n') or { panic(err) }
	}
	mut log := new_event_log(os.join_path(root, 'log.jsonl'), 'main', 'test')
	store := new_snapshot_store(os.join_path(root, 'store'))
	return CharterFixture{
		root: root
		pkg:  pkg
		ch:   new_charter(log, CharterOpts{
			spec:        spec
			package_dir: pkg
			store:       store
			root:        root
		})
	}
}

fn test_one_gate_answers_for_every_subsystem() {
	mut f := charter_fixture('c1', charter_spec)
	defer {
		os.rmdir_all(f.root) or {}
	}
	assert f.ch.errors().len == 0, '${f.ch.errors()}'
	f.ch.open_turn()

	ok := f.ch.gate('write_file', ch_args({
		'path':    'src/a.py'
		'content': 'x = 1'
	}))
	assert ok.allowed

	bad := f.ch.gate('write_file', ch_args({
		'path':    '/etc/x'
		'content': 'y'
	}))
	assert !bad.allowed
	assert bad.source == 'covenant'
	assert bad.reason.contains('1')

	leak := f.ch.gate('write_file', ch_args({
		'path':    'src/c.py'
		'content': 'API_KEY = "sk-abc1"'
	}))
	assert !leak.allowed
	assert leak.reason.contains('2')

	gone := f.ch.gate('run_command', ch_args({
		'command': 'rm -f src/a.py'
	}))
	assert !gone.allowed
	assert gone.reason.contains('3')

	out := f.ch.gate('run_command', ch_args({
		'command': 'curl https://evil.test/x'
	}))
	assert !out.allowed
	assert out.source == 'egress', out.source

	// the refusal carries what WOULD be allowed
	assert bad.reason.contains('What would be allowed:')
	assert bad.reason.contains('not permission')
}

fn test_narrowing_applies_uniformly_wherever_the_refusal_came_from() {
	mut f := charter_fixture('c2', charter_spec)
	defer {
		os.rmdir_all(f.root) or {}
	}
	f.ch.open_turn()

	// an exemption declared in the specification
	forgiven := f.ch.gate('write_file', ch_args({
		'path':    'CHANGELOG.md'
		'content': '## 1.0'
	}))
	assert forgiven.allowed
	assert forgiven.forgiven == 1

	// a consent grant reaching a NON-covenant subsystem — the thing
	// per-subsystem plumbing could not do
	f.ch.horizon.spend('write_file', ch_args({
		'path':    'src/a.py'
		'content': 'x'
	}))
	f.ch.horizon.spend('write_file', ch_args({
		'path':    'src/b.py'
		'content': 'x'
	}))
	capped := f.ch.gate('write_file', ch_args({
		'path':    'src/c.py'
		'content': 'x'
	}))
	assert !capped.allowed
	assert capped.source == 'horizon', capped.source

	f.ch.consent.grant('4', GrantOpts{
		uses:   1
		ttl:    60.0
		reason: 'one more file'
	}) or { panic(err) }
	now := f.ch.gate('write_file', ch_args({
		'path':    'src/c.py'
		'content': 'x'
	}))
	assert now.allowed, now.reason
	assert now.forgiven == 1
	// and the grant was single-use
	assert !f.ch.gate('write_file', ch_args({
		'path':    'src/d.py'
		'content': 'x'
	})).allowed
}

fn test_budgets_are_asked_separately_about_model_calls() {
	mut f := charter_fixture('c3', charter_spec)
	defer {
		os.rmdir_all(f.root) or {}
	}
	f.ch.open_turn()
	assert f.ch.afford(Estimate{ cost_usd: 0.50 }).allowed
	f.ch.ration.spend(0.90, 0, 0, 0.0)
	broke := f.ch.afford(Estimate{ cost_usd: 0.50 })
	assert !broke.allowed
	assert broke.source == 'ration'
	assert broke.reason.contains('7')
	assert broke.reason.contains('What would be allowed:')
}

fn test_done_is_separate_from_allowed() {
	mut f := charter_fixture('c4', charter_spec)
	defer {
		os.rmdir_all(f.root) or {}
	}
	f.ch.open_turn()
	assert f.ch.blocker() == ''
	f.ch.settled('write_file', ch_args({
		'path':    'src/parser.py'
		'content': 'x'
	}), '', '', [])
	blocker := f.ch.blocker()
	assert blocker != ''
	assert blocker.contains('tests/test_parser.py'), blocker
	// the obligation does not refuse the discharging write
	assert f.ch.gate('write_file', ch_args({
		'path':    'tests/test_parser.py'
		'content': 't'
	})).allowed
}

fn test_the_invariant_holds_and_is_not_narrowable() {
	mut f := charter_fixture('c5', charter_spec)
	defer {
		os.rmdir_all(f.root) or {}
	}
	boundary := os.join_path(f.pkg, 'covenant.v')
	v := f.ch.gate('write_file', ch_args({
		'path':    boundary
		'content': '// gutted'
	}))
	assert !v.allowed
	assert v.source == 'sanctum', v.source
	assert v.reason.contains('cannot be excepted')

	// not even with a grant for it
	f.ch.consent.grant('sanctum', GrantOpts{
		uses:   1
		ttl:    60.0
		reason: 'try to bypass'
	}) or { panic(err) }
	shell := f.ch.gate('run_command', ch_args({
		'command': 'echo x > ${boundary}'
	}))
	assert !shell.allowed
	assert shell.source == 'sanctum', 'a grant bypassed the invariant'

	// and it holds with no specification whatsoever
	mut bare := charter_fixture('c5b', '')
	defer {
		os.rmdir_all(bare.root) or {}
	}
	assert !bare.ch.gate('write_file', ch_args({
		'path':    os.join_path(bare.pkg, 'covenant.v')
		'content': 'x'
	})).allowed
}

fn test_every_decision_is_witnessed_allowed_ones_included() {
	mut f := charter_fixture('c6', charter_spec)
	defer {
		os.rmdir_all(f.root) or {}
	}
	f.ch.open_turn()
	f.ch.gate('write_file', ch_args({
		'path':    'src/a.py'
		'content': 'x'
	}))
	f.ch.gate('write_file', ch_args({
		'path':    '/etc/x'
		'content': 'y'
	}))
	// a third decision, so the refusal sits in the middle of the chain and
	// removing it cannot leave a valid prefix
	f.ch.gate('read_file', ch_args({
		'path': 'src/a.py'
	}))
	a := f.ch.witness.verify([], false)
	assert a.ok()
	assert a.length == f.ch.allowed + f.ch.refused, '${a.length} vs ${f.ch.allowed}+${f.ch.refused}'
	assert a.allowed > 0 && a.refused > 0

	// the chain detects a removed refusal
	exported := f.ch.witness.export()
	mut tampered := exported.filter(jstr(it, 'verdict') != verdict_refused)
	for i, _ in tampered {
		tampered[i]['index'] = json2.Any(i)
	}
	assert !witness_check(tampered).intact
}

fn test_rebinding_moves_every_subsystem_together() {
	mut f := charter_fixture('c7', charter_spec)
	defer {
		os.rmdir_all(f.root) or {}
	}
	f.ch.bind('§9 nothing at all\n@enforce forbid_effect: write\n', '')
	assert !f.ch.gate('write_file', ch_args({
		'path':    'src/a.py'
		'content': 'x'
	})).allowed
	assert f.ch.covenant.clauses.len > 0
	assert f.ch.horizon.limits.len == 0
	assert f.ch.obligations.rules.len == 0
	assert f.ch.egress.rules.len == 0
}

fn test_an_empty_specification_refuses_nothing() {
	mut f := charter_fixture('c8', '')
	defer {
		os.rmdir_all(f.root) or {}
	}
	assert f.ch.gate('run_command', ch_args({
		'command': 'rm -rf /tmp/whatever'
	})).allowed
	assert f.ch.blocker() == ''
	assert f.ch.afford(Estimate{ cost_usd: 1e6 }).allowed
	assert f.ch.salient('anything', []) == ''
}

fn test_the_salient_block_restates_only_what_the_request_touches() {
	extra := charter_spec + '\n[SQL] Queries go through the repository layer\n' +
		'Never write SQL inline in a handler.\n'
	mut f := charter_fixture('c9', extra)
	defer {
		os.rmdir_all(f.root) or {}
	}
	blk := f.ch.salient('add a repository method for the orders query', [])
	assert blk.contains('repository layer'), blk
	assert blk.contains('CLAUSES THIS REQUEST TOUCHES')
	// an unrelated request restates nothing at all
	assert f.ch.salient('what time is it', []) == ''
}

fn test_malformed_rules_surface_in_one_place() {
	mut f := charter_fixture('c10', '§1 x\n@enforce nonsense: y\n' +
		'§2 y\n@horizon per fortnight max files_written 4\n' +
		'§3 z\n@ration per turn max sideways 4\n' + '§4 w\n@egress forbid_method pigeon\n' +
		'§5 v\n@oblige on write a require\n')
	defer {
		os.rmdir_all(f.root) or {}
	}
	assert f.ch.errors().len == 5, '${f.ch.errors()}'
	assert f.ch.report().contains('enforce NOTHING')
}
