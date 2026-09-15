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
import LeanPrime.Agent.PromptLayers
import LeanPrime.Agent.Guardian
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
  /-- The assembled system prompt and the operator's extracted rules. -/
  prompts   : PromptStack
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

    Three classes of message survive unconditionally: the system prompt, the
    original task, and anything marked `pinned` — which is how the
    operator's instructions and their re-assertions are protected.  Of the
    rest, the most recent turns are kept and the middle is elided, so recent
    tool output (what the agent is currently reasoning about) is never what
    gets cut.

    Pinned messages keep their original position, so the conversation still
    reads in order after a trim. -/
def trimHistory (budget : Nat) (msgs : List Message) : List Message := Id.run do
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
    let body := rest.drop 1
    let indexed := body.zipIdx
    let pinnedSpend := body.foldl (fun a m => if m.pinned then a + m.estimateTokens else a) 0
    -- Walk backwards, keeping the most recent unpinned turns that fit.  Track
    -- positions rather than contents: two turns can carry identical text, and
    -- matching on content would keep every copy of a repeated message.
    let mut keepIdx : List Nat := []
    let mut spent := system.estimateTokens +
      keepHead.foldl (fun a m => a + m.estimateTokens) 0 + pinnedSpend
    for (m, i) in indexed.reverse do
      if m.pinned then continue
      if spent + m.estimateTokens > budget then break
      keepIdx := i :: keepIdx
      spent := spent + m.estimateTokens
    let dropped := body.length - body.countP Message.pinned - keepIdx.length
    if dropped == 0 then
      return system :: rest
    -- Reassemble in original order, so pinned turns stay where they were.
    let keptOrPinned := indexed.filterMap fun (m, i) =>
      if m.pinned || keepIdx.contains i then some m else none
    return system :: keepHead ++
      [Message.user s!"[{dropped} earlier turn(s) elided to stay within the context budget]"]
      ++ keptOrPinned

/-- Run the agent until it completes, fails, or is cancelled. -/
partial def runAgent (env : RunEnv) (task : String) : IO RunOutcome := do
  let startedMs ← IO.monoMsNow
  let sessionId ← freshId "s"
  env.events.emit (.sessionStarted sessionId task env.provider.model)

  let rules := env.prompts.rules
  let retryLimit := env.config.prompt.maxComplianceRetries
  let promptHash := PromptIntegrity.compute env.prompts.render
  let mut guardianSt := initGuardian env.prompts.render env.prompts.directives

  -- Phase: understanding -> inspecting -> context
  let mut st : AgentState :=
    { task := task, budget := { startedMs := startedMs } }
  st ← advance env st .start
  st ← advance env st .repositoryInspected
  let snap ← scanProject env.workspace
  env.events.emit (.projectDetected snap.kind.toString snap.isGit snap.files.size)
  st ← advance env st .contextReady

  let ctxText := buildContext snap task [] (env.config.budget.contextTokens * 3 / 10)
                   env.config.dataFencing
  -- The system prompt is exactly the text of SystemPrompt.lean, after
  -- template substitution. Nothing is prepended or appended to it.
  st := st.addMessage { Message.system env.prompts.render with pinned := true }
  st := st.addMessage { Message.user (taskPrompt task ctxText) with pinned := true }
  -- State the rules once more as an enumerated checklist. Prose in a system
  -- prompt is easy to skim past; a numbered list is not.
  if !env.prompts.directives.isEmpty then
    env.events.emit (.notice
      s!"{env.prompts.directives.length} directive(s) in force, {rules.length} enforced")
    st := st.addMessage
      { Message.user (reminderMessage env.prompts.directives) with pinned := true }

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

    -- Re-assert the operator's rules on a cadence.  Adherence decays with
    -- distance, not with time: by iteration ten the original instruction is
    -- far behind a wall of tool output and is competing with it for
    -- attention.  Restating it periodically is what keeps a long run on
    -- instruction.
    let cadence := env.config.prompt.reminderEvery
    if cadence > 0 && !env.prompts.directives.isEmpty
        && st.budget.iterations > 1 && st.budget.iterations % cadence == 1 then
      st := st.addMessage
        { Message.user (reminderMessage env.prompts.directives) with pinned := true }

    st := { st with messages := trimHistory env.config.budget.contextTokens st.messages }

    -- Restate the rules immediately before the call as well.  The top of the
    -- conversation is the strongest position for authority; the bottom is the
    -- strongest position for recency.  With this on, the rules hold both.
    if env.config.prompt.restateBeforeEveryCall && !env.prompts.directives.isEmpty then
      st := st.addMessage
        { Message.user (reminderMessage env.prompts.directives) with pinned := false }

    -- Prompt integrity gate: verify the system prompt message has not been
    -- altered since the run started.  Any mutation — accidental or injected —
    -- is a hard stop: continuing with a different instruction set defeats
    -- the purpose of having one.
    match st.messages.head? with
    | some sysMsg =>
      let sysText := sysMsg.plainText
      if !promptHash.verify sysText then
        env.events.emit (.integrityChecked false
          "system prompt message was altered mid-run")
        env.events.emit (.errorOccurred (err .internal
          "prompt integrity failure: the system prompt message in the conversation \
           no longer matches the original; aborting"))
        st ← advance env st .fatalError
        break
    | none => pure ()

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

      -- Mechanical compliance gate with cascading enforcement.
      --
      -- This is the part that does not rely on the model agreeing. A reply
      -- that breaks a checkable rule from SystemPrompt.lean is rejected here
      -- and never enters the conversation as an assistant turn: the model is
      -- handed the exact rule and the exact text it produced, and asked
      -- again with escalating severity.
      --
      -- Escalation: gentle (attempt 1) → firm (attempt 2) → explicit (attempt 3) → abort.
      if !rules.isEmpty && resp.toolCalls.isEmpty && !resp.content.isEmpty then
        let violations := checkCompliance rules resp.content
        if !violations.isEmpty then
          st := { st with complianceFailures := st.complianceFailures + 1 }
          if st.complianceRetries >= retryLimit then
            env.events.emit (.errorOccurred (err .verification
              s!"the reply still breaks {violations.length} rule(s) after \
                 {retryLimit} attempt(s) with escalating correction"
              (some (violationSummary violations))
              (some "check that the rule in SystemPrompt.lean is satisfiable")))
            st ← advance env st .fatalError
            break
          st := { st with complianceRetries := st.complianceRetries + 1 }
          let level := correctionLevelOf st.complianceRetries
          env.events.emit (.complianceRejected st.complianceRetries
            (violationSummary violations))
          st := st.addMessage
            { Message.user (cascadingCorrection violations level) with pinned := false }
          continue
        else
          st := { st with compliancePasses := st.compliancePasses + 1 }
          if st.complianceRetries > 0 then
            env.events.emit (.complianceAccepted st.complianceRetries)
            st := { st with complianceRetries := 0 }

      -- Guardian: semantic compliance, drift detection, authority enforcement.
      -- Runs after mechanical compliance passes.  A warning feeds correction
      -- back; a rejection (severe drift) is treated like a compliance failure.
      if resp.toolCalls.isEmpty && !resp.content.isEmpty then
        let verdict := guardianCheck rules guardianSt.semanticConstraints
          env.prompts.render task resp.content guardianSt
        guardianSt := updateGuardianState guardianSt verdict
          resp.usage.totalTokens resp.content
        match verdict.action with
        | .reject detail =>
          st := { st with guardianRejections := st.guardianRejections + 1 }
          env.events.emit (.guardianRejected (truncate detail 200))
          st := st.addMessage { Message.user detail with pinned := false }
          continue
        | .warn message =>
          st := { st with guardianWarnings := st.guardianWarnings + 1 }
          env.events.emit (.guardianWarning
            (match verdict.driftReport with
             | some r => r.severity.toString
             | none => "unknown") (truncate message 200))
          st := st.addMessage { Message.user message with pinned := false }
        | .accept => pure ()
        if verdict.distanceTriggered then
          st := { st with distanceTriggers := st.distanceTriggers + 1 }
          env.events.emit (.distanceTriggered
            guardianSt.distance.tokensSinceLastDirective
            guardianSt.distance.threshold)
          if !env.prompts.directives.isEmpty then
            st := st.addMessage
              { Message.user (reminderMessage env.prompts.directives) with pinned := false }
            guardianSt := { guardianSt with distance := guardianSt.distance.reset }
        if verdict.anchorNeeded && !guardianSt.anchorText.isEmpty then
          st := { st with anchorsInjected := st.anchorsInjected + 1 }
          env.events.emit (.anchorInjected "conversation boundary")
          st := st.addMessage
            { Message.user guardianSt.anchorText with pinned := false }
          guardianSt := { guardianSt with turnsSinceAnchor := 0 }

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
          -- Injection shield: detect prompt-injection patterns in tool output
          -- and wrap the content in a data fence when found.
          let injected := detectInjection res.content
          if !injected.isEmpty then
            st := { st with injectionBlocks := st.injectionBlocks + 1 }
            env.events.emit (.injectionBlocked injected call.name)
            st := st.addMessage (Message.toolResult call.id call.name (shieldText res.content))
          else
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

      -- Before accepting completion, require the model to account for each
      -- of the operator's rules.  Asked once per run: the point is a
      -- deliberate pass over the checklist at the moment it matters, not a
      -- loop that badgers the model into agreeing.
      if env.config.prompt.adherenceCheck && !env.prompts.directives.isEmpty
          && !st.adherenceChecked then
        st := { st with adherenceChecked := true }
        env.events.emit (.notice "checking the work against the operator's directives")
        st := st.addMessage
          { Message.user (adherenceMessage env.prompts.directives) with pinned := true }
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
