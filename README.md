# vagent

FullAgent — an advanced terminal AI agent — rewritten in V.

This is a port, not a reimplementation: the Python original's behaviour is
the specification, and where the two differ it is because V forced a choice
or because the original had a bug. Every such decision is written down at
the point in the source where it was made.

    v -enable-globals -o vagent-bin cmd/vagent     # build
    v -enable-globals test vagent                  # 97 test files
    python3 test/tui/tui_check.py                  # 28 pty checks
    python3 test/tui/tui_check2.py

`-enable-globals` is not optional: the module keeps a small amount of
process-wide state (the prompt registry, the tokenizer calibration, the
armed covenant) that V will not compile without it.

## What is where

The kernel is the whole architecture. Every user message, tool call, tool
result, assistant reply and cost is an immutable event in an append-only,
content-addressed log; conversation state, spend, goal distance, dead ends
and verdicts are projections FOLDED from that log. Nothing here holds
authoritative state of its own — which is why the log can be rewound,
forked, replayed, merged and audited, and why `vagent verify-log` means
something.

| Python | V | |
|---|---|---|
| `config.py` | `config.v` | providers, models, effort levels, paths |
| `systemprompt.py` | `systemprompt.v` | the one home of every system prompt |
| `mastermind.py` | `mastermind.v` | sealed vault, gate, composer, lineage |
| `tools.py` | `tools.v`, `shell.v`, `glob.v`, `web.v` | the tool registry |
| `client.py` | `client.v`, `client_stream.v` | streaming chat client |
| `agent.py` | `agent*.v` (9 files) | the agent loop |
| `kernel.py` | `kernel.v` | the event log |
| `goal.py`, `judge.py` | `goal.v`, `judge.v` | contracts and their proofs |
| `crew.py`, `team.py` | `crew.v`, `team.v`, `roster.v` | subagents |
| `tui.py` | `term_*.v`, `ui_*.v`, `slash*.v` | the terminal UI |
| `__main__.py` | `cmd/vagent/main.v`, `cli.v` | entry point, headless commands |

Every other Python module has a V file of the same name.

`tui.py` is the one file that did not survive as a file. It was 4,000 lines
that mixed four jobs: deciding what a key means, editing a draft, running a
command, and drawing. Here those are separate and each is testable on its
own — `ui_keys.v` is a pure function from (key, state) to action,
`slash.v` RETURNS what a command should show rather than printing it, and
`ui.v` is only the loop that joins them.

## The Python harnesses

Seven analyses — coverage, taint, the knowledge graph, mutation testing, the
skill and synthesis gates, and synthesized tool calls — embed the ORIGINAL
Python as a string constant, write it to a temp script and run it through
the system interpreter.

That is deliberate. Each of them needs CPython's own `ast` or
`sys.settrace`; a second parser that disagreed with CPython about what a
Python file means would be worse than no analysis at all, because the
disagreement would be silent and the gates are safety gates.

`harness.v` exists because that embedding failed once, quietly: a `\b` in a
borrowed regex — a word boundary — became a backspace byte inside a V string
literal, and the forbidden-name gate stopped matching anything while still
reporting that it ran. The harnesses are now checked as a set for control
characters and for still parsing as Python, by a test rather than by the
next person to wonder why a gate never fires.

## Configuration

State lives in `$FULLAGENT_HOME`, or `~/.fullagent`, or a per-user directory
under the system temp dir — whichever is actually writable, probed in that
order. Provider API keys come from the environment; the compiled-in defaults
are the original's and should be replaced with your own.
