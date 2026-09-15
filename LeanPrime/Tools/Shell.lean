/-
  LeanPrime.Tools.Shell

  The shell tool, plus the build and test tools.

  The model never receives a general "execute this" capability: it proposes a
  command line, the classifier in `LeanPrime.Security.Permissions` derives a
  requirement from it, and the executor obeys the policy's decision.  This
  module only runs what it was handed after that ruling.
-/
import LeanPrime.Tools.Tool
import LeanPrime.Tools.Process

open Lean

namespace LeanPrime.Tools

open LeanPrime

/-- Format a process result for the model, clamped to the output limits. -/
private def renderProc (ctx : ToolContext) (label : String) (r : ProcResult) : ToolResult :=
  let status :=
    if r.timedOut then s!"TIMED OUT after {r.durationMs}ms"
    else s!"exit code {r.exitCode} in {r.durationMs}ms"
  let combined :=
    (if r.stdout.isEmpty then "" else s!"--- stdout ---\n{r.stdout}") ++
    (if r.stderr.isEmpty then "" else s!"\n--- stderr ---\n{r.stderr}")
  let clamped := clampOutput (trim combined) ctx.config.limits.maxBytes
    ctx.config.limits.headLines ctx.config.limits.tailLines
  { ok := r.exitCode == 0 && !r.timedOut
    content := frameData ctx.config.dataFencing s!"command:{label}" s!"{status}\n{clamped}"
    display := s!"{label} — {status}"
    metadata := Json.mkObj
      [("exit_code", .num (JsonNumber.fromNat r.exitCode)),
       ("timed_out", .bool r.timedOut),
       ("duration_ms", .num (JsonNumber.fromNat r.durationMs))] }

def shell : Tool where
  name := "shell"
  description :=
    "Run a shell command in the workspace directory. \
     Use it for builds, tests, and inspection. Dangerous commands require approval \
     and some are refused outright. Prefer the dedicated file and git tools where they apply."
  parameters := schemaObject
    [ ("command", schemaProp "string" "The command line to run")
    , ("timeout_sec", schemaProp "integer" "Optional timeout override in seconds") ]
    ["command"]
  required := ["command"]
  requirement := fun cfg args =>
    classifyCommand cfg.deniedCommands ((argStr? args "command").getD "")
  run := fun ctx args => do
    let some cmdline := argStr? args "command"
      | return .error (err .tool "missing string argument `command`")
    let timeout := (argNat? args "timeout_sec").getD ctx.config.shellTimeoutSec
    ctx.notify s!"$ {truncate cmdline 120}"
    match ← runShell cmdline ctx.workspace.root timeout with
    | .error e => return .error e
    | .ok r => return .ok (renderProc ctx (truncate cmdline 60) r)

/-- Project kinds the agent can build and test without being told how. -/
inductive ProjectKind where
  | lean | rust | go | node | python | make | unknown
  deriving Repr, DecidableEq, Inhabited

def ProjectKind.toString : ProjectKind → String
  | .lean => "lean" | .rust => "rust" | .go => "go" | .node => "node"
  | .python => "python" | .make => "make" | .unknown => "unknown"

instance : ToString ProjectKind := ⟨ProjectKind.toString⟩

/-- Detect the project kind from marker files in the workspace root. -/
def detectProject (root : System.FilePath) : IO ProjectKind := do
  let has (n : String) : IO Bool := (root / n).pathExists
  if ← has "lakefile.lean" then return .lean
  if ← has "lakefile.toml" then return .lean
  if ← has "Cargo.toml" then return .rust
  if ← has "go.mod" then return .go
  if ← has "package.json" then return .node
  if ← has "pyproject.toml" then return .python
  if ← has "setup.py" then return .python
  if ← has "Makefile" then return .make
  return .unknown

def buildCommandFor : ProjectKind → Option String
  | .lean => some "lake build"
  | .rust => some "cargo build"
  | .go => some "go build ./..."
  | .node => some "npm run build"
  | .python => none
  | .make => some "make"
  | .unknown => none

def testCommandFor : ProjectKind → Option String
  | .lean => some "lake test"
  | .rust => some "cargo test"
  | .go => some "go test ./..."
  | .node => some "npm test"
  | .python => some "pytest"
  | .make => some "make test"
  | .unknown => none

def runBuild : Tool where
  name := "run_build"
  description :=
    "Build the project. The build command is detected from the project layout \
     unless `command` is given explicitly."
  parameters := schemaObject
    [("command", schemaProp "string" "Optional explicit build command")] []
  requirement := fun cfg args =>
    match argStr? args "command" with
    | some c => classifyCommand cfg.deniedCommands c
    | none => { permissions := [.execute, .readFs, .writeFs], risk := .medium
                summary := "build the project" }
  run := fun ctx args => do
    let kind ← detectProject ctx.workspace.root
    let cmd? := (argStr? args "command").orElse (fun _ => buildCommandFor kind)
    let some cmd := cmd?
      | return .ok (ToolResult.failure
          s!"no build command known for this project (detected: {kind}); pass `command` explicitly")
    ctx.notify s!"$ {cmd}"
    match ← runShell cmd ctx.workspace.root ctx.config.shellTimeoutSec with
    | .error e => return .error e
    | .ok r => return .ok (renderProc ctx cmd r)

def runTests : Tool where
  name := "run_tests"
  description :=
    "Run the project's test suite. The command is detected from the project layout \
     unless `command` is given explicitly. Use `filter` to run a subset."
  parameters := schemaObject
    [ ("command", schemaProp "string" "Optional explicit test command")
    , ("filter", schemaProp "string" "Optional test name filter appended to the command") ] []
  requirement := fun cfg args =>
    match argStr? args "command" with
    | some c => classifyCommand cfg.deniedCommands c
    | none => { permissions := [.execute, .readFs, .writeFs], risk := .medium
                summary := "run the test suite" }
  run := fun ctx args => do
    let kind ← detectProject ctx.workspace.root
    let base? := (argStr? args "command").orElse (fun _ => testCommandFor kind)
    let some base := base?
      | return .ok (ToolResult.failure
          s!"no test command known for this project (detected: {kind}); pass `command` explicitly")
    let cmd := match argStr? args "filter" with
      | some f => if f.isEmpty then base else s!"{base} {f}"
      | none => base
    ctx.notify s!"$ {cmd}"
    match ← runShell cmd ctx.workspace.root ctx.config.shellTimeoutSec with
    | .error e => return .error e
    | .ok r => return .ok (renderProc ctx cmd r)

end LeanPrime.Tools
