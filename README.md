# LEAN PRIME

An autonomous terminal coding agent written in Lean 4.

`lean-prime` inspects a repository, plans, calls typed tools, reads the real
output, and **verifies its own work before reporting anything as done**. It is
not a chat wrapper around a shell: the model proposes typed tool calls, a pure
permission engine rules on each one, and an executor obeys that ruling without
consulting the model's reasoning.

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

## Install

Requires [elan](https://github.com/leanprover/elan) (the Lean toolchain
manager) and `curl`. `git` is strongly recommended.

```bash
curl https://elan.lean-lang.org/elan-init.sh -sSf | sh   # if you don't have Lean
git clone <this repository> && cd lean-prime
lake build
```

The toolchain is pinned in `lean-toolchain` (Lean 4.34.0); `lake` installs it
automatically on first build.

## Configure

`lean-prime` needs one thing: an API key in the environment.

```bash
export LEANPRIME_API_KEY='…'        # OPENAI_API_KEY also works
lake exe lean-prime --doctor        # checks everything and tells you what is missing
```

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
max_tokens      = 8192
min_interval_ms = 6500                  # pace requests under a per-minute cap

[agent]
approval_mode   = "auto"                # auto | ask | read-only | yolo
max_iterations  = 40
```

## Use

```bash
lean-prime "fix the failing authentication tests"
lean-prime "explain this repository's architecture" --approval read-only
lean-prime "implement JWT validation in the auth module"
lean-prime --json "run the tests and report the result"     # one JSON event per line
lean-prime --doctor
lean-prime --sessions
lean-prime --resume <session>
```

Run `lean-prime --help` for every flag.

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

See [`Docs/architecture.md`](Docs/architecture.md) for the full picture and
[`Docs/agent-loop.md`](Docs/agent-loop.md) for the loop and its state machine.

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

Every tool result that carries outside data is wrapped in an explicit
`<<<UNTRUSTED-DATA>>>` fence and clamped to a byte and line budget, so no
command can flood the model's context.

## Security

The threat model and the defences are in [`Docs/security.md`](Docs/security.md).
In short:

- **The model cannot grant itself permission.** `Policy.decide` is a pure total
  function of the request; the executor calls it and obeys. The model's
  reasoning is never an input.
- **Prompt injection is treated as expected, not exceptional.** Repository
  contents and command output arrive fenced as data, below the user's request
  in an explicit authority order — and even a model that is fully convinced by
  an injected instruction still cannot execute anything the policy refuses.
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
lake test          # or: lake exe lean-prime-tests
```

109 assertions, no network required: string and TOML handling, path
containment, command classification, permission decisions, the diff, plan
parsing, the state machine, provider wire format — plus adversarial tests that
drive the **real executor** against path traversal, deny-listed commands,
shell chaining, read-only violations, malformed model output and ambiguous
edits.

## Development

```bash
lake build                      # build everything, proofs included
lake test                       # run the suite
lake exe lean-prime --doctor    # check your environment
```

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
- **Concurrency is used where it pays** (repository scan overlapped with git
  queries, both child pipes drained on separate tasks) and nowhere else.
- **Token counts are estimated**, not tokenized, so the context budget is
  conservative rather than exact.
- `run_tests`/`run_build` detect Lean, Rust, Go, Node, Python and Make layouts;
  anything else needs an explicit `command`.

## Licence

MIT. See [LICENSE](LICENSE).
