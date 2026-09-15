/-
  LeanPrime.Security.Approval

  The interactive approval prompt.

  Two rules hold regardless of what the model said:
    * the command shown to the user is the exact string that will be
      executed — there is no separate "display" text that could differ;
    * a non-interactive session (no TTY, `--json`, CI) denies rather than
      assuming yes.
-/
import LeanPrime.Security.Permissions
import LeanPrime.Security.Audit
import LeanPrime.Util.Logging

namespace LeanPrime

/-- Scope of a granted approval. -/
inductive ApprovalScope where
  | once | session | denied
  deriving Repr, DecidableEq, Inhabited

def ApprovalScope.toString : ApprovalScope → String
  | .once => "once" | .session => "session" | .denied => "denied"

/-- Render the approval prompt.  `detail` is the exact command or path. -/
def renderApprovalPrompt (toolName : String) (r : Requirement) (detail : String)
    (cwd : String) : String :=
  let perms := String.intercalate " + " (r.permissions.map Permission.toString)
  String.intercalate "\n"
    [ ""
    , "  ┌─ approval required ──────────────────────────────────────────"
    , s!"  │ tool        {toolName}"
    , s!"  │ action      {truncate detail 200}"
    , s!"  │ directory   {cwd}"
    , s!"  │ permission  {if perms.isEmpty then "none" else perms}"
    , s!"  │ risk        {r.risk}"
    , s!"  │ why         {truncate r.summary 160}"
    , "  └──────────────────────────────────────────────────────────────"
    , "   [y] allow once   [a] allow for this session   [n] deny (default)"
    , "  > " ]

/-- Ask on the terminal.  Returns the scope the user chose. -/
def promptApproval (toolName : String) (r : Requirement) (detail : String)
    (cwd : String) : IO ApprovalScope := do
  let stdout ← IO.getStdout
  let stdin ← IO.getStdin
  -- Never prompt when there is nobody there to answer.
  if !(← stdin.isTty) then
    return .denied
  stdout.putStr (renderApprovalPrompt toolName r detail cwd)
  stdout.flush
  let line ← stdin.getLine
  match toLower (trim line) with
  | "y" | "yes" => return .once
  | "a" | "all" | "always" => return .session
  | _ => return .denied

/-- Build the `askUser` callback used by `ToolContext`.

    `interactive := false` (headless, `--json`, no TTY) denies every request
    that needs a decision, rather than silently proceeding. -/
def makeAskUser (interactive : Bool) (policyRef : IO.Ref Policy)
    (audit : AuditSink) (cwd : String) : Requirement → String → IO Decision :=
  fun r detail => do
    if !interactive then
      audit.record (.approval "-" false "non-interactive")
      return .deny "approval required, but the session is not interactive"
    match ← promptApproval "-" r detail cwd with
    | .once =>
      audit.record (.approval "-" true "once")
      return .allow
    | .session =>
      policyRef.modify (fun p => p.grantSession r |>.approveCommand detail)
      audit.record (.approval "-" true "session")
      return .allow
    | .denied =>
      audit.record (.approval "-" false "denied")
      return .deny "denied by the user"

end LeanPrime
