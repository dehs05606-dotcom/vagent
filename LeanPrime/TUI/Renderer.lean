/-
  LeanPrime.TUI.Renderer

  The terminal transcript.

  Design brief: this must read like a professional developer terminal, not a
  dashboard.  No banner art, no boxes around everything, no progress
  animation.  The transcript is the interface: commands, their real output,
  plan state, and a status line.  Streamed model text is written through as
  it arrives.
-/
import LeanPrime.Agent.Events
import LeanPrime.TUI.Ansi
import LeanPrime.TUI.StatusBar

namespace LeanPrime

open LeanPrime.Ansi

/-- Mutable bits the renderer needs between events. -/
structure RendererState where
  /-- Are we mid-way through a streamed assistant paragraph? -/
  inText    : Bool := false
  /-- Suppress reasoning output when the user turned it off. -/
  showThinking : Bool := true
  lastPhase : AgentPhase := .idle
  toolCount : Nat := 0
  deriving Inhabited

/-- Build a terminal event sink. -/
def mkRenderer (color : Bool) (ui : UiConfig) (modelName : String)
    (bar : StatusBar) : IO EventSink := do
  let st ← IO.mkRef ({ showThinking := ui.showThinking } : RendererState)
  let out ← IO.getStdout
  let c := color
  -- Close an open streamed paragraph before printing a structured line, and
  -- restore the status block the stream erased.
  let endText : IO Unit := do
    if (← st.get).inText then
      out.putStrLn ""
      st.modify (fun s => { s with inText := false })
      bar.draw
  let line (s : String) : IO Unit := do endText; bar.println s
  return {
    emit := fun e => do
      match e with
      | .sessionStarted _ task model =>
        line (style c bold "lean-prime" ++ style c grey s!"  {model}")
        line (style c grey "─────────────────────────────────────────────────────────────")
        line (style c bold "› " ++ task)
        line ""
      | .projectDetected kind git files =>
        line (style c grey s!"  {kind} project · {files} files · git: {if git then "yes" else "no"}")
      | .phaseChanged _ to =>
        st.modify (fun s => { s with lastPhase := to })
        bar.update (fun m => { m with phase := to })
        if ui.compact then pure ()
        else match to with
          | .planning => line (style c grey "  planning…")
          | .verifying => line (style c grey "  verifying…")
          | .diagnosing => line (style c yellow "  diagnosing failure…")
          | .replanning => line (style c yellow "  replanning…")
          | _ => pure ()
      | .planCreated p =>
        if ui.showPlan then
          line ""
          line (style c bold "Plan")
          for s in p.steps do
            line s!"  {s.status.marker} {s.id}. {s.description}"
          line ""
      | .planStepChanged id status desc =>
        if ui.showPlan then
          line s!"  {status.marker} {id}. {desc}"
      | .modelStarted _ =>
        bar.update (fun m => { m with activity := "waiting on the model" })
      | .modelReasoning t =>
        if (← st.get).showThinking then
          -- reasoning is dimmed so it never competes with real output
          bar.print (style c grey t)
          st.modify (fun s => { s with inText := true })
      | .modelText t =>
        bar.print t
        st.modify (fun s => { s with inText := true })
      | .modelFinished _ u =>
        endText
        bar.update (fun m => { m with tokens := m.tokens + u.totalTokens })
      | .toolRequested _ _ _ => pure ()
      | .toolDecision _ _ verdict reason =>
        if verdict == "deny" then
          line (style c red s!"  ✗ refused — {reason}")
        else if verdict == "ask" then
          pure ()   -- the approval prompt itself is the output
      | .toolStarted name summary =>
        st.modify (fun s => { s with toolCount := s.toolCount + 1 })
        bar.update (fun m =>
          { m with activity := s!"{name} {truncate summary 40}"
                   toolCount := m.toolCount + 1 })
        line (style c cyan s!"  → {name}" ++ style c grey s!"  {truncate summary 90}")
      | .toolProgress t =>
        line (style c grey s!"  {truncate t 160}")
      | .toolFinished _ ok summary ms =>
        let mark := if ok then style c green "  ✓" else style c red "  ✗"
        line (s!"{mark} {truncate summary 100}" ++ style c grey s!" ({ms}ms)")
      | .verificationStarted =>
        line ""
        line (style c bold "Verifying")
      | .verificationCheck name outcome detail =>
        match outcome with
        | .passed => line (style c green s!"  ✓ {name}" ++ style c grey s!"  {truncate detail 90}")
        | .failed =>
          line (style c red s!"  ✗ {name}")
          for l in (clampLines detail 20 10).splitOn "\n" do
            line (style c grey s!"    {truncate l 160}")
        | .inconclusive =>
          line (style c yellow s!"  – {name}" ++ style c grey s!"  {truncate detail 90}")
      | .verificationFinished r =>
        let mark := match r.outcome with
          | .passed => style c green "✓"
          | .failed => style c red "✗"
          | .inconclusive => style c yellow "–"
        line s!"  {mark} {r.summary}"
        line ""
      | .userSteered t =>
        line (style c magenta s!"  ↪ steering: {truncate t 120}")
      | .complianceRejected attempt violations =>
        bar.update (fun m => { m with complianceRetry := some attempt })
        line (style c yellow s!"  ⊘ reply rejected — {violations}")
        line (style c grey s!"    re-requesting (attempt {attempt})")
      | .complianceAccepted n =>
        bar.update (fun m => { m with complianceRetry := none })
        line (style c green s!"  ✓ reply satisfies every enforced rule (after {n} retry/retries)")
      | .integrityChecked ok detail =>
        if ok then
          line (style c green s!"  ✓ prompt integrity verified — {detail}")
        else
          line (style c red s!"  ✗ PROMPT INTEGRITY FAILED — {detail}")
      | .injectionBlocked patterns toolName =>
        line (style c red s!"  ⚠ injection attempt blocked in {toolName} output")
        line (style c grey s!"    patterns: {String.intercalate ", " patterns}")
      | .guardianWarning severity detail =>
        bar.update (fun m => { m with guardianWarnings := m.guardianWarnings + 1 })
        line (style c yellow s!"  ⊘ guardian [{severity}]: {truncate detail 120}")
      | .guardianRejected detail =>
        bar.update (fun m => { m with guardianRejections := m.guardianRejections + 1 })
        line (style c red s!"  ✗ guardian rejected: {truncate detail 120}")
      | .authorityConflict higher lower phrase =>
        bar.update (fun m => { m with authorityConflicts := m.authorityConflicts + 1 })
        line (style c yellow s!"  ⚡ authority conflict: [{lower}] vs [{higher}] on \"{truncate phrase 60}\"")
      | .anchorInjected reason =>
        line (style c grey s!"  ⚓ anchor injected: {reason}")
      | .distanceTriggered tokens threshold =>
        line (style c yellow s!"  ↻ instruction distance: {tokens}/{threshold} tokens — re-asserting")
      | .custodyChecked cp intact detail =>
        bar.update (fun m => { m with custodyIntact := intact })
        if intact then
          if !ui.compact then
            line (style c grey s!"  ⛨ custody {cp}: intact")
        else
          line (style c red s!"  ⛨ CUSTODY FAILED at {cp} — {detail}")
      | .reviewCompleted verdict score unsat =>
        bar.update (fun m => { m with reviewScore := some score })
        let mark := if verdict == "pass" then style c green "✓"
          else if verdict == "warn" then style c yellow "–"
          else style c red "✗"
        let tail := if unsat == 0 then "" else s!" · {unsat} unsatisfied"
        line s!"  {mark} review: {verdict} ({score}/100){style c grey tail}"
      | .reviewRewrite attempt summary =>
        line (style c yellow s!"  ↻ rewrite requested (attempt {attempt})")
        line (style c grey s!"    {truncate summary 140}")
      | .sentinelAction action reason =>
        bar.update (fun m => { m with sentinelState := action })
        let col := if action == "halt" then red
          else if action == "quarantine" || action == "restore" then yellow
          else grey
        line (style c col s!"  ⚑ sentinel {action} — {truncate reason 120}")
      | .conversationRolledBack discarded toTurn =>
        line (style c yellow s!"  ⏮ rolled back {discarded} turn(s) to checkpoint {toTurn}")
      | .ledgerSealed entries failures sealValue intact =>
        let state := if intact then style c green "intact" else style c red "BROKEN"
        line (style c grey s!"  ledger: {entries} entries, {failures} failure(s), seal {sealValue}"
              ++ style c grey " · chain " ++ state)
      | .interlockRefused tool rules =>
        bar.update (fun m => { m with interlockRefusals := m.interlockRefusals + 1 })
        line (style c red s!"  ⛔ blocked before execution: {tool}")
        line (style c grey s!"    {truncate rules 150}")
      | .interlockFlagged tool rules =>
        line (style c yellow s!"  ⚠ flagged: {tool}" ++ style c grey s!"  {truncate rules 120}")
      | .behaviorUnsatisfied n detail =>
        line (style c yellow s!"  ⊘ {n} behaviour rule(s) unsatisfied — cannot report done")
        line (style c grey s!"    {truncate detail 160}")
      | .budgetWarning what used limit =>
        line (style c yellow s!"  ! {what} reached ({used}/{limit})")
      | .errorOccurred err_ =>
        line (style c red s!"  ✗ {err_.kind}: {err_.message}")
        match err_.detail with
        | some d => for l in (clampLines d 12 6).splitOn "\n" do
                      line (style c grey s!"    {truncate l 160}")
        | none => pure ()
      | .notice t => line (style c grey s!"  {t}")
      | .finished phase summary =>
        line ""
        let s ← st.get
        let mark := match phase with
          | .completed => style c green "completed"
          | .failed => style c red "failed"
          | .cancelled => style c yellow "cancelled"
          | other => other.toString
        line (style c grey "─────────────────────────────────────────────────────────────")
        line s!"{mark}  {summary}"
        line (style c grey s!"{s.toolCount} tool call(s) · model {modelName}")
  }

/-- A sink that writes one JSON object per line: `--json` mode. -/
def mkJsonSink : IO EventSink := do
  let out ← IO.getStdout
  return { emit := fun e => do
    out.putStrLn (redact e.toJson.compress)
    out.flush }

/-- A sink that writes nothing but keeps errors visible on stderr. -/
def mkQuietSink : IO EventSink := do
  let errOut ← IO.getStderr
  return { emit := fun e => do
    match e with
    | .errorOccurred er => errOut.putStrLn (redact (LPError.render er))
    | _ => pure () }

end LeanPrime
