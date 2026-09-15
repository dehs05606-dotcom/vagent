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
import LeanPrime.Agent.Sentinel
import LeanPrime.Agent.Adversary
import LeanPrime.Agent.Interlock
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
  let pcfg := env.config.prompt
  let retryLimit := pcfg.maxComplianceRetries
  let mut guardianSt := initGuardian env.prompts.render env.prompts.directives

  -- Seal the prompt.  Every later read of it goes through the vault, and
  -- every custody checkpoint compares the conversation's system message
  -- against this seal.
  let mut vault := PromptVault.seal env.prompts.render
  let mut ledger : LedgerChain := {}
  let mut sentinel : SentinelState :=
    { thresholds := { haltAfter := if pcfg.haltAfterFailures == 0 then 1000
                                   else pcfg.haltAfterFailures } }
  let reviewPolicy : ReviewPolicy :=
    { enabled := pcfg.adversarialReview
      finalOnly := true
      rewriteOnFail := true
      maxRewrites := pcfg.maxReviewRewrites
      minScore := pcfg.minReviewScore }
  let mut reviewRewrites := 0

  -- Compile the prompt's behavioural rules.  These are the ones no string
  -- comparison decides: they are checked against the trace of what the
  -- agent actually did, and the blocking ones are checked *before* a call
  -- runs rather than after.
  let mut interlock := InterlockState.ofDirectives env.prompts.directives
  let mut behaviorChecked := false

  let elapsed : IO Nat := do
    let now ← IO.monoMsNow
    return now - startedMs
  ledger := ledger.append 0 (.runStarted (truncate task 200) vault.digests.short)

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

    -- Prompt custody gate: verify the system prompt message against the
    -- seal taken at load.  Five independent digests plus a per-line hash
    -- chain, so a mutation is both detected and located.  Any mutation —
    -- accidental or injected — is a hard stop: continuing with a different
    -- instruction set defeats the purpose of having one.
    if pcfg.vaultCustody then
      match st.messages.head? with
      | some sysMsg =>
        let (verdict, v') := vault.check sysMsg.plainText
        vault := v'
        let ms ← elapsed
        ledger := ledger.append ms
          (.custodyCheck .preCall verdict.isIntact verdict.describe)
        env.events.emit (.custodyChecked (toString Checkpoint.preCall)
          verdict.isIntact verdict.describe)
        if !verdict.isIntact then
          let (action, s') := sentinel.step .custodyFailure
          sentinel := s'
          env.events.emit (.sentinelAction (toString action) action.reason)
          env.events.emit (.errorOccurred (err .internal
            (tamperReport .preCall verdict)
            (some verdict.describe)
            (some "the prompt is restored from the seal; re-run to continue")))
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
        let ms ← elapsed
        if !violations.isEmpty then
          st := { st with complianceFailures := st.complianceFailures + 1 }
          ledger := ledger.append ms
            (.complianceVerdict false rules.length (violationSummary violations))

          -- The sentinel sees the run, not the reply: it decides whether this
          -- failure is one of a pattern bad enough to roll back, quarantine
          -- or halt on.
          let (action, s') := sentinel.step .ruleViolation
          sentinel := s'
          if action.rank > 0 then
            env.events.emit (.sentinelAction (toString action) action.reason)
            ledger := ledger.append ms
              (.escalation "compliance" (toString action) action.reason)
          if action.isHalt then
            env.events.emit (.errorOccurred (err .verification
              s!"sentinel halted the run: {action.reason}"
              (some (violationSummary violations))
              (some "check that the rules in SystemPrompt.lean are satisfiable")))
            st ← advance env st .fatalError
            break
          match action with
          | .restore toTurn reason =>
            if pcfg.sentinelRollback then
              match sentinel.lastGood with
              | some cp =>
                let before := st.messages.length
                st := { st with messages := applyRollback cp st.messages reason }
                env.events.emit (.conversationRolledBack
                  (before - st.messages.length.min before) toTurn)
                ledger := ledger.append ms (.rollback toTurn reason)
              | none => pure ()
          | .quarantine reason =>
            st := st.addMessage
              { Message.user (quarantineMessage vault.text env.prompts.directives reason)
                with pinned := true }
            ledger := ledger.append ms (.quarantine reason)
          | .reassert _ =>
            if !env.prompts.directives.isEmpty then
              st := st.addMessage
                { Message.user (reminderMessage env.prompts.directives) with pinned := true }
          | _ => pure ()

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
          ledger := ledger.append ms (.complianceVerdict true rules.length "")
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
        let gms ← elapsed
        match verdict.action with
        | .reject detail =>
          st := { st with guardianRejections := st.guardianRejections + 1 }
          ledger := ledger.append gms (.guardianVerdict "reject"
            (match verdict.driftReport with
             | some r => r.severity.toString
             | none => "unknown") (truncate detail 200))
          env.events.emit (.guardianRejected (truncate detail 200))
          let (action, s') := sentinel.step .drift
          sentinel := s'
          if action.rank > 0 then
            env.events.emit (.sentinelAction (toString action) action.reason)
          if action.isHalt then
            env.events.emit (.errorOccurred (err .verification
              s!"sentinel halted the run: {action.reason}"))
            st ← advance env st .fatalError
            break
          st := st.addMessage { Message.user detail with pinned := false }
          continue
        | .warn message =>
          st := { st with guardianWarnings := st.guardianWarnings + 1 }
          ledger := ledger.append gms (.guardianVerdict "warn"
            (match verdict.driftReport with
             | some r => r.severity.toString
             | none => "unknown") (truncate message 200))
          env.events.emit (.guardianWarning
            (match verdict.driftReport with
             | some r => r.severity.toString
             | none => "unknown") (truncate message 200))
          let (_, s') := sentinel.step .blemished
          sentinel := s'
          st := st.addMessage { Message.user message with pinned := false }
        | .accept =>
          -- A clean turn is where a checkpoint is worth taking: this is the
          -- conversation state the sentinel rolls back to if drift follows.
          let (_, s') := sentinel.step .clean
          sentinel := s'.checkpoint st.messages
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

          -- Interlock: rule on the call against the prompt's behavioural
          -- rules *before* it runs.  A blocked call never reaches the
          -- permission engine and never executes; the model is handed a
          -- tool result saying which rule stopped it and what to do first.
          let callArgs := (parseArguments call.arguments).toOption.getD (Json.mkObj [])
          let proposed := proposedOf call.name callArgs
          let verdict :=
            if interlock.isActive then interlockCheck interlock.rules interlock.trace proposed
            else .clear
          let ims ← elapsed

          if !verdict.allowsExecution then
            interlock := interlock.noteRefusal
            let vs := verdict.violations
            env.events.emit (.interlockRefused call.name verdict.summary)
            ledger := ledger.append ims
              (.escalation "interlock" "refused" verdict.summary)
            st := st.addMessage
              (Message.toolResult call.id call.name (refusalResult vs).content)
            continue

          let res ← executeCall execEnv call
          interlock := interlock.observe call.name callArgs res.ok ims

          if let .flagged vs := verdict then
            interlock := interlock.noteFlag
            env.events.emit (.interlockFlagged call.name verdict.summary)
            ledger := ledger.append ims
              (.guardianVerdict "flag" "behaviour" verdict.summary)
            st := st.addMessage
              (Message.toolResult call.id call.name (res.content ++ flagNote vs))
            if let some p := touchedPath? call.name res then
              st := st.noteFile p
            continue

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

      -- Nothing was called in this whole run: the model answered rather than
      -- acted.
      --
      -- This used to push back — "stop describing the work and start doing
      -- it: make your first tool call now" — on the theory that a reply with
      -- no tool calls was the model talking about the task instead of doing
      -- it.  That reasoning only holds if every input is a work order.  It
      -- is not: "hello" is a greeting, "what does this repo do" is a
      -- question, and the push turned both into a forced repository audit
      -- the user never asked for.
      --
      -- An answer is a complete reply.  The checks below all verify *work*,
      -- so with none done there is nothing for them to check and they are
      -- skipped; verification of an untouched tree is inconclusive, which
      -- ends the run on the answer.
      let answeredOnly := st.budget.toolCalls == 0

      -- Behavioural gate.  The prompt's rules about *how* the work is done
      -- are checked against the trace of what actually happened, not against
      -- the model's account of it.  Asked once: the point is to surface
      -- missing work at the moment it matters, not to loop.
      if interlock.isActive && !behaviorChecked && !answeredOnly then
        let unmet := interlock.finalViolations
        if !unmet.isEmpty then
          behaviorChecked := true
          let bms ← elapsed
          ledger := ledger.append bms (.complianceVerdict false unmet.length
            (String.intercalate "; " (unmet.map BehaviorViolation.describe)))
          env.events.emit (.behaviorUnsatisfied unmet.length
            (String.intercalate "; " (unmet.map BehaviorViolation.describe)))
          st := st.addMessage
            { Message.user (finalViolationMessage unmet) with pinned := false }
          continue

      -- Adversarial review: hand the reply to a fresh model call, with the
      -- directives and an explicitly adversarial brief, and let it rule.
      -- This is the layer that reaches the rules no string comparison can —
      -- and it is a separate call precisely so the reviewer has no stake in
      -- the reply having been right.
      if reviewPolicy.enabled && !env.prompts.directives.isEmpty
          && !resp.content.isEmpty && !answeredOnly then
        match ← runReview env.provider env.prompts.directives task resp.content with
        | .error e =>
          -- A reviewer that could not be reached is not a pass.  Say so and
          -- carry on rather than silently dropping the layer.
          env.events.emit (.notice s!"compliance review unavailable: {e.message}")
        | .ok review =>
          let rms ← elapsed
          ledger := ledger.append rms (.adversarialReview
            review.verdict.toString review.score (truncate review.summary 200))
          env.events.emit (.reviewCompleted review.verdict.toString review.score
            review.violated.length)
          if reviewPolicy.demandsRewrite review reviewRewrites then
            reviewRewrites := reviewRewrites + 1
            let (action, s') := sentinel.step .reviewFailure
            sentinel := s'
            if action.rank > 0 then
              env.events.emit (.sentinelAction (toString action) action.reason)
            if action.isHalt then
              env.events.emit (.errorOccurred (err .verification
                s!"sentinel halted the run: {action.reason}"))
              st ← advance env st .fatalError
              break
            env.events.emit (.reviewRewrite reviewRewrites review.summary)
            st := st.addMessage
              { Message.user (rewriteRequest review) with pinned := false }
            continue
          else if !review.isClean then
            st := st.addMessage
              { Message.user (reviewWarningNote review) with pinned := false }

      -- Before accepting completion, require the model to account for each
      -- of the operator's rules.  Asked once per run: the point is a
      -- deliberate pass over the checklist at the moment it matters, not a
      -- loop that badgers the model into agreeing.
      if env.config.prompt.adherenceCheck && !env.prompts.directives.isEmpty
          && !st.adherenceChecked && !answeredOnly then
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

  -- Final custody check.  A run that reports success under a prompt that
  -- changed along the way did not do what it says it did, so this runs on
  -- the completion path as well as the failure one.
  if pcfg.vaultCustody then
    if let some sysMsg := st.messages.head? then
      let (verdict, v') := vault.check sysMsg.plainText
      vault := v'
      let ms ← elapsed
      ledger := ledger.append ms
        (.custodyCheck .preFinish verdict.isIntact verdict.describe)
      env.events.emit (.custodyChecked (toString Checkpoint.preFinish)
        verdict.isIntact verdict.describe)
      if !verdict.isIntact && st.phase == .completed then
        env.events.emit (.errorOccurred (err .internal (tamperReport .preFinish verdict)))
        st := { st with phase := .failed }

  let summary := match st.phase with
    | .completed =>
      -- A run that called no tools answered a question; saying "0 check(s)
      -- could be run; 0 file(s) changed" about a greeting reads as a failure
      -- when nothing failed.
      if st.budget.toolCalls == 0 then "answered; no action was taken"
      else
        let verdict := match st.lastVerification with
          | some v => v.summary
          | none => "no verification was run"
        s!"{verdict}; {st.touchedFiles.length} file(s) changed"
    | .failed => "run failed; see the errors above"
    | .cancelled => "cancelled by the user"
    | other => s!"stopped in phase {other}"

  -- Seal the ledger.  Emitted last so the transcript ends with the record
  -- of what was actually checked, and whether that record is whole.
  let endMs ← elapsed
  ledger := ledger.append endMs (.runEnded st.phase.toString summary)
  env.events.emit (.ledgerSealed ledger.length ledger.failureCount
    ledger.runSeal ledger.isIntact)

  env.events.emit (.finished st.phase summary)
  return { phase := st.phase, summary := summary, state := st }

end LeanPrime
