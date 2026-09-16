module vagent

import x.json2

// meta.v — the agent that creates agents.
//
// The roster is not fixed. When work demands a specialist that does not
// exist, the forge drafts one:
//
//   draft      the model proposes a role: name, brief, tool whitelist,
//              benchmark. The drafter is injected, so the tests run
//              offline with a scripted draft.
//   validate   mechanical gates, never prompt advice: the name must be new
//              (no shadowing an existing role), the brief must be
//              substantial, every tool must exist in the registry.
//   audition   the drafted role runs its own benchmark and must clear the
//              pass bar. A role that cannot do its own job is never sealed.
//   seal       the role goes LIVE: the roster, the briefs and the worker
//              prompt registry all grow at runtime.
//
// Every transition is sealed, so the roster's evolution is replayable and a
// role can always be checked against its audition record.

const role_name_pattern = r'^[a-z][a-z0-9_]{2,20}$'
const min_brief_chars = 80
pub const role_pass_bar = 0.6

// the tools that make a role a writer
const write_tools = ['write_file', 'edit_file', 'create_directory', 'delete_path',
	'move_path', 'copy_path', 'run_command']

pub struct RoleDraft {
pub:
	name      string
	brief     string
	tools     []string
	benchmark string
	writes    bool
}

pub fn (d &RoleDraft) to_json() map[string]json2.Any {
	return {
		'name':      json2.Any(d.name)
		'brief':     json2.Any(clip_plain(d.brief, 400))
		'tools':     json2.Any(d.tools.map(json2.Any(it)))
		'benchmark': json2.Any(clip_plain(d.benchmark, 200))
		'writes':    json2.Any(d.writes)
	}
}

// RoleDrafter proposes a role for a mission, as the raw JSON object the
// model replied with. Returning the raw shape rather than a RoleDraft is
// deliberate: validation is this module's job, not the drafter's.
pub type RoleDrafter = fn (mission string) map[string]json2.Any

// RoleEvaluator is the audition: a score in [0, 1].
pub type RoleEvaluator = fn (draft &RoleDraft) f64

@[heap]
pub struct RoleForge {
pub mut:
	log       &EventLog
	drafter   RoleDrafter
	evaluator RoleEvaluator
	pass_bar  f64 = role_pass_bar
}

pub fn new_role_forge(log &EventLog, drafter RoleDrafter, evaluator RoleEvaluator, pass_bar f64) &RoleForge {
	return &RoleForge{
		log:       unsafe { log }
		drafter:   drafter
		evaluator: evaluator
		pass_bar:  pass_bar
	}
}

// all_tool_names is every tool a whitelist may draw from.
pub fn all_tool_names() []string {
	mut out := build_registry().keys()
	out.sort()
	return out
}

// forge creates one new role for the mission. The status is 'sealed' or
// 'rejected', and the message says why either way.
pub fn (mut f RoleForge) forge(mission string) (string, string) {
	m := mission.trim_space()
	if m == '' {
		return 'rejected', 'empty mission'
	}
	raw := f.drafter(m)
	draft, problem := validate_draft(raw)

	f.log.append('meta.role.drafted', {
		'mission': json2.Any(clip_plain(m, 200))
		'draft':   if d := draft { json2.Any(d.to_json()) } else { json2.null }
		'problem': json2.Any(problem)
	}, AppendOpts{ actor: 'sovereign' })

	d := draft or { return 'rejected', problem }

	score := f.evaluator(&d)
	if score < f.pass_bar {
		f.log.append('meta.role.rejected', {
			'name':   json2.Any(d.name)
			'reason': json2.Any('audition ${score:.2f} < ${f.pass_bar}')
			'score':  json2.Any(score)
		}, AppendOpts{ actor: 'kernel' })
		return 'rejected', "role '${d.name}' failed its audition (${score:.2f} < ${f.pass_bar:.2f}) — nothing sealed"
	}

	seal_role(d)
	mut payload := d.to_json()
	payload['name'] = json2.Any(d.name)
	payload['score'] = json2.Any(round_to(score, 3))
	f.log.append('meta.role.sealed', payload, AppendOpts{ actor: 'kernel' })
	return 'sealed', "role '${d.name}' is LIVE — sealed at audition ${score:.2f}, available to the crew and sealed in the vault"
}

// -- mechanical gates --------------------------------------------------------

// validate_draft is every reason a draft can be refused. None of them is a
// judgement about the writing: they are all checks a machine can make.
pub fn validate_draft(raw map[string]json2.Any) (?RoleDraft, string) {
	if raw.len == 0 {
		return none, 'draft is not an object'
	}
	name := jstr(raw, 'name').trim_space().to_lower()
	re := compile_regex(role_name_pattern) or { return none, 'internal: bad name pattern' }
	if _ := re.search(name) {
	} else {
		return none, "bad role name '${name}' (snake_case, 3-21 chars)"
	}
	mut reg := role_registry
	if reg.has(name) {
		return none, "role '${name}' already exists — refusing to shadow it"
	}
	brief := jstr(raw, 'brief').trim_space()
	if brief.len < min_brief_chars {
		return none, 'brief too thin (${brief.len} chars < ${min_brief_chars}) — a specialist needs real instructions'
	}
	known := all_tool_names()
	mut tools := []string{}
	for t in jstrs(raw, 'tools') {
		name_t := t.trim_space()
		if name_t in known {
			tools << name_t
		}
	}
	tools = uniq_strings(tools)
	if tools.len == 0 {
		return none, 'no valid tools in the whitelist'
	}
	benchmark := jstr(raw, 'benchmark').trim_space()
	if benchmark == '' {
		return none, 'no benchmark — a role must prove itself'
	}
	mut writes := false
	for t in tools {
		if t in write_tools {
			writes = true
			break
		}
	}
	tools.sort()
	return RoleDraft{
		name:      name
		brief:     brief
		tools:     tools
		benchmark: benchmark
		writes:    writes
	}, ''
}

// -- going live --------------------------------------------------------------

// seal_role installs the role everywhere a role has to be: the roster, the
// briefs, and the worker prompt registry.
pub fn seal_role(d RoleDraft) {
	mut reg := role_registry
	reg.add(d.name, RoleSpec{
		tools:  d.tools
		writes: d.writes
	}, d.brief)
	register('worker:${d.name}', prompt_worker(d.name, max_workers)) or {}
}

pub fn (f &RoleForge) roster() []string {
	mut reg := role_registry
	return reg.sorted_names()
}
