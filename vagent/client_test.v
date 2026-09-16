module vagent

import x.json2

// -- inline <think> splitting ----------------------------------------------

fn test_split_inline_thinking_whole_string() {
	cases := [
		['plain answer', 'plain answer', ''],
		['<think>reasons</think>answer', 'answer', 'reasons'],
		['pre<think>a</think>mid<think>b</think>post', 'premidpost', 'ab'],
		// unterminated block: the model never reached an answer, so nothing
		// is shown rather than leaking half a thought as if it were the reply
		['<think>cut off', '', 'cut off'],
		['', '', ''],
		// a lone closing tag is not an opener — text stays visible
		['answer</think>', 'answer</think>', ''],
	]
	for c in cases {
		v, t := split_inline_thinking(c[0])
		assert v == c[1], 'visible for ${c[0]}: got ${v}'
		assert t == c[2], 'thinking for ${c[0]}: got ${t}'
	}
}

fn stream_split(pieces []string) (string, string) {
	mut s := InlineThinkSplitter{}
	mut v := []string{}
	mut t := []string{}
	for p in pieces {
		a, b := s.feed(p)
		v << a
		t << b
	}
	a, b := s.flush()
	v << a
	t << b
	return v.join(''), t.join('')
}

fn test_split_is_identical_at_every_chunk_boundary() {
	// the SAME input must split identically no matter where the chunk
	// boundaries fall — this is the case that regresses if the splitter
	// ever stops holding back partial tags
	src := 'hi<think>deep thought</think>bye'
	for width in 1 .. src.len + 1 {
		mut chunks := []string{}
		mut i := 0
		for i < src.len {
			e := if i + width < src.len { i + width } else { src.len }
			chunks << src[i..e]
			i = e
		}
		v, t := stream_split(chunks)
		assert v == 'hibye', 'width ${width}: visible=${v}'
		assert t == 'deep thought', 'width ${width}: thinking=${t}'
	}
}

fn test_split_handles_worst_case_boundaries() {
	// tag split across a boundary at the worst possible place
	v1, t1 := stream_split(['a<thi', 'nk>x</thi', 'nk>b'])
	assert v1 == 'ab' && t1 == 'x'
	// text that merely starts like a tag is not swallowed
	v2, t2 := stream_split(['<thinking about it>'])
	assert v2 == '<thinking about it>' && t2 == ''
}

// -- provider preconditions -------------------------------------------------

fn test_check_api_key_rejects_unconfigured_providers() {
	bad := [
		Provider{ key: 'k', name: 'K', base_url: 'https://x/v1', api_key: '' },
		Provider{ key: 'k', name: 'K', base_url: '', api_key: 'sk-1' },
		Provider{ key: 'k', name: 'K', base_url: 'router.example/v1', api_key: 'sk-1' },
	]
	for p in bad {
		if _ := check_api_key(p) {
			assert false, 'expected an error for ${p.base_url}/${p.api_key}'
		} else {
			assert err.msg().to_upper().contains('K'), err.msg()
		}
	}
	// both set: OK
	check_api_key(Provider{ key: 'k', name: 'K', base_url: 'https://x/v1', api_key: 'sk-1' }) or {
		assert false, 'a fully configured provider was rejected: ${err}'
	}
}

// -- context overflow -------------------------------------------------------

fn test_is_context_overflow_markers() {
	assert is_context_overflow('This model has a maximum context length of 262144 tokens')
	assert is_context_overflow('Please reduce the number of tokens')
	assert is_context_overflow('CONTEXT WINDOW exceeded')
	assert !is_context_overflow('invalid api key')
}

fn test_parse_overflow_extracts_real_counts() {
	msg := "This model's maximum context length is 262144 tokens. However, you " +
		'requested a total of 263120 tokens: 67440 tokens from the input ' +
		'messages and 195680 tokens for the completion.'
	info := parse_overflow(msg)
	assert info.present
	assert info.window == 262144, '${info.window}'
	assert info.input_tokens == 67440, '${info.input_tokens}'
	assert info.completion_tokens == 195680, '${info.completion_tokens}'
	assert info.total == 263120, '${info.total}'

	// a comma-formatted variant parses to the same numbers
	commas := 'maximum context length of 131,072 tokens'
	assert parse_overflow(commas).window == 131072

	// a non-overflow error yields nothing to act on
	assert !parse_overflow('unauthorized').present
}

fn test_fit_max_tokens_uses_backend_counts() {
	model := Model{ id: 'test-fit', label: 'T', context_window: 262_144 }
	effort := Effort{ key: 'high', max_tokens: 200_000 }
	info := OverflowInfo{
		window:       262_144
		input_tokens: 67_440
		present:      true
	}
	fitted := fit_max_tokens_from_actual(model, info, effort)
	assert fitted > 0
	// whatever it returns must provably fit inside the window
	assert info.input_tokens + fitted <= info.window

	// an input that fills the window on its own cannot be fixed by clamping
	huge := OverflowInfo{
		window:       262_144
		input_tokens: 262_000
		present:      true
	}
	assert fit_max_tokens_from_actual(model, huge, effort) == 0
}

// -- token estimation and payload building ---------------------------------

fn test_estimate_tokens_is_positive_and_scales() {
	small := estimate_tokens(json2.Any('hi'), 'nonexistent-model')
	big := estimate_tokens(json2.Any('x'.repeat(10_000)), 'nonexistent-model')
	assert small >= 1
	assert big > small
}

fn test_build_payload_shape() {
	model := Model{
		id:             'm1'
		provider:       'zen'
		label:          'M1'
		supports_tools: true
		context_window: 262_144
	}
	effort := Effort{ key: 'high', max_tokens: 200_000, temperature: 0.6 }
	mut msgs := [system_message('sys'), user_message('hello')]
	tools := [json2.Any({
		'type': json2.Any('function')
	})]
	p := build_payload(model, effort, mut msgs, tools, true) or { panic(err) }
	assert jstr(p, 'model') == 'm1'
	assert jbool(p, 'stream')
	assert jf64(p, 'temperature') == 0.6
	assert 'tools' in p
	assert jstr(p, 'tool_choice') == 'auto'
	// the hard invariant: input + max_tokens must fit the window
	budget := jint(p, 'max_tokens')
	assert budget >= 1024
	assert estimate_message_tokens(msgs, 'm1') + budget <= effective_window(model)
}

fn test_build_payload_refuses_an_input_that_cannot_fit() {
	model := Model{ id: 'tiny', label: 'Tiny', context_window: 2_048 }
	effort := Effort{ key: 'high', max_tokens: 200_000 }
	mut msgs := [user_message('x'.repeat(200_000))]
	if _ := build_payload(model, effort, mut msgs, []json2.Any{}, true) {
		assert false, 'a doomed request was built instead of refused'
	} else {
		assert is_context_overflow(err.msg()), err.msg()
		assert err.msg().contains('/rewind'), err.msg()
	}
}

fn test_tools_are_omitted_for_models_that_cannot_call_them() {
	model := Model{ id: 'notools', label: 'N', supports_tools: false }
	effort := Effort{ key: 'low', max_tokens: 1000 }
	mut msgs := [user_message('hi')]
	tools := [json2.Any({
		'type': json2.Any('function')
	})]
	p := build_payload(model, effort, mut msgs, tools, false) or { panic(err) }
	assert 'tools' !in p
	assert 'tool_choice' !in p
}

fn test_thinking_is_suppressed_per_provider() {
	effort := Effort{ key: 'low', max_tokens: 1000 }
	mut msgs := [user_message('hi')]

	// tokenrouter rejects reasoning_effort="none", so it gets the floor
	tr := Model{ id: 'q', provider: 'tokenrouter', label: 'Q', supports_reasoning: true }
	p1 := build_payload(tr, effort, mut msgs, []json2.Any{}, false) or { panic(err) }
	assert jstr(p1, 'reasoning_effort') == 'low'

	// everything else gets an explicit "none"
	other := Model{ id: 'z', provider: 'zen', label: 'Z', supports_reasoning: true }
	p2 := build_payload(other, effort, mut msgs, []json2.Any{}, false) or { panic(err) }
	assert jstr(p2, 'reasoning_effort') == 'none'

	// a model with no reasoning switch gets no key at all
	plain := Model{ id: 'p', provider: 'zen', label: 'P', supports_reasoning: false }
	p3 := build_payload(plain, effort, mut msgs, []json2.Any{}, false) or { panic(err) }
	assert 'reasoning_effort' !in p3
}

fn test_max_tokens_is_capped_per_provider() {
	// agnes' sglang backend rejects anything over 65536
	assert clamp_max_tokens('agnes', 200_000) == 65_536
	assert clamp_max_tokens('agnes', 1_000) == 1_000
	// a provider with no known cap passes through
	assert clamp_max_tokens('zen', 200_000) == 200_000
}

// -- message hygiene --------------------------------------------------------

fn test_assistant_message_keeps_empty_content_distinct_from_none() {
	// a reasoning model that spent its budget thinking can legitimately
	// answer with whitespace; that is NOT the same as no content at all
	with_empty := assistant_message(' ', []ToolCall{}, '')
	assert with_empty.content != none
	assert with_empty.text() == ' '

	without := assistant_message(none, []ToolCall{}, '')
	assert without.content == none

	j := without.to_json()
	assert j['content'] or { json2.Any('x') } is json2.Null
}

fn test_tool_call_turns_always_carry_reasoning_content() {
	calls := [ToolCall{
		id:       'c1'
		function: ToolCallFunction{ name: 'read_file', arguments: '{}' }
	}]
	// no reasoning available: the key must still be present, as an empty
	// string, or thinking-aware backends reject the history
	m := assistant_message('', calls, '')
	assert m.reasoning_content != none
	assert (m.reasoning_content or { 'x' }) == ''

	// real reasoning sets both keys for maximum provider compatibility
	m2 := assistant_message('', calls, 'because')
	assert (m2.reasoning_content or { '' }) == 'because'
	assert (m2.reasoning or { '' }) == 'because'

	// a plain text turn carries neither
	m3 := assistant_message('hello', []ToolCall{}, '')
	assert m3.reasoning_content == none
}

fn test_sanitize_messages_heals_stale_history() {
	calls := [ToolCall{ id: 'c1', function: ToolCallFunction{ name: 'x' } }]
	mut msgs := [
		user_message('hi'),
		Message{ role: 'assistant', content: '', tool_calls: calls },
		tool_message('c1', 'x', 'done'),
	]
	assert sanitize_messages(mut msgs)
	assert msgs[1].reasoning_content != none
	// a second pass finds nothing left to fix
	assert !sanitize_messages(mut msgs)
}

// -- overflow shrinking -----------------------------------------------------

fn test_shrink_truncates_oldest_tool_results_first() {
	long := 'y'.repeat(2000)
	mut msgs := [
		user_message('go'),
		tool_message('c1', 't', long),
		tool_message('c2', 't', long),
	]
	assert shrink_tool_outputs(mut msgs, 1, 400)
	// the oldest was truncated, the newest kept verbatim
	assert msgs[1].text().len < long.len
	assert msgs[1].text().contains('truncated')
	assert msgs[2].text() == long
}

fn test_shrink_escalates_to_the_newest_then_drops_a_turn() {
	long := 'y'.repeat(2000)
	mut msgs := [user_message('go'), tool_message('c1', 't', long)]
	// pass 1 finds nothing stale (the only result is the newest), so pass 2
	// truncates it anyway
	assert shrink_tool_outputs(mut msgs, 1, 400)
	assert msgs[1].text().contains('truncated')

	// nothing left to truncate: the oldest whole turn unit goes instead,
	// and the system prompt is never the thing dropped
	mut msgs2 := [
		system_message('sys'),
		user_message('first'),
		Message{ role: 'assistant', content: 'a1' },
		user_message('second'),
	]
	assert shrink_tool_outputs(mut msgs2, 1, 400)
	assert msgs2[0].role == 'system'
	assert msgs2[1].text() == 'second'
}

// -- result parsing ---------------------------------------------------------

fn test_result_from_json_parses_a_completion() {
	body := '{"model":"m9","usage":{"prompt_tokens":10,"completion_tokens":4},' +
		'"choices":[{"finish_reason":"tool_calls","message":{' +
		'"content":"<think>hmm</think>answer",' +
		'"tool_calls":[{"id":"c1","type":"function","function":' +
		'{"name":"read_file","arguments":"{\\"path\\":\\"x\\"}"}}]}}]}'
	r := result_from_json(decode_obj(body), 'fallback')
	assert r.model == 'm9'
	assert r.content == 'answer'
	assert r.reasoning == 'hmm'
	assert r.finish_reason == 'tool_calls'
	assert r.tool_calls.len == 1
	assert r.tool_calls[0].function.name == 'read_file'
	assert r.tool_calls[0].id == 'c1'
	assert r.has_usage
	assert jint(r.usage, 'prompt_tokens') == 10
}

fn test_extract_error_message_digs_out_the_real_reason() {
	assert extract_error_message('{"error":{"message":"bad key"}}') == 'bad key'
	assert extract_error_message('{"error":"flat"}') == 'flat'
	// valid JSON but not an object — no shape to dig into
	assert extract_error_message('[1,2]') == '[1,2]'
	assert extract_error_message('not json').contains('not json')
}

fn test_cold_admission_detection() {
	assert is_cold_admission('cache-only admission rejected')
	assert is_cold_admission('backend is COLD OR OVERLOADED')
	assert !is_cold_admission('rate limit exceeded')
}
