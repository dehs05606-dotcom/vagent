module vagent

import time
import x.json2

// turn.v — the record of one exchange, and of each tool call inside it.
//
// These live apart from agent.v because the renderer needs them and the
// renderer must not need the agent: a box that can only be drawn by
// starting a session is a box nobody can test.

pub struct ToolEvent {
pub mut:
	name   string
	args   map[string]json2.Any
	result string
	// running | done | error | denied | blocked
	status    string = 'running'
	duration  f64
	clause_id string
}

pub fn (e &ToolEvent) to_json() map[string]json2.Any {
	return {
		'name':      json2.Any(e.name)
		'args':      json2.Any(e.args)
		'result':    json2.Any(e.result)
		'status':    json2.Any(e.status)
		'duration':  json2.Any(e.duration)
		'clause_id': if e.clause_id != '' { json2.Any(e.clause_id) } else { json2.null }
	}
}

pub struct Turn {
pub mut:
	user_text      string
	assistant_text string
	reasoning      string
	tools          []ToolEvent
	model_id       string
	effort         string
	error          string
	usage          map[string]json2.Any
	has_usage      bool
	scorecard      map[string]json2.Any
	duration       f64
	timestamp      string = clock_now()
}

fn clock_now() string {
	t := time.now()
	return '${t.hour:02}:${t.minute:02}:${t.second:02}'
}

// tool_signature is the canonical approach signature — the dead-end
// ledger's key.
pub fn tool_signature(name string, args map[string]json2.Any) string {
	payload := canonical(json2.Any({
		'name': json2.Any(name)
		'args': json2.Any(args)
	}))
	return hash(payload)[..16]
}
