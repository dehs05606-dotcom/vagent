# Architecture

## Layering

Each layer depends only on the ones above it. `App/Bootstrap.lean` is the only
module that knows about all of them; it is where the wiring lives.

```
Util/        Prelude, Errors, Paths, Platform, Logging, Diff
Config/      Toml, Schema, Defaults, Loader
Security/    Permissions, Approval, Audit
Model/       Messages, Provider, Http, OpenAI
Tools/       Tool, Process, Filesystem, Search, Shell, Git, Registry
Context/     Manager
Memory/      Session
Agent/       State, Events, Prompt, Planner, Executor, Verifier, Loop
TUI/         Ansi, Renderer
App/         Cli, Doctor, Bootstrap, Main
Verification/ PathProofs, SecurityProofs, StateProofs, AxiomAudit
```

## The core renders nothing

`Agent/Loop.lean` never writes to a terminal. It emits `AgentEvent` values into
an `EventSink`. Three sinks exist:

| Sink | Used by |
|---|---|
| `mkRenderer` | the terminal transcript |
| `mkJsonSink` | `--json`, for CI and editor integrations |
| `EventSink.collecting` | the test suite |

`EventSink.tee` composes them. Adding a daemon or an HTTP surface means adding a
sink, not touching the agent.

## Data flow of one iteration

```
                    ┌──────────────────────────────┐
                    │ AgentState (typed, immutable)│
                    └──────────────┬───────────────┘
                                   │ transition (total, Option-returning)
   trimHistory ──► ModelRequest ──►│
                                   ▼
                           ModelProvider.run
                          (stream | chat, retry, throttle)
                                   │
                    ┌──────────────┴──────────────┐
                    │                             │
             tool calls present             no tool calls
                    │                             │
                    ▼                             ▼
             Tool.requirement              work done yet?
                    │                        no → nudge
            Policy.decide (pure)             yes → verify
                    │
        allow ──────┼────── ask ────── deny
          │         │         │          │
          ▼         ▼         ▼          ▼
        Tool.run  prompt   prompt      refusal returned
          │       (TTY)   (no TTY →      to the model
          ▼                 deny)         as a result
      ToolResult
          │
          ▼
    Message.toolResult  ──► back into AgentState
```

A refusal is a *tool result*, not an exception. The agent sees `REFUSED: …` and
can take another route or explain to the user why it needs the action. Killing
the run on every refusal would make `ask` mode useless.

## Why these abstractions exist

**`HttpClient`** — Lean has no HTTP client or TLS stack. The choice was an FFI
binding to libcurl (a native surface to audit and build per platform) or
driving the `curl` executable. The executable won, behind an interface, so the
model layer never names a transport and a future in-process client is a drop-in.

**`ModelProvider`** — a record of functions rather than a type class, so
providers can be built at runtime from config and swapped per request without
type-level dispatch.

**`Tool.requirement : Config → Json → Requirement`** — a tool declares what a
*specific call* needs before it runs. That is why `shell` can be low risk for
`ls` and forbidden for `sudo`, while the permission engine stays pure.

**`EventSink`** — see above.

## Concurrency

Used where it pays, not as decoration:

- `scanProject` runs the git queries on an `IO.asTask` while walking the file
  tree on the main task; neither depends on the other.
- `runProcess` drains the child's stdout and stderr on separate tasks while the
  main task polls `tryWait`. Without this a child that fills a pipe buffer
  deadlocks before it can exit — and a hung test command would freeze the agent.
- `Std.CloseableChannel` is available for the event bus; the current sinks are
  synchronous because ordering in a transcript matters more than throughput.

## Dependencies

None, beyond Lean's own standard library. JSON is `Lean.Data.Json`. The TOML
subset parser, the line diff, the search walker and the test harness are all
in-tree, each because it sits on a boundary worth being able to read in full.
`curl` and `git` are external *binaries*, both detected by `--doctor`.
