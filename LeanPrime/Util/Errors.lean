/-
  LeanPrime.Util.Errors

  A single structured error type for the whole agent.  Nothing in LeanPrime
  is allowed to signal failure with a bare string: every failure carries a
  category so the agent loop can decide whether it is recoverable.
-/
import LeanPrime.Util.Prelude

open Lean

namespace LeanPrime

/-- Error categories, mirroring the subsystems that can fail. -/
inductive ErrorKind where
  | configuration
  | provider
  | network
  | parse
  | tool
  | permission
  | file
  | shell
  | git
  | verification
  | cancellation
  | budget
  | internal
  deriving Repr, DecidableEq, Inhabited

def ErrorKind.toString : ErrorKind → String
  | .configuration => "ConfigurationError"
  | .provider      => "ProviderError"
  | .network       => "NetworkError"
  | .parse         => "ParseError"
  | .tool          => "ToolError"
  | .permission    => "PermissionError"
  | .file          => "FileError"
  | .shell         => "ShellError"
  | .git           => "GitError"
  | .verification  => "VerificationError"
  | .cancellation  => "CancellationError"
  | .budget        => "BudgetError"
  | .internal      => "InternalError"

instance : ToString ErrorKind := ⟨ErrorKind.toString⟩
instance : ToJson ErrorKind := ⟨fun k => Json.str k.toString⟩

/-- A structured error: category, human message, optional detail and hint. -/
structure LPError where
  kind    : ErrorKind
  message : String
  detail  : Option String := none
  hint    : Option String := none
  deriving Repr, Inhabited

namespace LPError

def render (e : LPError) : String :=
  let base := s!"{e.kind}: {e.message}"
  let base := match e.detail with | some d => base ++ s!"\n  {d}" | none => base
  match e.hint with | some h => base ++ s!"\n  hint: {h}" | none => base

def toJson (e : LPError) : Json :=
  Json.mkObj <|
    [("kind", Json.str e.kind.toString), ("message", Json.str e.message)]
    ++ (match e.detail with | some d => [("detail", Json.str d)] | none => [])
    ++ (match e.hint with | some h => [("hint", Json.str h)] | none => [])

/-- Is it worth the agent trying again after this failure? -/
def recoverable (e : LPError) : Bool :=
  match e.kind with
  | .network | .provider | .shell | .tool | .verification | .parse => true
  | _ => false

end LPError

instance : ToString LPError := ⟨LPError.render⟩
instance : ToJson LPError := ⟨LPError.toJson⟩

abbrev LPResult (α : Type) := Except LPError α

def err (k : ErrorKind) (m : String) (d : Option String := none)
    (h : Option String := none) : LPError := { kind := k, message := m, detail := d, hint := h }

def throwLP {α : Type} (k : ErrorKind) (m : String) (d : Option String := none) : IO α :=
  throw (IO.userError (LPError.render (err k m d)))

/-- Run an `IO` action, converting any exception into a structured error. -/
def guardIO {α : Type} (k : ErrorKind) (what : String) (act : IO α) : IO (LPResult α) := do
  try
    return .ok (← act)
  catch e =>
    return .error (err k what (some (toString e)))

end LeanPrime
