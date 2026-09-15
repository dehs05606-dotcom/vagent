/-
  LeanPrime.Agent.Planner

  Plans are structured data, not a blob of prose.

  The model writes its plan as a numbered list — the form it produces
  naturally — and this module parses it into `Plan`, so the UI can show live
  step state and the loop can tell how far the work has got.  Parsing is
  tolerant: an unparseable reply simply yields no plan rather than failing
  the run.
-/
import LeanPrime.Agent.State

namespace LeanPrime

/-- Strip a leading list marker: "1.", "1)", "- ", "* ", "Step 1:". -/
private def stripMarker (line : String) : Option (Nat × String) :=
  let l := trim line
  if l.isEmpty then none else
  let digits := l.toList.takeWhile Char.isDigit
  if digits.isEmpty then none
  else
    let n := (String.ofList digits).toNat?
    let rest := trim ((l.drop digits.length).toString)
    match n with
    | none => none
    | some num =>
      if rest.startsWith "." || rest.startsWith ")" || rest.startsWith ":" then
        let body := trim ((rest.drop 1).toString)
        if body.isEmpty then none else some (num, body)
      else none

/-- Parse a numbered plan out of model prose.

    Requires at least two consecutively numbered items so that an incidental
    "1." in a sentence is not mistaken for a plan. -/
def parsePlan (goal : String) (text : String) : Option Plan :=
  let steps := text.splitOn "\n" |>.filterMap stripMarker
  if steps.length < 2 then none
  else
    let sorted := steps.filter (fun (n, _) => n >= 1 && n <= 40)
    if sorted.length < 2 then none
    else some {
      goal := truncate goal 200
      steps := sorted.map (fun (n, d) =>
        { id := n, description := truncate d 200, status := StepStatus.pending })
      successCriteria := []
      assumptions := []
      risks := [] }

/-- Advance the plan as work happens: the first pending step becomes active,
    and an active step is completed when the agent moves on.

    Deliberately heuristic — the plan is a progress display, not a program
    counter.  The agent's real control flow is the state machine. -/
def advancePlan (p : Plan) : Plan × Option PlanStep :=
  match p.steps.find? (fun s => s.status == .active) with
  | some active =>
    let done := p.setStatus active.id .done
    match done.nextStep? with
    | some next => (done.setStatus next.id .active, some next)
    | none => (done, none)
  | none =>
    match p.nextStep? with
    | some next => (p.setStatus next.id .active, some next)
    | none => (p, none)

/-- Mark the whole plan finished, so the transcript does not end mid-step. -/
def completePlan (p : Plan) : Plan :=
  { p with steps := p.steps.map fun s =>
      if s.status == .done || s.status == .failed then s
      else { s with status := .done } }

end LeanPrime
