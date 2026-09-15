/-
  LeanPrime.Verification.AxiomAudit

  A build-time guard on the proofs.

  `#print axioms` reports what a theorem actually rests on.  Wrapping each
  in `#guard_msgs` turns that report into a build failure if it ever
  changes — so a `sorry` slipped into a proof, or a switch to
  `native_decide` (which would add `Lean.ofReduceBool`), breaks the build
  rather than quietly weakening a guarantee that this project advertises.

  `propext` is one of Lean's three standard axioms and is what `simp` uses
  to rewrite propositions; depending on it is ordinary.
-/
import LeanPrime.Verification.SecurityProofs
import LeanPrime.Verification.StateProofs
import LeanPrime.Verification.PathProofs

namespace LeanPrime

/-- info: 'LeanPrime.forbidden_never_allowed' depends on axioms: [propext] -/
#guard_msgs in #print axioms forbidden_never_allowed

/-- info: 'LeanPrime.denied_command_never_allowed' depends on axioms: [propext, Classical.choice, Quot.sound] -/
#guard_msgs in #print axioms denied_command_never_allowed

/-- info: 'LeanPrime.readOnly_denies_mutation' depends on axioms: [propext] -/
#guard_msgs in #print axioms readOnly_denies_mutation

/-- info: 'LeanPrime.ask_mode_never_silently_mutates' depends on axioms: [propext] -/
#guard_msgs in #print axioms ask_mode_never_silently_mutates

/-- info: 'LeanPrime.auto_never_allows_high' depends on axioms: [propext, Quot.sound] -/
#guard_msgs in #print axioms auto_never_allows_high

/-- info: 'LeanPrime.chaining_is_not_low' depends on axioms: [propext, Classical.choice, Quot.sound] -/
#guard_msgs in #print axioms chaining_is_not_low

/-- info: 'LeanPrime.normalizeSegments_noParent' depends on axioms: [propext] -/
#guard_msgs in #print axioms normalizeSegments_noParent

/-- info: 'LeanPrime.segmentsContained_normalize' depends on axioms: [propext, Quot.sound] -/
#guard_msgs in #print axioms segmentsContained_normalize

/-- info: 'LeanPrime.terminal_is_absorbing' depends on axioms: [propext] -/
#guard_msgs in #print axioms terminal_is_absorbing

/-- info: 'LeanPrime.completed_only_via_finish' depends on axioms: [propext] -/
#guard_msgs in #print axioms completed_only_via_finish

/-- info: 'LeanPrime.verificationFailed_never_completes' depends on axioms: [propext] -/
#guard_msgs in #print axioms verificationFailed_never_completes

/-- info: 'LeanPrime.cancel_always_accepted' depends on axioms: [propext] -/
#guard_msgs in #print axioms cancel_always_accepted

/-- info: 'LeanPrime.budget_always_fails' depends on axioms: [propext] -/
#guard_msgs in #print axioms budget_always_fails

/-- info: 'LeanPrime.success_requires_passed_verification' depends on axioms: [propext] -/
#guard_msgs in #print axioms success_requires_passed_verification

/-- info: 'LeanPrime.failing_check_fails_verification' depends on axioms: [propext] -/
#guard_msgs in #print axioms failing_check_fails_verification

end LeanPrime
