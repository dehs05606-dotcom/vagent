module vagent

import x.json2

const remedy_spec = '§1 Writes stay under src/ and tests/
@enforce confine_paths: src, tests

§2 No secrets in source
@enforce forbid_content: (?i)api[_-]?key\\s*=\\s*["\\\'][A-Za-z0-9]

§3 Nothing is ever deleted
@enforce forbid_effect: delete

§4 Python modules carry a docstring
@enforce {"kind": "require_content", "value": "^\\\\s*[\\"\']{3}", "where": "*.py"}

§5 Never delete_path
@enforce forbid_tool: delete_path
'

fn rm_args(pairs map[string]string) map[string]json2.Any {
	mut out := map[string]json2.Any{}
	for k, v in pairs {
		out[k] = json2.Any(v)
	}
	return out
}

fn pick(violations []Violation, kind string) Violation {
	for v in violations {
		if v.kind == kind {
			return v
		}
	}
	panic('no ${kind} violation in ${violations.map(it.kind)}')
}

fn test_confine_paths_suggests_the_nearest_permitted_root() {
	mut cov := new_covenant(new_event_log(tmp_log_path('rem1'), 'main', 'test'), remedy_spec)
	vs := cov.check('write_file', rm_args({
		'path':    '/etc/app.py'
		'content': '"""x."""'
	}))
	v := pick(vs, 'confine_paths')
	s := remedy_for_violation(&v, cov.guards()) or { panic('no suggestion') }
	assert s.action.contains('app.py'), s.action
	assert s.action.starts_with('write to src/') || s.action.starts_with('write to tests/'), s.action
	assert s.rationale.contains('permits only')

	// the NEAREST root is chosen, not simply the first
	near := cov.check('write_file', rm_args({
		'path':    '/elsewhere/tests/unit.py'
		'content': '"""x."""'
	}))
	nv := pick(near, 'confine_paths')
	s2 := remedy_for_violation(&nv, cov.guards()) or { panic('no suggestion') }
	assert s2.action.contains('tests/unit.py'), s2.action
}

fn test_forbid_content_names_the_offending_span() {
	mut cov := new_covenant(new_event_log(tmp_log_path('rem2'), 'main', 'test'), remedy_spec)
	vs := cov.check('write_file', rm_args({
		'path':    'src/c.py'
		'content': '"""d."""\nAPI_KEY = "sk-1"'
	}))
	v := pick(vs, 'forbid_content')
	s := remedy_for_violation(&v, cov.guards()) or { panic('no suggestion') }
	assert s.action.contains('remove'), s.action
	assert s.action.contains('API_KEY'), s.action
	assert s.rationale.contains('not the whole write')
}

fn test_require_content_says_what_is_missing() {
	mut cov := new_covenant(new_event_log(tmp_log_path('rem3'), 'main', 'test'), remedy_spec)
	vs := cov.check('write_file', rm_args({
		'path':    'src/nodoc.py'
		'content': 'x = 1'
	}))
	v := pick(vs, 'require_content')
	s := remedy_for_violation(&v, cov.guards()) or { panic('no suggestion') }
	assert s.action.contains('required content'), s.action
	assert s.action.contains('src/nodoc.py')
}

fn test_forbid_tool_and_forbid_effect_name_the_alternative() {
	mut cov := new_covenant(new_event_log(tmp_log_path('rem4'), 'main', 'test'), remedy_spec)
	tool_vs := cov.check('delete_path', rm_args({
		'path': 'src/a.py'
	}))
	tv := pick(tool_vs, 'forbid_tool')
	s := remedy_for_violation(&tv, cov.guards()) or { panic('no suggestion') }
	assert s.action.contains('move_path'), s.action

	effect_vs := cov.check('run_command', rm_args({
		'command': 'rm -f src/a.py'
	}))
	ev := pick(effect_vs, 'forbid_effect')
	e := remedy_for_violation(&ev, cov.guards()) or { panic('no suggestion') }
	assert e.rationale.contains('any route'), e.rationale

	// an opaque command gets the concrete alternative
	mut conf := new_covenant(new_event_log(tmp_log_path('rem5'), 'main', 'test'), '§9 no unreadable effects\n@enforce forbid_effect: opaque\n')
	op := conf.check('run_command', rm_args({
		'command': 'eval "\$CMD"'
	}))
	ov := pick(op, 'forbid_effect')
	o := remedy_for_violation(&ov, conf.guards()) or { panic('no suggestion') }
	assert o.action.contains('literal redirect'), o.action
}

fn test_a_horizon_breach_says_how_much_room_is_left() {
	mut hz := new_horizon(new_event_log(tmp_log_path('rem6'), 'main', 'test'), '§12 at most 3 files\n@horizon per turn max files_written 3\n')
	hz.open_turn()
	for i in 0 .. 2 {
		hz.spend('write_file', rm_args({
			'path':    'f${i}.py'
			'content': 'x'
		}))
	}
	br := hz.project('run_command', rm_args({
		'command': 'touch a && touch b && touch c'
	}))
	s := remedy_for_breach(&br[0])
	assert s.action.contains('at most 1 more files_written'), s.action

	// a full window says to start a new turn
	hz.spend('write_file', rm_args({
		'path':    'f2.py'
		'content': 'x'
	}))
	full := hz.project('write_file', rm_args({
		'path':    'f3.py'
		'content': 'x'
	}))
	f := remedy_for_breach(&full[0])
	assert f.action.contains('start a new turn'), f.action
}

fn test_a_ration_overspend_says_what_is_left_in_money() {
	mut r := new_ration(new_event_log(tmp_log_path('rem7'), 'main', 'test'), '§30 two dollars a turn\n@ration per turn max cost_usd 2.00\n')
	r.open_turn()
	r.spend(1.50, 0, 0, 0.0)
	over := r.project(Estimate{ cost_usd: 1.00 })
	s := remedy_for_overspend(&over[0])
	assert s.action.contains('\$0.50'), s.action
	assert s.rationale.contains('\$1.50 of \$2.00'), s.rationale
}

fn test_annotate_composes_them_onto_a_real_refusal() {
	mut cov := new_covenant(new_event_log(tmp_log_path('rem8'), 'main', 'test'), remedy_spec)
	vs := cov.check('write_file', rm_args({
		'path':    '/etc/x.py'
		'content': 'x = 1'
	}))
	text := annotate(cov.cite(vs), vs, cov.guards(), [], [])
	assert text.starts_with('CovenantViolation')
	assert text.contains('What would be allowed:')
	assert text.contains('not permission')

	// duplicate suggestions are collapsed
	mut doubled := vs.clone()
	doubled << vs
	dupe := annotate(cov.cite(vs), doubled, cov.guards(), [], [])
	assert dupe.count('write to src/') <= 1
}

fn test_a_refusal_with_nothing_to_derive_stays_unchanged() {
	plain := 'SomeOtherRefusal: no clause information here'
	assert annotate(plain, [], [], [], []) == plain
	// an unknown kind derives nothing rather than inventing something
	unknown := Violation{
		clause: '1'
		kind:   'something_new'
		detail: 'x'
	}
	assert remedy_for_violation(&unknown, []) == none
	// and confine_paths with no guard to read has nothing to compute from
	orphan := Violation{
		clause: '1'
		kind:   'confine_paths'
		path:   '/etc/x'
	}
	assert remedy_for_violation(&orphan, []) == none
}

fn test_a_remedy_is_only_ever_a_sentence() {
	mut cov := new_covenant(new_event_log(tmp_log_path('rem9'), 'main', 'test'), remedy_spec)
	args := rm_args({
		'path':    '/etc/x.py'
		'content': 'x = 1'
	})
	before := cov.check('write_file', args).len
	annotate('x', cov.check('write_file', args), cov.guards(), [], [])
	assert cov.check('write_file', args).len == before, 'a remedy affected enforcement'
	assert before > 0
}
