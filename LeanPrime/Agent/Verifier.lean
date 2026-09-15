/-
  LeanPrime.Agent.Verifier

  Independent verification of the agent's own work.

  The verifier does not ask the model whether the task succeeded.  It runs
  the project's build, runs its tests, and inspects the diff, and reports
  what actually happened.  `VerificationResult.ofChecks` encodes the rule
  that "no check could run" is `inconclusive`, never success — which is why
  the agent cannot report done on a project it never compiled.
-/
import LeanPrime.Agent.Events
import LeanPrime.Tools.Shell
import LeanPrime.Tools.Git
import LeanPrime.Tools.Process

namespace LeanPrime

open LeanPrime.Tools

/-- Output that means "this project has no such command", as opposed to
    "this project is broken".  A missing `build` script in package.json is
    not a build failure, and treating it as one would send the agent into a
    repair loop over nothing. -/
def looksLikeMissingCommand (text : String) : Bool :=
  [ "missing script", "command not found", "no such file or directory"
  , "unknown command", "is not recognized as an internal"
  , "no targets specified", "no rule to make target"
  , "error: no such command" ].any (containsSubstrI text)

/-- Summarise a process run into a check result. -/
private def checkOf (name : String) (r : ProcResult) (maxDetail : Nat) : CheckResult :=
  let text := trim (r.stdout ++ "\n" ++ r.stderr)
  if r.timedOut then
    { name := name, outcome := .failed, detail := s!"timed out after {r.durationMs}ms" }
  else if r.exitCode == 0 then
    { name := name, outcome := .passed, detail := s!"exit 0 in {r.durationMs}ms" }
  else if looksLikeMissingCommand text then
    { name := name, outcome := .inconclusive
      detail := s!"this project has no {name} command" }
  else
    { name := name, outcome := .failed
      detail := s!"exit {r.exitCode}\n" ++ clampOutput text maxDetail 40 40 }

/-- Run the project's build and tests, and inspect the diff.

    `changedFiles` is what the agent believes it touched; an empty list with
    a non-empty git diff is itself reported, because it means the agent lost
    track of its own edits. -/
def verify (ws : Workspace) (cfg : Config) (events : EventSink)
    (changedFiles : List String) : IO VerificationResult := do
  events.emit .verificationStarted
  let kind ← detectProject ws.root
  let mut checks : List CheckResult := []

  -- 1. build
  match buildCommandFor kind with
  | none =>
    checks := checks ++ [{ name := "build", outcome := .inconclusive
                           detail := s!"no build command known for a {kind} project" }]
  | some cmd =>
    events.emit (.toolProgress s!"$ {cmd}")
    match ← runShell cmd ws.root cfg.shellTimeoutSec with
    | .error e =>
      checks := checks ++ [{ name := "build", outcome := .failed, detail := e.message }]
    | .ok r =>
      let c := checkOf "build" r cfg.limits.maxBytes
      events.emit (.verificationCheck c.name c.outcome c.detail)
      checks := checks ++ [c]

  -- 2. tests, only when the build did not fail
  let buildFailed := checks.any (fun c => c.name == "build" && c.outcome == .failed)
  if buildFailed then
    checks := checks ++ [{ name := "tests", outcome := .inconclusive
                           detail := "skipped because the build failed" }]
  else
    match testCommandFor kind with
    | none =>
      checks := checks ++ [{ name := "tests", outcome := .inconclusive
                             detail := s!"no test command known for a {kind} project" }]
    | some cmd =>
      events.emit (.toolProgress s!"$ {cmd}")
      match ← runShell cmd ws.root cfg.shellTimeoutSec with
      | .error e =>
        checks := checks ++ [{ name := "tests", outcome := .failed, detail := e.message }]
      | .ok r =>
        let c := checkOf "tests" r cfg.limits.maxBytes
        events.emit (.verificationCheck c.name c.outcome c.detail)
        checks := checks ++ [c]

  -- 3. diff review
  if ← isGitRepo ws.root then
    match ← runProcess "git" #["diff", "--stat"] ws.root 30 with
    | .error e =>
      checks := checks ++ [{ name := "diff", outcome := .inconclusive, detail := e.message }]
    | .ok r =>
      let diffText := trim r.stdout
      let c : CheckResult :=
        if diffText.isEmpty && !changedFiles.isEmpty then
          { name := "diff", outcome := .failed
            detail := s!"the agent reported editing {changedFiles.length} file(s) but the \
                        working tree is unchanged" }
        else if diffText.isEmpty then
          { name := "diff", outcome := .inconclusive, detail := "no changes in the working tree" }
        else
          { name := "diff", outcome := .passed
            detail := clampOutput diffText 4000 40 10 }
      events.emit (.verificationCheck c.name c.outcome c.detail)
      checks := checks ++ [c]

  let result := VerificationResult.ofChecks checks
  events.emit (.verificationFinished result)
  return result

/-- Render a verification failure for the model, with the real output. -/
def renderFailure (v : VerificationResult) : String :=
  let failed := v.checks.filter (fun c => c.outcome == .failed)
  String.intercalate "\n\n"
    (failed.map fun c => untrustedBlock s!"verification:{c.name}" c.detail)

end LeanPrime
