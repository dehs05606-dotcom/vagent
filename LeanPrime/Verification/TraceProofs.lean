/-
  LeanPrime.Verification.TraceProofs

  Invariants of the behavioural predicate engine and the interlock.

  The properties that matter here are the two failure modes a pre-execution
  gate can have.  It can be *unsound* — refusing an action that breaks no
  rule, which stops real work — or *incomplete* — permitting one that does,
  which is the thing it exists to prevent.  The theorems below pin down the
  cases where neither can happen.
-/
import LeanPrime.Agent.Interlock

namespace LeanPrime

/-! ### The gate is closed by construction

    A refusal happens only when a blocking rule actually matched.  Nothing
    else in the module can produce one. -/

theorem no_rules_means_clear (trace : ActionTrace) (p : ProposedAction) :
    interlockCheck [] trace p = .clear := by
  simp [interlockCheck, checkAllProposed]

theorem no_rules_allows_execution (trace : ActionTrace) (p : ProposedAction) :
    (interlockCheck [] trace p).allowsExecution = true := by
  simp [interlockCheck, checkAllProposed, InterlockVerdict.allowsExecution]

/-- A verdict with no blocking violation always permits the call.  This is
    the soundness direction: `warn`-level rules never stop work. -/
theorem no_blocking_violation_permits
    (rules : List BehaviorRule) (trace : ActionTrace) (p : ProposedAction)
    (h : blockingViolations (checkAllProposed rules trace p) = []) :
    (interlockCheck rules trace p).allowsExecution = true := by
  unfold interlockCheck
  cases h' : checkAllProposed rules trace p with
  | nil => simp [InterlockVerdict.allowsExecution]
  | cons a as =>
    rw [h'] at h
    simp [h, InterlockVerdict.allowsExecution]

/-- Every violation in a blocking set really is at `block` level.  This is
    what makes a refusal message honest: it never cites a rule that was
    only ever a warning. -/
theorem blockingViolations_all_block (vs : List BehaviorViolation) :
    (blockingViolations vs).all (fun v => v.rule.level == .block) = true := by
  simp [blockingViolations, List.all_eq_true]

/-- A refusal carries exactly the blocking subset of what matched. -/
theorem refusal_carries_blocking_subset
    (rules : List BehaviorRule) (trace : ActionTrace) (p : ProposedAction)
    (vs : List BehaviorViolation)
    (h : interlockCheck rules trace p = .refused vs) :
    vs = blockingViolations (checkAllProposed rules trace p) := by
  unfold interlockCheck at h
  cases h' : checkAllProposed rules trace p with
  | nil => rw [h'] at h; simp at h
  | cons a as =>
    rw [h'] at h
    dsimp only at h
    cases h'' : blockingViolations (a :: as) with
    | nil => rw [h''] at h; simp at h
    | cons b bs =>
      rw [h''] at h
      simp only [InterlockVerdict.refused.injEq] at h
      exact h.symm

/-! ### Read-before-edit

    The rule that motivated the module.  Both directions are proved: it
    fires when the path is unread, and it abstains when the path was read. -/

theorem readBeforeEdit_blocks_unread
    (rule : BehaviorRule) (trace : ActionTrace) (path : String)
    (hp : rule.predicate = .readBeforeEdit)
    (hunread : trace.wasEverRead path = false) :
    (checkProposed rule trace
      { tool := "edit_file", path := some path }).isSome = true := by
  simp [checkProposed, hp, ProposedAction.isEdit, editingTools, hunread]

theorem readBeforeEdit_permits_read
    (rule : BehaviorRule) (trace : ActionTrace) (path : String)
    (hp : rule.predicate = .readBeforeEdit)
    (hread : trace.wasEverRead path = true) :
    checkProposed rule trace { tool := "edit_file", path := some path } = none := by
  simp [checkProposed, hp, ProposedAction.isEdit, editingTools, hread]

/-- A non-editing call is never stopped by the read-before-edit rule. -/
theorem readBeforeEdit_ignores_reads
    (rule : BehaviorRule) (trace : ActionTrace) (path : String)
    (hp : rule.predicate = .readBeforeEdit) :
    checkProposed rule trace { tool := "read_file", path := some path } = none := by
  simp [checkProposed, hp, ProposedAction.isEdit, editingTools]

/-- A fresh whole-file write is exempt: there is nothing to have read. -/
theorem readBeforeEdit_exempts_fresh_write
    (rule : BehaviorRule) (trace : ActionTrace) (path : String)
    (hp : rule.predicate = .readBeforeEdit) :
    checkProposed rule trace { tool := "write_file", path := some path } = none := by
  simp [checkProposed, hp, ProposedAction.isEdit, editingTools]

/-! ### Forbidden tools -/

theorem neverCallTool_blocks_that_tool
    (rule : BehaviorRule) (trace : ActionTrace) (tool : String)
    (hp : rule.predicate = .neverCallTool tool) :
    (checkProposed rule trace { tool := tool }).isSome = true := by
  simp [checkProposed, hp]

theorem neverCallTool_ignores_others
    (rule : BehaviorRule) (trace : ActionTrace) (tool other : String)
    (hp : rule.predicate = .neverCallTool tool)
    (hne : (other == tool) = false) :
    checkProposed rule trace { tool := other } = none := by
  simp [checkProposed, hp, hne]

/-- A forbidden tool is a blocking rule, so the theorem above actually
    stops the call rather than merely noting it. -/
theorem neverCallTool_is_blocking (tool : String) :
    (BehaviorPredicate.neverCallTool tool).defaultLevel = .block := by
  simp [BehaviorPredicate.defaultLevel]

theorem neverWriteMatching_is_blocking (ms : List String) (label : String) :
    (BehaviorPredicate.neverWriteMatching ms label).defaultLevel = .block := by
  simp [BehaviorPredicate.defaultLevel]

/-! ### Call-count limits -/

theorem maxCallsOf_blocks_at_limit
    (rule : BehaviorRule) (trace : ActionTrace) (tool : String) (n : Nat)
    (hp : rule.predicate = .maxCallsOf tool n)
    (h : trace.countOf tool ≥ n) :
    (checkProposed rule trace { tool := tool }).isSome = true := by
  simp [checkProposed, hp, h]

/-! ### Post-hoc checks

    An empty trace satisfies every "must have happened" rule vacuously,
    because a run that changed nothing has nothing to verify or review.
    Reporting such a run as non-compliant would be wrong. -/

theorem empty_trace_verifies_vacuously :
    ({} : ActionTrace).verifiedSinceLastEdit = true := by
  rfl

theorem empty_trace_diff_reviewed_vacuously :
    ({} : ActionTrace).diffReviewedSinceLastEdit = true := by
  rfl

theorem empty_trace_has_no_unread_edits :
    ({} : ActionTrace).editedUnread = [] := by
  rfl

theorem no_rules_no_final_violations (trace : ActionTrace) :
    checkAllFinal [] trace = [] := by
  simp [checkAllFinal]

/-! ### Trace accounting -/

theorem append_grows_trace (t : ActionTrace) (a : ActionRecord) :
    (t.append a).length = t.length + 1 := by
  simp [ActionTrace.append, ActionTrace.length]

theorem empty_trace_is_empty :
    ({} : ActionTrace).isEmpty = true := by
  rfl

/-! ### Interlock state -/

theorem interlock_with_no_directives_is_inactive :
    (InterlockState.ofDirectives []).isActive = false := by
  simp [InterlockState.ofDirectives, InterlockState.isActive, compileBehaviorRules]

theorem observe_grows_the_trace (s : InterlockState) (tool : String)
    (args : Lean.Json) (ok : Bool) (ms : Nat) :
    (s.observe tool args ok ms).trace.length = s.trace.length + 1 := by
  simp [InterlockState.observe, ActionTrace.append, ActionTrace.length]

end LeanPrime
