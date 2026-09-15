/-
  LeanPrime.Agent.Executor

  Turns a model-proposed tool call into an executed, audited action — or a
  refusal.

  The executor is deliberately dumb about intent: it does not interpret what
  the model *meant*, and it does not read the model's justification.  It
  looks up the tool, validates the arguments, asks the policy, and obeys.

  A refusal is returned to the model as an ordinary tool result rather than
  aborting the run, so the agent can adapt (ask the user, take another
  route) instead of dying.
-/
import LeanPrime.Agent.Events
import LeanPrime.Tools.Registry
import LeanPrime.Security.Approval

open Lean

namespace LeanPrime

/-- Everything the executor needs. -/
structure ExecutorEnv where
  registry : Registry
  toolCtx  : ToolContext
  events   : EventSink

/-- Parse tool arguments, tolerating the empty string some providers send. -/
def parseArguments (raw : String) : LPResult Json :=
  let t := trim raw
  if t.isEmpty then .ok (Json.mkObj [])
  else match Json.parse t with
  | .ok j => .ok j
  | .error e => .error (err .parse "tool arguments were not valid JSON"
      (some (truncate raw 300)) (some e))

/-- Short human description of a call, used in prompts and the audit log. -/
def describeCall (name : String) (args : Json) : String :=
  match name, args.getObjVal? "command", args.getObjVal? "path" with
  | _, .ok (.str c), _ => c
  | _, _, .ok (.str p) => p
  | n, _, _ => n

/-- Execute one tool call under the policy.  Never throws. -/
def executeCall (env : ExecutorEnv) (call : ToolCallRequest)
    : IO ToolResult := do
  let ev := env.events
  ev.emit (.toolRequested call.id call.name (truncate call.arguments 400))
  let some tool := env.registry.find? call.name
    | let msg := s!"unknown tool `{call.name}`; available tools are: " ++
        String.intercalate ", " env.registry.names
      ev.emit (.toolFinished call.name false msg 0)
      return ToolResult.failure msg
  match parseArguments call.arguments with
  | .error e =>
    ev.emit (.toolFinished call.name false e.message 0)
    return ToolResult.failure (LPError.render e)
  | .ok args =>
    match tool.validate args with
    | .error e =>
      ev.emit (.toolFinished call.name false e.message 0)
      return ToolResult.failure (LPError.render e)
    | .ok _ =>
      let requirement := tool.requirement env.toolCtx.config args
      let policy ← env.toolCtx.policy.get
      let decision := policy.decide requirement
      let detail := describeCall call.name args
      let verdict := match decision with
        | .allow => "allow" | .ask _ => "ask" | .deny _ => "deny"
      ev.emit (.toolDecision call.name requirement.risk verdict requirement.summary)
      env.toolCtx.audit.record
        (.decision call.name requirement.risk verdict requirement.summary)
      let finalDecision ← match decision with
        | .allow => pure Decision.allow
        | .deny r => pure (Decision.deny r)
        | .ask _ =>
          -- A command approved earlier in this session does not re-prompt.
          if policy.approvedCommands.contains detail then pure Decision.allow
          else env.toolCtx.askUser requirement detail
      match finalDecision with
      | .deny reason =>
        let msg := s!"REFUSED: {reason}. This action was not performed. \
                     Choose a different approach, or explain to the user why it is needed."
        ev.emit (.toolFinished call.name false s!"refused: {reason}" 0)
        env.toolCtx.audit.record (.execution call.name false 0 s!"refused: {reason}")
        return { ok := false, content := msg, display := s!"refused: {truncate reason 80}" }
      | .ask reason =>
        let msg := s!"REFUSED: approval required but not granted ({reason})."
        ev.emit (.toolFinished call.name false "approval not granted" 0)
        return { ok := false, content := msg, display := "approval not granted" }
      | .allow =>
        ev.emit (.toolStarted call.name requirement.summary)
        let started ← IO.monoMsNow
        let outcome ← try tool.run env.toolCtx args
          catch e => pure (.error (err .tool s!"tool `{call.name}` raised" (some (toString e))))
        let elapsed := (← IO.monoMsNow) - started
        match outcome with
        | .error e =>
          ev.emit (.toolFinished call.name false e.message elapsed)
          env.toolCtx.audit.record (.execution call.name false elapsed e.message)
          return ToolResult.failure (LPError.render e)
        | .ok res =>
          ev.emit (.toolFinished call.name res.ok res.display elapsed)
          env.toolCtx.audit.record (.execution call.name res.ok elapsed res.display)
          return res

/-- Tools whose success means a file changed, so the agent must re-verify. -/
def mutatingTools : List String :=
  ["write_file", "edit_file", "delete_file"]

/-- Extract the workspace path a successful mutation touched. -/
def touchedPath? (name : String) (res : ToolResult) : Option String :=
  if !res.ok || !mutatingTools.contains name then none
  else match res.metadata.getObjVal? "path" with
    | .ok (.str p) => some p
    | _ => none

end LeanPrime
