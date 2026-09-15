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
