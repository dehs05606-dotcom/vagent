/-
  LeanPrime.Agent.Loop

  The autonomous loop.

  Shape of one iteration:

      budget check -> model call -> tool calls? -> execute -> observe
                                 -> no tool calls -> verify -> done | repair

  Three properties the loop relies on, each proved in
  `LeanPrime.Verification.StateProofs`:

    * a terminal phase absorbs every signal, so the loop cannot resurrect a
      finished run;
    * `completed` is reachable only through the `finish` signal, which this
      loop emits only when `AgentState.mayReportSuccess` holds;
    * budget exhaustion and cancellation always terminate.
-/
import LeanPrime.Agent.Executor
import LeanPrime.Agent.Verifier
import LeanPrime.Agent.Prompt
import LeanPrime.Agent.Planner
import LeanPrime.Context.Manager
import LeanPrime.Model.Provider

open Lean

namespace LeanPrime

/-- Everything one run needs. -/
structure RunEnv where
  provider  : ModelProvider
  registry  : Registry
  toolCtx   : ToolContext
  events    : EventSink
  config    : Config
  workspace : Workspace
  /-- Poll for user steering typed while the agent was working. -/
  pollSteer : IO (List String)

/-- Outcome of a whole run. -/
structure RunOutcome where
  phase   : AgentPhase
  summary : String
  state   : AgentState
  deriving Inhabited

private def emitPhase (env : RunEnv) (old new : AgentPhase) : IO Unit :=
  if old == new then pure () else env.events.emit (.phaseChanged old new)

/-- Apply a signal, reporting an illegal transition rather than ignoring it. -/
private def advance (env : RunEnv) (st : AgentState) (sig : AgentSignal)
    : IO AgentState := do
  match st.transition sig with
  | some next =>
    emitPhase env st.phase next.phase
    return next
  | none =>
    env.events.emit (.errorOccurred
      (err .internal s!"illegal transition: {sig} is not accepted in phase {st.phase}"))
    -- An illegal transition is a bug, not a licence to continue.
    let failed := { st with phase := .failed }
    emitPhase env st.phase failed.phase
    return failed

/-- Build the model request from the current state. -/
private def buildRequest (env : RunEnv) (st : AgentState) : ModelRequest :=
  { messages := st.messages
    tools := env.registry.schemas
    temperature := env.config.provider.temperature
    maxTokens := env.config.provider.maxTokens
    stream := env.config.provider.stream
    toolChoice := "auto" }

/-- Fold pending user steering into the conversation. -/
private def applySteering (env : RunEnv) (st : AgentState) : IO AgentState := do
  let steers ← env.pollSteer
  let all := st.pendingSteer ++ steers
  if all.isEmpty then return st
  let mut s := { st with pendingSteer := [] }
  for t in all do
    env.events.emit (.userSteered t)
    s := s.addMessage (Message.user s!"[user steering, highest priority after policy] {t}")
  return s

/-- Trim conversation history when it outgrows the context budget.

    The system prompt and the first user turn are always kept, and so are the
    most recent turns; the middle is dropped with a marker.  Critical recent
    tool output is never the part that gets cut. -/
private def trimHistory (budget : Nat) (msgs : List Message) : List Message := Id.run do
  let total := msgs.foldl (fun a m => a + m.estimateTokens) 0
  if total <= budget then msgs
  else
    match msgs with
    | [] => []
    | system :: rest =>
      let keepHead := rest.take 1                       -- the task
      go budget system keepHead rest
where
  go (budget : Nat) (system : Message) (keepHead rest : List Message) : List Message := Id.run do
    let tailCandidates := (rest.drop 1).reverse
    let mut kept : List Message := []
    let mut spent := system.estimateTokens +
      keepHead.foldl (fun a m => a + m.estimateTokens) 0
    for m in tailCandidates do
      if spent + m.estimateTokens > budget then break
      kept := m :: kept
      spent := spent + m.estimateTokens
    let dropped := (rest.length - 1) - kept.length
    if dropped == 0 then
      return system :: rest
    return system :: keepHead ++
      [Message.user s!"[{dropped} earlier turn(s) elided to stay within the context budget]"]
      ++ kept

/-- Run the agent until it completes, fails, or is cancelled. -/
partial def runAgent (env : RunEnv) (task : String) : IO RunOutcome := do
  let startedMs ← IO.monoMsNow
  let sessionId ← freshId "s"
  env.events.emit (.sessionStarted sessionId task env.provider.model)

  -- Phase: understanding -> inspecting -> context
  let mut st : AgentState :=
    { task := task, budget := { startedMs := startedMs } }
  st ← advance env st .start
  st ← advance env st .repositoryInspected
  let snap ← scanProject env.workspace
  env.events.emit (.projectDetected snap.kind.toString snap.isGit snap.files.size)
  st ← advance env st .contextReady

  let ctxText := buildContext snap task [] (env.config.budget.contextTokens * 3 / 10)
  let sys := systemPrompt snap.kind.toString snap.isGit env.config.approval env.registry.names
  st := st.addMessage (Message.system sys)
  st := st.addMessage (Message.user (taskPrompt task ctxText ++ "\n\n" ++ planningPrompt))

  let execEnv : ExecutorEnv :=
    { registry := env.registry, toolCtx := env.toolCtx, events := env.events }

  -- Main loop
  repeat
    if st.phase.isTerminal then break

    -- budget
    let now ← IO.monoMsNow
    match st.budget.breach? env.config.budget now with
    | some breach =>
      env.events.emit (.budgetWarning breach.toString st.budget.iterations
        env.config.budget.maxIterations)
      st ← advance env st .budgetExhausted
      break
    | none => pure ()

    st ← applySteering env st
    if st.cancelled then
      st ← advance env st .cancelRequested
      st ← advance env st .cancelConfirmed
      break

    st := { st with budget := { st.budget with iterations := st.budget.iterations + 1 } }
    st := { st with messages := trimHistory env.config.budget.contextTokens st.messages }

    -- model call
    st ← advance env st .modelRequested
    if st.phase.isTerminal then break
    let tokensIn := st.messages.foldl (fun a m => a + m.estimateTokens) 0
    env.events.emit (.modelStarted tokensIn)
    let onEvent : StreamEvent → IO Unit := fun e =>
      match e with
      | .textDelta t => env.events.emit (.modelText t)
      | .reasoningDelta t => env.events.emit (.modelReasoning t)
      | .toolCallStarted _ _ name => env.events.emit (.notice s!"→ {name}")
      | _ => pure ()
    let reply ← env.provider.run (buildRequest env st) onEvent
    match reply with
    | .error e =>
      env.events.emit (.errorOccurred e)
      if e.recoverable && st.budget.repairs < env.config.budget.maxRepairRounds then
        st := { st with budget := { st.budget with repairs := st.budget.repairs + 1 } }
        st := st.addMessage (Message.user
          s!"The previous model call failed: {e.message}. Continue from where you were.")
        st ← advance env st .modelReplied
        continue
      st ← advance env st .fatalError
      break
    | .ok resp =>
      st := { st with budget := { st.budget with usage := st.budget.usage + resp.usage } }
      env.events.emit (.modelFinished resp.finishReason.toString resp.usage)

      -- a numbered plan in the reply becomes structured plan state
      if st.plan.isNone then
        if let some plan := parsePlan task resp.content then
          st := { st with plan := some plan }
          env.events.emit (.planCreated plan)

      -- record the assistant turn exactly as produced
      st := st.addMessage
        { role := .assistant
          content := if resp.content.isEmpty then [] else [.text resp.content]
          toolCalls := resp.toolCalls }

      if !resp.toolCalls.isEmpty then
        st ← advance env st .toolRequested
        if st.phase.isTerminal then break
        -- the plan advances as the agent actually acts
        if let some plan := st.plan then
          let (next, active) := advancePlan plan
          st := { st with plan := some next }
          if let some step := active then
            env.events.emit (.planStepChanged step.id .active step.description)
        for call in resp.toolCalls do
          st := { st with budget := { st.budget with toolCalls := st.budget.toolCalls + 1 } }
          let res ← executeCall execEnv call
          if let some p := touchedPath? call.name res then
            st := st.noteFile p
          st := st.addMessage (Message.toolResult call.id call.name res.content)
        st ← advance env st .toolFinished
        if st.phase.isTerminal then break
        continue

      -- No tool calls: the model believes it is done.
      st ← advance env st .modelReplied

      if resp.finishReason == .length then
        st := st.addMessage (Message.user
          "Your reply was cut off by the token limit. Continue, making tool calls rather \
           than long prose.")
        continue

      -- A reply with no tool calls and no work done yet is the model talking
      -- about the task rather than doing it.  Verification at that point
      -- would check a tree nobody has touched, so push it to act instead.
      if st.budget.toolCalls == 0 then
        if st.budget.iterations >= 3 then
          env.events.emit (.notice "the model produced no tool calls; stopping")
          st ← advance env st .fatalError
          break
        st := st.addMessage (Message.user
          "You have not called any tools yet. Stop describing the work and start doing it: \
           make your first tool call now.")
        continue

      -- Verify before accepting completion.
      st ← advance env st .verifyRequested
      if st.phase.isTerminal then break
      let v ← verify env.workspace env.config env.events st.touchedFiles
      st := { st with lastVerification := some v }
      match v.outcome with
      | .passed =>
        st ← advance env st .verificationPassed
        if st.mayReportSuccess then
          st ← advance env st .finish
        else
          st ← advance env st .fatalError
        break
      | .inconclusive =>
        -- Nothing could be checked.  That is not success, but it is also not
        -- a failure to repair: accept the run and say so in the summary.
        st ← advance env st .verificationPassed
        st ← advance env st .finish
        break
      | .failed =>
        st ← advance env st .verificationFailed
        if st.budget.repairs >= env.config.budget.maxRepairRounds then
          env.events.emit (.notice
            s!"reached the repair limit ({env.config.budget.maxRepairRounds}); stopping")
          st ← advance env st .finish       -- diagnosing --finish--> failed
          break
        st := { st with budget := { st.budget with repairs := st.budget.repairs + 1 } }
        st := st.addMessage (Message.user (repairPrompt (renderFailure v)))
        st ← advance env st .repairPlanned
        continue

  if st.phase == .completed then
    if let some plan := st.plan then
      st := { st with plan := some (completePlan plan) }

  let summary := match st.phase with
    | .completed =>
      let verdict := match st.lastVerification with
        | some v => v.summary
        | none => "no verification was run"
      s!"{verdict}; {st.touchedFiles.length} file(s) changed"
    | .failed => "run failed; see the errors above"
    | .cancelled => "cancelled by the user"
    | other => s!"stopped in phase {other}"
  env.events.emit (.finished st.phase summary)
  return { phase := st.phase, summary := summary, state := st }

end LeanPrime
