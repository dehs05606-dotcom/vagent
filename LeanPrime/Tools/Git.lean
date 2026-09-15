/-
  LeanPrime.Tools.Git

  Git as a first-class subsystem.

  Every operation runs `git` with a *fixed argument vector*, never through a
  shell, so a value supplied by the model cannot inject another command.  The
  set of subcommands is closed: there is no "run arbitrary git" tool.
-/
import LeanPrime.Tools.Tool
import LeanPrime.Tools.Process

open Lean

namespace LeanPrime.Tools

open LeanPrime

/-- Run git with an explicit argument vector (no shell). -/
def git (ctx : ToolContext) (args : Array String) : IO (LPResult ProcResult) :=
  runProcess "git" args ctx.workspace.root 60

private def gitResult (ctx : ToolContext) (label : String) (r : ProcResult) : ToolResult :=
  let text := if r.exitCode == 0 then r.stdout else s!"{r.stdout}\n{r.stderr}"
  let clamped := clampOutput (trim text) ctx.config.limits.maxBytes
    ctx.config.limits.headLines ctx.config.limits.tailLines
  { ok := r.exitCode == 0
    content := untrustedBlock s!"git:{label}"
      (if (trim clamped).isEmpty then "(no output)" else clamped)
    display := s!"git {label} — exit {r.exitCode}"
    metadata := Json.mkObj [("exit_code", .num (JsonNumber.fromNat r.exitCode))] }

def gitStatus : Tool where
  name := "git_status"
  description := "Show the working tree status, including staged and unstaged changes."
  parameters := schemaObject [] []
  requirement := fun _ _ =>
    { permissions := [.git, .readFs], risk := .low, summary := "inspect git status" }
  run := fun ctx _ => do
    match ← git ctx #["status", "--short", "--branch"] with
    | .error e => return .error e
    | .ok r => return .ok (gitResult ctx "status" r)

def gitDiff : Tool where
  name := "git_diff"
  description :=
    "Show the diff of the working tree. Set `staged` for the staged diff, or pass \
     `path` to limit it to one file. Use this to review your own changes before reporting."
  parameters := schemaObject
    [ ("staged", schemaProp "boolean" "Show the staged diff instead of the unstaged one")
    , ("path", schemaProp "string" "Optional path to limit the diff to") ] []
  requirement := fun _ _ =>
    { permissions := [.git, .readFs], risk := .low, summary := "inspect git diff" }
  run := fun ctx args => do
    let mut a := #["diff"]
    if (argBool? args "staged").getD false then a := a.push "--staged"
    if let some p := argStr? args "path" then
      match ctx.workspace.resolve p with
      | .error e => return .error e
      | .ok _ => a := a ++ #["--", p]
    match ← git ctx a with
    | .error e => return .error e
    | .ok r => return .ok (gitResult ctx "diff" r)

def gitLog : Tool where
  name := "git_log"
  description := "Show recent commits, most recent first."
  parameters := schemaObject
    [("limit", schemaProp "integer" "Number of commits (default 15)")] []
  requirement := fun _ _ =>
    { permissions := [.git, .readFs], risk := .low, summary := "inspect git log" }
  run := fun ctx args => do
    let n := (argNat? args "limit").getD 15
    match ← git ctx #["log", s!"-{n}", "--oneline", "--decorate"] with
    | .error e => return .error e
    | .ok r => return .ok (gitResult ctx "log" r)

def gitShow : Tool where
  name := "git_show"
  description := "Show a single commit, including its diff."
  parameters := schemaObject
    [("ref", schemaProp "string" "Commit reference (default HEAD)")] []
  requirement := fun _ _ =>
    { permissions := [.git, .readFs], risk := .low, summary := "inspect a commit" }
  run := fun ctx args => do
    let ref := (argStr? args "ref").getD "HEAD"
    -- `--` terminates option parsing so a hostile ref cannot become a flag.
    match ← git ctx #["show", "--stat", "--patch", ref, "--"] with
    | .error e => return .error e
    | .ok r => return .ok (gitResult ctx s!"show {ref}" r)

def gitAdd : Tool where
  name := "git_add"
  description := "Stage files for commit."
  parameters := schemaObject
    [("paths", Json.mkObj
       [("type", .str "array"), ("items", Json.mkObj [("type", .str "string")]),
        ("description", .str "Workspace-relative paths to stage")])]
    ["paths"]
  required := ["paths"]
  requirement := fun _ _ =>
    { permissions := [.git, .writeFs], risk := .medium, summary := "stage files" }
  run := fun ctx args => do
    let paths := match args.getObjVal? "paths" with
      | .ok (.arr xs) => xs.toList.filterMap (fun (j : Json) => j.getStr?.toOption)
      | _ => []
    if paths.isEmpty then
      return .ok (ToolResult.failure "no paths given")
    for p in paths do
      match ctx.workspace.resolve p with
      | .error e => return .error e
      | .ok _ => pure ()
    match ← git ctx (#["add", "--"] ++ paths.toArray) with
    | .error e => return .error e
    | .ok r => return .ok (gitResult ctx "add" r)

def gitCommit : Tool where
  name := "git_commit"
  description :=
    "Create a commit from the staged changes. Only use this when the user has asked for a commit."
  parameters := schemaObject
    [("message", schemaProp "string" "Commit message")] ["message"]
  required := ["message"]
  requirement := fun _ _ =>
    { permissions := [.git, .writeFs], risk := .high, summary := "create a git commit" }
  run := fun ctx args => do
    let some msg := argStr? args "message"
      | return .error (err .tool "missing string argument `message`")
    match ← git ctx #["commit", "-m", msg] with
    | .error e => return .error e
    | .ok r => return .ok (gitResult ctx "commit" r)

/-- Is the workspace inside a git repository? -/
def isGitRepo (root : System.FilePath) : IO Bool := do
  match ← runProcess "git" #["rev-parse", "--is-inside-work-tree"] root 15 with
  | .error _ => return false
  | .ok r => return r.exitCode == 0 && containsSubstr r.stdout "true"

end LeanPrime.Tools
