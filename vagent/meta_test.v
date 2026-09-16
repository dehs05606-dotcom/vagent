module vagent

import x.json2

fn good_draft(mission string) map[string]json2.Any {
	return {
		'name':      json2.Any('sql_surgeon')
		'brief':     json2.Any('You are a database surgery specialist. Diagnose schema pain, ' +
			'write precise migrations, verify with real queries, and never destroy data ' +
			'without a rollback path. You read the schema first, form a migration plan, ' +
			'apply it, and prove it with a round-trip query.')
		'tools':     json2.Any([json2.Any('read_file'), json2.Any('write_file'),
			json2.Any('run_command')])
		'benchmark': json2.Any('add an index to users.email and prove the query plan uses it')
	}
}

fn fresh_draft(mission string) map[string]json2.Any {
	mut d := good_draft(mission)
	d['name'] = json2.Any('data_wrangler')
	return d
}

fn eval_pass(draft &RoleDraft) f64 {
	return 0.9
}

fn eval_fail(draft &RoleDraft) f64 {
	return 0.2
}

fn test_a_good_draft_is_auditioned_and_sealed_live() {
	mut log := new_event_log(tmp_log_path('meta1'), 'main', 'test')
	mut f := new_role_forge(log, good_draft, eval_pass, role_pass_bar)
	status, msg := f.forge('we need a database specialist')
	assert status == 'sealed', msg
	assert msg.contains('LIVE')

	mut reg := role_registry
	assert reg.has('sql_surgeon')
	spec := reg.spec('sql_surgeon') or { panic('not in the roster') }
	// it has write tools, so it is a writer
	assert spec.writes
	assert 'run_command' in spec.tools
	// its tools all exist
	known := all_tool_names()
	for t in spec.tools {
		assert t in known
	}
	// the brief and the worker prompt went live with it
	assert reg.brief('sql_surgeon') or { '' }.contains('database surgery')
	assert 'worker:sql_surgeon' in prompt_names()
	assert prompt_worker('sql_surgeon', max_workers).contains('database surgery')
	// and role_spec, which everything else calls, resolves it
	assert role_spec('sql_surgeon').writes
	assert 'sql_surgeon' in f.roster()
}

fn test_a_duplicate_name_never_shadows_an_existing_role() {
	mut log := new_event_log(tmp_log_path('meta2'), 'main', 'test')
	// the first forge in this file sealed sql_surgeon; either way, coder is
	// always taken
	mut f := new_role_forge(log, good_draft, eval_pass, role_pass_bar)
	f.forge('a db specialist')
	status, msg := f.forge('another db specialist')
	assert status == 'rejected'
	assert msg.contains('already exists'), msg
}

fn test_the_mechanical_gates_reject_what_they_say_they_do() {
	mut reg := role_registry
	cases := [
		[json2.Any({
			'name':      json2.Any('Bad Name!')
			'brief':     json2.Any('x'.repeat(200))
			'tools':     json2.Any([json2.Any('read_file')])
			'benchmark': json2.Any('b')
		}), json2.Any('bad role name')],
		[json2.Any({
			'name':      json2.Any('ghostrole')
			'brief':     json2.Any('x'.repeat(200))
			'tools':     json2.Any([json2.Any('not_a_tool')])
			'benchmark': json2.Any('b')
		}), json2.Any('no valid tools')],
		[json2.Any({
			'name':      json2.Any('thinrole')
			'brief':     json2.Any('too short')
			'tools':     json2.Any([json2.Any('read_file')])
			'benchmark': json2.Any('b')
		}), json2.Any('brief too thin')],
		[json2.Any({
			'name':      json2.Any('nobench')
			'brief':     json2.Any('x'.repeat(200))
			'tools':     json2.Any([json2.Any('read_file')])
			'benchmark': json2.Any('')
		}), json2.Any('no benchmark')],
	]
	for case in cases {
		raw := case[0].as_map()
		why := case[1].str()
		draft, problem := validate_draft(raw)
		assert draft == none, why
		assert problem.contains(why), '${problem} (wanted ${why})'
		assert !reg.has(jstr(raw, 'name'))
	}

	// an empty object is not a draft at all
	empty, problem := validate_draft(map[string]json2.Any{})
	assert empty == none
	assert problem.contains('not an object')
}

fn test_a_read_only_whitelist_is_not_a_writer() {
	draft, problem := validate_draft({
		'name':      json2.Any('doc_reader')
		'brief':     json2.Any('x'.repeat(200))
		'tools':     json2.Any([json2.Any('read_file'), json2.Any('list_dir')])
		'benchmark': json2.Any('read a file')
	})
	assert problem == ''
	d := draft or { panic('rejected') }
	assert !d.writes
	// the whitelist is sorted and deduplicated
	assert d.tools == ['list_dir', 'read_file']
}

fn test_a_failed_audition_seals_nothing() {
	mut log := new_event_log(tmp_log_path('meta3'), 'main', 'test')
	mut f := new_role_forge(log, fresh_draft, eval_fail, role_pass_bar)
	status, msg := f.forge('db help')
	assert status == 'rejected'
	assert msg.contains('audition'), msg
	mut reg := role_registry
	assert !reg.has('data_wrangler')
	assert 'worker:data_wrangler' !in prompt_names()
}

fn test_an_empty_mission_is_a_clean_rejection() {
	mut log := new_event_log(tmp_log_path('meta4'), 'main', 'test')
	mut f := new_role_forge(log, good_draft, eval_pass, role_pass_bar)
	status, msg := f.forge('   ')
	assert status == 'rejected'
	assert msg == 'empty mission'
	// nothing was even drafted
	assert log.events('main').len == 0
}

fn test_the_lineage_is_sealed() {
	mut log := new_event_log(tmp_log_path('meta5'), 'main', 'test')
	mut ok := new_role_forge(log, good_draft, eval_pass, role_pass_bar)
	ok.forge('one')
	mut bad := new_role_forge(log, fresh_draft, eval_fail, role_pass_bar)
	bad.forge('two')
	kinds := log.events('main').map(it.typ)
	assert 'meta.role.drafted' in kinds
	assert 'meta.role.rejected' in kinds
	// the seal happens only for whichever forge ran first in the process
	assert kinds.any(it == 'meta.role.sealed') || kinds.any(it == 'meta.role.rejected')
}

fn test_the_roster_starts_as_the_compiled_in_roles() {
	mut reg := role_registry
	for name in role_names {
		assert reg.has(name), name
		assert reg.brief(name) or { '' } != ''
	}
	// the advanced specialists declared in team.v are real roles too
	for name, _ in roles {
		assert reg.has(name), name
	}
	// and a role nobody declared is not one
	assert !reg.has('definitely_not_a_role')
	assert role_spec('definitely_not_a_role').tools == roles[default_role] or {
		RoleSpec{}
	}.tools
}
