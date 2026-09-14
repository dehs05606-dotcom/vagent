module memory

import os
import time
import x.json2
import src.model
import src.utils

// V-AGENT keeps three memory layers, and the distinction is what stops the
// context window from becoming a transcript dump:
//
//   short term  — the live message list, owned by the agent
//   session     — this run's transcript, persisted so it can be resumed
//   project     — durable notes about the repository, carried between runs
//
// Only the project layer is ever injected into a future system prompt.

// Session is the persisted record of one run.
@[heap]
pub struct Session {
pub mut:
	id      string
	root    string
	started time.Time
	dir     string
	turns   int
}

pub fn new_session(root string) Session {
	now := time.now()
	id := '${now.format_ss().replace(' ', '_').replace(':', '-')}-${os.getpid()}'
	dir := os.join_path(utils.user_config_dir(), 'sessions')
	return Session{
		id:      id
		root:    root
		started: now
		dir:     dir
	}
}

// save writes the whole conversation to ~/.vagent/sessions/<id>.json. It is
// best-effort: a session that cannot be persisted must not kill the run.
pub fn (mut s Session) save(messages []model.Message) {
	utils.ensure_dir(s.dir) or { return }
	mut arr := []json2.Any{cap: messages.len}
	for m in messages {
		mut obj := map[string]json2.Any{}
		obj['role'] = json2.Any(m.role.str())
		obj['content'] = json2.Any(m.content)
		if m.tool_call_id != '' {
			obj['tool_call_id'] = json2.Any(m.tool_call_id)
		}
		if m.name != '' {
			obj['name'] = json2.Any(m.name)
		}
		if m.tool_calls.len > 0 {
			mut calls := []json2.Any{}
			for c in m.tool_calls {
				mut cm := map[string]json2.Any{}
				cm['id'] = json2.Any(c.id)
				cm['name'] = json2.Any(c.name)
				cm['arguments'] = json2.Any(c.arguments)
				calls << json2.Any(cm)
			}
			obj['tool_calls'] = json2.Any(calls)
		}
		arr << json2.Any(obj)
	}
	mut root := map[string]json2.Any{}
	root['id'] = json2.Any(s.id)
	root['project'] = json2.Any(s.root)
	root['started'] = json2.Any(s.started.format_ss())
	root['turns'] = json2.Any(s.turns)
	root['messages'] = json2.Any(arr)
	os.write_file(s.path(), json2.encode(json2.Any(root), prettify: true)) or {}
}

pub fn (s &Session) path() string {
	return os.join_path(s.dir, '${s.id}.json')
}

// load_messages restores a saved session; used by `--resume`.
pub fn load_messages(path string) ![]model.Message {
	raw := os.read_file(path) or {
		return utils.err_hint(.filesystem, 'cannot read session ${path}', err.msg())
	}
	obj := utils.parse_object(raw)!
	mut out := []model.Message{}
	for item in utils.jarr(obj, 'messages') {
		if item !is map[string]json2.Any {
			continue
		}
		m := item as map[string]json2.Any
		role := match utils.jstr(m, 'role', 'user') {
			'system' { model.Role.system }
			'assistant' { model.Role.assistant }
			'tool' { model.Role.tool }
			else { model.Role.user }
		}

		mut msg := model.Message{
			role:         role
			content:      utils.jstr(m, 'content', '')
			tool_call_id: utils.jstr(m, 'tool_call_id', '')
			name:         utils.jstr(m, 'name', '')
		}
		for c in utils.jarr(m, 'tool_calls') {
			if c !is map[string]json2.Any {
				continue
			}
			cm := c as map[string]json2.Any
			msg.tool_calls << model.ToolCall{
				id:        utils.jstr(cm, 'id', '')
				name:      utils.jstr(cm, 'name', '')
				arguments: utils.jstr(cm, 'arguments', '{}')
			}
		}
		out << msg
	}
	return out
}

// list_sessions returns saved session files, newest first.
pub fn list_sessions() []string {
	dir := os.join_path(utils.user_config_dir(), 'sessions')
	mut files := os.ls(dir) or { return [] }
	files = files.filter(it.ends_with('.json'))
	files.sort(a > b)
	return files.map(os.join_path(dir, it))
}
