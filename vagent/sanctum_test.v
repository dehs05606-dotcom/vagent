module vagent

import os
import x.json2

struct SanctumFixture {
mut:
	root string
	pkg  string
	spec string
	log  &EventLog
}

fn sanctum_fixture(name string) SanctumFixture {
	root := os.join_path(os.temp_dir(), 'vagent-sanctum-${name}-${os.getpid()}')
	os.rmdir_all(root) or {}
	pkg := os.join_path(root, 'pkg')
	os.mkdir_all(pkg) or { panic(err) }
	for module_name in protected_modules {
		os.write_file(os.join_path(pkg, module_name), '// ${module_name}\n') or { panic(err) }
	}
	spec := os.join_path(root, 'project.txt')
	os.write_file(spec, '§1 a rule\n') or { panic(err) }
	return SanctumFixture{
		root: root
		pkg:  pkg
		spec: spec
		log:  new_event_log(os.join_path(root, 'log.jsonl'), 'main', 'test')
	}
}

fn sa_args(pairs map[string]string) map[string]json2.Any {
	mut out := map[string]json2.Any{}
	for k, v in pairs {
		out[k] = json2.Any(v)
	}
	return out
}

fn test_the_boundarys_own_code_and_spec_cannot_be_written() {
	mut f := sanctum_fixture('s1')
	defer {
		os.rmdir_all(f.root) or {}
	}
	mut s := new_sanctum(f.log, f.spec, f.pkg)
	assert s.sealed.len == protected_modules.len + 1

	for name in ['covenant.v', 'charter.v', 'effects.v', 'sanctum.v'] {
		blocked := s.gate('write_file', sa_args({
			'path':    os.join_path(f.pkg, name)
			'content': 'x'
		}))
		assert blocked.contains('SanctumViolation'), name
		assert blocked.contains('cannot be excepted'), name
	}
	assert s.gate('write_file', sa_args({
		'path':    f.spec
		'content': 'x'
	})) != ''
}

fn test_it_holds_by_any_route_because_it_judges_effects() {
	mut f := sanctum_fixture('s2')
	defer {
		os.rmdir_all(f.root) or {}
	}
	mut s := new_sanctum(f.log, f.spec, f.pkg)
	cov := os.join_path(f.pkg, 'covenant.v')
	for cmd in ['echo x > ${cov}', 'cp /dev/null ${cov}', 'rm -f ${cov}',
		"sed -i 's/a/b/' ${cov}", 'mv ${cov} /tmp/gone',
		"cat > ${cov} <<'EOF'\nx\nEOF", "sed -i 's/rule/x/' ${f.spec}"] {
		assert s.gate('run_command', sa_args({
			'command': cmd
		})) != '', cmd
	}
	assert s.gate('live_shell', sa_args({
		'command': 'truncate -s 0 ${cov}'
	})) != ''
	assert s.gate('delete_path', sa_args({
		'path': cov
	})) != ''
}

fn test_a_package_relative_spelling_is_matched_too() {
	mut f := sanctum_fixture('s3')
	defer {
		os.rmdir_all(f.root) or {}
	}
	mut s := new_sanctum(f.log, f.spec, f.pkg)
	rel := '${os.base(f.pkg)}/covenant.v'

	// the spelling an agent working from the repository root produces
	assert s.gate('apply_patch', sa_args({
		'patch': '--- a/${rel}\n+++ b/${rel}\n@@ -1 +1 @@\n+x\n'
	})) != '', 'a package-relative patch reached the boundary'
	assert s.gate('write_file', sa_args({
		'path':    rel
		'content': 'x'
	})) != ''
	assert s.gate('run_command', sa_args({
		'command': 'echo x > ${rel}'
	})) != ''
	assert s.gate('run_command', sa_args({
		'command': 'echo x > deep/nested/${rel}'
	})) != ''

	// and a different spelling of the same absolute file
	assert s.gate('write_file', sa_args({
		'path':    os.join_path(f.pkg, './covenant.v')
		'content': 'x'
	})) != ''
	assert s.gate('write_file', sa_args({
		'path':    os.join_path(f.pkg, 'sub/../covenant.v')
		'content': 'x'
	})) != ''
}

fn test_ordinary_work_is_untouched() {
	mut f := sanctum_fixture('s4')
	defer {
		os.rmdir_all(f.root) or {}
	}
	mut s := new_sanctum(f.log, f.spec, f.pkg)
	assert s.gate('write_file', sa_args({
		'path':    os.join_path(f.root, 'src/app.v')
		'content': 'x = 1'
	})) == ''
	assert s.gate('run_command', sa_args({
		'command': 'pytest -q'
	})) == ''
	// reading the boundary is fine; only changing it is not
	assert s.gate('read_file', sa_args({
		'path': os.join_path(f.pkg, 'covenant.v')
	})) == ''
	// a file in the package that is not part of the boundary
	os.write_file(os.join_path(f.pkg, 'tui.v'), '// tui\n') or { panic(err) }
	assert s.gate('write_file', sa_args({
		'path':    os.join_path(f.pkg, 'tui.v')
		'content': 'x'
	})) == ''
}

fn test_it_holds_with_no_specification_at_all() {
	mut f := sanctum_fixture('s5')
	defer {
		os.rmdir_all(f.root) or {}
	}
	mut bare := new_sanctum(f.log, '', f.pkg)
	assert bare.gate('write_file', sa_args({
		'path':    os.join_path(f.pkg, 'charter.v')
		'content': 'x'
	})) != '', 'the invariant needed a specification to exist'
}

fn test_content_addresses_catch_a_change_made_by_any_other_route() {
	mut f := sanctum_fixture('s6')
	defer {
		os.rmdir_all(f.root) or {}
	}
	mut s := new_sanctum(f.log, f.spec, f.pkg)
	assert s.verify().len == 0

	os.write_file(os.join_path(f.pkg, 'covenant.v'), '// rewritten elsewhere\n') or { panic(err) }
	changes := s.verify()
	assert changes.len == 1
	assert changes[0].what == 'module'
	assert changes[0].describe().contains('changed since startup')
	assert s.report().contains('!!')

	// a removed file is reported, not silently forgotten
	os.rm(os.join_path(f.pkg, 'charter.v')) or { panic(err) }
	assert s.verify().any(it.describe().contains('removed or is unreadable'))

	// re-sealing accepts the current state deliberately
	os.write_file(os.join_path(f.pkg, 'charter.v'), '// back\n') or { panic(err) }
	s.seal()
	assert s.verify().len == 0

	// a specification change is a change too
	os.write_file(f.spec, '§1 a rule\n§2 another\n') or { panic(err) }
	spec_change := s.verify()
	assert spec_change.len == 1
	assert spec_change[0].what == 'specification'
}

fn test_every_outcome_is_sealed() {
	mut f := sanctum_fixture('s7')
	defer {
		os.rmdir_all(f.root) or {}
	}
	mut s := new_sanctum(f.log, f.spec, f.pkg)
	s.gate('write_file', sa_args({
		'path':    os.join_path(f.pkg, 'covenant.v')
		'content': 'x'
	}))
	os.write_file(os.join_path(f.pkg, 'covenant.v'), '// changed\n') or { panic(err) }
	s.verify()
	kinds := f.log.events('main').map(it.typ)
	assert 'sanctum.sealed' in kinds
	assert 'sanctum.blocked' in kinds
	assert 'sanctum.changed' in kinds
}

fn test_with_no_package_directory_the_tail_spelling_still_holds() {
	mut f := sanctum_fixture('s8')
	defer {
		os.rmdir_all(f.root) or {}
	}
	// a built binary has no source tree beside it
	mut s := new_sanctum(f.log, '', '')
	assert s.sealed.len == 0
	assert s.gate('write_file', sa_args({
		'path':    'vagent/covenant.v'
		'content': 'x'
	})) != ''
	assert s.gate('write_file', sa_args({
		'path':    'src/app.v'
		'content': 'x'
	})) == ''
}
