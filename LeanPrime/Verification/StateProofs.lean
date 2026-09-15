/-
  LeanPrime.Verification.StateProofs

  Invariants of the agent state machine.

  Each theorem rules out a specific failure mode of an autonomous loop.
  Because `AgentPhase.step` is total and pure, these hold for every run, not
  just the ones a test exercises.
-/
import LeanPrime.Agent.State

namespace LeanPrime

/-- **A finished task never resumes.**  No signal whatsoever moves the agent
    out of a terminal phase, so a completed, failed or cancelled run cannot
    drift back into executing tools. -/
theorem terminal_is_absorbing (p : AgentPhase) (s : AgentSignal)
    (h : p.isTerminal = true) : p.step s = none := by
  unfold AgentPhase.step
  simp [h]

/-- Specialisation: completion is final. -/
theorem completed_never_resumes (s : AgentSignal) :
    AgentPhase.completed.step s = none :=
  terminal_is_absorbing _ s rfl

/-- Specialisation: a cancelled run stays cancelled. -/
theorem cancelled_never_resumes (s : AgentSignal) :
    AgentPhase.cancelled.step s = none :=
  terminal_is_absorbing _ s rfl

/-- **A failed verification can never produce completion.**  The only
    transition out of `verifying` on failure is into `diagnosing`. -/
theorem verificationFailed_never_completes (p : AgentPhase) :
    p.step .verificationFailed ≠ some .completed := by
  intro h
  unfold AgentPhase.step at h
  split at h
  · exact absurd h (by simp)
  · cases p <;> simp_all [AgentPhase.stepLive, AgentPhase.isTerminal]

/-- **Nothing reaches `completed` except by the `finish` signal.**  The agent
    loop emits `finish` only when `AgentState.mayReportSuccess` holds, so
    this is the structural half of "never claim success unverified". -/
theorem completed_only_via_finish (p : AgentPhase) (s : AgentSignal)
    (h : p.step s = some .completed) : s = .finish := by
  unfold AgentPhase.step at h
  split at h
  · exact absurd h (by simp)
  · cases s <;> cases p <;> simp_all [AgentPhase.stepLive, AgentPhase.isTerminal]

/-- **The user can always stop the agent.**  From every non-terminal phase,
    a cancel request is accepted and moves into `cancelling`. -/
theorem cancel_always_accepted (p : AgentPhase) (h : p.isTerminal = false) :
    p.step .cancelRequested = some .cancelling := by
  unfold AgentPhase.step
  simp [h, AgentPhase.stepLive]

/-- **A fatal error always terminates.** -/
theorem fatal_always_fails (p : AgentPhase) (h : p.isTerminal = false) :
    p.step .fatalError = some .failed := by
  unfold AgentPhase.step
  simp [h, AgentPhase.stepLive]

/-- **An exhausted budget always terminates**, so a runaway loop cannot
    continue by ignoring its limits. -/
theorem budget_always_fails (p : AgentPhase) (h : p.isTerminal = false) :
    p.step .budgetExhausted = some .failed := by
  unfold AgentPhase.step
  simp [h, AgentPhase.stepLive]

/-- **Cancellation cannot be undone into ordinary work**: once cancelling,
    the only accepted signals are the terminal ones. -/
theorem cancelling_only_terminates (s : AgentSignal)
    (h : AgentPhase.cancelling.step s ≠ none) :
    AgentPhase.cancelling.step s = some .cancelling
      ∨ AgentPhase.cancelling.step s = some .failed
      ∨ AgentPhase.cancelling.step s = some .cancelled := by
  cases s <;> simp_all [AgentPhase.step, AgentPhase.stepLive, AgentPhase.isTerminal]

/-- **Success requires evidence.**  An agent state whose last verification is
    absent or non-passing may not report success.  Together with
    `completed_only_via_finish` this is the pair of facts behind the rule
    "never say done before verifying". -/
theorem success_requires_passed_verification (st : AgentState)
    (h : st.mayReportSuccess = true) :
    ∃ v, st.lastVerification = some v ∧ v.outcome = .passed := by
  unfold AgentState.mayReportSuccess at h
  cases hv : st.lastVerification with
  | none => rw [hv] at h; simp at h
  | some v =>
    rw [hv] at h
    exact ⟨v, rfl, by simpa using h⟩

/-- **An inconclusive verification is not a pass.**  When no check could run,
    `ofChecks` reports `inconclusive`, and `mayReportSuccess` rejects it. -/
theorem no_checks_is_not_passed :
    (VerificationResult.ofChecks []).outcome = .inconclusive := by
  rfl

/-- **Any failing check makes the whole verification fail**, whatever else
    passed alongside it. -/
theorem failing_check_fails_verification (checks : List CheckResult)
    (h : (checks.filter (fun c => c.outcome == .failed)) ≠ []) :
    (VerificationResult.ofChecks checks).outcome = .failed := by
  unfold VerificationResult.ofChecks
  simp [h]

end LeanPrime
