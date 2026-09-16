module vagent

import net.http
import time
import x.json2

// client_stream.v — the SSE stream loop, its retry budget, and the
// three-layer context-overflow recovery shared by streaming and blocking
// mode.

pub const overflow_retries = 2 // re-clamp-and-retry attempts (input still fits)
pub const overflow_shrinks = 2 // shrink-the-conversation-and-retry attempts

// StreamState is the incremental parser's state. It lives on the heap and is
// reached through the request's user_ptr, because V's http client hands the
// progress callback a plain function, not a closure.
@[heap]
struct StreamState {
mut:
	cb        StreamCallbacks
	result    StreamResult
	think     InlineThinkSplitter
	tc_order  []int
	tc_acc    map[int]ToolCallDelta
	announced map[int]bool
	// SSE frames arrive split across chunks, so partial lines are held here
	pending string
	// the whole body, kept only when the response turned out NOT to be SSE
	raw     string
	is_sse  bool
	checked_type bool
	// set when the stream raised: V progress callbacks propagate an error,
	// but the reason has to survive back to the caller
	failed     bool
	fail_msg   string
	fail_status int
	cancelled  bool
	// true once anything has been shown to the user, which makes a retry
	// unsafe (it would replay the completion on top of the partial output)
	emitted bool
}

// on_sse_chunk is the http progress callback: it feeds each received chunk
// into the SSE parser.
fn on_sse_chunk(req &http.Request, chunk []u8, read_so_far u64, expected u64, status int) ! {
	mut st := unsafe { &StreamState(req.user_ptr) }
	if !st.checked_type {
		st.checked_type = true
		// a non-200 body is an error payload, not a stream
		st.is_sse = status == 200
	}
	if status != 200 {
		st.raw += chunk.bytestr()
		return
	}
	if st.cb.should_cancel() {
		st.cancelled = true
		return error('cancelled')
	}
	text := chunk.bytestr()
	st.raw += text
	st.pending += text
	for {
		idx := st.pending.index('\n') or { break }
		line := st.pending[..idx].trim_right('\r')
		st.pending = st.pending[idx + 1..]
		st.handle_sse_line(line) or {
			st.failed = true
			st.fail_msg = err.msg()
			return err
		}
	}
}

// handle_sse_line parses one `data:` frame.
fn (mut st StreamState) handle_sse_line(raw_line string) ! {
	line := raw_line.trim_space()
	if line == '' {
		return
	}
	if line.starts_with(':') {
		return // comment / keepalive
	}
	if !line.starts_with('data:') {
		// the body is not an event stream at all; remember so the caller
		// can fall back to parsing it as one JSON completion
		if line.starts_with('{') {
			st.is_sse = false
		}
		return
	}
	data := line['data:'.len..].trim_space()
	if data == '[DONE]' {
		return
	}
	event := json2.decode[json2.Any](data) or { return }
	obj := match event {
		map[string]json2.Any { event }
		else { return }
	}
	st.apply_event(obj)!
}

fn (mut st StreamState) apply_event(event map[string]json2.Any) ! {
	if m := event['model'] {
		if m !is json2.Null && m.str() != '' {
			st.result.model = m.str()
		}
	}
	if u := event['usage'] {
		if u is map[string]json2.Any {
			st.result.usage = u.clone()
			st.result.has_usage = true
		}
	}
	if e := event['error'] {
		msg := match e {
			map[string]json2.Any {
				m := jstr(e, 'message')
				if m != '' { m } else { json2.Any(e).json_str() }
			}
			else {
				e.str()
			}
		}
		st.failed = true
		st.fail_msg = msg
		return error(msg)
	}
	choices := jarr(event, 'choices')
	if choices.len == 0 {
		return
	}
	choice := match choices[0] {
		map[string]json2.Any { choices[0] as map[string]json2.Any }
		else { return }
	}
	delta := jmap(choice, 'delta')

	fr := jstr(choice, 'finish_reason')
	if fr != '' {
		st.result.finish_reason = fr
	}

	piece := jstr(delta, 'content')
	if piece != '' {
		shown, thought := st.think.feed(piece)
		if shown != '' {
			st.result.content += shown
			st.emitted = true
			st.cb.on_token(shown)
		}
		if thought != '' {
			st.result.reasoning += thought
			st.emitted = true
			st.cb.on_reasoning(thought)
		}
	}

	mut reasoning := jstr(delta, 'reasoning_content')
	if reasoning == '' {
		reasoning = jstr(delta, 'reasoning')
	}
	if reasoning != '' {
		st.result.reasoning += reasoning
		st.emitted = true
		st.cb.on_reasoning(reasoning)
	}

	for tc_any in jarr(delta, 'tool_calls') {
		tc := match tc_any {
			map[string]json2.Any { tc_any }
			else { continue }
		}
		idx := jint(tc, 'index')
		if idx !in st.tc_acc {
			st.tc_acc[idx] = ToolCallDelta{}
			st.tc_order << idx
		}
		mut acc := st.tc_acc[idx]
		id := jstr(tc, 'id')
		if id != '' {
			acc.id = id
		}
		f := jmap(tc, 'function')
		name := jstr(f, 'name')
		if name != '' {
			acc.name += name
			if idx !in st.announced {
				st.announced[idx] = true
				st.cb.on_tool_start(acc.name)
			}
		}
		args := jstr(f, 'arguments')
		if args != '' {
			acc.arguments += args
			// tool-call arguments are already flowing to the UI — a retry
			// now would replay them on top of the live write
			st.emitted = true
			st.cb.on_tool_args(acc.name, args)
		}
		st.tc_acc[idx] = acc
	}
}

// finish releases whatever the splitter held back and assembles the tool
// calls in index order.
fn (mut st StreamState) finish() {
	shown, thought := st.think.flush()
	if shown != '' {
		st.result.content += shown
		st.cb.on_token(shown)
	}
	if thought != '' {
		st.result.reasoning += thought
		st.cb.on_reasoning(thought)
	}
	mut order := st.tc_order.clone()
	order.sort()
	for idx in order {
		acc := st.tc_acc[idx] or { continue }
		st.result.tool_calls << ToolCall{
			id:       if acc.id != '' { acc.id } else { 'call_${idx}' }
			kind:     'function'
			function: ToolCallFunction{
				name:      acc.name
				arguments: acc.arguments
			}
		}
	}
}

// ---------------------------------------------------------------------------
// One request
// ---------------------------------------------------------------------------

struct OnceResult {
	result  StreamResult
	emitted bool
}

fn chat_stream_once(url string, provider Provider, payload map[string]json2.Any, cb StreamCallbacks, timeout f64) !OnceResult {
	mut st := &StreamState{
		cb: cb
	}
	mut req := http.Request{
		url:              url
		method:           .post
		header:           auth_headers(provider, true)
		data:             json2.Any(payload).json_str()
		read_timeout:     i64(timeout * f64(time.second))
		write_timeout:    i64(timeout * f64(time.second))
		user_ptr:         st
		on_progress_body: on_sse_chunk
	}
	resp := req.do() or {
		if st.cancelled {
			return TurnCancelled{}
		}
		if st.failed {
			return api_error(st.fail_msg, st.fail_status)
		}
		return api_error('connection failed: ${err.msg()}', 0)
	}
	if resp.status_code != 200 {
		body := if st.raw != '' { st.raw } else { resp.body }
		return api_error(extract_error_message(body), resp.status_code)
	}
	if st.failed {
		return api_error(st.fail_msg, st.fail_status)
	}
	if cb.should_cancel() {
		return TurnCancelled{}
	}
	ctype := (resp.header.get(.content_type) or { '' }).to_lower()
	if !ctype.contains('text/event-stream') && !st.is_sse {
		// Some providers return a non-streamed JSON body even when
		// stream=true was requested — parse it like blocking mode instead
		// of silently dropping the whole completion.
		body := if st.raw != '' { st.raw } else { resp.body }
		data := decode_obj(body)
		if data.len > 0 {
			return OnceResult{
				result:  result_from_json(data, jstr(data, 'model'))
				emitted: st.emitted
			}
		}
	}
	st.finish()
	return OnceResult{
		result:  st.result
		emitted: st.emitted
	}
}

// ---------------------------------------------------------------------------
// Retry loop
// ---------------------------------------------------------------------------

// chat_stream_with_retries is the plain retry loop (rate limits, timeouts,
// connection errors, and TokenRouter cold-admission rejections).
//
// A retry restarts the WHOLE request — once any token has already been
// streamed to the UI a restart would replay (duplicate) the completion on
// top of the partial output, so mid-output failures surface immediately
// instead of being retried.
fn chat_stream_with_retries(url string, provider Provider, payload map[string]json2.Any, cb StreamCallbacks, timeout f64) !StreamResult {
	mut cold_retries := 0
	mut attempt := 0
	mut last_error := ''

	for attempt < max_retries {
		once := chat_stream_once(url, provider, payload, cb, timeout) or {
			if err is TurnCancelled {
				return err
			}
			last_error = err.msg()
			status := if err is APIError { err.status } else { 0 }
			emitted := false

			// Cold-admission rejection: not an HTTP failure and not a hard
			// error — the prompt cache just isn't warm yet. A dedicated
			// backoff budget lets a session-opening request on a free-tier
			// endpoint survive until admission opens up.
			if is_cold_admission(last_error) {
				if cb.should_cancel() {
					return TurnCancelled{}
				}
				cold_retries++
				if cold_retries <= max_cold_retries {
					time.sleep(i64(cold_retry_wait * f64(cold_retries) * f64(time.second)))
					continue
				}
				return err
			}
			if status in retry_statuses && attempt < max_retries - 1 {
				// fast first retry, then escalate — rate limits resolve
				// quickly on free tiers; never stall the UI for seconds
				wait := if attempt == 0 { 0.5 } else { 2.0 * f64(attempt) }
				time.sleep(i64(wait * f64(time.second)))
				attempt++
				continue
			}
			// a transport failure is only retryable while nothing has been
			// shown; `emitted` is false here because the request never
			// produced a result to read it from
			if status == 0 && attempt < max_retries - 1 && !emitted {
				time.sleep(500 * time.millisecond)
				attempt++
				continue
			}
			return err
		}
		return once.result
	}
	return api_error(last_error, 0)
}

// ---------------------------------------------------------------------------
// Overflow healing
// ---------------------------------------------------------------------------

// heal_overflow turns a backend overflow error into a tighter Effort. The
// second return is false when the input itself no longer fits — nothing a
// clamp can fix.
fn heal_overflow(model Model, effort Effort, error_msg string, attempt int, sent_chars int) (Effort, bool) {
	if !is_context_overflow(error_msg) {
		return effort, false
	}
	if attempt >= overflow_retries {
		return effort, false
	}
	info := parse_overflow(error_msg)
	// the backend just reported the real input size — calibrate the
	// per-model estimator with it so every later clamp is accurate
	if info.input_tokens > 0 && sent_chars > 0 {
		learn_token_ratio(sent_chars, info.input_tokens, model.id)
	}
	fitted := fit_max_tokens_from_actual(model, info, effort)
	if fitted == 0 {
		return effort, false
	}
	if effort.max_tokens != 0 && fitted >= effort.max_tokens {
		return effort, false // no tightening left to do
	}
	return Effort{
		key:              effort.key
		label:            effort.label
		color:            effort.color
		max_tokens:       fitted
		temperature:      effort.temperature
		reasoning_effort: effort.reasoning_effort
		description:      effort.description
	}, true
}

// ---------------------------------------------------------------------------
// chat_stream
// ---------------------------------------------------------------------------

// chat_stream sends a streaming chat completion request, calls callbacks as
// tokens arrive, and returns the fully accumulated result.
//
// Context-overflow recovery — three escalating layers, so a long session on
// a huge project never dies with a context-length error:
//  1. pre-flight clamp with the learned per-model chars/token ratio;
//  2. on rejection, parse the backend's REAL token counts, recalibrate,
//     re-clamp max_tokens, retry (up to overflow_retries times);
//  3. if the input itself no longer fits, invoke on_overflow (the caller
//     shrinks the conversation — e.g. emergency compaction) and retry with
//     the shrunken messages.
//
// The payload invariant is re-asserted before every send: the request that
// goes out always satisfies input + max_tokens <= window.
pub fn chat_stream(provider Provider, model Model, effort Effort, mut messages []Message, tools []json2.Any, cb StreamCallbacks, timeout f64) !StreamResult {
	check_api_key(provider)!
	url := completions_url(provider)
	mut current_effort := effort
	mut shrinks_used := 0

	for overflow_attempt in 0 .. overflow_retries + overflow_shrinks + 1 {
		if cb.should_cancel() {
			return TurnCancelled{}
		}
		sent_chars := prompt_chars(messages, tools)
		payload := build_payload(model, current_effort, mut messages, tools, true) or {
			// pre-flight refusal (input already over the window). Give the
			// caller a chance to shrink the conversation and retry.
			if is_context_overflow(err.msg()) && shrinks_used < overflow_shrinks
				&& cb.on_overflow() {
				shrinks_used++
				continue
			}
			return err
		}
		result := chat_stream_with_retries(url, provider, payload, cb, timeout) or {
			if err is TurnCancelled {
				return err
			}
			// reasoning_content validation — heal history and retry once
			if is_reasoning_content_error(err.msg()) {
				if sanitize_messages(mut messages) {
					continue
				}
				// already sanitized but the provider still rejects it
				return api_error('${err.msg()} — history was sanitized but provider ' +
					'still rejects. Try /new or /rewind to clear the stale ' +
					'thinking turn.', 0)
			}
			healed, ok := heal_overflow(model, current_effort, err.msg(), overflow_attempt,
				sent_chars)
			if ok {
				current_effort = healed
				continue
			}
			// clamping cannot help — the input itself is too big. Let the
			// caller shrink the conversation, then retry.
			if is_context_overflow(err.msg()) && shrinks_used < overflow_shrinks
				&& cb.on_overflow() {
				shrinks_used++
				continue
			}
			return err
		}
		if result.has_usage {
			learn_from_usage(result.usage, sent_chars, model.id)
		}
		return result
	}
	// retries exhausted — surface the last overflow error
	return api_error('conversation is too large for ${model.label} even after ' +
		're-clamping — start a new session (/new) or rewind (/rewind)', 0)
}

// ---------------------------------------------------------------------------
// Blocking mode
// ---------------------------------------------------------------------------

// result_from_json parses a non-streamed chat.completion body into a
// StreamResult (shared by blocking mode and the stream-mode JSON fallback).
pub fn result_from_json(data map[string]json2.Any, model_id string) StreamResult {
	mut result := StreamResult{
		model: if jstr(data, 'model') != '' { jstr(data, 'model') } else { model_id }
	}
	if u := data['usage'] {
		if u is map[string]json2.Any {
			result.usage = u.clone()
			result.has_usage = true
		}
	}
	choices := jarr(data, 'choices')
	if choices.len == 0 {
		return result
	}
	choice := match choices[0] {
		map[string]json2.Any { choices[0] as map[string]json2.Any }
		else { return result }
	}
	msg := jmap(choice, 'message')
	visible, inline := split_inline_thinking(jstr(msg, 'content'))
	result.content = visible
	mut reasoning := jstr(msg, 'reasoning_content')
	if reasoning == '' {
		reasoning = jstr(msg, 'reasoning')
	}
	result.reasoning = reasoning + inline
	result.finish_reason = jstr(choice, 'finish_reason')
	for tc_any in jarr(msg, 'tool_calls') {
		tc := match tc_any {
			map[string]json2.Any { tc_any }
			else { continue }
		}
		f := jmap(tc, 'function')
		id := jstr(tc, 'id')
		result.tool_calls << ToolCall{
			id:       if id != '' { id } else { 'call_0' }
			kind:     'function'
			function: ToolCallFunction{
				name:      jstr(f, 'name')
				arguments: jstr(f, 'arguments')
			}
		}
	}
	return result
}

// post_with_cold_retries POSTs with a dedicated budget for TokenRouter
// cold-admission rejections ("cache-only admission rejected"). Returns a 200
// response or raises; non-cold errors raise immediately.
fn post_with_cold_retries(url string, provider Provider, payload map[string]json2.Any, timeout f64, cb StreamCallbacks) !http.Response {
	mut last := api_error('no attempt made', 0)
	for cold in 0 .. max_cold_retries + 1 {
		if cb.should_cancel() {
			return TurnCancelled{}
		}
		mut req := http.Request{
			url:           url
			method:        .post
			header:        auth_headers(provider, false)
			data:          json2.Any(payload).json_str()
			read_timeout:  i64(timeout * f64(time.second))
			write_timeout: i64(timeout * f64(time.second))
		}
		resp := req.do() or { return api_error('connection failed: ${err.msg()}', 0) }
		if resp.status_code == 200 {
			return resp
		}
		err_msg := extract_error_message(resp.body)
		if !is_cold_admission(err_msg) || cold >= max_cold_retries {
			return api_error(err_msg, resp.status_code)
		}
		last = api_error(err_msg, resp.status_code)
		time.sleep(i64(cold_retry_wait * f64(cold + 1) * f64(time.second)))
	}
	return last
}

// chat_blocking is the non-streaming fallback (used when a provider rejects
// stream=true).
//
// It carries the same three-layer context-overflow recovery as chat_stream:
// pre-flight clamp, re-clamp-and-retry on rejection, and (when the input
// itself is too big) caller-driven shrink-and-retry via on_overflow.
//
// It also honours cancellation. The request itself is one blocking POST, so
// the checks sit around it: before sending, between overflow retries, and
// after the response returns but before the result is handed back.
pub fn chat_blocking(provider Provider, model Model, effort Effort, mut messages []Message, tools []json2.Any, cb StreamCallbacks, timeout f64) !StreamResult {
	// before anything else, including the API-key check: a turn the user
	// already cancelled should stop, not report a configuration problem
	if cb.should_cancel() {
		return TurnCancelled{}
	}
	check_api_key(provider)!
	url := completions_url(provider)
	mut current_effort := effort
	mut shrinks_used := 0

	for overflow_attempt in 0 .. overflow_retries + overflow_shrinks + 1 {
		if cb.should_cancel() {
			return TurnCancelled{}
		}
		sent_chars := prompt_chars(messages, tools)
		payload := build_payload(model, current_effort, mut messages, tools, false) or {
			if is_context_overflow(err.msg()) && shrinks_used < overflow_shrinks
				&& cb.on_overflow() {
				shrinks_used++
				continue
			}
			return err
		}
		resp := post_with_cold_retries(url, provider, payload, timeout, cb) or {
			if err is TurnCancelled {
				return err
			}
			if is_reasoning_content_error(err.msg()) {
				if sanitize_messages(mut messages) {
					continue
				}
				return api_error('${err.msg()} — history was sanitized but provider ' +
					'still rejects. Try /new or /rewind.', 0)
			}
			healed, ok := heal_overflow(model, current_effort, err.msg(), overflow_attempt,
				sent_chars)
			if ok {
				current_effort = healed
				continue
			}
			if is_context_overflow(err.msg()) && shrinks_used < overflow_shrinks
				&& cb.on_overflow() {
				shrinks_used++
				continue
			}
			return err
		}
		if cb.should_cancel() {
			// the answer arrived, but the user asked to stop before it did:
			// honour the request rather than delivering work they cancelled
			return TurnCancelled{}
		}
		result := result_from_json(decode_obj(resp.body), model.id)
		if result.has_usage {
			learn_from_usage(result.usage, sent_chars, model.id)
		}
		return result
	}
	return api_error('conversation is too large for ${model.label} even after ' +
		're-clamping — start a new session (/new) or rewind (/rewind)', 0)
}
