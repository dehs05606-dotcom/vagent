# Architecture

## The shape of the thing

```
                       ┌──────────────────────┐
                       │   cmd/vagent.v       │  parse, dispatch, exit code
                       └──────────┬───────────┘
                                  ▼
                       ┌──────────────────────┐
                       │      src/app         │  wiring, REPL, slash commands
                       └──────────┬───────────┘
                                  ▼
                       ┌──────────────────────┐
                       │     src/agent        │  observe → plan → act →
                       │   the agent loop     │  verify → reflect
                       └──────────┬───────────┘
            ┌─────────────────────┼─────────────────────┐
            ▼                     ▼                     ▼
     ┌─────────────┐      ┌──────────────┐      ┌──────────────┐
     │ src/tools   │      │ src/context  │      │ src/memory   │
     │ registry +  │      │ discovery +  │      │ session +    │
     │ execution   │      │ compaction   │      │ project      │
     └──────┬──────┘      └──────────────┘      └──────────────┘
            │
            ▼
     ┌─────────────┐
     │ src/security│  levels, policy, danger heuristics, prompt
     └─────────────┘
                                  ▼
                       ┌──────────────────────┐
                       │     src/model        │  gateway → provider → SSE
                       └──────────┬───────────┘
             ┌────────────────────┼────────────────────┐
             ▼                    ▼                    ▼
       OpenAI dialect      Anthropic dialect      anything you add
```

Dependencies point downward only. `src/model` does not know tools exist;
`src/tools` does not know a model exists; `src/security` knows about neither.
The agent is what joins them, and `src/app` is the only module that has seen
all of them.

## The loop

`Agent.run_turn` is the whole thing:

1. Rebuild the system prompt for the current mode, project snapshot and tool
   set. It is rebuilt per turn rather than cached, because all three can change
   mid-session.
2. Append the user message.
3. Repeat until the model answers without asking for a tool:
   * compact the conversation if it is over budget;
   * one model turn, streamed into the renderer;
   * record the assistant message, tool calls included;
   * execute every tool call through the registry, appending one tool message
     per call — a missing tool result is a protocol error on the next request;
   * feed failures back with enough context for the model to change approach.
4. If the iteration budget runs out, make one final tool-free request so the
   turn still ends with a usable summary instead of silence.

Two properties fall out of this and are worth stating:

**Every tool call produces a message.** Success, failure, permission denial,
malformed arguments — all of them become a `tool` message. The loop never
silently drops a call, because a dangling `tool_call_id` breaks the next
request on every provider.

**Verification is the model's job, enforced by the prompt.** The loop does not
try to guess how to test your project. It gives the model the shell tool, tells
it the likely build commands it discovered, and instructs it never to claim
success without having run something. What the loop *does* enforce is that the
model sees the real output.

## Failure handling

Three distinct mechanisms, because they fail differently:

* **A tool fails.** The error text goes back to the model. Normal.
* **The same call fails repeatedly.** `State.note_failure` fingerprints each
  failing call; after `max_tool_retries + 1` identical failures the tool
  message carries an explicit instruction to stop retrying and change approach.
* **The provider fails.** The error is shown with a hint derived from the HTTP
  status (401 → check the key, 413 → use `/compact`, 429 → rate limited) and
  the session continues, so the user can switch model or retry.

## Context management

`context.Manager` estimates tokens by character count — deliberately not a real
tokenizer, because budgeting only needs to be roughly right and a per-model BPE
table would be a lot of weight for that.

When the conversation exceeds `context_limit - reserve`, compaction runs in two
escalating passes:

1. Truncate the *middle* of old tool outputs. Errors live at the tail of a build
   log and the command echo lives at the head, so dropping the middle preserves
   more signal than dropping the tail.
2. If still over: drop the oldest exchanges, keeping the system prompt and the
   original request as anchors, and leave a synthetic note saying history was
   elided. Tool results whose originating call was dropped are removed too —
   an orphaned tool message is a protocol error.

## Streaming

V's `net.http` exposes an `on_progress_body` callback that delivers dechunked
body bytes as they arrive. `Request.user_ptr` carries a pointer to an
`Accumulator`, which is how a plain C-style callback reaches caller state.

The accumulator is dialect-agnostic: it does SSE framing (partial lines held
across chunk boundaries, `:` comments, `[DONE]`), and a per-dialect `EventFn`
interprets each decoded payload. That is why OpenAI's anonymous deltas and
Anthropic's named events share one parser and one set of tests.

Two details that matter in practice:

* Tool-call arguments arrive as fragments across many frames and are
  concatenated by index. A stream cut off before the function name arrives
  yields a nameless call, which is dropped rather than dispatched.
* Some gateways ignore `stream: true` and answer with one whole JSON body. The
  streaming path detects that and falls back to parsing a normal completion,
  instead of returning an empty turn.

## Permissions

`security.Engine.evaluate` is pure policy and never blocks:

```
session "deny all"? ──────────────────────────────► deny
explicit deny rule matches? ──────────────────────► deny
flagged destructive? ───► allow-mode + allow rule ► allow
                     └──► interactive ► ask │ headless ► deny
READ and auto_approve_read? ──────────────────────► allow
allow rule or session grant matches? ─────────────► allow
mode: allow ► allow │ deny ► deny │ ask ► ask/deny
```

`authorize` wraps it with the prompt and records "always" grants for the
session. The prompt itself lives in `tui`, injected as a function, so the
security module contains no terminal code and stays testable.

## Why line-based UI, not a full-screen TUI

A repainted alternate screen loses scrollback, breaks copy-paste, fights tmux,
and produces unreadable CI logs. A line-based transcript survives all of those.
The status bar is printed on demand (`/status`) rather than pinned, for the
same reason.

## Extension points

* **A new tool**: a struct with `spec()` and `execute()`, registered once. See
  `examples/custom_tool.v`.
* **A new provider dialect**: implement `model.Provider`, then
  `Gateway.set_provider`. The agent loop is unchanged — that is also how the
  tests run the loop without a network.
* **Project policy**: `AGENTS.md`, `CONVENTIONS.md` or `.vagent/rules/*.md` are
  read at startup and injected as `<project_rules>`, which the system prompt
  says take precedence over its own defaults.
