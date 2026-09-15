# Terminal interface

## Brief

A professional developer terminal, not a dashboard. No banner art, no neon, no
boxes around everything, no progress spinners, no fake 3D. The **transcript is
the interface**: commands, their real output, plan state, and a closing status
line.

The renderer consumes `AgentEvent` and holds no agent state beyond what it
needs to format (whether a streamed paragraph is open, how many tools have
run). The core does not know a terminal exists.

## Anatomy

```
lean-prime  oc/muse-spark-1.3-contributor       ← header: what is running
─────────────────────────────────────────────
› fix the failing authentication tests          ← the task

  node project · 3 files · git: yes             ← project facts, dimmed

Plan                                            ← structured, live
  ● 1. Read auth.js, test.js, package.json
  ◐ 2. Run the test suite
  ○ 3. Identify the root cause

  → read_file   read auth.js                    ← tool call, cyan
  ✓ read auth.js (17 lines)          (0ms)      ← result, green
  $ npm test                                    ← command, dimmed
  ✗ npm test — exit code 1         (177ms)      ← failure, red

Verifying                                       ← verification block
  – build  this project has no build command    ← inconclusive, yellow
  ✓ tests  exit 0 in 176ms
  ✓ 2 check(s) passed: tests, diff
─────────────────────────────────────────────
completed  2 check(s) passed; 1 file(s) changed
8 tool call(s) · model oc/muse-spark-1.3-contributor
```

Streamed model text is written straight through as it arrives. Reasoning, when
a provider exposes it, is dimmed so it never competes with real output.

## Markers

| | |
|---|---|
| `→` | tool call starting |
| `✓` `✗` `–` | passed / failed / inconclusive |
| `○` `◐` `●` | plan step pending / active / done |
| `$` | a command being run |
| `↪` | user steering |
| `!` | budget warning |

## Colour

Sixteen-colour codes only, so they render correctly everywhere and in both
light and dark terminals. Colour is off when: stdout is not a TTY, `NO_COLOR`
is set, `--no-color` or `--plain` is passed, or `ui.color = false`.

## Approval prompt

The command shown is the exact string that will be executed — there is no
separate display text that could differ from what runs.

```
  ┌─ approval required ──────────────────────────────────────────
  │ tool        shell
  │ action      npm install express
  │ directory   /home/you/project
  │ permission  execute + write
  │ risk        medium
  │ why         `npm` builds or runs project code
  └──────────────────────────────────────────────────────────────
   [y] allow once   [a] allow for this session   [n] deny (default)
  >
```

Default is deny. Without a TTY the prompt is skipped and the answer is deny.

## Other modes

`--json` emits one JSON object per line — every event, redacted — for CI and
editor integrations:

```json
{"event":"tool_finished","tool":"edit_file","ok":true,"summary":"edit auth.js (-1/+1)","duration_ms":1}
```

`--plain` is the transcript without styling. `--quiet` suppresses it entirely;
errors still go to stderr.

## Not implemented

No pane splitting, file explorer sidebar, or command palette. The renderer is a
styled, event-driven transcript with an approval prompt. Adding a full-screen
layout means adding an `EventSink`, not changing the agent.
