/-
  LeanPrime.Agent.Prompt

  Turn-level framing only.

  The system prompt is not here, and is not anywhere else in this code base:
  it lives entirely in `SystemPrompt.lean` and reaches a run through
  `LeanPrime.Prompt.Source`.  What remains below is the wording of the
  individual turns the loop has to send — the task, the report of a failed
  check.  These carry the loop's own state into the conversation; they
  assert no policy and give the model no instructions.

  If you are looking for where the agent is told how to behave, it is
  `SystemPrompt.lean`.
-/
import LeanPrime.Agent.State
import LeanPrime.Tools.Registry

namespace LeanPrime

/-- The first user turn: the task plus the freshly gathered project context. -/
def taskPrompt (task : String) (context : String) : String :=
  s!"# Task\n\n{task}\n\n# Repository context\n\n{context}"

/-- Report of a failed check, handed back so the agent can act on it.

    States what happened, and nothing about what to do about it: how to
    respond to a failing check is the system prompt's business, not this
    module's. -/
def repairPrompt (failure : String) : String :=
  s!"The verification run failed.\n\n{failure}"

end LeanPrime
