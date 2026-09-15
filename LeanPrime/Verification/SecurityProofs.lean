/-
  LeanPrime.Verification.SecurityProofs

  Invariants of the permission engine.

  These are not decorative.  Each one rules out a specific way an autonomous
  agent can go wrong, and because `Policy.decide` is pure and total, the
  properties hold for *every* input the model can produce — not just the
  inputs a test happens to try.
-/
import LeanPrime.Security.Permissions

namespace LeanPrime

/-- **A forbidden requirement is never allowed, in any approval mode.**

    This covers the deny list and unparseable commands.  Note it holds even
    for `yolo`: there is no mode in which the user's deny list is bypassed. -/
theorem forbidden_never_allowed (p : Policy) (r : Requirement)
    (h : r.risk = .forbidden) : (p.decide r).isAllow = false := by
  unfold Policy.decide
  simp [h, Decision.isAllow]

/-- Stronger form: a forbidden requirement is explicitly denied, not merely
    left un-allowed (so the user always sees a reason). -/
theorem forbidden_is_denied (p : Policy) (r : Requirement)
    (h : r.risk = .forbidden) : (p.decide r).isDeny = true := by
  unfold Policy.decide
  simp [h, Decision.isDeny]

/-- **A command on the deny list always classifies as forbidden**, whatever
    else appears on the command line. -/
theorem denied_command_is_forbidden (denied : List String) (cmdline : String)
    (h : denied.contains (commandHead cmdline) = true) :
    (classifyCommand denied cmdline).risk = .forbidden := by
  have hm : commandHead cmdline ∈ denied := by simpa using h
  simp [classifyCommand, hm]

/-- **Composition of the two: a denied command can never execute.**
    This is the property the executor relies on. -/
theorem denied_command_never_allowed (p : Policy) (cmdline : String)
    (h : p.deniedCommands.contains (commandHead cmdline) = true) :
    (p.decide (classifyCommand p.deniedCommands cmdline)).isAllow = false :=
  forbidden_never_allowed p _ (denied_command_is_forbidden _ _ h)

/-- **A read-only session cannot perform a mutating action.** -/
theorem readOnly_denies_mutation (p : Policy) (r : Requirement)
    (hmode : p.mode = .readOnly)
    (hmut : r.permissions.any Permission.isMutating = true) :
    (p.decide r).isDeny = true := by
  unfold Policy.decide
  by_cases hf : r.risk = .forbidden
  · simp [hf, Decision.isDeny]
  · have : (r.risk == Risk.forbidden) = false := by
      simp [beq_eq_false_iff_ne, hf]
    simp [this, hmode, hmut, Decision.isDeny]

/-- **`ask` mode never silently performs a mutating action**: every mutating
    requirement either prompts or is denied, never `allow`. -/
theorem ask_mode_never_silently_mutates (p : Policy) (r : Requirement)
    (hmode : p.mode = .ask)
    (hmut : r.permissions.any Permission.isMutating = true) :
    (p.decide r).isAllow = false := by
  unfold Policy.decide
  by_cases hf : r.risk = .forbidden
  · simp [hf, Decision.isAllow]
  · have hne : (r.risk == Risk.forbidden) = false := by
      simp [beq_eq_false_iff_ne, hf]
    simp [hne, hmode, hmut, Decision.isAllow]

/-- **High-risk work is never auto-approved in `auto` mode.**  This is the
    guarantee behind the default: the agent moves on its own for safe work
    and stops for the rest. -/
theorem auto_never_allows_high (p : Policy) (r : Requirement)
    (hmode : p.mode = .auto) (hrisk : r.risk = .high) :
    (p.decide r).isAllow = false := by
  unfold Policy.decide
  have hne : (r.risk == Risk.forbidden) = false := by
    simp [beq_eq_false_iff_ne, hrisk]
  by_cases hro : p.mode = .readOnly
  · rw [hmode] at hro; exact absurd hro (by simp)
  · simp [hne, hmode, hrisk, Decision.isAllow]

/-- Escalation step: with chaining present, the result is never `low`. -/
theorem escalateChaining_not_low (cmdline : String) (base : Requirement)
    (hchain : hasShellChaining cmdline = true) :
    (escalateChaining cmdline base).risk ≠ .low := by
  unfold escalateChaining
  split
  · simp
  · rename_i hcond
    intro hlow
    exact hcond (by simp [hchain, hlow, Risk.rank])

/-- **Shell chaining can never be classified as low risk.**  Without this, an
    approved `ls` could smuggle `ls && rm -rf ~` past the classifier. -/
theorem chaining_is_not_low (denied : List String) (cmdline : String)
    (hchain : hasShellChaining cmdline = true)
    (hhead : denied.contains (commandHead cmdline) = false)
    (hne : (commandHead cmdline).isEmpty = false) :
    (classifyCommand denied cmdline).risk ≠ .low := by
  simp only [classifyCommand, hhead, hne, if_false, Bool.false_eq_true]
  exact escalateChaining_not_low cmdline _ hchain

end LeanPrime
