# Memory and sessions

Three layers, deliberately separate.

## Short term — the conversation

Lives in `AgentState.messages` for the duration of a run. When it outgrows
`context_budget`, `trimHistory` elides the **middle**:

- the system prompt is always kept;
- the original task turn is always kept;
- the most recent turns are always kept;
- what is dropped is replaced by `[N earlier turn(s) elided …]`.

Recent tool output is never the part that gets cut, because that is exactly
what the agent is currently reasoning about.

Token counts are estimated at roughly four bytes per token. No tokenizer is
bundled; the budget only has to be conservative, not exact.

## Session — one run, persisted

Written to `~/.local/state/lean-prime/sessions/<id>.json` when the run ends.

```bash
lean-prime --sessions          # list
lean-prime --resume <id>       # continue
```

A record holds the task, workspace, model, final phase, summary, touched files
and the conversation as role/text pairs. Tool-call *structure* is not replayed:
a resumed session continues from the transcript, not from the middle of a tool
call, which would be a lie about what happened.

Session files are written through `redact` and created `0600`. A session file
must never become a place where a credential comes to rest.

Saving is best-effort: a failure is logged, never fatal.

## Project — durable facts about a repository

`~/.local/state/lean-prime/projects/<key>.json`, keyed by workspace path so two
checkouts of the same project keep separate memory. Holds the build and test
commands and free-form notes.

The intent is that a project's quirks — "tests need `--no-sandbox`", "the build
is `make -C build`" — survive across runs rather than being rediscovered every
time.

## What is deliberately *not* stored

- Credentials, in any layer.
- Raw tool output. Sessions keep what the model saw, already clamped.
- Anything under the model's control that could act as a persistent
  instruction. Project memory is written by the agent's own code paths, not by
  the model writing arbitrary text into its own future system prompt.
