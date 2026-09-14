# Providers

V-AGENT is not tied to a vendor. A provider is "some base URL that speaks a
known dialect, plus a model name".

## Configuration

```json
{
  "provider": {
    "name": "custom",
    "kind": "openai",
    "base_url": "https://router.kiosapi.com/v1",
    "api_key_env": "VAGENT_API_KEY",
    "model": "oc/muse-spark-1.3-contributor",
    "context_limit": 128000,
    "streaming": true,
    "temperature": 0.0,
    "max_tokens": 8192,
    "timeout_secs": 300,
    "headers": { "X-Custom": "value" },
    "input_price": 0.0,
    "output_price": 0.0
  }
}
```

| Field | Meaning |
|---|---|
| `kind` | wire dialect: `openai` or `anthropic` |
| `base_url` | must include the version segment, e.g. `.../v1` |
| `api_key_env` | environment variable to read the key from |
| `api_key` | literal key — works, but prefer the environment |
| `context_limit` | drives budgeting and compaction, not the request |
| `streaming` | false makes every request blocking |
| `input_price`/`output_price` | per 1M tokens, for the cost readout only |

The key is resolved from `$api_key_env`, then `$OPENAI_API_KEY`, then the
config file, then whatever was compiled into the binary — so a key never has to
be written to disk, and `/status` always prints it redacted and names where it
came from.

## Compiling credentials into the binary

`make bundled` passes the endpoint and key to the compiler as V defines:

```sh
VAGENT_API_KEY=sk-... VAGENT_BASE_URL=https://.../v1 VAGENT_MODEL=m make bundled
```

which is shorthand for:

```sh
v -prod -d vagent_api_key='sk-...' \
        -d vagent_base_url='https://.../v1' \
        -d vagent_model='m' \
        -o bin/vagent cmd/vagent.v
```

`src/config/baked.v` reads them with `$d()`, so nothing is ever written into
the source tree. The built-in values sit one layer above the defaults and below
everything else, which keeps a bundled binary overridable:

```
defaults → built-in → global file → project file → --config → env → flags
```

`--version` reports what a bundled build carries, minus the key:

```
vagent 0.1.0 (bundled: some-model @ https://router.example.com/v1, key included)
```

A compiled-in string is recoverable with `strings`. This buys convenience, not
secrecy — a bundled binary is the credential.

## Known-good endpoints

Anything that implements `POST {base_url}/chat/completions` with `tools`,
`tool_choice` and `stream` works: OpenAI, Azure OpenAI, OpenRouter, Together,
Groq, Fireworks, DeepSeek, vLLM, llama.cpp's server, LM Studio, Ollama's
OpenAI-compatible endpoint, and hosted routers such as the one in the example
config.

For Anthropic set `"kind": "anthropic"` and
`"base_url": "https://api.anthropic.com/v1"`. V-AGENT then sends `x-api-key`
and `anthropic-version`, hoists system turns into the top-level `system` field,
and converts tool results into `tool_result` content blocks.

## Requirements on the endpoint

Tool calling is not optional — the agent loop is built on it. A model without
tool support can still be used in `/chat` mode, but it cannot act.

Streaming is optional. If the endpoint ignores `stream: true` and returns one
whole JSON body, V-AGENT detects that and parses it as a normal completion
rather than reporting an empty turn. To turn streaming off explicitly, pass
`--no-stream` or set `"streaming": false`.

## Switching at runtime

```
/model                      show the current model
/model gpt-oss-20b          switch, same endpoint, same conversation
```

`Gateway.switch_model` rebuilds the provider behind the same gateway, so
nothing above that layer holds a stale reference.

## Adding a dialect

Implement the interface:

```v
pub interface Provider {
	name() string
	model_id() string
	context_limit() int
	chat(req Request, mut sink Sink) !Response
}
```

`Request` and `Response` are provider-neutral; translating to and from the wire
format is the whole job. For a streaming dialect, reuse `Accumulator`: it
already handles SSE framing, and you supply an `EventFn` that interprets one
decoded payload. `openai_event` and `anthropic_event` are each about 40 lines
and are the models to copy.

Register it with `Gateway.set_provider`, or add a branch to `Gateway.rebuild`
for a new `kind`.

Both dialects are tested against recorded wire captures in
`tests/model_test.v`, including chunk boundaries landing mid-line — worth
copying for a new dialect, since that is where SSE parsers actually break.

## Diagnosing failures

HTTP errors are translated into actionable messages:

| Status | What V-AGENT tells you |
|---|---|
| 400 | check the model name and the tool schema |
| 401/403 | the key was rejected — check `$VAGENT_API_KEY` and the base URL |
| 404 | check `base_url` (it should include `/v1`) and the model name |
| 413 | the request is too large — use `/compact` |
| 429 | rate limited — wait, or `/model` to something else |

`--debug` logs every request URL, message count and tool count to stderr and to
`~/.vagent/logs/vagent.log`.
