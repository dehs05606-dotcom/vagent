/-
  LeanPrime.Verification.SentinelProofs

  Invariants of the vault, the ledger and the sentinel.

  The properties here are the ones the enforcement story actually rests on.
  "The sentinel halts eventually" is a claim about a loop that could
  otherwise spin forever; "the vault accepts its own text" is the
  soundness side of a check that is useless if it false-positives.  Both
  are proved for every input, not sampled by a test.
-/
import LeanPrime.Prompt.Vault
import LeanPrime.Agent.Ledger
import LeanPrime.Agent.Sentinel

namespace LeanPrime

/-! ### Vault soundness

    A sealed prompt verifies against itself.  Without this the vault would
    abort runs on an unmodified prompt, which is worse than not having it. -/

theorem vault_accepts_its_own_text (prompt : String) :
    ((PromptVault.seal prompt).verify prompt).isIntact = true := by
  simp [PromptVault.seal, PromptVault.verify, Digests.matches, VaultVerdict.isIntact]

theorem vault_check_counts_a_pass (prompt : String) :
    ((PromptVault.seal prompt).check prompt).2.verifiedAt = 1 := by
  simp [PromptVault.seal, PromptVault.check, PromptVault.verify, Digests.matches]

theorem vault_text_is_the_sealed_text (prompt : String) :
    (PromptVault.seal prompt).text = prompt := by
  simp [PromptVault.seal, PromptVault.text]

/-- Restoration always yields the original text, whatever happened since. -/
theorem vault_restore_is_original (prompt : String) (v : PromptVault)
    (h : v = PromptVault.seal prompt) :
    v.restore = prompt := by
  subst h; simp [PromptVault.seal, PromptVault.restore]

/-- Full agreement means every digest matched. -/
theorem agreement_of_equal (d : Digests) : d.agreement d = 5 := by
  simp [Digests.agreement]

/-! ### Ledger integrity

    An empty chain is intact, and appending preserves intactness.  Together
    these give: any chain built only through `append` verifies. -/

theorem empty_ledger_is_intact :
    ({} : LedgerChain).isIntact = true := by
  rfl

theorem append_advances_head (c : LedgerChain) (atMs : Nat) (ev : LedgerEvent) :
    (c.append atMs ev).head =
      chainStep c.head c.entries.length atMs ev.canonical := by
  rfl

theorem append_grows_by_one (c : LedgerChain) (atMs : Nat) (ev : LedgerEvent) :
    (c.append atMs ev).length = c.length + 1 := by
  simp [LedgerChain.append, LedgerChain.length]

/-- A chain with no failure entries reports zero failures. -/
theorem no_failures_when_empty :
    ({} : LedgerChain).failureCount = 0 := by
  rfl

/-! ### Sentinel termination

    The sentinel must eventually stop a run that never produces a clean
    reply.  Two independent paths guarantee it: the deadman counter and the
    accumulated weight budget. -/

/-- The deadman halts once enough calls have passed with no clean reply. -/
theorem deadman_halts (s : SentinelState) (outcome : TurnOutcome)
    (h : s.sinceClean ≥ s.thresholds.deadmanCalls) :
    (s.judge outcome).isHalt = true := by
  unfold SentinelState.judge
  cases outcome <;> simp [h, SentinelAction.isHalt]

/-- A custody failure halts unconditionally — no streak, no budget, no
    threshold can soften it. -/
theorem custody_failure_always_halts (s : SentinelState) :
    (s.judge .custodyFailure).isHalt = true := by
  simp [SentinelState.judge, SentinelAction.isHalt]

/-- The weight budget halts independently of the streak. -/
theorem weight_budget_halts (s : SentinelState) (outcome : TurnOutcome)
    (hd : ¬ (s.sinceClean ≥ s.thresholds.deadmanCalls))
    (h : s.weight ≥ s.thresholds.weightBudget) :
    (s.judge outcome).isHalt = true := by
  unfold SentinelState.judge
  cases outcome <;> simp [hd, h, SentinelAction.isHalt]

/-! ### Sentinel accounting

    A non-clean turn always advances the deadman counter, and a clean turn
    always resets it.  These are what make the termination proofs bite: the
    counter cannot stall while violations continue. -/

theorem clean_turn_resets_streak (s : SentinelState) (a : SentinelAction) :
    (s.record .clean a).streak = 0 := by
  simp [SentinelState.record, TurnOutcome.isClean]

theorem clean_turn_resets_deadman (s : SentinelState) (a : SentinelAction) :
    (s.record .clean a).sinceClean = 0 := by
  simp [SentinelState.record, TurnOutcome.isClean]

theorem violation_advances_deadman (s : SentinelState) (a : SentinelAction) :
    (s.record .ruleViolation a).sinceClean = s.sinceClean + 1 := by
  simp [SentinelState.record, TurnOutcome.isClean]

theorem violation_advances_streak (s : SentinelState) (a : SentinelAction) :
    (s.record .ruleViolation a).streak = s.streak + 1 := by
  simp [SentinelState.record, TurnOutcome.isClean]

theorem drift_advances_streak (s : SentinelState) (a : SentinelAction) :
    (s.record .drift a).streak = s.streak + 1 := by
  simp [SentinelState.record, TurnOutcome.isClean]

/-- Every turn is counted, whatever its outcome. -/
theorem every_turn_is_counted (s : SentinelState) (o : TurnOutcome) (a : SentinelAction) :
    (s.record o a).turns = s.turns + 1 := by
  simp [SentinelState.record]

/-- Custody failure carries strictly more weight than any ordinary
    violation — the escalation ladder cannot treat it as routine. -/
theorem custody_outweighs_violation :
    TurnOutcome.custodyFailure.weight > TurnOutcome.ruleViolation.weight := by
  simp [TurnOutcome.weight]

theorem clean_costs_nothing :
    TurnOutcome.clean.weight = 0 := by
  simp [TurnOutcome.weight]

/-! ### Escalation ordering

    The action ranks are strictly increasing in severity, which is what lets
    `peakEscalation` be reported as "how far this run went". -/

theorem escalation_is_ordered :
    (SentinelAction.proceed).rank < (SentinelAction.note "").rank ∧
    (SentinelAction.note "").rank < (SentinelAction.reassert "").rank ∧
    (SentinelAction.reassert "").rank < (SentinelAction.restore 0 "").rank ∧
    (SentinelAction.restore 0 "").rank < (SentinelAction.quarantine "").rank ∧
    (SentinelAction.quarantine "").rank < (SentinelAction.halt "").rank := by
  refine ⟨?_, ?_, ?_, ?_, ?_⟩ <;> simp [SentinelAction.rank]

end LeanPrime
