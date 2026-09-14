module main

import src.model

// The streaming tests replay real wire captures rather than synthetic JSON, so
// a dialect change on the provider side shows up here as a failing test.

const openai_stream = 'data: {"id":"c1","object":"chat.completion.chunk","model":"test-model","choices":[{"index":0,"delta":{"role":"assistant"},"finish_reason":null}]}

data: {"id":"c1","choices":[{"index":0,"delta":{"content":"Reading the "},"finish_reason":null}]}

data: {"id":"c1","choices":[{"index":0,"delta":{"content":"file."},"finish_reason":null}]}

data: {"id":"c1","choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"id":"call_abc","type":"function","function":{"name":"read_file","arguments":""}}]},"finish_reason":null}]}

data: {"id":"c1","choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"function":{"arguments":"{\\"path\\":"}}]},"finish_reason":null}]}

data: {"id":"c1","choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"function":{"arguments":"\\"a.v\\"}"}}]},"finish_reason":null}]}

data: {"id":"c1","choices":[{"index":0,"delta":{},"finish_reason":"tool_calls"}],"usage":{"prompt_tokens":11,"completion_tokens":22,"total_tokens":33}}

data: [DONE]

'

// Collector is heap-allocated on purpose: a V closure captures by value, so a
// plain local array would be copied and the appends would never be observable
// here. The renderer works in production for the same reason -- it is a
// pointer.
@[heap]
struct Collector {
mut:
	chunks []string
}

fn test_openai_stream_assembles_text_and_tool_calls() {
	mut seen := &Collector{}
	mut sink := model.Sink{}
	sink.on_text = fn [mut seen] (chunk string) {
		seen.chunks << chunk
	}
	resp := model.decode_stream(openai_stream, model.openai_event, mut sink)

	assert resp.content == 'Reading the file.'
	assert resp.finish_reason == 'tool_calls'
	assert resp.model == 'test-model'
	assert resp.usage.total_tokens == 33
	assert resp.tool_calls.len == 1
	assert resp.tool_calls[0].id == 'call_abc'
	assert resp.tool_calls[0].name == 'read_file'
	// Arguments arrive as fragments and must be concatenated in order.
	assert resp.tool_calls[0].arguments == '{"path":"a.v"}'
	// The sink sees the text incrementally, which is what makes it stream.
	assert seen.chunks.len == 2
}

fn test_stream_survives_chunk_boundaries_mid_line() {
	mut sink := model.Sink{}
	mut acc := model.new_accumulator(mut sink, model.openai_event)
	// Split the capture at an arbitrary byte, the way TCP would.
	cut := openai_stream.len / 3
	acc.feed(openai_stream#[..cut])
	acc.feed(openai_stream#[cut..])
	acc.finish_stream()
	resp := acc.response()
	assert resp.content == 'Reading the file.'
	assert resp.tool_calls.len == 1
	assert resp.tool_calls[0].arguments == '{"path":"a.v"}'
}

fn test_stream_ignores_comments_and_blank_lines() {
	body := ': keep-alive\n\ndata: {"choices":[{"delta":{"content":"hi"}}]}\n\ndata: [DONE]\n'
	mut sink := model.Sink{}
	resp := model.decode_stream(body, model.openai_event, mut sink)
	assert resp.content == 'hi'
}

fn test_incomplete_tool_call_is_dropped() {
	// A stream cut off before the function name arrives must not produce a
	// nameless tool call, which the registry could never dispatch.
	body := 'data: {"choices":[{"delta":{"tool_calls":[{"index":0,"id":"x"}]}}]}\n\n'
	mut sink := model.Sink{}
	resp := model.decode_stream(body, model.openai_event, mut sink)
	assert resp.tool_calls.len == 0
}

const anthropic_stream = 'event: message_start
data: {"type":"message_start","message":{"model":"claude-test","usage":{"input_tokens":7}}}

event: content_block_start
data: {"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}

event: content_block_delta
data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Checking."}}

event: content_block_start
data: {"type":"content_block_start","index":1,"content_block":{"type":"tool_use","id":"toolu_1","name":"shell"}}

event: content_block_delta
data: {"type":"content_block_delta","index":1,"delta":{"type":"input_json_delta","partial_json":"{\\"command\\""}}

event: content_block_delta
data: {"type":"content_block_delta","index":1,"delta":{"type":"input_json_delta","partial_json":":\\"ls\\"}"}}

event: message_delta
data: {"type":"message_delta","delta":{"stop_reason":"tool_use"},"usage":{"output_tokens":13}}

event: message_stop
data: {"type":"message_stop"}

'

fn test_anthropic_stream_assembles_blocks() {
	mut sink := model.Sink{}
	resp := model.decode_stream(anthropic_stream, model.anthropic_event, mut sink)
	assert resp.content == 'Checking.'
	assert resp.finish_reason == 'tool_use'
	assert resp.model == 'claude-test'
	assert resp.usage.prompt_tokens == 7
	assert resp.usage.completion_tokens == 13
	// Block 0 is text, so the tool_use at block index 1 is the only call.
	assert resp.tool_calls.len == 1
	assert resp.tool_calls[0].name == 'shell'
	assert resp.tool_calls[0].id == 'toolu_1'
	assert resp.tool_calls[0].arguments == '{"command":"ls"}'
}

fn test_join_url_does_not_double_the_path() {
	assert model.join_url('https://x.test/v1', 'chat/completions') == 'https://x.test/v1/chat/completions'
	assert model.join_url('https://x.test/v1/', 'chat/completions') == 'https://x.test/v1/chat/completions'
	// A base that already names the endpoint is left alone.
	assert model.join_url('https://x.test/v1/chat/completions', 'chat/completions') == 'https://x.test/v1/chat/completions'
}

fn test_http_error_messages_are_actionable() {
	e := model.describe_http_error(401, '{"error":"bad key"}')
	assert e.msg().contains('401')
	assert e.msg().contains('VAGENT_API_KEY')
	rate := model.describe_http_error(429, 'slow down')
	assert rate.msg().contains('rate limited')
}
