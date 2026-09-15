/-
  LeanPrime.Agent.Events

  Typed events, and the bus that carries them.

  The agent core emits events and never renders anything.  The TUI, the JSON
  writer and the test harness are all just consumers.  This is what lets the
  same core drive a terminal, a `--json` stream or a future daemon without
  the core knowing which.
-/
import LeanPrime.Agent.State
import LeanPrime.Tools.Tool

open Lean

namespace LeanPrime

inductive AgentEvent where
  | sessionStarted (id : String) (task : String) (model : String)
  | phaseChanged (from_ : AgentPhase) (to : AgentPhase)
  | projectDetected (kind : String) (gitRepo : Bool) (files : Nat)
  | planCreated (plan : Plan)
  | planStepChanged (id : Nat) (status : StepStatus) (description : String)
  | modelStarted (tokensIn : Nat)
  | modelReasoning (text : String)
  | modelText (text : String)
  | modelFinished (reason : String) (usage : Usage)
  | toolRequested (id : String) (name : String) (args : String)
  | toolDecision (name : String) (risk : Risk) (verdict : String) (reason : String)
  | toolStarted (name : String) (summary : String)
  | toolProgress (text : String)
  | toolFinished (name : String) (ok : Bool) (summary : String) (ms : Nat)
  | verificationStarted
  | verificationCheck (name : String) (outcome : VerificationOutcome) (detail : String)
  | verificationFinished (result : VerificationResult)
  | userSteered (text : String)
  /-- A reply was rejected for breaking a rule from the system prompt. -/
  | complianceRejected (attempt : Nat) (violations : String)
  /-- A previously rejected reply now satisfies every checkable rule. -/
  | complianceAccepted (afterAttempts : Nat)
  /-- Prompt integrity was verified (or failed). -/
  | integrityChecked (passed : Bool) (detail : String)
  /-- A prompt injection attempt was detected in tool output. -/
  | injectionBlocked (patterns : List String) (toolName : String)
  /-- The guardian detected behavioral drift and issued a warning. -/
  | guardianWarning (severity : String) (detail : String)
  /-- The guardian rejected a reply for severe drift. -/
  | guardianRejected (detail : String)
  /-- An authority conflict was detected between message levels. -/
  | authorityConflict (higher : String) (lower : String) (phrase : String)
  /-- A behavioral anchor was injected at a conversation boundary. -/
  | anchorInjected (reason : String)
  /-- Instruction distance triggered an early re-assertion. -/
  | distanceTriggered (tokensSince : Nat) (threshold : Nat)
  /-- A prompt custody checkpoint ran. -/
  | custodyChecked (checkpoint : String) (intact : Bool) (detail : String)
  /-- An adversarial review of a reply completed. -/
  | reviewCompleted (verdict : String) (score : Nat) (unsatisfied : Nat)
  /-- A reply was sent back for a rewrite after a failed review. -/
  | reviewRewrite (attempt : Nat) (summary : String)
  /-- The sentinel escalated. -/
  | sentinelAction (action : String) (reason : String)
  /-- The conversation was rolled back to a clean checkpoint. -/
  | conversationRolledBack (discarded : Nat) (toTurn : Nat)
  /-- The run's forensic ledger was sealed at the end. -/
  | ledgerSealed (entries : Nat) (failures : Nat) (sealValue : String) (intact : Bool)
  /-- The interlock refused a tool call before it ran. -/
  | interlockRefused (tool : String) (rules : String)
  /-- The interlock permitted a call but flagged it. -/
  | interlockFlagged (tool : String) (rules : String)
  /-- Behavioural rules were unsatisfied when the run tried to finish. -/
  | behaviorUnsatisfied (count : Nat) (detail : String)
  | budgetWarning (what : String) (used : Nat) (limit : Nat)
  | errorOccurred (e : LPError)
  | notice (text : String)
  | finished (phase : AgentPhase) (summary : String)
  deriving Inhabited

namespace AgentEvent

/-- Structured form for `--json` mode and the audit trail. -/
def toJson : AgentEvent → Json
  | .sessionStarted i t m => Json.mkObj
      [("event", .str "session_started"), ("session", .str i),
       ("task", .str t), ("model", .str m)]
  | .phaseChanged f t => Json.mkObj
      [("event", .str "phase_changed"), ("from", .str f.toString), ("to", .str t.toString)]
  | .projectDetected k g n => Json.mkObj
      [("event", .str "project_detected"), ("kind", .str k), ("git", .bool g),
       ("files", .num (JsonNumber.fromNat n))]
  | .planCreated p => Json.mkObj
      [("event", .str "plan_created"), ("goal", .str p.goal),
       ("steps", .arr (p.steps.toArray.map fun s =>
          Json.mkObj [("id", .num (JsonNumber.fromNat s.id)),
                      ("description", .str s.description)]))]
  | .planStepChanged i st d => Json.mkObj
      [("event", .str "plan_step"), ("id", .num (JsonNumber.fromNat i)),
       ("status", .str st.toString), ("description", .str d)]
  | .modelStarted n => Json.mkObj
      [("event", .str "model_started"), ("tokens_in", .num (JsonNumber.fromNat n))]
  | .modelReasoning t => Json.mkObj [("event", .str "model_reasoning"), ("text", .str t)]
  | .modelText t => Json.mkObj [("event", .str "model_text"), ("text", .str t)]
  | .modelFinished r u => Json.mkObj
      [("event", .str "model_finished"), ("reason", .str r),
       ("total_tokens", .num (JsonNumber.fromNat u.totalTokens))]
  | .toolRequested i n a => Json.mkObj
      [("event", .str "tool_requested"), ("id", .str i), ("tool", .str n),
       ("arguments", .str (truncate a 2000))]
  | .toolDecision n r v why => Json.mkObj
      [("event", .str "tool_decision"), ("tool", .str n), ("risk", .str r.toString),
       ("verdict", .str v), ("reason", .str why)]
  | .toolStarted n s => Json.mkObj
      [("event", .str "tool_started"), ("tool", .str n), ("summary", .str s)]
  | .toolProgress t => Json.mkObj [("event", .str "tool_progress"), ("text", .str t)]
  | .toolFinished n ok s ms => Json.mkObj
      [("event", .str "tool_finished"), ("tool", .str n), ("ok", .bool ok),
       ("summary", .str s), ("duration_ms", .num (JsonNumber.fromNat ms))]
  | .verificationStarted => Json.mkObj [("event", .str "verification_started")]
  | .verificationCheck n o d => Json.mkObj
      [("event", .str "verification_check"), ("check", .str n),
       ("outcome", .str o.toString), ("detail", .str (truncate d 500))]
  | .verificationFinished r => Json.mkObj
      [("event", .str "verification_finished"), ("outcome", .str r.outcome.toString),
       ("summary", .str r.summary)]
  | .userSteered t => Json.mkObj [("event", .str "user_steered"), ("text", .str t)]
  | .complianceRejected n v => Json.mkObj
      [("event", .str "compliance_rejected"), ("attempt", .num (JsonNumber.fromNat n)),
       ("violations", .str v)]
  | .complianceAccepted n => Json.mkObj
      [("event", .str "compliance_accepted"), ("after_attempts", .num (JsonNumber.fromNat n))]
  | .integrityChecked ok d => Json.mkObj
      [("event", .str "integrity_checked"), ("passed", .bool ok), ("detail", .str d)]
  | .injectionBlocked ps tool => Json.mkObj
      [("event", .str "injection_blocked"),
       ("patterns", .arr (ps.toArray.map (fun s => Json.str s))),
       ("tool", .str tool)]
  | .guardianWarning sev detail => Json.mkObj
      [("event", .str "guardian_warning"), ("severity", .str sev),
       ("detail", .str detail)]
  | .guardianRejected detail => Json.mkObj
      [("event", .str "guardian_rejected"), ("detail", .str detail)]
  | .authorityConflict higher lower phrase => Json.mkObj
      [("event", .str "authority_conflict"), ("higher", .str higher),
       ("lower", .str lower), ("phrase", .str phrase)]
  | .anchorInjected reason => Json.mkObj
      [("event", .str "anchor_injected"), ("reason", .str reason)]
  | .distanceTriggered tokens threshold => Json.mkObj
      [("event", .str "distance_triggered"),
       ("tokens_since", .num (JsonNumber.fromNat tokens)),
       ("threshold", .num (JsonNumber.fromNat threshold))]
  | .custodyChecked cp intact detail => Json.mkObj
      [("event", .str "custody_checked"), ("checkpoint", .str cp),
       ("intact", .bool intact), ("detail", .str detail)]
  | .reviewCompleted verdict score unsat => Json.mkObj
      [("event", .str "review_completed"), ("verdict", .str verdict),
       ("score", .num (JsonNumber.fromNat score)),
       ("unsatisfied", .num (JsonNumber.fromNat unsat))]
  | .reviewRewrite attempt summary => Json.mkObj
      [("event", .str "review_rewrite"),
       ("attempt", .num (JsonNumber.fromNat attempt)),
       ("summary", .str (truncate summary 500))]
  | .sentinelAction action reason => Json.mkObj
      [("event", .str "sentinel_action"), ("action", .str action),
       ("reason", .str reason)]
  | .conversationRolledBack discarded toTurn => Json.mkObj
      [("event", .str "conversation_rolled_back"),
       ("discarded", .num (JsonNumber.fromNat discarded)),
       ("to_turn", .num (JsonNumber.fromNat toTurn))]
  | .ledgerSealed entries failures sealValue intact => Json.mkObj
      [("event", .str "ledger_sealed"),
       ("entries", .num (JsonNumber.fromNat entries)),
       ("failures", .num (JsonNumber.fromNat failures)),
       ("seal", .str sealValue), ("intact", .bool intact)]
  | .interlockRefused tool rules => Json.mkObj
      [("event", .str "interlock_refused"), ("tool", .str tool), ("rules", .str rules)]
  | .interlockFlagged tool rules => Json.mkObj
      [("event", .str "interlock_flagged"), ("tool", .str tool), ("rules", .str rules)]
  | .behaviorUnsatisfied n detail => Json.mkObj
      [("event", .str "behavior_unsatisfied"),
       ("count", .num (JsonNumber.fromNat n)), ("detail", .str detail)]
  | .budgetWarning w u l => Json.mkObj
      [("event", .str "budget_warning"), ("what", .str w),
       ("used", .num (JsonNumber.fromNat u)), ("limit", .num (JsonNumber.fromNat l))]
  | .errorOccurred e => Json.mkObj [("event", .str "error"), ("error", LPError.toJson e)]
  | .notice t => Json.mkObj [("event", .str "notice"), ("text", .str t)]
  | .finished p s => Json.mkObj
      [("event", .str "finished"), ("phase", .str p.toString), ("summary", .str s)]

end AgentEvent

/-- A consumer of agent events. -/
structure EventSink where
  emit : AgentEvent → IO Unit

def EventSink.none_ : EventSink := ⟨fun _ => pure ()⟩

/-- Fan out to several sinks (for example TUI plus audit log). -/
def EventSink.tee (a b : EventSink) : EventSink :=
  ⟨fun e => do a.emit e; b.emit e⟩

/-- Collect events in memory; used by the test suite. -/
def EventSink.collecting (ref : IO.Ref (Array AgentEvent)) : EventSink :=
  ⟨fun e => ref.modify (·.push e)⟩

end LeanPrime
