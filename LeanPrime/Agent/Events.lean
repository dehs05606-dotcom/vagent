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
