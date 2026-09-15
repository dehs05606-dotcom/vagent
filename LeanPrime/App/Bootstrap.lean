/-
  LeanPrime.App.Bootstrap

  Wiring.  This is the only module that knows about every other subsystem;
  everything below it depends on interfaces, not on each other.
-/
import LeanPrime.App.Cli
import LeanPrime.App.Doctor
import LeanPrime.Agent.Loop
import LeanPrime.Memory.Session
import LeanPrime.TUI.Renderer
import LeanPrime.TUI.Banner
import LeanPrime.Model.OpenAI

namespace LeanPrime

/-- Resolve config from every layer, in precedence order. -/
def buildConfig (opts : CliOptions) : IO (LPResult (Config × Option System.FilePath)) := do
  let ws ← match opts.workspace with
    | some w => pure w
    | none => IO.currentDir
  match ← loadConfig ws opts.configPath with
  | .error e => return .error e
  | .ok (cfg, path) => return .ok (applyCli cfg opts, path)

/-- A short form of the prompt origin, for the status line. -/
def shortOrigin : PromptOrigin → String
  | .flagFile p => (p.splitOn "/").getLast!
  | .envFile p => (p.splitOn "/").getLast!
  | .workspaceFile _ => "SystemPrompt.lean"
  | .installFile _ => "SystemPrompt.lean"
  | .compiledIn => "SystemPrompt.lean (built in)"

/-- Gather what the opening screen reports.  Every field is read from the
    resolved configuration, so the banner cannot claim enforcement that is
    not actually in force. -/
def bannerInfoOf (cfg : Config) (registry : Registry) (prompts : PromptStack)
    (cfgPath : Option System.FilePath) : BannerInfo :=
  let report := compileReport prompts.directives
  { version := versionString
    model := cfg.provider.model
    approval := cfg.approval
    execution := cfg.execution
    toolCount := registry.tools.length
    directives := prompts.directives.length
    textRules := prompts.rules.length
    behaviorRules := report.rules.length
    blockingRules := report.blockingCount
    promptOrigin := shortOrigin prompts.origin
    configPath := cfgPath.map (fun p => p.toString) }

/-- Choose the event sink for the requested output mode.

    The two-line status block is drawn only for the interactive `tui` mode:
    `--plain`, `--json` and a redirected stdout must stay byte-clean. -/
def buildSink (cfg : Config) (opts : CliOptions) (interactive : Bool)
    (prompts : PromptStack) : IO EventSink := do
  let initial : StatusModel := {
    promptOrigin := shortOrigin prompts.origin
    directives := prompts.directives.length
    enforced := prompts.rules.length
    custodyFingerprint :=
      if cfg.prompt.vaultCustody then (Digests.of prompts.render).short else ""
    behaviorRules := (compileBehaviorRules prompts.directives).length
    model := shortModelName cfg.provider.model
    mode := cfg.execution.toString }
  if opts.quiet then mkQuietSink
  else match cfg.output with
    | .json => mkJsonSink
    | .plain => do
      let bar ← mkStatusBar false false initial
      mkRenderer false cfg.ui cfg.provider.model bar
    | .tui => do
      let color := cfg.ui.color && interactive
      let bar ← mkStatusBar interactive color initial
      mkRenderer color cfg.ui cfg.provider.model bar

/-- Gather the values available to `{{…}}` placeholders in the prompt. -/
def buildTemplateVars (cfg : Config) (registry : Registry) (task : String)
    : IO TemplateVars := do
  let kind ← Tools.detectProject cfg.workspace
  let isGit ← Tools.isGitRepo cfg.workspace
  let branch ← if !isGit then pure "not a git repository" else
    match ← runProcess "git" #["rev-parse", "--abbrev-ref", "HEAD"] cfg.workspace 15 with
    | .ok r => pure (trim r.stdout)
    | .error _ => pure "unknown"
  let status ← if !isGit then pure "" else
    match ← runProcess "git" #["status", "--short"] cfg.workspace 20 with
    | .ok r => pure (clampLines (trim r.stdout) 40 0)
    | .error _ => pure ""
  return {
    tools := String.intercalate ", " registry.names
    toolDetail := String.intercalate "\n"
      (registry.tools.map fun t => s!"  {t.name} — {truncate t.description 140}")
    projectKind := kind.toString
    workspace := cfg.workspace.toString
    gitBranch := branch
    gitStatus := status
    mode := cfg.execution.toString
    task := task }

/-- Load the one system prompt and derive everything from it. -/
def buildPrompts (cfg : Config) (registry : Registry) (task : String)
    : IO (LPResult PromptStack) := do
  let vars ← buildTemplateVars cfg registry task
  buildPromptStack cfg cfg.workspace vars

/-- Assemble everything needed for a run. -/
def buildRunEnv (cfg : Config) (apiKey : String) (events : EventSink)
    (prompts : PromptStack) (interactive : Bool) : IO RunEnv := do
  let logger : Logger :=
    { minLevel := cfg.logging.level, file := cfg.logging.file
      quiet := cfg.output == .json || cfg.logging.level.rank > LogLevel.debug.rank }
  let ws : Workspace := { root := cfg.workspace, unrestricted := cfg.unrestricted }
  let policyRef ← IO.mkRef (Policy.ofConfig cfg)
  let audit := fileAuditSink (← defaultAuditPath)
  let registry := Registry.forMode cfg.approval
  let provider ← OpenAI.make cfg.provider apiKey Curl.client logger
  let toolCtx : ToolContext := {
    workspace := ws
    config := cfg
    policy := policyRef
    logger := logger
    audit := audit
    askUser := makeAskUser interactive policyRef audit cfg.workspace.toString
    notify := fun t => events.emit (.toolProgress t) }
  return {
    provider := provider
    registry := registry
    toolCtx := toolCtx
    events := events
    config := cfg
    workspace := ws
    prompts := prompts
    -- Steering is read from a non-blocking source; with no TTY there is none.
    pollSteer := pure [] }

end LeanPrime
