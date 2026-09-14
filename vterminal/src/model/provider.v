module model

import x.json2
import src.utils

pub enum Role {
	system
	user
	assistant
	tool
}

pub fn (r Role) str() string {
	return match r {
		.system { 'system' }
		.user { 'user' }
		.assistant { 'assistant' }
		.tool { 'tool' }
	}
}

// ToolCall is one function invocation requested by the model. `arguments` is
// kept as raw JSON text because that is what the wire format carries and what
// has to be echoed back verbatim in the follow-up assistant message.
pub struct ToolCall {
pub mut:
	id        string
	name      string
	arguments string
}

// Message is one turn of the conversation in provider-neutral form.
pub struct Message {
pub mut:
	role         Role
	content      string
	tool_calls   []ToolCall
	tool_call_id string // set on .tool messages, links back to the call
	name         string
}

pub fn system_msg(content string) Message {
	return Message{
		role:    .system
		content: content
	}
}

pub fn user_msg(content string) Message {
	return Message{
		role:    .user
		content: content
	}
}

pub fn tool_msg(call_id string, name string, content string) Message {
	return Message{
		role:         .tool
		content:      content
		tool_call_id: call_id
		name:         name
	}
}

// Usage is token accounting as reported by the provider. Providers that omit
// it leave zeroes, and the caller falls back to the character estimate.
pub struct Usage {
pub mut:
	prompt_tokens     int
	completion_tokens int
	total_tokens      int
}

pub fn (u Usage) add(o Usage) Usage {
	return Usage{
		prompt_tokens:     u.prompt_tokens + o.prompt_tokens
		completion_tokens: u.completion_tokens + o.completion_tokens
		total_tokens:      u.total_tokens + o.total_tokens
	}
}

// Request is what the agent hands to a provider for one model turn.
pub struct Request {
pub mut:
	messages []Message
	tools    []json2.Any
	stream   bool
}

// Response is one completed model turn, whether it arrived streamed or whole.
pub struct Response {
pub mut:
	content       string
	reasoning     string
	tool_calls    []ToolCall
	finish_reason string
	usage         Usage
	model         string
}

// Sink receives streamed output as it arrives. The renderer supplies it; a nil
// sink turns streaming into plain accumulation.
@[heap]
pub struct Sink {
pub mut:
	on_text      fn (chunk string) = unsafe { nil }
	on_reasoning fn (chunk string) = unsafe { nil }
	on_tool      fn (name string)  = unsafe { nil }
}

pub fn (mut s Sink) emit_text(chunk string) {
	if s.on_text != unsafe { nil } {
		s.on_text(chunk)
	}
}

pub fn (mut s Sink) emit_reasoning(chunk string) {
	if s.on_reasoning != unsafe { nil } {
		s.on_reasoning(chunk)
	}
}

pub fn (mut s Sink) emit_tool(name string) {
	if s.on_tool != unsafe { nil } {
		s.on_tool(name)
	}
}

// Provider is the wire-dialect interface. Everything above this line is
// provider-neutral; everything a specific API does differently lives behind it.
pub interface Provider {
	name() string
	model_id() string
	context_limit() int
	chat(req Request, mut sink Sink) !Response
}

// join_url concatenates a base URL and a path without doubling the separator,
// and tolerates a base that already carries the endpoint path.
pub fn join_url(base string, path string) string {
	b := base.trim_right('/')
	p := path.trim_left('/')
	if b.ends_with('/' + p) {
		return b
	}
	return '${b}/${p}'
}

// describe_http_error turns a non-2xx response into a message that says what
// to actually do about it, because "HTTP 401" alone helps nobody.
pub fn describe_http_error(status int, body string) IError {
	short := utils.truncate(body.trim_space(), 1200)
	hint := match status {
		400 { 'the request was rejected: check the model name and that the tool schema is valid' }
		401, 403 { 'the API key was rejected: check \$VAGENT_API_KEY and that it is valid for this base_url' }
		404 { 'endpoint not found: check provider.base_url (it should include /v1) and the model name' }
		408, 504 { 'the provider timed out; retry, or raise provider.timeout_secs' }
		413 { 'the request was too large: use /compact to shrink the conversation' }
		429 { 'rate limited: wait and retry, or switch model with /model' }
		else { 'provider-side failure; the body above is what it returned' }
	}

	return utils.err_hint(.provider, 'provider returned HTTP ${status}: ${short}', hint)
}
