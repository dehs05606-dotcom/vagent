# V-AGENT

A native terminal AI coding agent, written in [V](https://vlang.io).

V-AGENT reads your project, plans, edits files, runs commands, checks its own
work, and corrects itself when a test fails — inside the terminal, against any
OpenAI- or Anthropic-compatible endpoint you point it at.

```
❯ There is a bug in hello.py: add() returns the wrong value. Fix it and verify.

assistant
Fixing your add() bug — reading the file first.
  ◉ read_file hello.py
  ✓ hello.py (5 lines)
  ◉ edit_file hello.py
  ✓ hello.py:1 (1 edit)
  ◉ shell python3 hello.py
  ✓ python3 hello.py -> ok (0.0s)

Fixed `hello.py:2` from `return a - b` to `return a + b`.
Verified with `python3 hello.py` — output `5`, as expected for `add(2, 3)`.
```

## Why

The point is not "prompt → model → answer". The point is the loop:

```
observe → plan → act → verify → reflect → (replan on failure)
```

Every tool result re-enters the model's context as an observation, every change
is checked by actually running something, and the model never gets to *claim*
success without evidence.

## Status

Phases 1–3 of the roadmap are implemented and working end to end:

| Area | State |
|---|---|
| CLI, layered configuration, logging | done |
| Model gateway (OpenAI + Anthropic dialects) | done |
| Real token streaming over SSE | done |
| Agent loop with tool calling, retries, budgets | done |
| Tool engine: filesystem, search, shell, git, plan | done |
| Permission engine with interactive approval | done |
| Project context discovery + context compaction | done |
| Session and project memory | done |
| Terminal UI: streaming, tool panels, plan, status | done |
| MCP gateway | not yet — `/mcp` says so rather than pretending |
| Multi-agent supervisor | not yet |

## Install

V-AGENT needs the V compiler (0.5.2 or newer):

```sh
git clone https://github.com/vlang/v && cd v && make
export PATH="$PWD:$PATH"
```

Then:

```sh
cd vterminal
make build          # -> bin/vagent
make test           # 7 test files, no network required
```

## Configure

The API key is read from the environment, never required in a file:

```sh
export VAGENT_API_KEY=sk-...
export VAGENT_BASE_URL=https://router.kiosapi.com/v1
export VAGENT_MODEL=oc/muse-spark-1.3-contributor
```

Or write a config file and keep the key in the environment:

```sh
bin/vagent --init          # writes ./.vagent/config.json
```

Configuration is layered, later layers winning:

```
defaults → ~/.vagent/config.json → ./.vagent/config.json → --config → env → flags
```

`/status` shows which layers actually contributed, and prints the key redacted.

## Use

```sh
bin/vagent                                  # interactive session
bin/vagent "fix the failing auth test"      # one task, then exit
bin/vagent --read-only "review my changes"  # cannot modify anything
bin/vagent --yes "run the test suite"       # approve every tool call
bin/vagent --tools                          # list tools, no API key needed
```

Inside a session:

```
/help /status /model /tools /context /memory /clear /compact /quit
/agent /chat /plan /execute /review /debug /search
```

Modes change the contract, not the tool set: `/plan` investigates read-only and
produces a plan, `/review` reads the diff and reports findings, `/debug`
reproduces before hypothesising, `/chat` sends no tools at all.

## Safety

Every tool declares a permission level — `READ`, `WRITE`, `EXECUTE`, `NETWORK`,
`ADMIN` — and the permission engine decides per call:

* reads are auto-approved (configurable)
* writes and shell commands prompt: `[y] once  [a] always  [n] deny  [q] deny all`
* destructive commands (`rm -rf /`, `sudo`, `git push --force`, …) always
  prompt, even in `--yes` mode
* explicit `deny` rules beat everything, including `--yes`
* file paths are confined to the project root; `../../etc/passwd` is refused

In a pipeline there is nobody to prompt, so policy alone decides — which means
an unattended run does nothing dangerous unless you passed `--yes`.

## Documentation

* [docs/architecture.md](docs/architecture.md) — how the pieces fit, and why
* [docs/tools.md](docs/tools.md) — the tool contract and every built-in tool
* [docs/providers.md](docs/providers.md) — adding an endpoint or a dialect
* [docs/mcp.md](docs/mcp.md) — the MCP gateway design and what remains

## Layout

```
vterminal/
├── cmd/vagent.v        entry point
├── src/
│   ├── app/            wiring, REPL, slash commands
│   ├── agent/          the loop, state, system prompt
│   ├── model/          provider-neutral types, OpenAI, Anthropic, SSE, gateway
│   ├── tools/          tool contract, registry, fs/search/shell/git/plan
│   ├── context/        project discovery, token budget, compaction
│   ├── memory/         session persistence, project notes
│   ├── security/       permission levels, policy, danger heuristics
│   ├── config/         schema, defaults, layered loader
│   ├── tui/            style, renderer, input, modes
│   └── utils/          errors, logging, JSON helpers, text, platform
├── tests/              unit + integration tests (no network)
├── examples/           config.json, custom_tool.v
└── docs/
```

## License

MIT.
