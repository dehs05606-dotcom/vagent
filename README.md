# LEAN PRIME

An autonomous terminal coding agent written in Lean 4.

`lean-prime` inspects a repository, plans, calls typed tools, reads the real
output, and **verifies its own work before reporting anything as done**. It is
not a chat wrapper around a shell: the model proposes typed tool calls, a pure
permission engine rules on each one, and an executor obeys that ruling without
consulting the model's reasoning.

**Your system prompt is the highest authority in the run** — supplied from a
flag, config, the environment, or a `LEANPRIME.md` in the repository, and kept
in force through the whole run by pinning and periodic re-assertion. See
[The system prompt](Docs/system-prompt.md).

Several of its safety properties are not tested but **proved**, in Lean, with no
`sorry` and no `native_decide` — see [Verification](#verification).

```
lean-prime  oc/muse-spark-1.3-contributor
─────────────────────────────────────────────────────────────
› Run the test suite, find why the failing test fails, fix the root cause.

  node project · 3 files · git: yes

Plan
  ◐ 1. Read auth.js, test.js, package.json
  ○ 2. Run the test suite to capture the failure
  ○ 3. Identify the root cause
  ○ 4. Fix it with a minimal edit
  ○ 5. Re-run the tests
  ○ 6. Review the diff

  → read_file   read auth.js
  ✓ read auth.js (17 lines)                                   (0ms)
  → run_tests   run the test suite
  $ npm test
  ✗ npm test — exit code 1 in 177ms                         (177ms)
  → edit_file   edit auth.js
  ✗ old_string not found in auth.js; re-read the file          (0ms)
  → edit_file   edit auth.js
  ✓ edit auth.js (-1/+1)                                       (1ms)
  → run_tests   run the test suite
  ✓ npm test — exit code 0 in 176ms                          (176ms)

Verifying
  – build  this project has no build command
  ✓ tests  exit 0 in 176ms
  ✓ diff   auth.js | 2 +- , 1 file changed
  ✓ 2 check(s) passed: tests, diff

─────────────────────────────────────────────────────────────
completed  2 check(s) passed: tests, diff; 1 file(s) changed
8 tool call(s) · model oc/muse-spark-1.3-contributor
```

That transcript is from a real run, including the failed edit the agent
recovered from on its own.

## Quick start

Three commands, from nothing to a working agent:

```bash
curl https://elan.lean-lang.org/elan-init.sh -sSf | sh   # if you don't have Lean
export LEANPRIME_API_KEY='your-key-here'
./run.sh "fix the failing authentication tests"
```

`run.sh` is the single entry point — the equivalent of `python main.py` here.
It finds the toolchain, brings the build up to date, and runs. The first build
takes a few minutes; after that the check costs about a second and prints
nothing, so day-to-day it just starts.

```bash
./run.sh "explain this repository's architecture"   # run a task
./run.sh --doctor                                   # check the setup
./run.sh --list-models                              # see the models
./run.sh --show-prompt                              # see every rule in force
./run.sh test                                       # run the test suite
./run.sh build                                      # build without running
```

Lean is compiled rather than interpreted, so a build step has to exist
somewhere; `run.sh` makes it invisible rather than pretending it is absent.
Nothing depends on the wrapper — `lake build && .lake/build/bin/lean-prime …`
does exactly the same thing, and the sections below use that longer form
where it makes the underlying command clearer.

## Install

Requires [elan](https://github.com/leanprover/elan) (the Lean toolchain
manager) and `curl`. `git` is strongly recommended.

```bash
curl https://elan.lean-lang.org/elan-init.sh -sSf | sh   # if you don't have Lean
git clone <this repository> && cd vagent
./run.sh build
```

The toolchain is pinned in `lean-toolchain` (Lean 4.34.0); `lake` installs it
automatically on first build.

On Windows, run it from WSL or Git Bash — the script is bash, and the agent
shells out to POSIX tools.

## Configure

`lean-prime` needs one thing: an API key in the environment.

```bash
export LEANPRIME_API_KEY='…'        # OPENAI_API_KEY also works
./run.sh --doctor                   # checks everything and tells you what is missing
```

To avoid re-exporting it every shell, put the line in `~/.bashrc` or
`~/.zshrc` — or in a file only you can read (`chmod 600`) and `source` that.

Never put the key in a config file or a repository. `--doctor` reports that a
key is *present* and how long it is; it never prints the value, and the logger
redacts anything that looks like a credential before it can reach a log, a
session file or the transcript.

Everything else is optional. Settings resolve in this order, later winning:

```
built-in defaults → ~/.config/lean-prime/config.toml → environment → command line flags
```

A full example lives in [`Examples/config.toml`](Examples/config.toml).

```toml
[provider]
kind            = "openai-compatible"
base_url        = "https://router.kiosapi.com/v1"
model           = "oc/muse-spark-1.3-contributor"
api_key_env     = "LEANPRIME_API_KEY"   # the NAME of the variable, never the key
max_tokens      = 200000
min_interval_ms = 6500                  # pace requests under a per-minute cap

[agent]
approval_mode   = "auto"                # auto | ask | read-only | yolo
max_iterations  = 40
context_budget  = 1000000               # trim history once it exceeds this
```

## Use

```bash
./run.sh "fix the failing authentication tests"
./run.sh "explain this repository's architecture" --approval read-only
./run.sh "implement JWT validation in the auth module"
./run.sh --json "run the tests and report the result"     # one JSON event per line
./run.sh --doctor
./run.sh --sessions
./run.sh --resume <session>
./run.sh --list-models
```

Run `./run.sh --help` for every flag.

Put the task in quotes. Without them the shell splits it into separate
arguments and only the first becomes the task.

If you would rather have `lean-prime` on your PATH than type `./run.sh`:

```bash
./run.sh build
sudo ln -s "$PWD/.lake/build/bin/lean-prime" /usr/local/bin/lean-prime
lean-prime "fix the failing authentication tests"
```

The symlinked binary does not rebuild itself, so re-run `./run.sh build`
after changing the source.

### Models

`--list-models` prints what the configured router offers. Each has a short
alias, so `--model muse-1.2` is enough — the full id, a unique prefix, or an
id not in the list all work too, since the catalog is a convenience rather
than a whitelist.

| alias | id | |
|---|---|---|
| `muse-1.3` | `oc/muse-spark-1.3-contributor` | default |
| `muse-1.2` | `oc/muse-spark-1.2-contributor` | |
| `atria-dawn` | `atria-asi/atria-dawn-preview` | preview |
| `deepseek-v4` | `deepseek-v4-flash-vision-exp-free` | vision, free, preview |
| `ling-3.0` | `ling-3.0-flash-fin` | |

Context and output limits differ per model and are not recorded here, because
this project has no authoritative source for them and a wrong figure would
read as a guarantee. If a run fails with a length or limit error, lower
`max_tokens`.

### Your system prompt

```bash
lean-prime --system-prompt ./my-rules.md "refactor the parser"
lean-prime --system-prompt-text "Always write tests first." "add validation"
lean-prime --prompt-mode replace --system-prompt ./rules.md "…"   # yours only
lean-prime --show-prompt          # what instructions are actually in force?
```

Or drop a `LEANPRIME.md` (or `AGENTS.md`, or `CLAUDE.md`) in the repository and
every run there picks it up.

Instructions do not just get *loaded* — they get *kept*. Rules are parsed out
of your prompt into a checklist, pinned so context trimming can never evict
them, re-asserted every few model calls, and accounted for individually before
the run may report success. That last part matters more than it sounds: an
agent "ignoring" a system prompt on iteration fifteen is almost always an
agent whose instruction is thousands of tokens behind a wall of tool output.

Full detail in [`Docs/system-prompt.md`](Docs/system-prompt.md).

### Approval modes

| Mode | Behaviour |
|---|---|
| `auto` (default) | Safe, reversible work runs unattended. Anything high-risk stops and asks. |
| `ask` | Every mutating action asks first. |
| `read-only` | Inspection only. Mutating tools are *not even advertised to the model*. |
| `yolo` | No prompting. The deny list is still enforced — there is no mode that disables it. |

Without a TTY (CI, `--json`, a pipe) anything that would prompt is **denied**,
never auto-approved.

## How it works

```
USER
 ↓
CLI  →  CONFIG  →  CONTEXT ENGINE  →  SYSTEM PROMPT
 ↓
AGENT LOOP ──────────────────────────────────────────┐
 ↓                                                   │
MODEL GATEWAY (streaming, retry, throttle)           │
 ↓                                                   │
TOOL CALL (typed, validated against a schema)        │
 ↓                                                   │
PERMISSION ENGINE  (pure · total · proved)           │
 ↓            ↘ deny → refusal returned to the model │
EXECUTOR  →  AUDIT LOG                               │
 ↓                                                   │
OBSERVATION → STATE MACHINE                          │
 ↓                                                   │
VERIFIER (build · tests · diff)                      │
 ↓                                                   │
passed → report      failed → diagnose → replan ─────┘
```

The core emits **typed events** and renders nothing. The terminal transcript,
`--json` mode and the test harness are all just event sinks, which is why the
same core drives all three.

The system prompt itself is assembled from ordered layers — yours above
LeanPrime's — rather than hardcoded; `--show-prompt` prints the result.

See [`Docs/architecture.md`](Docs/architecture.md) for the full picture,
[`Docs/agent-loop.md`](Docs/agent-loop.md) for the loop and its state machine,
and [`Docs/system-prompt.md`](Docs/system-prompt.md) for prompt authority.

## Tools

| Tool | Permission | Notes |
|---|---|---|
| `read_file` | read | line-numbered, range-selectable, size-capped |
| `write_file` | write | reports a diff of what changed |
| `edit_file` | write | exact unique anchor; refuses ambiguous or missing text |
| `delete_file` | write (high) | refuses directories |
| `list_directory`, `search_files`, `search_text` | read | implemented in Lean, not shelled out |
| `shell` | derived from the command | classified per call; chaining escalates risk |
| `run_build`, `run_tests` | execute | command detected from the project layout |
| `git_status/diff/log/show/add/commit` | git | fixed argument vectors, never a shell string |

Every tool result that carries outside data is labelled with the file or
command that produced it, so the model can cite its evidence, and clamped to a
byte and line budget, so no command can flood the model's context.

## Security

The threat model and the defences are in [`Docs/security.md`](Docs/security.md).
In short:

- **The model cannot grant itself permission.** `Policy.decide` is a pure total
  function of the request; the executor calls it and obeys. The model's
  reasoning is never an input.
- **Permission is not a matter of persuasion.** Your prompt governs behaviour;
  it does not govern what may run. A model convinced by anything it read still
  cannot execute what the policy refuses.
- **Instructions found in a repository are followed by default.** File contents
  and command output arrive labelled with their source, and nothing tells the
  model to disregard them. Set `[security] data_fencing = true` to mark
  external material as data rather than instruction when working in a codebase
  you did not write.
- **Paths cannot escape the workspace** — proved, not tested.
- **Credentials never reach argv.** The API key is written into a `0600` curl
  config file inside a `0700` temporary directory, so it is not visible in
  `ps` or `/proc`.
- **Every decision and execution is audited** to `~/.local/state/lean-prime/audit.jsonl`.

## Verification

Safety properties that hold for *every* input, not just tested ones:

| Property | Theorem |
|---|---|
| A denied command never runs, in any mode — including `yolo` | `denied_command_never_allowed` |
| A read-only session cannot mutate | `readOnly_denies_mutation` |
| `ask` mode never silently mutates | `ask_mode_never_silently_mutates` |
| `auto` never approves high risk | `auto_never_allows_high` |
| Shell chaining is never classified low risk | `chaining_is_not_low` |
| A normalised path contains no `..` | `normalizeSegments_noParent` |
| A finished run never resumes | `terminal_is_absorbing` |
| Completion is reachable only via `finish` | `completed_only_via_finish` |
| A failed verification never completes | `verificationFailed_never_completes` |
| Cancellation is always accepted | `cancel_always_accepted` |
| An exhausted budget always terminates | `budget_always_fails` |
| Claiming success requires a passing verification | `success_requires_passed_verification` |
| Any failing check fails the whole verification | `failing_check_fails_verification` |

`LeanPrime/Verification/AxiomAudit.lean` pins each theorem's axiom set at build
time, so slipping in a `sorry` — or swapping a proof for `native_decide` —
**breaks the build** instead of quietly weakening a claim this README makes.

## Tests

```bash
./run.sh test      # or: lake test
```

399 assertions, no network required: string and TOML handling, path
containment, command classification, permission decisions, the diff, plan
parsing, the state machine, prompt layering, directive extraction, pinned
context trimming, provider wire format, the prompt vault's five digests, the
ledger's hash chain, the sentinel's escalation ladder, the action trace, the
behavioural predicate engine, the directive compiler, the interlock, the model
catalog and the banner's layout at both wide and narrow widths — plus
adversarial tests that drive the **real executor** against path traversal,
deny-listed commands, shell chaining, read-only violations, malformed model
output, ambiguous edits and both data-framing modes.

## Development

```bash
./run.sh build        # build everything, proofs included
./run.sh test         # run the suite
./run.sh --doctor     # check your environment
```

`run.sh` only ever calls `lake`, so the underlying commands (`lake build`,
`lake test`, `lake exe lean-prime …`) remain available and behave identically.

The project has **no external Lean dependencies**. JSON comes from Lean's own
`Lean.Data.Json`; the TOML subset parser, the diff, the search walker and the
test harness are all in-tree, because each sits on a boundary worth being able
to audit. `curl` is the one external binary, isolated behind the `HttpClient`
interface.

`autoImplicit` is off across the project.

## Limitations

Stated plainly, because the point of this agent is not overclaiming:

- **MCP is designed for but not implemented.** The tool registry, permission
  engine and audit trail already treat tools uniformly, so MCP tools would
  enter through the same gate — but no MCP client ships today.
- **Multi-agent roles are not implemented.** The event bus and typed state make
  room for supervisor/coder/reviewer roles; the current agent is single-role.
- **Only OpenAI-compatible providers work.** `ProviderKind` names Anthropic and
  Gemini; only `openai-compatible` has a backend.
- **Vision is representable but not wired.** `ContentPart` carries image cases
  and the serialiser emits them; no tool produces one yet.
- **The TUI is a transcript, not a full-screen layout.** There is no pane
  splitting, explorer sidebar or command palette — the renderer is a styled,
  event-driven transcript with an approval prompt.
- **Steering is single-shot.** A task is given up front; there is no
  interrupt-and-redirect while the agent is mid-run.
- **Directive extraction is lexical.** It classifies rules by phrasing
  ("never", "always", bullet points), not by understanding them. A rule
  written as an unmarked paragraph will be carried in the prompt but not
  lifted into the checklist — write rules as bullets or with a modal verb.
- **Concurrency is used where it pays** (repository scan overlapped with git
  queries, both child pipes drained on separate tasks) and nowhere else.
- **Token counts are estimated**, not tokenized, so the context budget is
  conservative rather than exact.
- `run_tests`/`run_build` detect Lean, Rust, Go, Node, Python and Make layouts;
  anything else needs an explicit `command`.

## Licence

MIT. See [LICENSE](LICENSE).
