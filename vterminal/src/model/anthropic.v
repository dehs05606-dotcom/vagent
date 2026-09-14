module model

import net.http
import time
import x.json2
import src.config
import src.utils

// AnthropicProvider speaks the Messages API. The dialect differs from OpenAI's
// in three ways that matter here: the system prompt is a top-level field, tool
// results are content blocks inside a user turn rather than their own role, and
// the stream is a named-event SSE rather than a sequence of anonymous deltas.
@[heap]
pub struct AnthropicProvider {
pub mut:
	cfg config.ProviderConfig
	log &utils.Logger = unsafe { nil }
}

pub fn new_anthropic(cfg config.ProviderConfig, mut log utils.Logger) &AnthropicProvider {
	return &AnthropicProvider{
		cfg: cfg
		log: &log
	}
}

pub fn (p &AnthropicProvider) name() string {
	return p.cfg.name
}

pub fn (p &AnthropicProvider) model_id() string {
	return p.cfg.model
}

pub fn (p &AnthropicProvider) context_limit() int {
	return p.cfg.context_limit
}

fn (p &AnthropicProvider) headers() http.Header {
	mut h := http.new_header()
	h.add(.content_type, 'application/json')
	h.add(.accept, 'application/json, text/event-stream')
	h.add_custom('x-api-key', p.cfg.api_key) or {}
	h.add_custom('anthropic-version', '2023-06-01') or {}
	for k, v in p.cfg.headers {
		h.add_custom(k, v) or {}
	}
	return h
}

pub fn (p &AnthropicProvider) chat(req Request, mut sink Sink) !Response {
	body := p.build_body(req)
	url := join_url(p.cfg.base_url, 'messages')
	if p.log != unsafe { nil } {
		mut l := p.log
		l.debug('POST ${url} (anthropic) stream=${req.stream} messages=${req.messages.len}')
	}
	mut acc := new_accumulator(mut sink, anthropic_event)
	mut hreq := http.Request{
		method:        .post
		url:           url
		data:          body
		header:        p.headers()
		read_timeout:  i64(p.cfg.timeout_secs) * time.second
		write_timeout: i64(p.cfg.timeout_secs) * time.second
	}
	if req.stream {
		hreq.user_ptr = acc
		hreq.on_progress_body = anthropic_on_body
	}
	resp := hreq.do() or {
		return utils.err_hint(.network, 'request to ${url} failed: ${err.msg()}',
			'check connectivity and provider.base_url')
	}
	if resp.status_code < 200 || resp.status_code >= 300 {
		return describe_http_error(resp.status_code, resp.body)
	}
	if !req.stream {
		return parse_anthropic_message(resp.body)
	}
	acc.finish_stream()
	if acc.last_error != '' && acc.content.len == 0 && acc.calls.len == 0 {
		return utils.err(.protocol, acc.last_error)
	}
	return acc.response()
}

fn (p &AnthropicProvider) build_body(req Request) string {
	mut obj := map[string]json2.Any{}
	obj['model'] = json2.Any(p.cfg.model)
	obj['max_tokens'] = json2.Any(if p.cfg.max_tokens > 0 { p.cfg.max_tokens } else { 4096 })
	if p.cfg.temperature != 0.0 {
		obj['temperature'] = json2.Any(p.cfg.temperature)
	}
	system, msgs := split_system(req.messages)
	if system != '' {
		obj['system'] = json2.Any(system)
	}
	obj['messages'] = json2.Any(msgs)
	if req.tools.len > 0 {
		obj['tools'] = json2.Any(to_anthropic_tools(req.tools))
	}
	if req.stream {
		obj['stream'] = json2.Any(true)
	}
	return json2.Any(obj).json_str()
}

// split_system hoists system turns into the top-level field and rewrites the
// remaining conversation into Anthropic's content-block form.
fn split_system(messages []Message) (string, []json2.Any) {
	mut system := []string{}
	mut out := []json2.Any{}
	mut pending_results := []json2.Any{}

	flush := fn (mut out []json2.Any, mut pending []json2.Any) {
		if pending.len == 0 {
			return
		}
		mut m := map[string]json2.Any{}
		m['role'] = json2.Any('user')
		m['content'] = json2.Any(pending.clone())
		out << json2.Any(m)
		pending.clear()
	}

	for msg in messages {
		match msg.role {
			.system {
				system << msg.content
			}
			.tool {
				// Consecutive tool results are merged into one user turn, which
				// is what the API expects after a multi-tool assistant turn.
				mut block := map[string]json2.Any{}
				block['type'] = json2.Any('tool_result')
				block['tool_use_id'] = json2.Any(msg.tool_call_id)
				block['content'] = json2.Any(msg.content)
				pending_results << json2.Any(block)
			}
			.user {
				flush(mut out, mut pending_results)
				mut m := map[string]json2.Any{}
				m['role'] = json2.Any('user')
				m['content'] = json2.Any(msg.content)
				out << json2.Any(m)
			}
			.assistant {
				flush(mut out, mut pending_results)
				mut blocks := []json2.Any{}
				if msg.content.trim_space() != '' {
					mut tb := map[string]json2.Any{}
					tb['type'] = json2.Any('text')
					tb['text'] = json2.Any(msg.content)
					blocks << json2.Any(tb)
				}
				for c in msg.tool_calls {
					mut ub := map[string]json2.Any{}
					ub['type'] = json2.Any('tool_use')
					ub['id'] = json2.Any(c.id)
					ub['name'] = json2.Any(c.name)
					input := utils.parse_object(c.arguments) or {
						map[string]json2.Any{}
					}
					ub['input'] = json2.Any(input)
					blocks << json2.Any(ub)
				}
				if blocks.len == 0 {
					continue
				}
				mut m := map[string]json2.Any{}
				m['role'] = json2.Any('assistant')
				m['content'] = json2.Any(blocks)
				out << json2.Any(m)
			}
		}
	}
	flush(mut out, mut pending_results)
	return system.join('\n\n'), out
}

// to_anthropic_tools unwraps the OpenAI `{type, function:{...}}` envelope that
// the registry produces into Anthropic's flat tool shape.
fn to_anthropic_tools(tools []json2.Any) []json2.Any {
	mut out := []json2.Any{cap: tools.len}
	for t in tools {
		if t !is map[string]json2.Any {
			continue
		}
		wrapper := t as map[string]json2.Any
		func := utils.jmap(wrapper, 'function')
		if func.len == 0 {
			out << t
			continue
		}
		mut m := map[string]json2.Any{}
		m['name'] = json2.Any(utils.jstr(func, 'name', ''))
		m['description'] = json2.Any(utils.jstr(func, 'description', ''))
		m['input_schema'] = json2.Any(utils.jmap(func, 'parameters'))
		out << json2.Any(m)
	}
	return out
}

fn parse_anthropic_message(body string) !Response {
	obj := utils.parse_object(body) or {
		return utils.err_hint(.protocol, 'provider returned invalid JSON',
			utils.truncate(body, 500))
	}
	if e := utils.jget(obj, 'error') {
		return utils.err(.provider, 'provider error: ${utils.any_to_display(e)}')
	}
	mut r := Response{
		finish_reason: utils.jstr(obj, 'stop_reason', '')
		model:         utils.jstr(obj, 'model', '')
	}
	mut text := []string{}
	for raw in utils.jarr(obj, 'content') {
		if raw !is map[string]json2.Any {
			continue
		}
		block := raw as map[string]json2.Any
		match utils.jstr(block, 'type', '') {
			'text' {
				text << utils.jstr(block, 'text', '')
			}
			'tool_use' {
				input := utils.jmap(block, 'input')
				r.tool_calls << ToolCall{
					id:        utils.jstr(block, 'id', '')
					name:      utils.jstr(block, 'name', '')
					arguments: json2.Any(input).json_str()
				}
			}
			else {}
		}
	}
	r.content = text.join('')
	usage := utils.jmap(obj, 'usage')
	r.usage = Usage{
		prompt_tokens:     utils.jint(usage, 'input_tokens', 0)
		completion_tokens: utils.jint(usage, 'output_tokens', 0)
	}
	r.usage.total_tokens = r.usage.prompt_tokens + r.usage.completion_tokens
	return r
}

fn anthropic_on_body(request &http.Request, chunk []u8, _body_read u64, _body_size u64, status_code int) ! {
	if status_code != 0 && (status_code < 200 || status_code >= 300) {
		return
	}
	if request.user_ptr == unsafe { nil } {
		return
	}
	mut acc := unsafe { &Accumulator(request.user_ptr) }
	acc.feed(chunk.bytestr())
}

// anthropic_event maps the named SSE events onto the shared accumulator. The
// block index doubles as the tool-call index, which is why text blocks and
// tool_use blocks can be interleaved without confusing the accumulator.
pub fn anthropic_event(mut acc Accumulator, event string, obj map[string]json2.Any) {
	kind := if event != '' { event } else { utils.jstr(obj, 'type', '') }
	match kind {
		'message_start' {
			msg := utils.jmap(obj, 'message')
			acc.model = utils.jstr(msg, 'model', acc.model)
			usage := utils.jmap(msg, 'usage')
			acc.usage.prompt_tokens = utils.jint(usage, 'input_tokens', acc.usage.prompt_tokens)
		}
		'content_block_start' {
			block := utils.jmap(obj, 'content_block')
			if utils.jstr(block, 'type', '') == 'tool_use' {
				index := utils.jint(obj, 'index', 0)
				acc.set_call_id(index, utils.jstr(block, 'id', ''))
				acc.note_tool_name(index, utils.jstr(block, 'name', ''))
			}
		}
		'content_block_delta' {
			index := utils.jint(obj, 'index', 0)
			delta := utils.jmap(obj, 'delta')
			match utils.jstr(delta, 'type', '') {
				'text_delta' { acc.append_text(utils.jstr(delta, 'text', '')) }
				'thinking_delta' { acc.append_reasoning(utils.jstr(delta, 'thinking', '')) }
				'input_json_delta' { acc.append_args(index, utils.jstr(delta, 'partial_json', '')) }
				else {}
			}
		}
		'message_delta' {
			delta := utils.jmap(obj, 'delta')
			if sr := utils.jget(delta, 'stop_reason') {
				if sr is string {
					acc.finish = sr
				}
			}
			usage := utils.jmap(obj, 'usage')
			acc.usage.completion_tokens = utils.jint(usage, 'output_tokens',
				acc.usage.completion_tokens)
			acc.usage.total_tokens = acc.usage.prompt_tokens + acc.usage.completion_tokens
		}
		'message_stop' {
			acc.done = true
		}
		'error' {
			acc.last_error = 'provider error: ${utils.any_to_display(json2.Any(utils.jmap(obj,
				'error')))}'
		}
		else {}
	}
}
