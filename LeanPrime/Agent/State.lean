/-
  LeanPrime.Agent.State

  The agent's state machine, as data.

  The phase is an inductive type, not a string, and transitions go through
  one total function `AgentPhase.step`.  It returns `Option AgentPhase`:
  `none` means "this signal is not legal here", which the supervisor treats
  as an internal error rather than silently continuing.  That is what makes
  the invariants in `LeanPrime.Verification.StateProofs` meaningful — an
  illegal transition has no representation as a successful result.
-/
import LeanPrime.Util.Prelude
import LeanPrime.Util.Errors
import LeanPrime.Model.Messages
import LeanPrime.Security.Permissions

open Lean

namespace LeanPrime

/-- Where the agent is in its cycle. -/
inductive AgentPhase where
  | idle
  | understanding
  | inspecting
  | contextBuilding
  | planning
  | awaitingModel
  | executing
  | observing
  | verifying
  | diagnosing
  | replanning
  | cancelling
  | completed
  | failed
  | cancelled
  deriving Repr, DecidableEq, Inhabited

def AgentPhase.toString : AgentPhase → String
  | .idle => "idle" | .understanding => "understanding" | .inspecting => "inspecting"
  | .contextBuilding => "context" | .planning => "planning"
  | .awaitingModel => "awaiting-model" | .executing => "executing"
  | .observing => "observing" | .verifying => "verifying"
  | .diagnosing => "diagnosing" | .replanning => "replanning"
  | .cancelling => "cancelling" | .completed => "completed"
  | .failed => "failed" | .cancelled => "cancelled"

instance : ToString AgentPhase := ⟨AgentPhase.toString⟩

/-- A phase from which no further work happens. -/
def AgentPhase.isTerminal : AgentPhase → Bool
  | .completed | .failed | .cancelled => true
  | _ => false

/-- Things that can happen to the agent. -/
inductive AgentSignal where
  | start
  | repositoryInspected
  | contextReady
  | planReady
  | modelRequested
  | modelReplied
  | toolRequested
  | toolFinished
  | verifyRequested
  | verificationPassed
  | verificationFailed
  | repairPlanned
  | budgetExhausted
  | fatalError
  | cancelRequested
  | cancelConfirmed
  | finish
  deriving Repr, DecidableEq, Inhabited

def AgentSignal.toString : AgentSignal → String
  | .start => "start" | .repositoryInspected => "repository-inspected"
  | .contextReady => "context-ready" | .planReady => "plan-ready"
  | .modelRequested => "model-requested" | .modelReplied => "model-replied"
  | .toolRequested => "tool-requested" | .toolFinished => "tool-finished"
  | .verifyRequested => "verify-requested"
  | .verificationPassed => "verification-passed"
  | .verificationFailed => "verification-failed"
  | .repairPlanned => "repair-planned" | .budgetExhausted => "budget-exhausted"
  | .fatalError => "fatal-error" | .cancelRequested => "cancel-requested"
  | .cancelConfirmed => "cancel-confirmed" | .finish => "finish"

instance : ToString AgentSignal := ⟨AgentSignal.toString⟩

/-- The transition function.

    Three rules are enforced structurally and relied upon by the proofs:

    1. a terminal phase accepts no signal at all, so a finished task can
       never resume;
    2. `verificationFailed` never leads to `completed` — the only route to
       `completed` is `finish`, and the loop only emits `finish` after a
       verification that passed;
    3. `cancelRequested` is accepted from every non-terminal phase, so the
       user can always stop the agent. -/
def AgentPhase.stepLive (p : AgentPhase) (s : AgentSignal) : Option AgentPhase :=
    match s with
    | .cancelRequested => some .cancelling
    | .fatalError => some .failed
    | .budgetExhausted => some .failed
    | .cancelConfirmed => if p == .cancelling then some .cancelled else none
    | other =>
      if p == .cancelling then none else
      match p, other with
      | .idle, .start => some .understanding
      | .understanding, .repositoryInspected => some .inspecting
      | .understanding, .contextReady => some .contextBuilding
      | .inspecting, .contextReady => some .contextBuilding
      | .contextBuilding, .planReady => some .planning
      | .contextBuilding, .modelRequested => some .awaitingModel
      | .planning, .modelRequested => some .awaitingModel
      | .planning, .planReady => some .planning
      | .awaitingModel, .modelReplied => some .observing
      | .awaitingModel, .toolRequested => some .executing
      | .executing, .toolFinished => some .observing
      | .observing, .toolRequested => some .executing
      | .observing, .modelRequested => some .awaitingModel
      | .observing, .verifyRequested => some .verifying
      | .observing, .finish => some .completed
      | .verifying, .verificationPassed => some .observing
      | .verifying, .verificationFailed => some .diagnosing
      | .diagnosing, .repairPlanned => some .replanning
      | .diagnosing, .finish => some .failed
      | .replanning, .modelRequested => some .awaitingModel
      | .replanning, .planReady => some .planning
      | _, _ => none

/-- Terminal phases accept nothing; everything else defers to `stepLive`. -/
def AgentPhase.step (p : AgentPhase) (s : AgentSignal) : Option AgentPhase :=
  if p.isTerminal then none else p.stepLive s

/-! ### Plans -/

inductive StepStatus where
  | pending | active | done | failed | skipped
  deriving Repr, DecidableEq, Inhabited

def StepStatus.toString : StepStatus → String
  | .pending => "pending" | .active => "active" | .done => "done"
  | .failed => "failed" | .skipped => "skipped"

instance : ToString StepStatus := ⟨StepStatus.toString⟩

def StepStatus.marker : StepStatus → String
  | .pending => "○" | .active => "◐" | .done => "●"
  | .failed => "✗" | .skipped => "–"

structure PlanStep where
  id           : Nat
  description  : String
  status       : StepStatus := .pending
  /-- What the agent expects to be true once this step succeeds. -/
  expected     : String := ""
  /-- Step ids that must complete first. -/
  dependsOn    : List Nat := []
  deriving Repr, Inhabited

structure Plan where
  goal            : String
  assumptions     : List String := []
  steps           : List PlanStep := []
  successCriteria : List String := []
  risks           : List String := []
  deriving Repr, Inhabited

namespace Plan

def isComplete (p : Plan) : Bool :=
  p.steps.all (fun s => s.status == .done || s.status == .skipped)

def nextStep? (p : Plan) : Option PlanStep :=
  p.steps.find? (fun s => s.status == .pending &&
    s.dependsOn.all (fun d => (p.steps.find? (fun t => t.id == d)).all
      (fun t => t.status == .done || t.status == .skipped)))

def setStatus (p : Plan) (id : Nat) (st : StepStatus) : Plan :=
  { p with steps := p.steps.map (fun s => if s.id == id then { s with status := st } else s) }

def render (p : Plan) : String :=
  let header := s!"Plan: {p.goal}"
  let steps := p.steps.map fun s =>
    s!"  {s.status.marker} {s.id}. {s.description}"
  String.intercalate "\n" (header :: steps)

end Plan

/-! ### Verification results -/

inductive VerificationOutcome where
  | passed
  | failed
  /-- Nothing to check: no build system, no tests, nothing to compare. -/
  | inconclusive
  deriving Repr, DecidableEq, Inhabited

def VerificationOutcome.toString : VerificationOutcome → String
  | .passed => "passed" | .failed => "failed" | .inconclusive => "inconclusive"

instance : ToString VerificationOutcome := ⟨VerificationOutcome.toString⟩

structure CheckResult where
  name    : String
  outcome : VerificationOutcome
  detail  : String
  deriving Repr, Inhabited

structure VerificationResult where
  outcome : VerificationOutcome
  checks  : List CheckResult
  /-- Evidence the agent must cite when reporting success. -/
  summary : String
  deriving Repr, Inhabited

/-- A verification passes only when it ran at least one check and none of
    them failed.  Encoded here rather than at each call site so the
    "inconclusive is not success" rule cannot be forgotten. -/
def VerificationResult.ofChecks (checks : List CheckResult) : VerificationResult :=
  let failed := checks.filter (fun c => c.outcome == .failed)
  let passed := checks.filter (fun c => c.outcome == .passed)
  let outcome :=
    if !failed.isEmpty then VerificationOutcome.failed
    else if passed.isEmpty then VerificationOutcome.inconclusive
    else VerificationOutcome.passed
  { outcome := outcome
    checks := checks
    summary :=
      if !failed.isEmpty then
        s!"{failed.length} check(s) failed: " ++
          String.intercalate ", " (failed.map CheckResult.name)
      else if passed.isEmpty then "no checks could be run"
      else s!"{passed.length} check(s) passed: " ++
          String.intercalate ", " (passed.map CheckResult.name) }

/-! ### Budgets -/

structure BudgetState where
  iterations : Nat := 0
  toolCalls  : Nat := 0
  repairs    : Nat := 0
  startedMs  : Nat := 0
  usage      : Usage := {}
  deriving Inhabited

/-- Why the loop stopped, if it stopped on a budget. -/
inductive BudgetBreach where
  | iterations | toolCalls | repairs | wallClock
  deriving Repr, DecidableEq, Inhabited

def BudgetBreach.toString : BudgetBreach → String
  | .iterations => "iteration limit" | .toolCalls => "tool call limit"
  | .repairs => "repair round limit" | .wallClock => "time limit"

def BudgetState.breach? (s : BudgetState) (b : Budget) (nowMs : Nat) : Option BudgetBreach :=
  if s.iterations >= b.maxIterations then some .iterations
  else if s.toolCalls >= b.maxToolCalls then some .toolCalls
  else if s.repairs >= b.maxRepairRounds then some .repairs
  else if nowMs > s.startedMs + b.wallClockSec * 1000 then some .wallClock
  else none

/-! ### The agent's mutable state -/

structure AgentState where
  phase     : AgentPhase := .idle
  task      : String := ""
  plan      : Option Plan := none
  messages  : List Message := []
  budget    : BudgetState := {}
  /-- Verification result of the most recent check, if any. -/
  lastVerification : Option VerificationResult := none
  /-- Files the agent has modified in this run. -/
  touchedFiles : List String := []
  /-- User steering received mid-run, to be folded into the next model call. -/
  pendingSteer : List String := []
  /-- Whether the operator's directives have been put to the model for a
      closing account.  Asked once per run. -/
  adherenceChecked : Bool := false
  /-- Consecutive replies rejected for breaking a rule from the system
      prompt.  Reset on the first compliant reply. -/
  complianceRetries : Nat := 0
  /-- Cumulative compliance pass/fail across the run. -/
  compliancePasses : Nat := 0
  complianceFailures : Nat := 0
  /-- Injection attempts detected in tool output during this run. -/
  injectionBlocks : Nat := 0
  cancelled : Bool := false
  deriving Inhabited

namespace AgentState

/-- Apply a signal.  Returns `none` for an illegal transition so the caller
    must handle it rather than drifting into an undefined state. -/
def transition (s : AgentState) (sig : AgentSignal) : Option AgentState :=
  (s.phase.step sig).map (fun p => { s with phase := p })

def addMessage (s : AgentState) (m : Message) : AgentState :=
  { s with messages := s.messages ++ [m] }

def noteFile (s : AgentState) (path : String) : AgentState :=
  if s.touchedFiles.contains path then s
  else { s with touchedFiles := s.touchedFiles ++ [path] }

/-- The agent may only report success when the last verification passed.
    Consulted by the loop before emitting `finish`. -/
def mayReportSuccess (s : AgentState) : Bool :=
  match s.lastVerification with
  | some v => v.outcome == .passed
  | none => false

end AgentState

end LeanPrime
