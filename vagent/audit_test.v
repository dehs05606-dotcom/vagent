module vagent


import x.json2

fn json2_any_str(s string) json2.Any {
	return json2.Any(s)
}
fn audit_covenant(name string, spec string) &Covenant {
	mut log := new_event_log(tmp_log_path(name), 'main', 'test')
	return new_covenant(log, spec)
}

fn findings_at(rep &AuditReport, level string) []AuditFinding {
	return rep.findings.filter(it.level == level)
}

fn test_a_specification_that_really_binds_is_reported_as_binding() {
	cov := audit_covenant('aud1', '§1 Writes stay under src/ and tests/
@enforce confine_paths: src, tests

§2 No secrets in source
@enforce forbid_content: (?i)(api[_-]?key|token)\\s*=\\s*["\\\'][A-Za-z0-9]

§3 Nothing is ever deleted
@enforce forbid_effect: delete

§4 Prose: write clearly and comment intent.
')
	rep := audit(cov, map[string]Tool{}, false, [])
	assert rep.enforcing(), rep.describe()
	assert rep.clauses == 4
	assert rep.enforced == 3
	assert rep.refused > 0 && rep.allowed > 0
	// the ordinary in-project probes are not refused
	assert rep.allowed >= 4, rep.describe()
	// every enforced clause fired on something
	assert findings_at(&rep, 'silent').len == 0, rep.describe()
	mut keys := rep.by_clause.keys()
	keys.sort()
	assert keys == ['1', '2', '3'], '${keys}'
}

fn test_prose_only_gets_the_honest_verdict() {
	cov := audit_covenant('aud2', '§1 Be careful.\n§2 Write good code.\n')
	rep := audit(cov, map[string]Tool{}, false, [])
	assert !rep.enforcing()
	assert rep.enforced == 0
	assert rep.refused == 0
	assert rep.describe().contains('every clause is prose')
}

fn test_a_bound_rule_that_nothing_can_trigger_is_reported_as_silent() {
	cov := audit_covenant('aud3', '§5 Rust modules need a header\n' +
		'@enforce {"kind": "require_content", "value": "^//!", "where": "*.rs"}\n')
	rep := audit(cov, map[string]Tool{}, false, [])
	assert findings_at(&rep, 'silent').len > 0, rep.describe()
	assert !rep.enforcing()
	assert rep.describe().contains('nothing in the probe corpus made it fire')
}

fn test_a_contradiction_is_named_as_one() {
	cov := audit_covenant('aud4', '§6 Work only in src\n@enforce confine_paths: src\n' +
		'§7 src is off limits\n@enforce forbid_path: src\n')
	rep := audit(cov, map[string]Tool{}, false, [])
	bad := findings_at(&rep, 'contradiction')
	assert bad.len > 0
	assert bad[0].detail.contains('no write can satisfy both')
	assert bad[0].clause == '6+7'
}

fn test_two_clauses_saying_the_same_thing_are_reported_as_redundant() {
	cov := audit_covenant('aud5', '§8 no deleting\n@enforce forbid_effect: delete\n' +
		'§9 really, no deleting\n@enforce forbid_effect: delete\n')
	rep := audit(cov, map[string]Tool{}, false, [])
	dup := findings_at(&rep, 'redundant')
	assert dup.len > 0, rep.describe()
	assert dup[0].detail.contains('editing one will not move the other')
}

fn test_forbidding_a_tool_that_does_not_exist_is_unreachable() {
	cov := audit_covenant('aud6', '§10 never use it\n@enforce forbid_tool: no_such_tool\n')
	rep := audit(cov, build_registry(), true, [])
	ghost := findings_at(&rep, 'unreachable')
	assert ghost.len > 0, rep.describe()
	assert ghost[0].detail.contains('not in the registry')

	// a tool that IS in the registry is reachable
	real := audit_covenant('aud6b', '§10 never use it\n@enforce forbid_tool: delete_path\n')
	rep2 := audit(real, build_registry(), true, [])
	assert findings_at(&rep2, 'unreachable').len == 0
}

fn test_malformed_rules_surface_in_the_audit_too() {
	cov := audit_covenant('aud7', '§11 x\n@enforce forbid_content: [unclosed\n')
	rep := audit(cov, map[string]Tool{}, false, [])
	assert rep.errors.len > 0
	assert !rep.enforcing()
	assert rep.describe().contains('!!')
}

fn test_an_empty_specification_says_nothing_is_bound() {
	cov := audit_covenant('aud8', '')
	rep := audit(cov, map[string]Tool{}, false, [])
	assert rep.clauses == 0
	assert rep.describe() == 'audit: no specification is bound'
}

fn test_the_corpus_covers_the_routes_one_act_can_be_spelled_by() {
	// the corpus is fixed, so two audits of the same spec are comparable
	assert audit_probes.len == 30
	tools := uniq_strings(audit_probes.map(it.tool))
	for expected in ['write_file', 'edit_file', 'run_command', 'apply_patch',
		'delete_path', 'live_shell'] {
		assert expected in tools, expected
	}
	// and a confining clause catches the evasions, not just the direct write
	cov := audit_covenant('aud9', '§1 stay in src\n@enforce confine_paths: src, tests\n')
	rep := audit(cov, map[string]Tool{}, false, [])
	assert rep.by_clause['1'] >= 6, rep.describe()
}

fn test_a_caller_may_supply_its_own_corpus() {
	cov := audit_covenant('aud10', '§1 stay in src\n@enforce confine_paths: src\n')
	rep := audit(cov, map[string]Tool{}, false, [
		AuditProbe{
			tool: 'write_file'
			args: {
				'path':    json2_any_str('/etc/x')
				'content': json2_any_str('y')
			}
		},
	])
	assert rep.probes == 1
	assert rep.refused == 1
	assert rep.allowed == 0
}
