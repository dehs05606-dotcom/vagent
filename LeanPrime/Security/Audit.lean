/-
  LeanPrime.Security.Audit

  An append-only record of every permission decision and every tool
  execution.  The audit trail is what makes an autonomous run reviewable
  after the fact; it is written even when the TUI is not attached.
-/
import LeanPrime.Security.Permissions
import LeanPrime.Util.Logging
import LeanPrime.Util.Platform

open Lean

namespace LeanPrime

inductive AuditEvent where
  | decision (tool : String) (risk : Risk) (verdict : String) (summary : String)
  | execution (tool : String) (ok : Bool) (durationMs : Nat) (detail : String)
  | approval (tool : String) (granted : Bool) (scope : String)
  | policyChange (what : String)
  deriving Repr, Inhabited

def AuditEvent.toJson : AuditEvent → Json
  | .decision t r v s => Json.mkObj
      [("event", .str "decision"), ("tool", .str t), ("risk", .str r.toString),
       ("verdict", .str v), ("summary", .str s)]
  | .execution t ok ms d => Json.mkObj
      [("event", .str "execution"), ("tool", .str t), ("ok", .bool ok),
       ("duration_ms", .num (JsonNumber.fromNat ms)), ("detail", .str d)]
  | .approval t g sc => Json.mkObj
      [("event", .str "approval"), ("tool", .str t), ("granted", .bool g),
       ("scope", .str sc)]
  | .policyChange w => Json.mkObj
      [("event", .str "policy_change"), ("what", .str w)]

/-- Where audit records go.  Abstracted so tests can capture them. -/
structure AuditSink where
  record : AuditEvent → IO Unit

/-- A sink that appends redacted JSON lines to a file, and never fails the
    caller if the write fails. -/
def fileAuditSink (path : System.FilePath) : AuditSink where
  record e := do
    try
      if let some parent := path.parent then
        IO.FS.createDirAll parent
      let h ← IO.FS.Handle.mk path IO.FS.Mode.append
      h.putStrLn (redact e.toJson.compress)
    catch _ => pure ()

def nullAuditSink : AuditSink where
  record _ := pure ()

/-- Default audit log location. -/
def defaultAuditPath : IO System.FilePath := do
  return (← stateHome) / "audit.jsonl"

end LeanPrime
