module vagent

import x.json2

// message.v — the wire shape of an OpenAI-compatible chat conversation.
//
// The Python original passed raw dicts around, which made three states
// indistinguishable at the type level: a key that is absent, a key that is
// present and null, and a key that is present and empty. Two of those
// distinctions are load-bearing here:
//
//   * `content` is nullable when tool_calls are present, and an empty or
//     whitespace string from a reasoning model that spent its budget
//     thinking is a LEGITIMATE reply — not the same as "no content at all".
//     Collapsing the two corrupts conversation history.
//   * `reasoning_content` only has to EXIST for thinking-aware backends to
//     accept a tool-call turn in the history; an empty string counts as
//     present.
//
// So both are modelled as options: `none` means the key is absent, and a
// present empty string means the key is there and empty.

pub struct ToolCallFunction {
pub mut:
	name      string
	arguments string
}

pub struct ToolCall {
pub mut:
	id   string
	kind string = 'function' // serialised as "type"
	function ToolCallFunction
}

pub fn (tc &ToolCall) to_json() map[string]json2.Any {
	mut fn_obj := map[string]json2.Any{}
	fn_obj['name'] = tc.function.name
	fn_obj['arguments'] = tc.function.arguments
	mut m := map[string]json2.Any{}
	m['id'] = tc.id
	m['type'] = if tc.kind == '' { 'function' } else { tc.kind }
	m['function'] = fn_obj
	return m
}

pub fn tool_call_from_json(m map[string]json2.Any) ToolCall {
	f := jmap(m, 'function')
	return ToolCall{
		id:       jstr(m, 'id')
		kind:     if k := m['type'] { k.str() } else { 'function' }
		function: ToolCallFunction{
			name:      jstr(f, 'name')
			arguments: jstr(f, 'arguments')
		}
	}
}

pub struct Message {
pub mut:
	role string
	// `none` means the JSON key is absent or null; a present empty string
	// means the model really did answer with nothing but whitespace.
	content           ?string
	tool_calls        []ToolCall
	tool_call_id      string
	name              string
	reasoning_content ?string
	reasoning         ?string
}

// text is the content with `none` flattened to an empty string, for the
// many call sites that only want something printable.
pub fn (m &Message) text() string {
	return m.content or { '' }
}

// to_json renders a message exactly as the provider expects it, omitting
// keys that are absent rather than sending explicit nulls for them.
pub fn (m &Message) to_json() map[string]json2.Any {
	mut o := map[string]json2.Any{}
	o['role'] = m.role
	// OpenAI spec: content is nullable when tool_calls are present.
	if c := m.content {
		o['content'] = c
	} else {
		o['content'] = json2.null
	}
	if m.tool_calls.len > 0 {
		o['tool_calls'] = m.tool_calls.map(json2.Any(it.to_json()))
	}
	if m.tool_call_id != '' {
		o['tool_call_id'] = m.tool_call_id
	}
	if m.name != '' {
		o['name'] = m.name
	}
	if rc := m.reasoning_content {
		o['reasoning_content'] = rc
	}
	if r := m.reasoning {
		o['reasoning'] = r
	}
	return o
}

pub fn message_from_json(o map[string]json2.Any) Message {
	mut m := Message{
		role:         jstr(o, 'role')
		tool_call_id: jstr(o, 'tool_call_id')
		name:         jstr(o, 'name')
	}
	if c := o['content'] {
		if c !is json2.Null {
			m.content = c.str()
		}
	}
	if rc := o['reasoning_content'] {
		if rc !is json2.Null {
			m.reasoning_content = rc.str()
		}
	}
	if r := o['reasoning'] {
		if r !is json2.Null {
			m.reasoning = r.str()
		}
	}
	for tc in jarr(o, 'tool_calls') {
		if tc is map[string]json2.Any {
			m.tool_calls << tool_call_from_json(tc)
		}
	}
	return m
}

// messages_to_json renders a whole conversation for the request body.
pub fn messages_to_json(messages []Message) []json2.Any {
	return messages.map(json2.Any(it.to_json()))
}

// ---------------------------------------------------------------------------
// Constructors
// ---------------------------------------------------------------------------

pub fn user_message(text string) Message {
	return Message{
		role:    'user'
		content: text
	}
}

pub fn system_message(text string) Message {
	return Message{
		role:    'system'
		content: text
	}
}

pub fn tool_message(tool_call_id string, name string, content string) Message {
	return Message{
		role:         'tool'
		tool_call_id: tool_call_id
		name:         name
		content:      content
	}
}

// assistant_message builds an assistant message that is valid for
// thinking-aware backends.
//
// Providers like TokenRouter (Qwen3) validate the *history*: any assistant
// turn that carried tool_calls must also carry reasoning_content when the
// model was invoked with thinking enabled (reasoning_effort=low). If the
// history was built while reasoning was stripped, the next request fails
// with 'messages[N].reasoning_content is required for thinking tool-call
// history'.
//
// This helper guarantees the invariant: tool-call turns always carry
// reasoning_content (real reasoning when available, else an empty string),
// so history never becomes invalid regardless of the provider's
// suppression mode.
pub fn assistant_message(content ?string, tool_calls []ToolCall, reasoning string) Message {
	mut m := Message{
		role:       'assistant'
		tool_calls: tool_calls
	}
	// Preserve any string the backend gave us — empty/whitespace text from
	// a reasoning model that spent the budget on thinking is a legitimate
	// reply, not the same as "no content at all". Testing truthiness here
	// was turning real "" / " " replies into null and corrupting history.
	if c := content {
		m.content = c
	}
	// Always carry reasoning_content when reasoning exists OR when the turn
	// carried tool_calls (history validation requires it). Set both keys for
	// maximum provider compatibility.
	if reasoning != '' {
		m.reasoning_content = reasoning
		// some providers also accept "reasoning"
		m.reasoning = reasoning
	} else if tool_calls.len > 0 {
		m.reasoning_content = ''
	}
	return m
}

// sanitize_messages ensures history satisfies thinking validation.
//
// Mutates `messages` in place: any assistant message with tool_calls that
// lacks reasoning_content/reasoning gets an empty reasoning_content.
// Returns true if anything was fixed.
//
// Note: an existing empty string ("") counts as present — the provider only
// requires the field to exist, not to be non-empty.
pub fn sanitize_messages(mut messages []Message) bool {
	mut fixed := false
	for mut m in messages {
		if m.role != 'assistant' || m.tool_calls.len == 0 {
			continue
		}
		if m.reasoning_content != none || m.reasoning != none {
			continue
		}
		m.reasoning_content = ''
		fixed = true
	}
	return fixed
}
