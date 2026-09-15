/-
  LeanPrime.Tools.Tool

  The typed tool interface.

  A tool declares what it needs *before* it runs (`requirement`), so the
  permission engine can rule on a call without executing anything.  The
  executor never asks the model whether a call is allowed; it asks the
  policy.
-/
import LeanPrime.Security.Permissions
import LeanPrime.Security.Audit
import LeanPrime.Util.Paths
import LeanPrime.Util.Logging
import LeanPrime.Config.Schema
import LeanPrime.Model.Messages

open Lean

namespace LeanPrime

/-- Outcome of running a tool. -/
structure ToolResult where
  ok      : Bool
  /-- Text handed back to the model.  Already clamped to the output limits. -/
  content : String
  /-- One-line summary for the transcript. -/
  display : String := ""
  /-- Structured facts for the agent (files changed, exit codes, …). -/
  metadata : Json := Json.mkObj []
  deriving Inhabited

def ToolResult.failure (msg : String) : ToolResult :=
  { ok := false, content := msg, display := msg }

def ToolResult.success (content : String) (display : String := "") : ToolResult :=
  { ok := true, content := content, display := if display.isEmpty then "ok" else display }

/-- Everything a tool is allowed to touch. -/
structure ToolContext where
  workspace : Workspace
  config    : Config
  /-- Mutable so a session-scoped approval persists across calls. -/
  policy    : IO.Ref Policy
  logger    : Logger
  audit     : AuditSink
  /-- Ask the user to approve a requirement.  Returns the decision actually
      taken.  Supplied by the app layer; headless mode denies. -/
  askUser   : Requirement → String → IO Decision
  /-- Progress notification for the UI. -/
  notify    : String → IO Unit

/-- A tool the model may call. -/
structure Tool where
  name        : String
  description : String
  /-- JSON Schema for the arguments. -/
  parameters  : Json
  /-- Names of required argument keys, checked before `run`. -/
  required    : List String := []
  /-- What this call needs, derived from its arguments.  Pure: the policy
      must be decidable without side effects. -/
  requirement : Config → Json → Requirement
  run         : ToolContext → Json → IO (LPResult ToolResult)

/-- Convenience for a JSON Schema object property. -/
def schemaProp (type_ desc : String) : Json :=
  Json.mkObj [("type", .str type_), ("description", .str desc)]

def schemaObject (props : List (String × Json)) (required : List String) : Json :=
  Json.mkObj
    [ ("type", .str "object")
    , ("properties", Json.mkObj props)
    , ("required", Json.arr (required.toArray.map Json.str)) ]

/-- Total JSON field accessors used by tool implementations. -/
def argStr? (j : Json) (k : String) : Option String :=
  match j.getObjVal? k with
  | .ok v => v.getStr?.toOption
  | .error _ => none

def argNat? (j : Json) (k : String) : Option Nat :=
  match j.getObjVal? k with
  | .ok v => v.getNat?.toOption
  | .error _ => none

def argBool? (j : Json) (k : String) : Option Bool :=
  match j.getObjVal? k with
  | .ok v => v.getBool?.toOption
  | .error _ => none

/-- Declared schema for the provider. -/
def Tool.schema (t : Tool) : ToolSchema :=
  { name := t.name, description := t.description, parameters := t.parameters }

/-- Check that every required argument is present, before any side effect. -/
def Tool.validate (t : Tool) (args : Json) : LPResult Unit := do
  for k in t.required do
    match args.getObjVal? k with
    | .error _ => throw (err .tool s!"tool `{t.name}` requires argument `{k}`")
    | .ok v => if v.isNull then
        throw (err .tool s!"tool `{t.name}` requires argument `{k}` (got null)")
  return ()

end LeanPrime
