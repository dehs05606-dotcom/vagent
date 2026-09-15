# Tools

## The interface

```lean
structure Tool where
  name        : String
  description : String
  parameters  : Json                          -- JSON Schema
  required    : List String
  requirement : Config → Json → Requirement   -- pure: what THIS call needs
  run         : ToolContext → Json → IO (LPResult ToolResult)
```

`requirement` is pure and is evaluated **before** `run`, which is what lets the
permission engine rule on a call without executing anything, and what lets
`shell` be low risk for `ls` and forbidden for `sudo` while the engine itself
stays a pure function.

## Lifecycle of a call

```
model emits tool_call
  → registry lookup            unknown name → rejected, with the real list
  → JSON.parse arguments       malformed    → rejected
  → Tool.validate              missing required key → rejected
  → Tool.requirement           pure
  → Policy.decide              allow | ask | deny
  → (ask) prompt, or deny when non-interactive
  → Tool.run
  → audit + events
  → ToolResult back to the model
```

Nothing is executed before the decision, and a rejection at any stage returns a
result the model can read rather than aborting the run.

## Built-in tools

### Files

| Tool | Risk | Notes |
|---|---|---|
| `read_file` | low | line-numbered; `start_line`/`max_lines`; refuses binaries and files over `max_file_bytes` |
| `write_file` | medium | creates parents; returns a diff of what changed |
| `edit_file` | medium | exact anchor, must be unique unless `replace_all` |
| `delete_file` | high | refuses directories |
| `list_directory` | low | marks ignored directories rather than hiding them |

`edit_file` is the important one. It fails — without touching the file — when
`old_string` is absent or ambiguous:

```
old_string appears 3 times in src/auth.ts; include more surrounding
context to make it unique, or set replace_all
```

This is what stops a model that only half-understood a file from destroying it,
and in practice the agent recovers by re-reading and retrying with exact
whitespace.

### Search

`search_files` (path substring) and `search_text` (content, with file and line
numbers) are implemented in Lean rather than shelling out to grep or ripgrep.
That keeps behaviour identical across platforms, lets the walker honour the
same ignore rules the context engine uses, and means search needs no `execute`
permission — it is a pure read.

### Execution

| Tool | Risk | Notes |
|---|---|---|
| `shell` | per command | classified individually; see `Docs/security.md` |
| `run_build` | medium | command detected from project layout |
| `run_tests` | medium | command detected; `filter` for a subset |

Detection covers Lean (`lake`), Rust, Go, Node, Python and Make. Anything else
needs an explicit `command`.

`runProcess` enforces a real timeout: both child pipes are drained on separate
tasks while the main task polls `tryWait`, and the child is killed at the
deadline. `IO.Process.output` blocks forever, which would let one hung test
command freeze the agent.

A build that fails with "missing script" or "command not found" is reported
`inconclusive`, not `failed` — a project with no build step is not a broken
build, and treating it as one sends the agent into a repair loop over nothing.

### Git

`git_status`, `git_diff`, `git_log`, `git_show`, `git_add`, `git_commit`.

All run `git` with a **fixed argument vector**, never a shell string, so a
model-supplied ref or path cannot inject a second command. There is
deliberately no "run arbitrary git" tool. `git_commit` is high risk and asks.

## Adding a tool

```lean
def myTool : Tool where
  name := "my_tool"
  description := "What it does, and when the model should reach for it."
  parameters := schemaObject [("path", schemaProp "string" "Workspace-relative")] ["path"]
  required := ["path"]
  requirement := fun _ args =>
    { permissions := [.readFs], risk := .low
      summary := s!"inspect {(argStr? args "path").getD "?"}" }
  run := fun ctx args => do
    match ctx.workspace.resolve ((argStr? args "path").getD "") with
    | .error e => return .error e
    | .ok path => return .ok (ToolResult.success s!"…")
```

Then add it to `Registry.builtin`. Three rules:

1. **Resolve every path through `ctx.workspace.resolve`.** That is the proved
   containment boundary.
2. **Wrap outside data in `untrustedBlock`** and clamp it with
   `clampOutput ctx.config.limits.…`.
3. **Declare the requirement honestly.** The engine trusts it.
