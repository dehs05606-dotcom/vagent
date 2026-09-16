module vagent

import os
import x.json2

fn cov_log(name string) &EventLog {
	return new_event_log(tmp_log_path('${name}.jsonl'), 'main', '')
}

const sample_spec = '
Preamble text that belongs to no numbered clause.

§1 Source layout
Application code lives under src/ and tests under tests/.
@enforce confine_paths: src, tests

§2 Secrets never appear in source
@enforce forbid_content: (?i)api[_-]?key\\s*=\\s*["\'][A-Za-z0-9]

§3 Destructive shell forms are never used
@enforce forbid_command: rm\\s+-rf\\s+/

§4 Deleting files is not this agent\'s job
@enforce forbid_tool: delete_path
'

fn test_parse_clauses_addresses_every_byte() {
	clauses, errors := parse_clauses(sample_spec)
	assert errors.len == 0, '${errors}'
	ids := clauses.map(it.id)
	assert 'preamble' in ids, '${ids}'
	assert '1' in ids && '2' in ids && '3' in ids && '4' in ids, '${ids}'

	// the preamble carries the text before the first header
	preamble := clauses.filter(it.id == 'preamble')[0]
	assert preamble.body.contains('belongs to no numbered clause')
	assert !preamble.enforced()

	// each numbered clause carries its rule
	one := clauses.filter(it.id == '1')[0]
	assert one.title == 'Source layout'
	assert one.enforced()
	assert one.guards[0].kind == 'confine_paths'
	assert one.guards[0].roots == ['src', 'tests']
}

fn test_clause_ids_are_unique_and_slugged() {
	clauses, _ := parse_clauses('## First Heading\nbody\n## First Heading\nmore\n')
	ids := clauses.map(it.id)
	assert 'first-heading' in ids, '${ids}'
	assert 'first-heading#2' in ids, '${ids}'

	tagged, _ := parse_clauses('[no-secrets] Keep keys out\nbody\n')
	assert tagged[0].id == 'no-secrets'
	assert tagged[0].title == 'Keep keys out'
}

fn test_fingerprint_changes_with_the_text() {
	a := Clause{ id: 'x', title: 't', body: 'one' }
	b := Clause{ id: 'x', title: 't', body: 'two' }
	assert a.fingerprint() != b.fingerprint()
	assert a.fingerprint().len == 16
}

fn test_malformed_rules_are_reported_not_guessed() {
	cases := [
		'§1 x\n@enforce nonsense_kind: v\n',
		'§1 x\n@enforce forbid_content: (unclosed\n',
		'§1 x\n@enforce forbid_content:\n',
		'§1 x\n@enforce require_content: foo\n', // no `where`
		'§1 x\n@enforce forbid_tool:\n',
		'§1 x\n@enforce forbid_effect: teleport\n',
		'§1 x\n@enforce confine_paths:\n',
		'§1 x\n@enforce forbid_path:\n',
		'§1 x\n@enforce {not json}\n',
	]
	for case_spec in cases {
		clauses, errors := parse_clauses(case_spec)
		assert errors.len == 1, 'no error for: ${case_spec}'
		// a rule that failed to parse does NOT quietly become a guard
		assert !clauses.filter(it.id == '1')[0].enforced(), case_spec
	}
}

fn test_json_rules_may_span_lines() {
	json_spec := '§5 Python modules carry a docstring\n' +
		'@enforce {"kind": "require_content", "value": "^\\\\s*docstring",\n' +
		'          "where": "*.py"}\n'
	clauses, errors := parse_clauses(json_spec)
	assert errors.len == 0, '${errors}'
	g := clauses.filter(it.id == '5')[0].guards[0]
	assert g.kind == 'require_content'
	assert g.where == '*.py'
}

// -- effects -----------------------------------------------------------------

fn kinds_of(effects []Effect) []string {
	return effects.map(it.kind)
}

fn test_derive_names_direct_tool_effects() {
	w := derive('write_file', {
		'path':    json2.Any('src/a.py')
		'content': json2.Any('x = 1')
	})
	assert w.len == 1 && w[0].kind == effect_write
	assert w[0].path == 'src/a.py' && w[0].content == 'x = 1'

	d := derive('delete_path', {
		'path': json2.Any('src/a.py')
	})
	assert d[0].kind == effect_delete

	mv := derive('move_path', {
		'src': json2.Any('a')
		'dst': json2.Any('b')
	})
	assert effect_delete in kinds_of(mv) && effect_write in kinds_of(mv)
}

fn test_shell_redirection_is_a_write() {
	e := derive('run_command', {
		'command': json2.Any('echo boom > /etc/cron.d/x')
	})
	writes := e.filter(it.kind == effect_write)
	assert writes.len == 1, '${e}'
	assert writes[0].path == '/etc/cron.d/x'
	// the written CONTENT is known, so a content rule can see it
	assert writes[0].content.contains('boom')
	assert effect_exec in kinds_of(e)
}

fn test_known_shell_commands_map_to_effects() {
	assert effect_delete in kinds_of(derive('run_command', {
		'command': json2.Any('rm -f src/a.py')
	}))
	assert effect_write in kinds_of(derive('run_command', {
		'command': json2.Any('touch src/new.py')
	}))
	assert effect_write in kinds_of(derive('run_command', {
		'command': json2.Any('cp a.py src/b.py')
	}))
	assert effect_write in kinds_of(derive('run_command', {
		'command': json2.Any('tee out.txt')
	}))
	assert effect_write in kinds_of(derive('run_command', {
		'command': json2.Any('sed -i s/a/b/ src/x.py')
	}))
	assert effect_write in kinds_of(derive('run_command', {
		'command': json2.Any('dd if=/dev/zero of=out.img')
	}))
}

fn test_unanalysable_commands_are_opaque() {
	for cmd in ['eval "\$X"', 'bash -c "\$CMD"', 'python -c "open(1)"',
		'xargs rm', 'echo hi > \$DIR/f'] {
		e := derive('run_command', {
			'command': json2.Any(cmd)
		})
		assert effect_opaque in kinds_of(e), 'not opaque: ${cmd} -> ${kinds_of(e)}'
	}
	// an ordinary command is NOT opaque
	plain := derive('run_command', {
		'command': json2.Any('ls -la src')
	})
	assert effect_opaque !in kinds_of(plain)
}

fn test_patch_effects_reach_every_file() {
	patch := '--- a/src/one.py\n+++ b/src/one.py\n@@ -1 +1 @@\n-old\n+new line\n' +
		'--- a/etc/two.py\n+++ b/etc/two.py\n@@ -1 +1 @@\n-x\n+y\n'
	e := derive('apply_patch', {
		'patch': json2.Any(patch)
	})
	paths := e.map(it.path)
	assert 'src/one.py' in paths && 'etc/two.py' in paths, '${paths}'
	assert e.filter(it.path == 'src/one.py')[0].content.contains('new line')
}

// -- the boundary ------------------------------------------------------------

fn test_confine_paths_holds_across_every_route() {
	mut log := cov_log('cov-confine')
	defer {
		log.close()
	}
	mut cov := new_covenant(log, sample_spec)

	// the direct route
	assert cov.gate('write_file', {
		'path':    json2.Any('/etc/passwd')
		'content': json2.Any('x')
	}) != ''
	// the same act spelled as a shell redirect is refused identically
	assert cov.gate('run_command', {
		'command': json2.Any('echo x > /etc/passwd')
	}) != ''
	// a write inside the permitted roots passes
	assert cov.gate('write_file', {
		'path':    json2.Any('src/ok.py')
		'content': json2.Any('x')
	}) == ''
}

fn test_a_traversal_cannot_slip_a_root() {
	mut log := cov_log('cov-traverse')
	defer {
		log.close()
	}
	mut cov := new_covenant(log, '§1 x\n@enforce confine_paths: src\n')
	assert cov.gate('write_file', {
		'path':    json2.Any('src/../etc/passwd')
		'content': json2.Any('x')
	}) != ''
}

fn test_opaque_effects_fail_a_containment_clause() {
	mut log := cov_log('cov-opaque')
	defer {
		log.close()
	}
	mut cov := new_covenant(log, '§1 x\n@enforce confine_paths: src\n')
	reason := cov.gate('run_command', {
		'command': json2.Any('bash -c "\$CMD"')
	})
	assert reason != '', 'an unprovable claim passed as a proven one'
	assert reason.contains('cannot be determined before running'), reason

	// where the author declared NO containment, an opaque command runs
	mut open_cov := new_covenant(log, '§1 x\n@enforce forbid_tool: delete_path\n')
	assert open_cov.gate('run_command', {
		'command': json2.Any('bash -c "\$CMD"')
	}) == ''
}

fn test_content_and_command_rules() {
	mut log := cov_log('cov-content')
	defer {
		log.close()
	}
	mut cov := new_covenant(log, sample_spec)

	secret := cov.gate('write_file', {
		'path':    json2.Any('src/conf.py')
		'content': json2.Any('API_KEY = "abc123"')
	})
	assert secret != '', 'a secret was written into source'
	assert secret.contains('§') || secret.contains('2'), secret

	assert cov.gate('run_command', {
		'command': json2.Any('rm -rf /')
	}) != ''
	assert cov.gate('delete_path', {
		'path': json2.Any('src/x.py')
	}) != ''
}

fn test_require_content_is_scoped_by_where() {
	mut log := cov_log('cov-require')
	defer {
		log.close()
	}
	mut cov := new_covenant(log, '§1 x\n' +
		'@enforce {"kind":"require_content","value":"LICENSE","where":"*.py"}\n')
	// a .py file without the required text is refused
	assert cov.gate('write_file', {
		'path':    json2.Any('a.py')
		'content': json2.Any('x = 1')
	}) != ''
	// with it, it passes
	assert cov.gate('write_file', {
		'path':    json2.Any('a.py')
		'content': json2.Any('# LICENSE\nx = 1')
	}) == ''
	// an unrelated file is out of scope entirely
	assert cov.gate('write_file', {
		'path':    json2.Any('notes.txt')
		'content': json2.Any('x = 1')
	}) == ''
}

fn test_arming_makes_the_boundary_unavoidable() {
	mut log := cov_log('cov-arm')
	defer {
		log.close()
	}
	dir := os.join_path(os.temp_dir(), 'vagent-cov-${os.getpid()}')
	os.rmdir_all(dir) or {}
	os.mkdir_all(dir) or { panic(err) }

	mut cov := new_covenant(log, '§1 x\n@enforce confine_paths: ${dir}/src\n')
	armed := cov.arm(build_registry())
	assert armed['write_file'] or { Tool{ handler: no_tool } }.guarded

	// calling the handler DIRECTLY — the route crew.py used — still passes
	// the boundary, because the unguarded handler is unreachable
	outside := os.join_path(dir, 'outside.txt')
	res := armed['write_file'] or { panic('') }.handler({
		'path':    json2.Any(outside)
		'content': json2.Any('x')
	}, no_sink)
	assert res.starts_with('ERROR: CovenantViolation'), res
	assert !os.exists(outside), 'the refused write still landed'

	// and reaching the wrapper without the gate is itself recorded
	mut saw := false
	for e in log.events('') {
		if e.typ == 'covenant.bypassed' {
			saw = true
		}
	}
	assert saw, 'a bypass was not sealed'

	// a permitted write goes through
	inside := os.join_path(dir, 'src', 'ok.txt')
	ok := armed['write_file'] or { panic('') }.handler({
		'path':    json2.Any(inside)
		'content': json2.Any('x')
	}, no_sink)
	assert ok.starts_with('OK: created'), ok

	// arming is idempotent
	twice := cov.arm(armed)
	assert twice['write_file'] or { Tool{ handler: no_tool } }.guarded
}

fn no_tool(args map[string]json2.Any, sink OutputSink) string {
	return ''
}

fn test_unnamed_tools_are_reported_not_hidden() {
	gaps := unnamed_tools(build_registry())
	// read_file has no effects to derive, so containment clauses do not
	// reach it — that limit is reported rather than passing for coverage
	assert 'read_file' in gaps, '${gaps}'
	assert 'write_file' !in gaps
	assert 'run_command' !in gaps
}

fn test_report_shows_what_is_bound_and_what_is_not() {
	mut log := cov_log('cov-report')
	defer {
		log.close()
	}
	mut cov := new_covenant(log, sample_spec)
	assert new_covenant(log, '').report() == 'covenant: no specification bound'

	before := cov.report()
	assert before.contains('4 enforced'), before
	assert before.contains('○'), 'an unhit clause should be marked'
	assert before.contains('carry no @enforce rule'), before

	cov.gate('delete_path', {
		'path': json2.Any('x')
	})
	after := cov.report()
	assert after.contains('●'), 'a clause that caught something should be marked'
	assert after.contains('1 block'), after
}

fn test_every_evaluation_is_sealed() {
	mut log := cov_log('cov-sealed')
	defer {
		log.close()
	}
	mut cov := new_covenant(log, sample_spec)
	cov.gate('delete_path', {
		'path': json2.Any('x')
	})
	mut blocked := 0
	for e in log.events('') {
		if e.typ == 'covenant.blocked' {
			blocked++
		}
	}
	assert blocked == 1
	assert cov.stats().blocked == 1
}
