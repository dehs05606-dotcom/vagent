# The agent loop

## Phases

`AgentPhase` is an inductive type, not a string. Transitions go through one
total function:

```lean
def AgentPhase.step : AgentPhase → AgentSignal → Option AgentPhase
```

`none` means "this signal is not legal here". The loop treats that as an
internal error and fails, rather than drifting into an undefined state — which
is what makes the invariants meaningful: an illegal transition has no
representation as a successful result.

```
idle ──start──► understanding ──► inspecting ──► contextBuilding
                                                      │
                                                   planning
                                                      │
                            ┌────────────► awaitingModel ◄──────────┐
                            │                 │      │              │
                            │        toolRequested   modelReplied   │
                            │                 │      │              │
                            │             executing  │              │
                            │                 │      │              │
                            │          toolFinished  │              │
                            │                 ▼      ▼              │
                            └──────────── observing ────────────────┘
                                              │
                                        verifyRequested
                                              ▼
                                          verifying
                                    ┌─────────┴─────────┐
                              passed│                   │failed
                                    ▼                   ▼
                                observing           diagnosing
                                    │                   │
                                 finish           repairPlanned
                                    ▼                   ▼
                                completed          replanning ──► awaitingModel

  from any non-terminal phase:
     cancelRequested ──► cancelling ──► cancelled
     fatalError / budgetExhausted ──► failed
```

`completed`, `failed` and `cancelled` accept **no** signal at all.

## One iteration

1. **Budget check.** Iterations, tool calls, repair rounds and wall clock.
   A breach emits `budgetExhausted`, which always terminates.
2. **Steering.** Any user input received mid-run is folded in as a high-priority
   user turn.
3. **History trim.** The system prompt and the original task are always kept;
   the *middle* of the conversation is elided, never the most recent tool
   output, because that is what the agent is currently reasoning about.
4. **Model call.** Streaming when the provider supports it, with retry and
   client-side pacing.
5. **Branch:**
   - *tool calls present* → execute each through the permission engine, append
     results, iterate.
   - *no tool calls, nothing done yet* → the model is talking about the work
     rather than doing it. Nudge it to act. After three such turns, fail.
   - *no tool calls, work done* → verify.
6. **Verify.** Build, tests, diff.
   - `passed` → `finish` → `completed`.
   - `failed` → `diagnosing`; feed the *real* output back and retry, up to
     `max_repair_rounds`.
   - `inconclusive` → accept, and say so in the summary. Never dressed up as
     success.

## Never claiming unverified success

Two facts combine:

- `completed_only_via_finish` — the only route into `completed` is the `finish`
  signal.
- The loop emits `finish` only when `AgentState.mayReportSuccess` holds, which
  `success_requires_passed_verification` shows means the last verification
  exists and passed.

`VerificationResult.ofChecks` encodes the rest: no checks at all is
`inconclusive`, and any failing check fails the whole result regardless of what
else passed.

## Budgets

| Setting | Default | Guards against |
|---|---|---|
| `max_iterations` | 40 | an endless model conversation |
| `max_tool_calls` | 120 | a tool-call storm |
| `max_repair_rounds` | 5 | thrashing on a failure it cannot fix |
| `wall_clock_sec` | 1800 | a run that never ends |
| `context_budget` | 96000 | context overflow |

## Plans

The model writes a numbered plan, `Agent/Planner.lean` parses it into `Plan`,
and the transcript shows live step state. Parsing requires at least two
consecutively numbered items so an incidental "1." in a sentence is not
mistaken for a plan; an unparseable reply simply yields no plan.

The plan is a **progress display**, not a program counter. Control flow is the
state machine.
