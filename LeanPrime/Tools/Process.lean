/-
  LeanPrime.Tools.Process

  Child-process execution with a real timeout.

  `IO.Process.output` blocks forever, which is unacceptable for an
  autonomous loop: one hung test command would freeze the agent.  Here the
  child's pipes are drained on separate tasks while the main thread polls
  `tryWait`, and the child is killed when the deadline passes.
-/
import LeanPrime.Util.Prelude
import LeanPrime.Util.Errors
import LeanPrime.Util.Platform

namespace LeanPrime

structure ProcResult where
  exitCode : Nat
  stdout   : String
  stderr   : String
  timedOut : Bool
  durationMs : Nat
  deriving Inhabited, Repr

/-- Run a program with arguments, bounded by `timeoutSec`. -/
def runProcess (cmd : String) (args : Array String) (cwd : System.FilePath)
    (timeoutSec : Nat) : IO (LPResult ProcResult) := do
  let started ← IO.monoMsNow
  try
    let child ← IO.Process.spawn {
      cmd := cmd, args := args, cwd := some cwd,
      stdout := .piped, stderr := .piped, stdin := .null }
    -- Drain both pipes concurrently: a full pipe buffer would otherwise
    -- deadlock the child before it can exit.
    let outTask ← IO.asTask child.stdout.readToEnd
    let errTask ← IO.asTask child.stderr.readToEnd
    let deadline := started + timeoutSec * 1000
    let mut code : Option UInt32 := none
    let mut timedOut := false
    repeat
      code ← child.tryWait
      if code.isSome then break
      if (← IO.monoMsNow) > deadline then
        try child.kill catch _ => pure ()
        timedOut := true
        code ← some <$> child.wait
        break
      IO.sleep 25
    let out ← match ← IO.wait outTask with
      | .ok s => pure s | .error _ => pure ""
    let errOut ← match ← IO.wait errTask with
      | .ok s => pure s | .error _ => pure ""
    let finished ← IO.monoMsNow
    return .ok {
      exitCode := (code.getD 0).toNat
      stdout := out
      stderr := errOut
      timedOut := timedOut
      durationMs := finished - started }
  catch e =>
    return .error (err .shell s!"cannot run `{cmd}`" (some (toString e))
      (some s!"is `{cmd}` installed and on PATH?"))

/-- Run a command line through the platform shell. -/
def runShell (cmdline : String) (cwd : System.FilePath) (timeoutSec : Nat)
    : IO (LPResult ProcResult) := do
  let (sh, pre) := shellFor detectPlatform
  runProcess sh (pre.push cmdline) cwd timeoutSec

end LeanPrime
