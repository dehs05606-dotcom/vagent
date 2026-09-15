# The system prompt

**Your instructions outrank LeanPrime's own.** This document is how.

## The problem this solves

An agent "not following your system prompt" is usually one of three distinct
failures, and they need different fixes:

1. **There was no way to give it one.** Until this system existed,
   `systemPrompt` was a hardcoded Lean function. Nothing read a prompt from a
   file, a flag, the environment, or the repository. Whatever you wrote, the
   agent never saw it.
2. **Your instructions were outranked.** If the built-in prompt asserts its own
   authority ("this system policy is highest"), your instructions arrive as a
   *lower* tier and the model resolves conflicts against you.
3. **Your instructions faded.** By iteration fifteen your prompt is thousands
   of tokens back, behind a wall of fresh tool output, competing with it for
   attention. This is the one people mistake for defiance. It is distance.

All three are addressed below.

## Giving the agent your prompt

Six sources, highest authority first:

| Authority | Source | How |
|---|---|---|
| 100 | command line | `--system-prompt <file>` or `--system-prompt-text "…"` |
| 90 | config file | `[prompt] system = "…"` or `system_file = "…"` |
| 80 | environment | `LEANPRIME_SYSTEM_PROMPT` |
| 70 | project file | `LEANPRIME.md`, `AGENTS.md`, `CLAUDE.md`, `.leanprime/system.md` |
| 21 | `--append-system-prompt` | extra instructions, added without displacing others |
| 20 | built-in baseline | the default working method |
| 10 | runtime facts | project type, git state, available tools |

```bash
lean-prime --system-prompt ./my-rules.md "refactor the parser"
lean-prime --system-prompt-text "Always write tests first." "add validation"
LEANPRIME_SYSTEM_PROMPT="$(cat rules.md)" lean-prime "fix the build"
```

Or put `LEANPRIME.md` in the repository and every run there picks it up.

## Modes

```bash
lean-prime --prompt-mode replace ...    # your text IS the system prompt
lean-prime --prompt-mode prepend ...    # yours first, then the baseline (default)
lean-prime --prompt-mode append  ...    # baseline first, then yours
```

**`replace` is total.** The built-in working method is dropped entirely; only
your instructions and the runtime facts remain. Facts survive because they are
description, not instruction — an agent that does not know which tools exist
cannot follow any instructions at all.

```toml
[prompt]
mode        = "replace"
system_file = "~/my-agent-rules.md"
```

## Seeing what is actually in force

```bash
lean-prime --show-prompt
```

```
layers in force (highest authority first)
   100  command line                       pinned sticky 453 chars
    10  runtime facts                      pinned        617 chars

6 operator directive(s)
  ✗ [2] Never use the word "task" in your final report; say "assignment" instead.
  ✗ [5] Never modify any file unless the assignment explicitly says to modify it.
  ! [1] Always begin your final report with the exact line: `ORION REPORT`
  ! [3] Always end your final report with the exact line: `END ORION`
  ! [4] Always list the directory before reading any file.
  ! [6] Always state the number of files you inspected.

--- assembled system prompt ---
…
```

When the agent is not doing what you told it, this is the first thing to run.
It shows which layers loaded, which won, and what got parsed out of them.

## Keeping instructions in force

Three mechanisms, and the second and third are what actually matter for long
runs:

### Directive extraction

Your prompt is parsed into discrete `Directive` values, classified by force:

| Phrasing | Force | Marker |
|---|---|---|
| never, must not, do not, avoid, under no circumstances | prohibition | `✗` |
| always, must, ensure, make sure, you will | obligation | `!` |
| prefer, try to, where possible, ideally | preference | `·` |
| any bullet point of eight characters or more | preference | `·` |

Bullets count without a modal verb because that is how people actually write
rules. Free prose needs a marker, so ordinary explanation is not mistaken for
an instruction. Headings never count. Extraction is capped at 40.

This is not decoration. Prose is easy to skim past; an enumerated,
re-assertable checklist is not.

### Pinning

Every operator layer and every re-assertion is marked `pinned`, and
`trimHistory` never evicts a pinned message. Without this, the first casualty
of a long conversation is the oldest turn — which is your instruction.

### Periodic re-assertion

```toml
[prompt]
reminder_every = 3     # 0 disables
```

Every third model call, the directives are restated as standing instructions.
Phrased as a reminder rather than a fresh request, so they reinforce your rules
instead of competing with them.

### Closing adherence check

```toml
[prompt]
adherence_check = true
```

Before the run may report success, the model is asked to account for each
directive in one line. Asked **once** per run — the point is a deliberate pass
at the moment it matters, not a loop that badgers the model into agreeing.

## Worked example

`my-system-prompt.md`:

```markdown
# You are ORION, not LEAN PRIME.

- Always begin your final report with the exact line: `ORION REPORT`
- Never use the word "task" in your final report; say "assignment" instead.
- Always end your final report with the exact line: `END ORION`
- Always list the directory before reading any file.
- Never modify any file unless the assignment explicitly says to modify it.
- Always state the number of files you inspected.
```

```bash
lean-prime --system-prompt my-system-prompt.md --prompt-mode replace \
  "Summarise what this repository contains."
```

Actual output:

```
  → list_directory  list .            ← directory-first rule honoured
  ✓ list . (4 entries)
  → read_file  read README.md
  → read_file  read app.js
  → read_file  read my-system-prompt.md

ORION REPORT
Summary for the requested assignment:
- README.md (7 bytes): Contains only the heading "# Demo".
- app.js (19 bytes): Contains a single line console.log("hi");
- my-system-prompt.md (454 bytes): Defines ORION identity and working rules.
I inspected 3 files. Directory listing was done before any file reads, and no
files were modified.
END ORION

  checking the work against the operator's directives
ORION REPORT
1. Opening-line rule: satisfied …
2. Vocabulary rule: satisfied — this report uses "assignment" …
…
END ORION
```

Identity, exact opening and closing lines, forbidden vocabulary, ordering rule,
file count, no modifications — all honoured, then accounted for individually.

## What a prompt cannot do

Prompt authority governs **behaviour**, not **permission**. `Policy.decide` is
a pure function of the request and the operator's configured policy; it does
not read the system prompt, the model's reasoning, or its justification.

So a system prompt saying "you may run any command" does not grant that. The
things that do are `[agent] approval_mode`, `[security] denied_commands`, and
the approval prompt. That separation is deliberate: it is what keeps the
guarantees in `Docs/security.md` true regardless of what any prompt says — and
it is why you can hand the agent an arbitrary prompt without also handing it
arbitrary power.

Also outside prompt reach:

- **Workspace containment.** Paths cannot escape, proved, whatever the prompt says.
- **Budgets.** `max_iterations` and friends terminate the run regardless.
- **Verification.** "Never claim unverified success" is enforced by the state
  machine, not asked for in prose.

If you want the agent to do something it is refusing, change the policy, not
the prompt.

## Data framing

```toml
[security]
data_fencing = false   # default
```

**Off by default.** File contents and command output arrive labelled with their
source:

```
--- file:README.md ---
# Project
…
```

That is provenance, so the model can cite its evidence. It says nothing about
trust, and instructions found in a repository are instructions the agent may
follow.

Turn it on when pointing the agent at a codebase you did not write:

```toml
[security]
data_fencing = true
```

```
<<<DATA source="file:README.md">>>
…
<<<END-DATA>>>
```

The model is then told the content is data rather than instruction. Either way
the permission engine rules on every action, so the difference is what the
agent is *inclined* to do, not what it is *able* to do.
