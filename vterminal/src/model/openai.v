module model

import net.http
import time
import x.json2
import src.config
import src.utils

// OpenAIProvider speaks the OpenAI /v1/chat/completions dialect, which is what
// nearly every hosted router and local server implements. Point `base_url` at
// anything that speaks it and V-AGENT works unchanged.
@[heap]
pub struct OpenAIProvider {
pub mut:
	cfg config.ProviderConfig
	log &utils.Logger = unsafe { nil }
}

pub fn new_openai(cfg config.ProviderConfig, mut log utils.Logger) &OpenAIProvider {
	return &OpenAIProvider{
		cfg: cfg
		log: &log
	}
}

pub fn (p &OpenAIProvider) name() string {
	return p.cfg.name
}

pub fn (p &OpenAIProvider) model_id() string {
	return p.cfg.model
}

pub fn (p &OpenAIProvider) context_limit() int {
	return p.cfg.context_limit
}

pub fn (p &OpenAIProvider) chat(req Request, mut sink Sink) !Response {
	body := p.build_body(req)
	url := join_url(p.cfg.base_url, 'chat/completions')
	if p.log != unsafe { nil } {
		mut l := p.log
		l.debug('POST ${url} stream=${req.stream} messages=${req.messages.len} tools=${req.tools.len}')
	}
	if req.stream {
		return p.chat_streaming(url, body, mut sink)
	}
	return p.chat_blocking(url, body)
}

fn (p &OpenAIProvider) headers() http.Header {
	mut h := http.new_header()
	h.add(.content_type, 'application/json')
	h.add(.authorization, 'Bearer ${p.cfg.api_key}')
	h.add(.accept, 'application/json, text/event-stream')
	for k, v in p.cfg.headers {
		h.add_custom(k, v) or {}
	}
	return h
}

fn (p &OpenAIProvider) build_body(req Request) string {
	mut obj := map[string]json2.Any{}
	obj['model'] = json2.Any(p.cfg.model)
	obj['messages'] = json2.Any(encode_messages(req.messages))
	if req.tools.len > 0 {
		obj['tools'] = json2.Any(req.tools)
		obj['tool_choice'] = json2.Any('auto')
	}
	if p.cfg.temperature != 0.0 {
		obj['temperature'] = json2.Any(p.cfg.temperature)
	}
	if p.cfg.top_p != 1.0 {
		obj['top_p'] = json2.Any(p.cfg.top_p)
	}
	if p.cfg.max_tokens > 0 {
		obj['max_tokens'] = json2.Any(p.cfg.max_tokens)
	}
	if req.stream {
		obj['stream'] = json2.Any(true)
		// Ask for a final usage frame; providers that do not support it ignore
		// the field rather than erroring.
		mut so := map[string]json2.Any{}
		so['include_usage'] = json2.Any(true)
		obj['stream_options'] = json2.Any(so)
	}
	return json2.Any(obj).json_str()
}

// encode_messages maps the neutral Message list onto the OpenAI wire shape.
fn encode_messages(messages []Message) []json2.Any {
	mut out := []json2.Any{cap: messages.len}
	for m in messages {
		mut obj := map[string]json2.Any{}
		obj['role'] = json2.Any(m.role.str())
		obj['content'] = json2.Any(m.content)
		if m.role == .tool {
			obj['tool_call_id'] = json2.Any(m.tool_call_id)
			if m.name != '' {
				obj['name'] = json2.Any(m.name)
			}
		}
		if m.tool_calls.len > 0 {
			mut calls := []json2.Any{cap: m.tool_calls.len}
			for c in m.tool_calls {
				mut func := map[string]json2.Any{}
				func['name'] = json2.Any(c.name)
				func['arguments'] = json2.Any(c.arguments)
				mut wrap := map[string]json2.Any{}
				wrap['id'] = json2.Any(c.id)
				wrap['type'] = json2.Any('function')
				wrap['function'] = json2.Any(func)
				calls << json2.Any(wrap)
			}
			obj['tool_calls'] = json2.Any(calls)
		}
		out << json2.Any(obj)
	}
	return out
}

fn (p &OpenAIProvider) chat_blocking(url string, body string) !Response {
	mut req := http.Request{
		method:        .post
		url:           url
		data:          body
		header:        p.headers()
		read_timeout:  i64(p.cfg.timeout_secs) * time.second
		write_timeout: i64(p.cfg.timeout_secs) * time.second
	}
	resp := req.do() or {
		return utils.err_hint(.network, 'request to ${url} failed: ${err.msg()}',
			'check connectivity and provider.base_url')
	}
	if resp.status_code < 200 || resp.status_code >= 300 {
		return describe_http_error(resp.status_code, resp.body)
	}
	return parse_completion(resp.body)
}

// parse_completion reads a non-streamed chat completion.
fn parse_completion(body string) !Response {
	obj := utils.parse_object(body) or {
		return utils.err_hint(.protocol, 'provider returned invalid JSON',
			utils.truncate(body, 500))
	}
	if e := utils.jget(obj, 'error') {
		if e is map[string]json2.Any {
			detail := utils.jstr(e, 'message', json2.Any(e).json_str())
			return utils.err(.provider, 'provider error: ${detail}')
		}
		return utils.err(.provider, 'provider error: ${utils.any_to_display(e)}')
	}
	choices := utils.jarr(obj, 'choices')
	if choices.len == 0 {
		return utils.err_hint(.protocol, 'provider returned no choices', utils.truncate(body, 500))
	}
	first := choices[0] as map[string]json2.Any
	msg := utils.jmap(first, 'message')
	mut r := Response{
		content:       utils.jstr(msg, 'content', '')
		reasoning:     utils.jstr(msg, 'reasoning_content', '')
		finish_reason: utils.jstr(first, 'finish_reason', '')
		model:         utils.jstr(obj, 'model', '')
	}
	for idx, raw in utils.jarr(msg, 'tool_calls') {
		if raw !is map[string]json2.Any {
			continue
		}
		tc := raw as map[string]json2.Any
		func := utils.jmap(tc, 'function')
		name := utils.jstr(func, 'name', '')
		if name == '' {
			continue
		}
		mut id := utils.jstr(tc, 'id', '')
		if id == '' {
			id = 'call_${idx}'
		}
		mut argv := utils.jstr(func, 'arguments', '')
		if argv.trim_space() == '' {
			argv = '{}'
		}
		r.tool_calls << ToolCall{
			id:        id
			name:      name
			arguments: argv
		}
	}
	usage := utils.jmap(obj, 'usage')
	r.usage = Usage{
		prompt_tokens:     utils.jint(usage, 'prompt_tokens', 0)
		completion_tokens: utils.jint(usage, 'completion_tokens', 0)
		total_tokens:      utils.jint(usage, 'total_tokens', 0)
	}
	return r
}

fn (p &OpenAIProvider) chat_streaming(url string, body string, mut sink Sink) !Response {
	mut acc := new_accumulator(mut sink, openai_event)
	mut req := http.Request{
		method:           .post
		url:              url
		data:             body
		header:           p.headers()
		read_timeout:     i64(p.cfg.timeout_secs) * time.second
		write_timeout:    i64(p.cfg.timeout_secs) * time.second
		user_ptr:         acc
		on_progress_body: openai_on_body
	}
	resp := req.do() or {
		return utils.err_hint(.network, 'streaming request to ${url} failed: ${err.msg()}',
			'check connectivity and provider.base_url')
	}
	if resp.status_code < 200 || resp.status_code >= 300 {
		return describe_http_error(resp.status_code, resp.body)
	}
	acc.finish_stream()
	// Some gateways ignore `stream: true` and answer with one whole JSON body.
	// Detect that rather than returning an empty turn.
	if !acc.done && acc.content.len == 0 && acc.calls.len == 0
		&& resp.body.trim_space().starts_with('{') {
		return parse_completion(resp.body)
	}
	if acc.last_error != '' && acc.content.len == 0 && acc.calls.len == 0 {
		return utils.err(.protocol, acc.last_error)
	}
	return acc.response()
}

// openai_on_body is the HTTP progress callback. V's http client passes caller
// state through `user_ptr`, so the accumulator is recovered from there.
fn openai_on_body(request &http.Request, chunk []u8, _body_read u64, _body_size u64, status_code int) ! {
	if status_code != 0 && (status_code < 200 || status_code >= 300) {
		return
	}
	if request.user_ptr == unsafe { nil } {
		return
	}
	mut acc := unsafe { &Accumulator(request.user_ptr) }
	acc.feed(chunk.bytestr())
}

// openai_event interprets one `data:` frame of an OpenAI-style stream. It is
// public so the dialect can be exercised without a network round trip.
pub fn openai_event(mut acc Accumulator, _event string, obj map[string]json2.Any) {
	if m := utils.jget(obj, 'model') {
		if acc.model == '' {
			acc.model = m.str()
		}
	}
	if u := utils.jget(obj, 'usage') {
		if u is map[string]json2.Any {
			acc.usage = Usage{
				prompt_tokens:     utils.jint(u, 'prompt_tokens', acc.usage.prompt_tokens)
				completion_tokens: utils.jint(u, 'completion_tokens', acc.usage.completion_tokens)
				total_tokens:      utils.jint(u, 'total_tokens', acc.usage.total_tokens)
			}
		}
	}
	if e := utils.jget(obj, 'error') {
		acc.last_error = 'provider error: ${utils.any_to_display(e)}'
		return
	}
	choices := utils.jarr(obj, 'choices')
	if choices.len == 0 {
		return
	}
	if choices[0] !is map[string]json2.Any {
		return
	}
	choice := choices[0] as map[string]json2.Any
	if fr := utils.jget(choice, 'finish_reason') {
		if fr is string {
			acc.finish = fr
		}
	}
	delta := utils.jmap(choice, 'delta')
	if delta.len == 0 {
		return
	}
	if c := utils.jget(delta, 'content') {
		if c is string {
			acc.append_text(c)
		}
	}
	if r := utils.jget(delta, 'reasoning_content') {
		if r is string {
			acc.append_reasoning(r)
		}
	}
	for i, raw in utils.jarr(delta, 'tool_calls') {
		if raw !is map[string]json2.Any {
			continue
		}
		tc := raw as map[string]json2.Any
		index := utils.jint(tc, 'index', i)
		acc.set_call_id(index, utils.jstr(tc, 'id', ''))
		func := utils.jmap(tc, 'function')
		acc.note_tool_name(index, utils.jstr(func, 'name', ''))
		if a := utils.jget(func, 'arguments') {
			if a is string {
				acc.append_args(index, a)
			}
		}
	}
}
