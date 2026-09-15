/-
  LeanPrime.Util.Platform

  All platform-specific behaviour is isolated here.  The rest of the agent
  never assumes bash, /bin/sh, POSIX utilities or Unix path separators.
-/
import LeanPrime.Util.Prelude
import LeanPrime.Util.Errors

namespace LeanPrime

inductive Platform where
  | linux | macos | windows | other
  deriving Repr, DecidableEq, Inhabited

def Platform.toString : Platform → String
  | .linux => "linux" | .macos => "macos" | .windows => "windows" | .other => "other"

instance : ToString Platform := ⟨Platform.toString⟩

/-- Detect the host platform.  `System.Platform` exposes compile-time flags. -/
def detectPlatform : Platform :=
  if System.Platform.isWindows then .windows
  else if System.Platform.isOSX then .macos
  else .linux

/-- The shell used to run a command line, as (program, argument-prefix). -/
def shellFor : Platform → String × Array String
  | .windows => ("cmd.exe", #["/C"])
  | _        => ("/bin/sh", #["-c"])

/-- Preferred config directory for the current platform. -/
def configHome : IO System.FilePath := do
  match detectPlatform with
  | .windows =>
    match ← IO.getEnv "APPDATA" with
    | some a => return System.FilePath.mk a / "lean-prime"
    | none   => return System.FilePath.mk "." / ".lean-prime"
  | _ =>
    match ← IO.getEnv "XDG_CONFIG_HOME" with
    | some x => return System.FilePath.mk x / "lean-prime"
    | none =>
      match ← IO.getEnv "HOME" with
      | some h => return System.FilePath.mk h / ".config" / "lean-prime"
      | none   => return System.FilePath.mk "." / ".lean-prime"

/-- Directory for sessions, audit logs and project memory. -/
def stateHome : IO System.FilePath := do
  match detectPlatform with
  | .windows =>
    match ← IO.getEnv "LOCALAPPDATA" with
    | some a => return System.FilePath.mk a / "lean-prime"
    | none   => return System.FilePath.mk "." / ".lean-prime"
  | _ =>
    match ← IO.getEnv "XDG_STATE_HOME" with
    | some x => return System.FilePath.mk x / "lean-prime"
    | none =>
      match ← IO.getEnv "HOME" with
      | some h => return System.FilePath.mk h / ".local" / "state" / "lean-prime"
      | none   => return System.FilePath.mk "." / ".lean-prime"

/-- Is an executable available on PATH? -/
def hasExecutable (name : String) : IO Bool := do
  let (sh, pre) := shellFor detectPlatform
  let probe := if detectPlatform == .windows then s!"where {name}" else s!"command -v {name}"
  try
    let out ← IO.Process.output { cmd := sh, args := pre.push probe }
    return out.exitCode == 0
  catch _ => return false

end LeanPrime
