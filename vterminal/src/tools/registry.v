module tools

import x.json2
import src.utils
import src.security

// Registry owns every tool the agent can call and is the single place where
// arguments are validated, permission is checked, and output is bounded.
// Built-in, MCP and custom tools all land here and become indistinguishable
// to the agent loop.
@[heap]
pub struct Registry {
pub mut:
	ctx   Context
	perms &security.Engine = unsafe { nil }
mut:
	by_name map[string]Tool
	order   []string
}

pub fn new_registry(ctx Context, mut perms security.Engine) Registry {
	return Registry{
		ctx:   ctx
		perms: &perms
	}
}

// register adds a tool, replacing any previous tool of the same name so that a
// user-supplied tool can deliberately shadow a built-in one.
pub fn (mut r Registry) register(t Tool) {
	name := t.spec().name
	if name !in r.by_name {
		r.order << name
	}
	r.by_name[name] = t
}

pub fn (r &Registry) names() []string {
	return r.order.clone()
}

pub fn (r &Registry) len() int {
	return r.by_name.len
}

pub fn (r &Registry) get(name string) ?Tool {
	t := r.by_name[name] or { return none }
	return t
}

pub fn (r &Registry) specs() []Spec {
	mut out := []Spec{}
	for name in r.order {
		if t := r.by_name[name] {
			out << t.spec()
		}
	}
	return out
}

// schema renders the registry as the `tools` array of an OpenAI-style chat
// request. The same JSON Schema doubles as our validation source.
pub fn (r &Registry) schema() []json2.Any {
	mut out := []json2.Any{}
	for name in r.order {
		t := r.by_name[name] or { continue }
		out << spec_to_schema(t.spec())
	}
	return out
}

fn spec_to_schema(s Spec) json2.Any {
	mut props := map[string]json2.Any{}
	mut required := []json2.Any{}
	for p in s.params {
		mut field := map[string]json2.Any{}
		field['type'] = json2.Any(p.typ)
		field['description'] = json2.Any(p.description)
		if p.typ == 'array' {
			mut items := map[string]json2.Any{}
			items['type'] = json2.Any(p.items_type)
			field['items'] = json2.Any(items)
		}
		if p.enum_values.len > 0 {
			mut ev := []json2.Any{}
			for e in p.enum_values {
				ev << json2.Any(e)
			}
			field['enum'] = json2.Any(ev)
		}
		props[p.name] = json2.Any(field)
		if p.required {
			required << json2.Any(p.name)
		}
	}
	mut params := map[string]json2.Any{}
	params['type'] = json2.Any('object')
	params['properties'] = json2.Any(props)
	params['required'] = json2.Any(required)

	mut func := map[string]json2.Any{}
	func['name'] = json2.Any(s.name)
	func['description'] = json2.Any(s.description)
	func['parameters'] = json2.Any(params)

	mut wrapper := map[string]json2.Any{}
	wrapper['type'] = json2.Any('function')
	wrapper['function'] = json2.Any(func)
	return json2.Any(wrapper)
}

// validate_args checks required fields and obvious type mismatches before a
// tool runs, so a malformed call becomes a message the model can correct
// rather than a crash or a silently wrong action.
fn validate_args(s Spec, args map[string]json2.Any) ! {
	for p in s.params {
		val := utils.jget(args, p.name) or {
			if p.required {
				return utils.err(.tool, 'missing required argument "${p.name}"')
			}
			continue
		}
		actual := utils.type_name_of(val)
		ok := match p.typ {
			'string' { actual == 'string' }
			'integer' { actual == 'integer' || actual == 'number' || actual == 'string' }
			'number' { actual == 'integer' || actual == 'number' || actual == 'string' }
			'boolean' { actual == 'boolean' || actual == 'string' }
			'array' { actual == 'array' }
			'object' { actual == 'object' }
			else { true }
		}

		if !ok {
			return utils.err(.tool, 'argument "${p.name}" must be ${p.typ}, got ${actual}')
		}
		if p.enum_values.len > 0 && actual == 'string' {
			sv := val.str()
			if sv !in p.enum_values {
				return utils.err(.tool,
					'argument "${p.name}" must be one of ${p.enum_values}, got "${sv}"')
			}
		}
	}
	return
}

// summarize builds the one-line echo shown in the terminal for a call.
pub fn summarize(s Spec, args map[string]json2.Any) string {
	if s.summary_param != '' {
		if v := utils.jget(args, s.summary_param) {
			return utils.first_line(utils.any_to_display(v))
		}
	}
	mut parts := []string{}
	for p in s.params {
		v := utils.jget(args, p.name) or { continue }
		parts << '${p.name}=${utils.first_line(utils.any_to_display(v))}'
		if parts.len == 2 {
			break
		}
	}
	return parts.join(' ')
}

// execute runs one tool call end to end: decode arguments, validate them,
// ask the permission engine, run the tool, then bound the output.
//
// It returns a Result rather than an error even for failures, because every
// outcome has to be reportable back to the model as a tool message; an
// unrecoverable V error here would abandon the conversation mid-turn.
pub fn (mut r Registry) execute(name string, raw_args string) Result {
	t := r.get(name) or {
		return fail_result('unknown tool "${name}". Available tools: ${r.order.join(', ')}')
	}
	spec := t.spec()
	args := utils.parse_object(raw_args) or {
		return fail_result('could not parse arguments for ${name}: ${err.msg()}')
	}
	validate_args(spec, args) or { return fail_result(err.msg()) }

	summary := summarize(spec, args)
	danger := if spec.level == .execute {
		security.classify_command(utils.jstr(args, 'command', summary))
	} else {
		''
	}
	req := security.Request{
		tool:    name
		level:   spec.level
		summary: if summary != '' { '${name} ${summary}' } else { name }
		target:  utils.jstr(args, 'path', utils.jstr(args, 'command', summary))
		danger:  danger
	}
	allowed := r.perms.authorize(req) or {
		return fail_result('permission check failed: ${err.msg()}')
	}
	if !allowed {
		return fail_result('permission denied by the user for ${name}. Do not retry this exact call; explain what you need and why, or propose a different approach.')
	}

	r.ctx.calls++
	if r.ctx.log != unsafe { nil } {
		r.ctx.log.debug('tool ${name} args=${utils.truncate(raw_args, 400)}')
	}
	mut res := t.execute(mut r.ctx, args)
	if res.summary == '' {
		res.summary = summary
	}
	res.output = utils.truncate_middle(res.output, r.ctx.max_output)
	if r.ctx.log != unsafe { nil } {
		status := if res.ok { 'ok' } else { 'fail' }
		r.ctx.log.debug('tool ${name} -> ${status} (${res.output.len} bytes)')
	}
	return res
}

// register_builtins installs the tool set that ships with V-AGENT.
pub fn (mut r Registry) register_builtins() {
	r.register(ReadFileTool{})
	r.register(WriteFileTool{})
	r.register(EditFileTool{})
	r.register(DeleteFileTool{})
	r.register(ListDirectoryTool{})
	r.register(SearchFilesTool{})
	r.register(SearchTextTool{})
	r.register(ShellTool{})
	r.register(GitStatusTool{})
	r.register(GitDiffTool{})
	r.register(GitLogTool{})
	r.register(GitCommitTool{})
	r.register(UpdatePlanTool{})
}
