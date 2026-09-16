module vagent

import net.http
import sync
import time as _
import x.json2

// client.v — OpenAI-compatible streaming chat client.
//
// V's http client has no blocking stream API, but `on_progress_body` fires
// per received chunk, which is exactly what SSE needs: the callback feeds an
// incremental parser, so tokens reach the UI as they arrive rather than when
// the response completes. `stop_copying_limit: 0` keeps the whole body out
// of memory, since the parser has already consumed it.

pub const retry_statuses = [408, 429, 500, 502, 503, 504]
pub const max_retries = 3

// TokenRouter's free tier admits a request only when its prompt cache is
// warm; a cold or overloaded one is rejected with "cache-only admission
// rejected". This is transient — backing off and retrying succeeds once the
// cache warms up (the CLIs that "just work" retry implicitly). Cold
// rejections get their own, longer retry budget, separate from max_retries.
pub const max_cold_retries = 4
pub const cold_retry_wait = 4.0 // seconds; multiplied by the retry number

pub fn is_cold_admission(message string) bool {
	low := message.to_lower()
	return low.contains('cache-only admission') || low.contains('cold or overloaded')
}

// ---------------------------------------------------------------------------
// Errors
// ---------------------------------------------------------------------------

pub struct APIError {
	Error
pub:
	message string
	status  int
}

pub fn (e APIError) msg() string {
	return e.message
}

fn api_error(message string, status int) IError {
	return APIError{
		message: message
		status:  status
	}
}

// TurnCancelled is raised inside the stream loop when the user cancels.
pub struct TurnCancelled {
	Error
}

pub fn (e TurnCancelled) msg() string {
	return 'turn cancelled'
}

// is_reasoning_content_error reports whether an error is the
// reasoning_content history validation.
fn is_reasoning_content_error(msg string) bool {
	low := msg.to_lower()
	return low.contains('reasoning_content') && low.contains('required')
}

// ---------------------------------------------------------------------------
// Callbacks
// ---------------------------------------------------------------------------

pub type TokenFn = fn (piece string)

pub type ToolStartFn = fn (name string)

pub type ToolArgsFn = fn (name string, chunk string)

pub type CancelFn = fn () bool

pub type OverflowFn = fn () bool

pub fn noop_token(piece string) {}

pub fn noop_tool_start(name string) {}

pub fn noop_tool_args(name string, chunk string) {}

pub fn never_cancel() bool {
	return false
}

pub fn no_overflow() bool {
	return false
}

// StreamCallbacks are plain function fields with no-op defaults rather than
// optionals: V's codegen mishandles an optional function captured by a
// closure, and every caller here builds closures over a `&` receiver.
pub struct StreamCallbacks {
pub:
	on_token      TokenFn     = noop_token
	on_reasoning  TokenFn     = noop_token
	on_tool_start ToolStartFn = noop_tool_start
	on_tool_args  ToolArgsFn  = noop_tool_args
	should_cancel CancelFn    = never_cancel
	on_overflow   OverflowFn  = no_overflow
}

// ---------------------------------------------------------------------------
// Results
// ---------------------------------------------------------------------------

pub struct ToolCallDelta {
pub mut:
	id        string
	name      string
	arguments string
}

pub struct StreamResult {
pub mut:
	content       string
	reasoning     string
	tool_calls    []ToolCall
	finish_reason string
	usage         map[string]json2.Any
	has_usage     bool
	model         string
}

// ---------------------------------------------------------------------------
// Learned tokenizer calibration
// ---------------------------------------------------------------------------
// The backend rejects a request when input + max_tokens exceeds the model's
// context window, and it counts input with ITS OWN tokenizer. A fixed
// chars/token guess always drifts from reality (code, unicode, tool schemas
// all tokenize differently), so the real ratio is learned from every
// response and a safety margin kept on top.
//
// Enterprise hardening:
//   * calibration is keyed by model id — switching models mid-session can
//     never poison the estimate (each model has its own tokenizer);
//   * calibration AND learned context windows persist to disk, so a restart
//     on a huge project starts already calibrated;
//   * the context window itself is learned: when a backend error reports a
//     smaller window than configured, it is remembered for that model.

const baseline_chars_per_token = 3.2 // conservative start (real code is denser)
const min_chars_per_token = 2.0 // never assume text is cheaper than this
const ratio_samples_max = 8 // rolling window of recent measurements

@[heap]
struct Calibration {
mut:
	mu     sync.Mutex
	ratios map[string][]f64 // model id -> measured ratios
	windows map[string]int  // model id -> real window
	loaded bool
}

__global (
	calibration &Calibration
)

fn calibration_file() string {
	return os_join(app_dir, 'calibration.json')
}

// cal_key is the calibration bucket key. Unknown/empty model ids share one
// bucket.
fn cal_key(model_id string) string {
	return if model_id == '' { '_default' } else { model_id }
}

// load_calibration restores persisted calibration once per process (best
// effort). The caller holds calibration.mu.
fn (mut c Calibration) load_locked() {
	if c.loaded {
		return
	}
	c.loaded = true
	data := decode_obj(read_text_or_empty(calibration_file()))
	if data.len == 0 {
		return
	}
	for key, samples in jmap(data, 'ratios') {
		if samples !is []json2.Any {
			continue
		}
		mut clean := []f64{}
		for s in samples as []json2.Any {
			v := match s {
				f64 { s }
				i64 { f64(s) }
				int { f64(s) }
				else { continue }
			}
			if v >= min_chars_per_token * 0.5 && v <= 16.0 {
				clean << v
			}
		}
		if clean.len > 0 {
			start := if clean.len > ratio_samples_max { clean.len - ratio_samples_max } else { 0 }
			c.ratios[key] = clean[start..].clone()
		}
	}
	for key, win in jmap(data, 'windows') {
		w := match win {
			i64 { int(win) }
			int { win }
			f64 { int(win) }
			else { continue }
		}
		if w > 0 {
			c.windows[key] = w
		}
	}
}

// save_locked persists calibration so the next process starts already tuned.
// Persistence is an optimisation, never a failure path.
fn (mut c Calibration) save_locked() {
	ensure_dirs()
	mut ratios := map[string]json2.Any{}
	for k, v in c.ratios {
		ratios[k] = v.map(json2.Any(it))
	}
	mut windows := map[string]json2.Any{}
	for k, v in c.windows {
		windows[k] = json2.Any(v)
	}
	atomic_write_text(calibration_file(), json2.Any({
		'ratios':  json2.Any(ratios)
		'windows': json2.Any(windows)
	}).json_str()) or {}
}

// chars_per_token is the current best chars/token for this model: the mean
// of its recent real measurements when there are any, else the conservative
// baseline.
pub fn chars_per_token(model_id string) f64 {
	calibration.mu.@lock()
	defer {
		calibration.mu.unlock()
	}
	calibration.load_locked()
	mut samples := calibration.ratios[cal_key(model_id)] or { []f64{} }
	if samples.len == 0 {
		samples = calibration.ratios['_default'] or { []f64{} }
	}
	if samples.len == 0 {
		return baseline_chars_per_token
	}
	mut sum := 0.0
	for s in samples {
		sum += s
	}
	return sum / f64(samples.len)
}

// learn_token_ratio records one real (chars, tokens) measurement from a
// backend response. Called after every completion whose usage reports
// prompt_tokens.
pub fn learn_token_ratio(sent_chars int, actual_tokens int, model_id string) {
	if sent_chars <= 0 || actual_tokens <= 0 {
		return
	}
	ratio := f64(sent_chars) / f64(actual_tokens)
	// ignore implausible outliers (broken usage reporting)
	if ratio < min_chars_per_token * 0.5 || ratio > 16.0 {
		return
	}
	calibration.mu.@lock()
	defer {
		calibration.mu.unlock()
	}
	calibration.load_locked()
	key := cal_key(model_id)
	mut samples := calibration.ratios[key] or { []f64{} }
	samples << ratio
	if samples.len > ratio_samples_max {
		samples = samples[samples.len - ratio_samples_max..].clone()
	}
	calibration.ratios[key] = samples
	calibration.save_locked()
}

// learn_context_window remembers the real context window a backend reported
// for a model. The configured window is only ever SHRUNK — a backend that
// reports a smaller window is authoritative for that deployment.
pub fn learn_context_window(model_id string, window int) {
	if window <= 0 || model_id == '' {
		return
	}
	calibration.mu.@lock()
	defer {
		calibration.mu.unlock()
	}
	calibration.load_locked()
	key := cal_key(model_id)
	known := calibration.windows[key] or { 0 }
	if known == 0 || window < known {
		calibration.windows[key] = window
		calibration.save_locked()
	}
}

// effective_window is the context window to plan against: the configured
// value, capped by anything the backend has actually reported.
pub fn effective_window(model Model) int {
	calibration.mu.@lock()
	defer {
		calibration.mu.unlock()
	}
	calibration.load_locked()
	learned := calibration.windows[cal_key(model.id)] or { return model.context_window }
	return if learned < model.context_window { learned } else { model.context_window }
}

// ---------------------------------------------------------------------------
// Token estimation
// ---------------------------------------------------------------------------

// estimate_tokens is a deterministic token estimate for any JSON value.
//
// Starts from a conservative ~3.2 chars/token baseline, then corrects itself
// with the REAL chars/token ratio learned from every backend response
// (usage.prompt_tokens vs the prompt actually sent). The backend's own
// tokenizer is the ground truth — once a few responses have landed, this
// estimate tracks reality instead of a fixed guess, which is what keeps long
// sessions from ever overflowing the window.
pub fn estimate_tokens(obj json2.Any, model_id string) int {
	payload := obj.json_str()
	est := int(f64(payload.len) / chars_per_token(model_id))
	return if est < 1 { 1 } else { est }
}

pub fn estimate_message_tokens(messages []Message, model_id string) int {
	return estimate_tokens(json2.Any(messages_to_json(messages)), model_id)
}

// prompt_chars is the character count of exactly what is sent as the prompt.
fn prompt_chars(messages []Message, tools []json2.Any) int {
	return json2.Any({
		'messages': json2.Any(messages_to_json(messages))
		'tools':    json2.Any(tools)
	}).json_str().len
}

// context_margin is the safety headroom between the estimated input and the
// window. It scales with input size: the bigger the prompt, the bigger the
// absolute tokenizer error can be, so the margin grows instead of staying a
// fixed constant.
pub const context_margin = 8_192
const min_completion_tokens = 1_024 // never clamp max_tokens below this

// window_max_tokens clamps the requested max_tokens so that input +
// max_tokens fits in the model's context window. Backends reject the whole
// request when the sum exceeds the window (e.g. 'maximum context length of
// 262144 tokens'). The input size is estimated with the learned per-model
// chars/token ratio plus a size-scaled margin, so the clamp stays correct
// even as the conversation grows for hours. If the input alone overflows the
// window, this raises a clear, recoverable error instead of sending a doomed
// request.
fn window_max_tokens(model Model, effort Effort, messages []Message, tools []json2.Any) !int {
	requested := effort.max_tokens
	if requested == 0 {
		return 0
	}
	window := effective_window(model)
	mut input_tokens := estimate_message_tokens(messages, model.id)
	if tools.len > 0 && model.supports_tools {
		input_tokens += estimate_tokens(json2.Any(tools), model.id)
	}
	// margin grows with the prompt: ~1 extra token of headroom per 32
	// estimated input tokens, on top of the fixed floor
	margin := context_margin + input_tokens / 32
	if input_tokens + margin + min_completion_tokens > window {
		return api_error('conversation is too large for ${model.label} ' +
			'(~${thousands(input_tokens)} input tokens vs ${thousands(window)} ' +
			'context window) — start a new session (/new), rewind (/rewind), ' +
			'or switch to a larger-context model (Ctrl+T)', 0)
	}
	headroom := window - input_tokens - margin
	fitted := if requested < headroom { requested } else { headroom }
	return if fitted > min_completion_tokens { fitted } else { min_completion_tokens }
}

// max_tokens_cap — the agent asks for 200k output tokens everywhere, but
// each backend has its own hard ceiling. Clamping at send time keeps a
// request from being rejected for an oversized max_tokens; providers without
// a known cap pass through.
const max_tokens_cap = {
	'agnes': 65_536 // sglang backend: "max_tokens exceeds the limit of 65536"
}

fn clamp_max_tokens(provider_key string, value int) int {
	cap_value := max_tokens_cap[provider_key] or { return value }
	return if value < cap_value { value } else { cap_value }
}

// thinking_off_payload — THINKING IS GLOBALLY OFF. Every reasoning-capable
// model gets its backend's strongest thinking suppression at send time:
//   - tokenrouter (Qwen3.8 open-text checkpoints): the backend REJECTS
//     enable_thinking=false ("checkpoints require thinking") and
//     reasoning_effort must be low|medium|xhigh — so the floor effort "low"
//     is forced. The thinking the model still produces is stripped
//     client-side (never streamed, never stored).
//   - every other provider: an explicit reasoning_effort "none".
fn thinking_off_payload(provider_key string) map[string]json2.Any {
	if provider_key == 'tokenrouter' {
		return {
			'reasoning_effort': json2.Any('low')
		}
	}
	return {
		'reasoning_effort': json2.Any('none')
	}
}

// build_payload assembles the request body.
pub fn build_payload(model Model, effort Effort, mut messages []Message, tools []json2.Any, stream bool) !map[string]json2.Any {
	// sanitize history before it hits the wire — fixes stale sessions that
	// were built before reasoning_content was preserved
	sanitize_messages(mut messages)
	mut payload := map[string]json2.Any{}
	payload['model'] = model.id
	payload['messages'] = messages_to_json(messages)
	payload['stream'] = stream
	payload['temperature'] = effort.temperature

	if effort.max_tokens != 0 {
		// The request must fit in the window: input + max_tokens <= window,
		// otherwise the backend rejects it wholesale.
		windowed := window_max_tokens(model, effort, messages, tools)!
		mut budget := clamp_max_tokens(model.provider, windowed)
		// HARD INVARIANT — the last mechanical gate before the wire. No
		// request may leave with estimated input + max_tokens over the
		// window. If any earlier layer drifted, clamp again here rather
		// than send a doomed request.
		window := effective_window(model)
		mut est_input := estimate_message_tokens(messages, model.id)
		if tools.len > 0 && model.supports_tools {
			est_input += estimate_tokens(json2.Any(tools), model.id)
		}
		if est_input + budget > window {
			floor := window - est_input - context_margin
			budget = if floor > min_completion_tokens { floor } else { min_completion_tokens }
		}
		payload['max_tokens'] = budget
	}
	if tools.len > 0 && model.supports_tools {
		payload['tools'] = tools
		payload['tool_choice'] = 'auto'
	}
	// Any thinking tokens a backend still produces are dropped client-side,
	// never streamed and never stored.
	if model.supports_reasoning {
		for k, v in thinking_off_payload(model.provider) {
			payload[k] = v
		}
	}
	return payload
}

// ---------------------------------------------------------------------------
// Inline <think> splitting
// ---------------------------------------------------------------------------
// Some backends ignore the suppression above and emit their thinking INLINE,
// as <think>…</think> inside `content`, instead of in the reasoning_content
// field the parser splits on. ling-3.0-flash-fin on the Kios router does
// exactly this even though it accepts reasoning_effort="none". Left alone,
// that thinking is printed to the user and written into the stored history —
// precisely what "never streamed, never stored" promises it is not. So
// inline blocks are split out here and routed to `reasoning`, the same place
// a well-behaved backend's thinking goes.

const think_open = '<think>'
const think_close = '</think>'

// InlineThinkSplitter splits inline <think>…</think> out of a *streamed*
// content channel.
//
// Streaming makes this stateful: a tag can straddle two chunks ("<thi" |
// "nk>"), so any trailing text that could still become a tag is held back
// rather than emitted and regretted. feed() returns (visible, thinking) for
// the text it can commit; flush() releases whatever was held once the stream
// ends (an unterminated block stays thinking — a model that opened <think>
// and was cut off produced no answer, and showing the partial reasoning
// would be worse than showing nothing).
@[heap]
pub struct InlineThinkSplitter {
mut:
	buf    string
	inside bool
}

// partial_tag_len is the length of the suffix of buf that is a proper prefix
// of tag.
fn partial_tag_len(buf string, tag string) int {
	mut n := if buf.len < tag.len - 1 { buf.len } else { tag.len - 1 }
	for n > 0 {
		if buf[buf.len - n..] == tag[..n] {
			return n
		}
		n--
	}
	return 0
}

pub fn (mut s InlineThinkSplitter) feed(piece string) (string, string) {
	s.buf += piece
	mut visible := []string{}
	mut thinking := []string{}
	for {
		if !s.inside {
			i := s.buf.index(think_open) or { break }
			visible << s.buf[..i]
			s.buf = s.buf[i + think_open.len..]
			s.inside = true
		} else {
			i := s.buf.index(think_close) or { break }
			thinking << s.buf[..i]
			s.buf = s.buf[i + think_close.len..]
			s.inside = false
		}
	}
	// hold back only what could still grow into the tag being hunted
	tag := if s.inside { think_close } else { think_open }
	hold := partial_tag_len(s.buf, tag)
	mut ready := s.buf
	if hold > 0 {
		ready = s.buf[..s.buf.len - hold]
		s.buf = s.buf[s.buf.len - hold..]
	} else {
		s.buf = ''
	}
	if s.inside {
		thinking << ready
	} else {
		visible << ready
	}
	return visible.join(''), thinking.join('')
}

pub fn (mut s InlineThinkSplitter) flush() (string, string) {
	rest := s.buf
	s.buf = ''
	return if s.inside { '', rest } else { rest, '' }
}

// split_inline_thinking is the whole-string form of the splitter, for
// non-streamed bodies.
pub fn split_inline_thinking(text string) (string, string) {
	mut s := InlineThinkSplitter{}
	v1, t1 := s.feed(text)
	v2, t2 := s.flush()
	return v1 + v2, t1 + t2
}

// ---------------------------------------------------------------------------
// Error body parsing
// ---------------------------------------------------------------------------

fn extract_error_message(body string) string {
	head := if body.len > 500 { body[..500] } else { body }
	parsed := json2.decode[json2.Any](body) or { return head }
	obj := match parsed {
		// valid JSON but not an object (array/string/number) — no shape to dig
		map[string]json2.Any { parsed }
		else { return head }
	}
	err := obj['error'] or { return head }
	return match err {
		map[string]json2.Any {
			m := jstr(err, 'message')
			if m != '' { m } else { json2.Any(err).json_str() }
		}
		string {
			err
		}
		else {
			head
		}
	}
}

// ---------------------------------------------------------------------------
// Context-overflow detection + self-healing
// ---------------------------------------------------------------------------
// Backends reject a request outright when input + max_tokens exceeds the
// context window, and the error message carries the REAL token counts (e.g.
// "maximum context length of 262144 tokens ... 67440 tokens from the input
// messages and 195680 tokens for the completion"). Those numbers are parsed,
// the true chars/token ratio learned from them, max_tokens re-clamped to the
// actual headroom, and the request retried — so a long session heals itself
// instead of dying with the error.

const overflow_markers = ['context length', 'context_length', 'context window',
	'too many tokens', 'maximum context', 'reduce the number of tokens']

// is_context_overflow reports whether an API error message is a
// context-window overflow.
pub fn is_context_overflow(message string) bool {
	low := message.to_lower()
	for m in overflow_markers {
		if low.contains(m) {
			return true
		}
	}
	return false
}

// OverflowInfo holds the real token counts a backend reported.
pub struct OverflowInfo {
pub mut:
	window            int
	input_tokens      int
	completion_tokens int
	total             int
	present           bool
}

fn num_from(low string, pattern string) int {
	re := compile_regex(pattern) or { return 0 }
	m := re.search(low) or { return 0 }
	return group_text(low, &m, 1).replace(',', '').int()
}

fn first_num(low string, patterns []string) int {
	for p in patterns {
		n := num_from(low, p)
		if n > 0 {
			return n
		}
	}
	return 0
}

// parse_overflow extracts real token counts from a backend overflow error.
pub fn parse_overflow(message string) OverflowInfo {
	mut info := OverflowInfo{}
	if !is_context_overflow(message) {
		return info
	}
	low := message.to_lower()
	info.window = first_num(low, [r'maximum context length (?:of|is)\s+([\d,]+)\s+tokens',
		r'context (?:length|window) (?:of|is)\s+([\d,]+)\s+tokens'])
	info.input_tokens = first_num(low, [r'([\d,]+)\s+tokens?\s+from the input',
		r'([\d,]+)\s+tokens?\s+(?:in|from)\s+(?:the\s+)?(?:input|prompt|messages)',
		r'(?:input|prompt|messages)\s+(?:resulted in|is|are)\s+([\d,]+)\s+tokens'])
	info.completion_tokens = num_from(low, r'([\d,]+)\s+tokens?\s+for (?:the )?completion')
	info.total = first_num(low, [r'a total of\s+([\d,]+)\s+tokens',
		r'requested (?:a total of )?([\d,]+)\s+tokens'])
	info.present = info.window > 0 || info.input_tokens > 0 || info.completion_tokens > 0
		|| info.total > 0
	return info
}

// fit_max_tokens_from_actual returns a max_tokens that provably fits,
// computed from the backend's OWN counts. A zero return means the input
// alone overflows — the caller must shrink the conversation, not the
// completion budget.
fn fit_max_tokens_from_actual(model Model, info OverflowInfo, effort Effort) int {
	if info.window > 0 {
		learn_context_window(model.id, info.window)
	}
	window := effective_window(model)
	mut actual_input := info.input_tokens
	if actual_input == 0 && info.total > 0 && info.completion_tokens > 0 {
		actual_input = info.total - info.completion_tokens
	}
	if actual_input <= 0 {
		return 0
	}
	mut margin := window / 64
	if margin < 4_096 {
		margin = 4_096
	}
	headroom := window - actual_input - margin
	if headroom < min_completion_tokens {
		return 0
	}
	requested := if effort.max_tokens != 0 { effort.max_tokens } else { headroom }
	return if requested < headroom { requested } else { headroom }
}

// learn_from_usage calibrates the chars/token estimator with the backend's
// real count.
fn learn_from_usage(usage map[string]json2.Any, sent_chars int, model_id string) {
	prompt_tokens := jint(usage, 'prompt_tokens')
	if prompt_tokens > 0 && sent_chars > 0 {
		learn_token_ratio(sent_chars, prompt_tokens, model_id)
	}
}

// shrink_tool_outputs is the in-place overflow shrinker for any message
// list. Used as the on_overflow path by sub-agents (scouts, workers) whose
// own tool loop can bloat their context — the same protection the main agent
// gets. Three escalating passes, all pairing-safe:
//  1. truncate the OLDEST tool results to short summaries (keeping the
//     newest `keep` verbatim),
//  2. if nothing was stale, truncate the newest tool results too,
//  3. if still nothing shrank, drop the oldest complete turn unit (user
//     message + its assistant reply + tool results) so tool_call /
//     tool-response pairing is never broken.
//
// Returns true if anything actually shrank.
pub fn shrink_tool_outputs(mut messages []Message, keep int, max_chars int) bool {
	mut tool_idx := []int{}
	for i, m in messages {
		if m.role == 'tool' {
			tool_idx << i
		}
	}
	mut stale := tool_idx.clone()
	if keep > 0 && tool_idx.len > keep {
		stale = tool_idx[..tool_idx.len - keep].clone()
	} else if keep > 0 {
		stale = []int{}
	}

	if truncate_at(mut messages, stale, max_chars) {
		return true
	}
	// even the newest results, if desperate
	if truncate_at(mut messages, tool_idx, max_chars) {
		return true
	}

	// drop the oldest complete turn unit (never a lone message)
	start := if messages.len > 0 && messages[0].role == 'system' { 1 } else { 0 }
	mut end := -1
	for j := start + 1; j < messages.len; j++ {
		if messages[j].role == 'user' {
			end = j
			break
		}
	}
	if end > start {
		messages.delete_many(start, end - start)
		return true
	}
	return false
}

fn truncate_at(mut messages []Message, indices []int, max_chars int) bool {
	mut shrank := false
	for i in indices {
		content := messages[i].text()
		if content.len > max_chars {
			messages[i].content = content[..max_chars] +
				'\n[… truncated — ${thousands(content.len)} chars originally]'
			shrank = true
		}
	}
	return shrank
}

// ---------------------------------------------------------------------------
// Provider preconditions
// ---------------------------------------------------------------------------

// check_api_key fails fast with actionable guidance instead of an opaque
// 401.
//
// Two preconditions, both checked here because both are the same class of
// mistake — a provider that is listed but not configured — and both
// otherwise surface as errors that name nothing the user can act on: a bare
// 401 for the key, and an invalid-URL error for the endpoint.
pub fn check_api_key(provider Provider) ! {
	if provider.api_key == '' {
		env_name := match provider.key {
			'zen' { 'OPENCODE_API_KEY' }
			'tokenrouter' { 'TOKENROUTER_API_KEY' }
			'agnes' { 'AGNES_API_KEY' }
			else { '${provider.key.to_upper()}_API_KEY' }
		}
		return api_error('no API key configured for ${provider.name}. Set the ' +
			'${env_name} environment variable (export ${env_name}=sk-...) and restart.',
			401)
	}
	url := provider.base_url.trim_space()
	if !url.starts_with('http://') && !url.starts_with('https://') {
		env_name := '${provider.key.to_upper()}_BASE_URL'
		shown := if provider.base_url != '' { "'${provider.base_url}'" } else { 'empty' }
		return api_error('no endpoint configured for ${provider.name} (base_url is ' +
			'${shown}). Set the ${env_name} environment variable to the ' +
			"provider's OpenAI-compatible URL (export " +
			'${env_name}="https://<host>/v1") and restart.', 0)
	}
}

fn completions_url(provider Provider) string {
	return provider.base_url.trim_right('/') + '/chat/completions'
}

fn auth_headers(provider Provider, accept_sse bool) http.Header {
	mut h := http.new_header()
	h.add_custom('Authorization', 'Bearer ${provider.api_key}') or {}
	h.add_custom('Content-Type', 'application/json') or {}
	if accept_sse {
		h.add_custom('Accept', 'text/event-stream') or {}
	}
	return h
}
