/-
  LeanPrime.Util.Logging

  Structured logging with a hard rule: values that look like credentials are
  redacted before they can reach a log sink.
-/
import LeanPrime.Util.Prelude
import LeanPrime.Util.Errors

open Lean

namespace LeanPrime

inductive LogLevel where
  | trace | debug | info | warn | error
  deriving Repr, DecidableEq, Inhabited

def LogLevel.rank : LogLevel → Nat
  | .trace => 0 | .debug => 1 | .info => 2 | .warn => 3 | .error => 4

def LogLevel.toString : LogLevel → String
  | .trace => "trace" | .debug => "debug" | .info => "info"
  | .warn  => "warn"  | .error => "error"

instance : ToString LogLevel := ⟨LogLevel.toString⟩

def LogLevel.ofString? (s : String) : Option LogLevel :=
  match toLower (trim s) with
  | "trace" => some .trace | "debug" => some .debug | "info" => some .info
  | "warn" | "warning" => some .warn | "error" => some .error
  | _ => none

/-- Patterns whose *values* must never be written to a log or transcript. -/
def secretMarkers : List String :=
  ["api_key", "apikey", "api-key", "authorization", "bearer", "token",
   "secret", "password", "passwd", "credential", "private_key"]

/-- Redact anything that looks like a credential.

    Two rules:
    1. a token that looks like a key (`sk-…`, long opaque strings after a
       secret marker) is replaced wholesale;
    2. `marker=value` / `marker: value` pairs have the value replaced. -/
def redact (s : String) : String := Id.run do
  let mut out := s
  -- rule 1: provider-style keys
  for tokenPrefix in ["sk-", "sk_live_", "ghp_", "gho_", "xoxb-", "AIza"] do
    let parts := out.splitOn tokenPrefix
    if parts.length > 1 then
      let mut rebuilt := parts.head!
      for seg in parts.tail! do
        -- drop the opaque run of key characters that follows the prefix
        let rest := seg.toList.dropWhile (fun c =>
          c.isAlphanum || c == '_' || c == '-')
        rebuilt := rebuilt ++ "[REDACTED]" ++ String.ofList rest
      out := rebuilt
  -- rule 2: marker = value
  for m in secretMarkers do
    let lower := toLower out
    if containsSubstr lower m then
      let lines := out.splitOn "\n"
      out := String.intercalate "\n" (lines.map fun line =>
        if containsSubstr (toLower line) m then
          match line.splitOn "=" with
          | k :: _ :: _ => k ++ "=[REDACTED]"
          | _ =>
            match line.splitOn ":" with
            | k :: _ :: _ => k ++ ": [REDACTED]"
            | _ => line
        else line)
  return out

structure Logger where
  minLevel : LogLevel
  /-- When set, lines are appended to this file in addition to stderr. -/
  file     : Option System.FilePath
  /-- Suppress stderr output (headless/JSON mode writes its own stream). -/
  quiet    : Bool
  deriving Inhabited

def Logger.default : Logger := { minLevel := .info, file := none, quiet := false }

def Logger.log (lg : Logger) (lvl : LogLevel) (msg : String) : IO Unit := do
  if lvl.rank < lg.minLevel.rank then return
  let line := s!"[{lvl}] {redact msg}"
  unless lg.quiet do
    (← IO.getStderr).putStrLn line
  match lg.file with
  | none => pure ()
  | some f =>
    try
      let h ← IO.FS.Handle.mk f IO.FS.Mode.append
      h.putStrLn line
    catch _ => pure ()   -- logging must never take the agent down

def Logger.debug (lg : Logger) (m : String) : IO Unit := lg.log .debug m
def Logger.info  (lg : Logger) (m : String) : IO Unit := lg.log .info m
def Logger.warn  (lg : Logger) (m : String) : IO Unit := lg.log .warn m
def Logger.error (lg : Logger) (m : String) : IO Unit := lg.log .error m
def Logger.trace (lg : Logger) (m : String) : IO Unit := lg.log .trace m

end LeanPrime
