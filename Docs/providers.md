# Providers

## The abstraction

```lean
structure ModelProvider where
  name         : String
  model        : String
  capabilities : ProviderCapabilities
  chat         : ModelRequest → IO (LPResult ModelResponse)
  stream       : ModelRequest → (StreamEvent → IO Unit) → IO (LPResult ModelResponse)
```

The agent core depends on this record and nothing else. `ModelProvider.run`
picks streaming when both the config and the provider support it.

## OpenAI-compatible

The one implemented backend. `POST {base_url}/chat/completions` with
`model`, `messages`, `tools`, `tool_choice`, `max_tokens`, `temperature`,
`stream`.

Configure it:

```toml
[provider]
kind        = "openai-compatible"
base_url    = "https://your-endpoint/v1"
model       = "your-model"
api_key_env = "LEANPRIME_API_KEY"
```

### Streaming

SSE `data:` lines are parsed incrementally. Tool calls arrive as *indexed
fragments* — an `id` and `name` in one chunk, argument text spread over many —
so `StreamState` accumulates by index and `finalize` assembles the complete
calls. Keep-alives and unparseable lines are ignored rather than fatal.

If the server ignores `stream` and returns a whole document, that is detected
(no `data:` payload was ever seen) and the body is parsed as a normal response.
Getting this distinction wrong is subtle: a *successful* stream in which the
model emitted nothing looks identical to a non-streaming reply unless you track
whether any SSE payload arrived at all.

### Reasoning models

Some models spend a large share of their completion budget on reasoning the
router does not forward. The symptom is `finish_reason: "length"` with empty
`content`. The default `max_tokens` is 200000 so the reasoning budget is not
what runs out; if you still see it, raising `max_tokens` is the fix, not
lowering temperature. Note that a provider caps this at whatever the model
actually supports — asking for more than the model allows is an error from
the provider, not a silent clamp. `reasoning_content` is surfaced as
`StreamEvent.reasoningDelta` and shown dimmed when the provider sends it.

### Retry and pacing

| Condition | Treatment |
|---|---|
| HTTP 5xx, 408 | retry, 600ms → 8s |
| HTTP 429, "rate limit", "too many requests" | retry, **15s → 60s** |
| `system_cpu_overloaded` and similar error bodies | retry as transient |
| 4xx other than 429 | fail immediately |

Rate limits are usually per *minute*, so a sub-second retry is guaranteed to
fail again and merely spends an attempt. `min_interval_ms` (default 6500) paces
requests client-side so a per-minute cap is not tripped in the first place.

Note that some routers answer an error with HTTP 200 and an error body; both
paths are checked.

### Credentials

The key is read from the environment at call time, passed as a `secretHeader`,
and written by the transport into a `0600` curl config file — never into
`argv`. See `Docs/security.md`.

## Adding a provider

1. Add a constructor to `ProviderKind` (`anthropic` and `gemini` are already
   named).
2. Write `YourProvider.make : ProviderConfig → String → HttpClient → Logger →
   IO ModelProvider`, translating `ModelRequest`/`ModelResponse` to the wire
   format.
3. Dispatch on the kind in `App/Bootstrap.lean`.

`ContentPart` already carries `imageUrl` and `imageBase64` cases and the
OpenAI serialiser emits them, so a vision-capable provider does not need the
message types changed — only a tool that produces an image part.

## Model routing

Not implemented. `ProviderCapabilities` exists so the agent can adapt to what a
backend supports, and the abstraction is the place routing would go, but there
is one provider per run today.
