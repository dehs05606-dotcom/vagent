/-
  LeanPrime.Agent.Interlock

  The gate every tool call passes through before it runs.

  There are two gates in front of a tool call now, and they answer
  different questions:

      the permission engine   is this action *safe*?
      the interlock           does this action break the *operator's rules*?

  They are deliberately separate.  The permission engine encodes what the
  system will not do regardless of instruction, and its theorems are stated
  about it alone.  The interlock encodes what *this operator's prompt* said,
  which is a different authority and changes with the prompt.  Merging them
  would mean either the prompt could weaken the safety engine, or the safety
  engine could be blamed for a prompt rule — both wrong.

  ## Ordering

  The interlock runs *before* the permission engine, so a call the prompt
  forbids is refused without ever being classified, approved or audited as
  an attempted action.  A refusal here is returned to the model as an
  ordinary tool result: the agent should adapt, not die.

  ## Unrestricted mode

  Unrestricted mode removes the *permission engine* — the deny list,
  workspace containment, approval prompts.  It does not remove the
  interlock, and that is not an oversight.  Unrestricted mode exists so
  nothing stands between the agent and the operator's prompt; the interlock
  *is* the operator's prompt. Turning it off there would remove the one
  thing unrestricted mode is supposed to leave standing.
-/
import LeanPrime.Prompt.Predicate
import LeanPrime.Prompt.Compiler
import LeanPrime.Agent.Events

open Lean

namespace LeanPrime

/-- What the interlock decided about one proposed call. -/
inductive InterlockVerdict where
  /-- Nothing matched. -/
  | clear
  /-- Rules matched, none at `block` level: the call proceeds, the
      violations are recorded and reported. -/
  | flagged (violations : List BehaviorViolation)
  /-- At least one `block` rule matched: the call does not run. -/
  | refused (violations : List BehaviorViolation)
  deriving Inhabited

def InterlockVerdict.allowsExecution : InterlockVerdict → Bool
  | .refused _ => false
  | _ => true

def InterlockVerdict.violations : InterlockVerdict → List BehaviorViolation
  | .clear => []
  | .flagged vs => vs
  | .refused vs => vs

def InterlockVerdict.toString : InterlockVerdict → String
  | .clear => "clear" | .flagged _ => "flagged" | .refused _ => "refused"

instance : ToString InterlockVerdict := ⟨InterlockVerdict.toString⟩

def InterlockVerdict.summary (v : InterlockVerdict) : String :=
  match v with
  | .clear => "clear"
  | .flagged vs | .refused vs =>
    String.intercalate "; " (vs.map BehaviorViolation.describe)

/-- Rule on a proposed call against the compiled behavioural rules. -/
def interlockCheck (rules : List BehaviorRule) (trace : ActionTrace)
    (p : ProposedAction) : InterlockVerdict :=
  match checkAllProposed rules trace p with
  | [] => .clear
  | vs =>
    match blockingViolations vs with
    | [] => .flagged vs
    | blocking => .refused blocking

/-- The result handed back for a refused call.

    Shaped as a normal tool result so the conversation stays well-formed:
    the model asked for a tool, it gets a result, and the result explains
    what to do differently. -/
def refusalResult (vs : List BehaviorViolation) : ToolResult :=
  let body := String.intercalate "\n\n" (vs.map blockMessage)
  { ok := false
    content := body
    display := s!"blocked by prompt rule: {truncate (String.intercalate "; "
                  (vs.map (fun v => v.rule.predicate.describe))) 70}" }

/-- The note appended to a flagged (but permitted) call's result, so the
    model sees the warning in the place it will actually read. -/
def flagNote (vs : List BehaviorViolation) : String :=
  if vs.isEmpty then "" else
  String.intercalate "\n"
    ([ ""
     , "[the operator's prompt flags this action, though it was permitted:" ]
     ++ vs.map (fun v => s!"   ⚠ {v.describe}")
     ++ [ " satisfy the rule before continuing.]" ])

/-! ### Tracking

    The interlock owns the trace, because the trace is what its predicates
    are evaluated against and nothing else needs to mutate it. -/

structure InterlockState where
  rules   : List BehaviorRule := []
  trace   : ActionTrace := {}
  /-- Calls refused outright. -/
  refusals : Nat := 0
  /-- Calls permitted with a flag. -/
  flags    : Nat := 0
  deriving Inhabited

namespace InterlockState

def ofDirectives (ds : List Directive) : InterlockState :=
  { rules := compileBehaviorRules ds }

def isActive (s : InterlockState) : Bool := !s.rules.isEmpty

def blockingRules (s : InterlockState) : Nat :=
  (s.rules.filter (fun r => r.level == .block)).length

/-- Record a call that actually ran. -/
def observe (s : InterlockState) (tool : String) (args : Json) (ok : Bool) (atMs : Nat)
    : InterlockState :=
  { s with trace := s.trace.append (recordOf s.trace.length tool args ok atMs) }

def noteRefusal (s : InterlockState) : InterlockState :=
  { s with refusals := s.refusals + 1 }

def noteFlag (s : InterlockState) : InterlockState :=
  { s with flags := s.flags + 1 }

/-- Behavioural rules unsatisfied over the whole run.  Consulted before the
    run is allowed to report success. -/
def finalViolations (s : InterlockState) : List BehaviorViolation :=
  checkAllFinal s.rules s.trace

def describe (s : InterlockState) : String :=
  let r := if s.refusals > 0 then s!" · {s.refusals} refused" else ""
  let f := if s.flags > 0 then s!" · {s.flags} flagged" else ""
  s!"{s.rules.length} behaviour rule(s){r}{f}"

/-- The short form for the status line. -/
def statusText (s : InterlockState) : String :=
  if s.rules.isEmpty then ""
  else if s.refusals + s.flags == 0 then s!"⛨{s.rules.length}"
  else s!"⛨{s.rules.length}·{s.refusals}⊘"

end InterlockState

end LeanPrime
