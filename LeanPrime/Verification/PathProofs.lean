/-
  LeanPrime.Verification.PathProofs

  Workspace containment.

  `Workspace.resolve` is the single gate every filesystem tool passes
  through.  Its safety rests on one property of the pure segment
  normaliser: whatever a caller (in practice, the model) supplies, the
  normalised segment list contains no `..`, so the joined path cannot climb
  out of the workspace root.
-/
import LeanPrime.Util.Paths

namespace LeanPrime

/-- No segment is an upward traversal. -/
def NoParent (l : List String) : Prop := ∀ x ∈ l, x ≠ ".."

/-- The normaliser never leaves a `..` in its output, for any input, given an
    accumulator that has none.  Proved by induction on the input segments. -/
theorem normalizeGo_noParent :
    ∀ (rest acc : List String), NoParent acc → NoParent (normalizeGo acc rest) := by
  intro rest
  induction rest with
  | nil =>
    intro acc h
    simp only [normalizeGo]
    intro x hx
    exact h x (List.mem_reverse.mp hx)
  | cons s t ih =>
    intro acc h
    simp only [normalizeGo]
    by_cases hs : s == ".."
    · simp only [hs, ite_true]
      cases acc with
      | nil => exact ih [] (by intro x hx; cases hx)
      | cons a as =>
        simp only
        exact ih as (fun x hx => h x (List.mem_cons_of_mem a hx))
    · simp only [hs, Bool.false_eq_true, ite_false]
      refine ih (s :: acc) ?_
      intro x hx
      cases hx with
      | head => simpa using (by simpa using hs)
      | tail _ hmem => exact h x hmem

/-- The public normaliser produces no upward traversal. -/
theorem normalizeSegments_noParent (segs : List String) :
    NoParent (normalizeSegments segs) := by
  unfold normalizeSegments
  exact normalizeGo_noParent segs [] (by intro x hx; cases hx)

/-- Stated in the Boolean form the runtime actually checks: the containment
    test that `Workspace.resolve` performs always succeeds on normalised
    input, so a relative path can never be rejected for a reason other than
    the one the code checks — and can never escape. -/
theorem segmentsContained_normalize (segs : List String) :
    segmentsContained (normalizeSegments segs) = true := by
  unfold segmentsContained
  rw [List.all_eq_true]
  intro x hx
  have h := normalizeSegments_noParent segs x hx
  simpa using h

/-! Concrete corollaries, checked at compile time.  `#guard` evaluates the
    claim during elaboration and fails the build if it is false, without
    introducing the `ofReduceBool` axiom that `native_decide` would. -/

#guard normalizeSegments (pathSegments "../../etc/passwd") == ["etc", "passwd"]

#guard normalizeSegments (pathSegments "src/../../../../root/.ssh/id_rsa")
        == ["root", ".ssh", "id_rsa"]

#guard segmentsContained (normalizeSegments (pathSegments "a/../../../b"))

end LeanPrime
