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

/-- Choose the event sink for the requested output mode. -/
def buildSink (cfg : Config) (opts : CliOptions) (interactive : Bool) : IO EventSink := do
  if opts.quiet then mkQuietSink
  else match cfg.output with
    | .json => mkJsonSink
    | .plain => mkRenderer false cfg.ui cfg.provider.model
    | .tui => mkRenderer (cfg.ui.color && interactive) cfg.ui cfg.provider.model

/-- Assemble the system prompt for a run from every configured source.

    `--append-system-prompt` is folded in as the lowest-authority operator
    layer, which is what "append" means: it adds instructions without
    displacing the ones already in force. -/
def buildPrompts (cfg : Config) (opts : CliOptions) (snapshotKind : String)
    (isGit : Bool) (toolNames : List String) : IO (LPResult PromptStack) := do
  let baseline := baselinePrompt
  let facts := runtimeFactsPrompt snapshotKind isGit cfg.approval toolNames
  match ← buildPromptStack cfg cfg.workspace baseline facts
          opts.systemPromptText opts.systemPromptFile with
  | .error e => return .error e
  | .ok stack =>
    match opts.appendSystemPrompt with
    | none => return .ok stack
    | some extra =>
      let layer : PromptLayer :=
        { source := .cliFlag, authority := authorityOf .builtinBaseline + 1
          pinned := true, sticky := true, text := trim extra }
      let directives :=
        if cfg.prompt.extractDirectives then
          stack.directives ++
            (extractDirectives extra).map (fun d =>
              { d with id := d.id + stack.directives.length })
        else stack.directives
      return .ok { layers := stack.layers ++ [layer], directives := directives }

/-- Assemble everything needed for a run. -/
def buildRunEnv (cfg : Config) (apiKey : String) (events : EventSink)
    (prompts : PromptStack) (interactive : Bool) : IO RunEnv := do
  let logger : Logger :=
    { minLevel := cfg.logging.level, file := cfg.logging.file
      quiet := cfg.output == .json || cfg.logging.level.rank > LogLevel.debug.rank }
  let ws : Workspace := { root := cfg.workspace }
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
