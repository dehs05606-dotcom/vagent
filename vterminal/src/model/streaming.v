module model

import strings
import x.json2
import src.utils

// Accumulator turns a stream of server-sent-event bytes into a finished
// Response. It is shared by the OpenAI and Anthropic clients: both speak SSE,
// they only disagree about what the JSON payloads mean, so each supplies a
// `handler` that interprets one decoded event.
//
// The struct is heap-allocated because a pointer to it is handed to the HTTP
// layer through `Request.user_ptr`, which is how V's http client gives a
// progress callback access to caller state.
@[heap]
pub struct Accumulator {
pub mut:
	sink      &Sink           = unsafe { nil }
	handler   EventFn         = unsafe { nil }
	content   strings.Builder = strings.new_builder(1024)
	reasoning strings.Builder = strings.new_builder(256)
	calls     []ToolCall
	finish    string
	usage     Usage
	model     string
	done      bool
	// last_error holds a decode failure so the caller can report it after the
	// transfer finishes; a callback cannot abort the request cleanly.
	last_error string
mut:
	buf        string
	event_name string
}

// EventFn interprets a single decoded SSE payload. `event` is the SSE event
// name, empty for providers that do not use one.
pub type EventFn = fn (mut acc Accumulator, event string, payload map[string]json2.Any)

pub fn new_accumulator(mut sink Sink, handler EventFn) &Accumulator {
	return &Accumulator{
		sink:      unsafe { &sink }
		handler:   handler
		content:   strings.new_builder(2048)
		reasoning: strings.new_builder(256)
	}
}

// feed consumes a chunk of raw bytes. Chunks arrive at arbitrary boundaries,
// so partial lines are held in `buf` until their newline shows up.
pub fn (mut a Accumulator) feed(chunk string) {
	a.buf += chunk
	for {
		idx := a.buf.index('\n') or { break }
		line := a.buf#[..idx].trim_right('\r')
		a.buf = a.buf#[idx + 1..]
		a.handle_line(line)
	}
}

// finish_stream flushes any trailing partial line at end of transfer.
pub fn (mut a Accumulator) finish_stream() {
	if a.buf.trim_space() != '' {
		a.handle_line(a.buf.trim_right('\r'))
		a.buf = ''
	}
}

fn (mut a Accumulator) handle_line(line string) {
	if line == '' {
		// A blank line terminates an SSE event; the name does not carry over.
		a.event_name = ''
		return
	}
	if line.starts_with(':') {
		return
	}
	if line.starts_with('event:') {
		a.event_name = line#[6..].trim_space()
		return
	}
	if !line.starts_with('data:') {
		return
	}
	payload := line#[5..].trim_space()
	if payload == '' {
		return
	}
	if payload == '[DONE]' {
		a.done = true
		return
	}
	decoded := json2.decode[json2.Any](payload) or {
		a.last_error = 'malformed stream payload: ${utils.truncate(payload, 200)}'
		return
	}
	if decoded !is map[string]json2.Any {
		return
	}
	obj := decoded as map[string]json2.Any
	if a.handler != unsafe { nil } {
		a.handler(mut a, a.event_name, obj)
	}
}

// append_text records assistant text and forwards it to the renderer.
pub fn (mut a Accumulator) append_text(s string) {
	if s == '' {
		return
	}
	a.content.write_string(s)
	if a.sink != unsafe { nil } {
		a.sink.emit_text(s)
	}
}

// append_reasoning records chain-of-thought style output that some providers
// stream on a separate channel. It is kept out of `content` so it never gets
// echoed back as an assistant message.
pub fn (mut a Accumulator) append_reasoning(s string) {
	if s == '' {
		return
	}
	a.reasoning.write_string(s)
	if a.sink != unsafe { nil } {
		a.sink.emit_reasoning(s)
	}
}

// ensure_call grows the tool-call slice so index-addressed deltas can be
// accumulated out of order, which some providers do.
pub fn (mut a Accumulator) ensure_call(index int) int {
	mut i := index
	if i < 0 {
		i = 0
	}
	for a.calls.len <= i {
		a.calls << ToolCall{}
	}
	return i
}

pub fn (mut a Accumulator) note_tool_name(index int, name string) {
	i := a.ensure_call(index)
	if name != '' && a.calls[i].name != name {
		a.calls[i].name = name
		if a.sink != unsafe { nil } {
			a.sink.emit_tool(name)
		}
	}
}

pub fn (mut a Accumulator) append_args(index int, fragment string) {
	i := a.ensure_call(index)
	a.calls[i].arguments += fragment
}

pub fn (mut a Accumulator) set_call_id(index int, id string) {
	i := a.ensure_call(index)
	if id != '' {
		a.calls[i].id = id
	}
}

// response materialises the finished turn, dropping any tool call that never
// received a name (a truncated stream can leave one behind).
pub fn (mut a Accumulator) response() Response {
	mut calls := []ToolCall{}
	for i, c in a.calls {
		if c.name == '' {
			continue
		}
		mut call := c
		if call.id == '' {
			call.id = 'call_${i}'
		}
		if call.arguments.trim_space() == '' {
			call.arguments = '{}'
		}
		calls << call
	}
	return Response{
		content:       a.content.str()
		reasoning:     a.reasoning.str()
		tool_calls:    calls
		finish_reason: a.finish
		usage:         a.usage
		model:         a.model
	}
}

// decode_stream runs a complete SSE body through the accumulator in one call.
// The clients use `feed` incrementally; this exists for tests and for replaying
// a captured stream, and guarantees the two paths share the same parser.
pub fn decode_stream(body string, handler EventFn, mut sink Sink) Response {
	mut acc := new_accumulator(mut sink, handler)
	acc.feed(body)
	acc.finish_stream()
	return acc.response()
}
