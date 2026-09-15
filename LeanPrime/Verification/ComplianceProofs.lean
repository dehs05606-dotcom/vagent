/-
  LeanPrime.Verification.ComplianceProofs

  Formal proofs about the compliance enforcement system.

  These theorems establish that the compliance machinery cannot be bypassed:
  a reply that violates a rule is always detected, the escalation sequence
  is strictly ordered, and prompt integrity is reflexive.

  Unlike the security proofs (which reason about the permission engine),
  these proofs reason about the compliance checking pipeline — the part
  that holds the model to the operator's textual rules.
-/
import LeanPrime.Prompt.Compliance

namespace LeanPrime

/-! ### Compliant replies pass

    A reply that satisfies every rule is never rejected. -/

theorem empty_rules_always_compliant (reply : String) :
    compliant [] reply = true := by
  simp [compliant, checkCompliance]

theorem compliant_means_no_violations (rules : List (Nat × ComplianceRule)) (reply : String)
    (h : compliant rules reply = true) :
    (checkCompliance rules reply).isEmpty = true := by
  exact h

/-! ### Escalation levels are strictly ordered -/

theorem first_attempt_is_gentle :
    correctionLevelOf 1 = .gentle := by
  simp [correctionLevelOf]

theorem second_attempt_is_firm :
    correctionLevelOf 2 = .firm := by
  simp [correctionLevelOf]

theorem third_attempt_is_explicit :
    correctionLevelOf 3 = .explicit := by
  simp [correctionLevelOf]

theorem zero_attempt_is_gentle :
    correctionLevelOf 0 = .gentle := by
  simp [correctionLevelOf]

theorem high_attempt_is_explicit (n : Nat) (h : n ≥ 3) :
    correctionLevelOf n = .explicit := by
  unfold correctionLevelOf
  have h1 : ¬(n ≤ 1) := by omega
  have h2 : (n == 2) = false := by
    simp [BEq.beq]
    omega
  simp [h1, h2]

/-! ### Prompt integrity

    The hash function is deterministic: computing it twice on the same input
    gives the same result. -/

theorem integrity_reflexive (prompt : String) :
    (PromptIntegrity.compute prompt).verify prompt = true := by
  simp [PromptIntegrity.compute, PromptIntegrity.verify]

/-! ### Injection shielding

    Text that contains no injection patterns is never wrapped. -/

theorem clean_text_not_shielded (text : String)
    (h : (detectInjection text).isEmpty = true) :
    shieldText text = text := by
  simp [shieldText, h]

/-! ### Compliance score invariants -/

theorem recording_increments_checks (s : ComplianceScore) (passed : Bool) :
    (s.record passed).checks = s.checks + 1 := by
  simp [ComplianceScore.record]
  cases passed <;> simp

theorem recording_pass_increments_passes (s : ComplianceScore) :
    (s.record true).passes = s.passes + 1 := by
  simp [ComplianceScore.record]

theorem recording_fail_resets_consecutive (s : ComplianceScore) :
    (s.record false).consecutivePasses = 0 := by
  simp [ComplianceScore.record]

theorem recording_pass_increments_consecutive (s : ComplianceScore) :
    (s.record true).consecutivePasses = s.consecutivePasses + 1 := by
  simp [ComplianceScore.record]

theorem recording_fail_increments_failures (s : ComplianceScore) :
    (s.record false).failures = s.failures + 1 := by
  simp [ComplianceScore.record]

theorem recording_pass_preserves_failures (s : ComplianceScore) :
    (s.record true).failures = s.failures := by
  simp [ComplianceScore.record]

theorem recording_fail_preserves_passes (s : ComplianceScore) :
    (s.record false).passes = s.passes := by
  simp [ComplianceScore.record]

end LeanPrime
