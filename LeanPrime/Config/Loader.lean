/-
  LeanPrime.Config.Loader

  Resolution order (lowest precedence first):

      built-in defaults
        → config file (~/.config/lean-prime/config.toml or --config)
        → environment variables
        → command line flags        (applied by LeanPrime.App.Cli)

  The API key itself is never part of this pipeline: only the *name* of the
  variable holding it is configurable.
-/
import LeanPrime.Config.Schema
import LeanPrime.Config.Defaults
import LeanPrime.Config.Toml

namespace LeanPrime

open LeanPrime.Toml

/-- Apply a parsed TOML document over a base config. -/
def applyToml (base : Config) (d : Document) : LPResult Config := do
  let p := base.provider
  let provider : ProviderConfig := {
    kind := ← (match d.getStr? "provider.kind" with
      | none => pure p.kind
      | some s => match ProviderKind.ofString? s with
        | some k => pure k
        | none => throw (err .configuration s!"unknown provider.kind: {s}"
            none (some "expected one of: openai-compatible, anthropic, gemini")))
    baseUrl           := d.getStr? "provider.base_url" |>.getD p.baseUrl
    model             := d.getStr? "provider.model" |>.getD p.model
    apiKeyEnv         := d.getStr? "provider.api_key_env" |>.getD p.apiKeyEnv
    timeoutSec        := d.getNat? "provider.timeout_sec" |>.getD p.timeoutSec
    connectTimeoutSec := d.getNat? "provider.connect_timeout_sec" |>.getD p.connectTimeoutSec
    maxTokens         := d.getNat? "provider.max_tokens" |>.getD p.maxTokens
    temperature       := d.getFloat? "provider.temperature" |>.getD p.temperature
    stream            := d.getBool? "provider.stream" |>.getD p.stream
    maxRetries        := d.getNat? "provider.max_retries" |>.getD p.maxRetries
    minIntervalMs     := d.getNat? "provider.min_interval_ms" |>.getD p.minIntervalMs
    extraHeaders      := d.getStrArray? "provider.extra_headers" |>.getD p.extraHeaders
  }
  let approval ← (match d.getStr? "agent.approval_mode" with
    | none => pure base.approval
    | some s => match ApprovalMode.ofString? s with
      | some m => pure m
      | none => throw (err .configuration s!"unknown agent.approval_mode: {s}"
          none (some "expected one of: auto, ask, read-only, yolo")))
  let budget : Budget := {
    maxIterations   := d.getNat? "agent.max_iterations"    |>.getD base.budget.maxIterations
    maxToolCalls    := d.getNat? "agent.max_tool_calls"    |>.getD base.budget.maxToolCalls
    maxRepairRounds := d.getNat? "agent.max_repair_rounds" |>.getD base.budget.maxRepairRounds
    wallClockSec    := d.getNat? "agent.wall_clock_sec"    |>.getD base.budget.wallClockSec
    contextTokens   := d.getNat? "agent.context_budget"    |>.getD base.budget.contextTokens
  }
  let limits : OutputLimits := {
    maxBytes     := d.getNat? "limits.max_output_bytes" |>.getD base.limits.maxBytes
    headLines    := d.getNat? "limits.head_lines"       |>.getD base.limits.headLines
    tailLines    := d.getNat? "limits.tail_lines"       |>.getD base.limits.tailLines
    maxFileBytes := d.getNat? "limits.max_file_bytes"   |>.getD base.limits.maxFileBytes
  }
  let logging : LoggingConfig := {
    level := (d.getStr? "logging.level").bind LogLevel.ofString? |>.getD base.logging.level
    file  := (d.getStr? "logging.file").map System.FilePath.mk |>.orElse (fun _ => base.logging.file)
    trace := d.getBool? "logging.trace" |>.getD base.logging.trace
  }
  let ui : UiConfig := {
    color        := d.getBool? "ui.color"         |>.getD base.ui.color
    showPlan     := d.getBool? "ui.show_plan"     |>.getD base.ui.showPlan
    showThinking := d.getBool? "ui.show_thinking" |>.getD base.ui.showThinking
    compact      := d.getBool? "ui.compact"       |>.getD base.ui.compact
  }
  let promptCfg : PromptConfig := {
    mode := ← (match d.getStr? "prompt.mode" with
      | none => pure base.prompt.mode
      | some s => match PromptMode.ofString? s with
        | some m => pure m
        | none => throw (err .configuration s!"unknown prompt.mode: {s}"
            none (some "expected one of: replace, prepend, append")))
    text := (d.getStr? "prompt.system").orElse (fun _ => base.prompt.text)
    file := (d.getStr? "prompt.system_file").map System.FilePath.mk
              |>.orElse (fun _ => base.prompt.file)
    projectFiles := d.getStrArray? "prompt.project_files" |>.getD base.prompt.projectFiles
    reminderEvery := d.getNat? "prompt.reminder_every" |>.getD base.prompt.reminderEvery
    extractDirectives :=
      d.getBool? "prompt.extract_directives" |>.getD base.prompt.extractDirectives
    adherenceCheck := d.getBool? "prompt.adherence_check" |>.getD base.prompt.adherenceCheck
  }
  let mcp := (d.arrayIndices "mcp").filterMap fun i =>
    match d.getStr? s!"mcp.{i}.command" with
    | none => none
    | some cmd => some {
        name    := d.getStr? s!"mcp.{i}.name" |>.getD s!"mcp-{i}"
        command := cmd
        args    := d.getStrArray? s!"mcp.{i}.args" |>.getD []
        enabled := d.getBool? s!"mcp.{i}.enabled" |>.getD true
        timeoutSec := d.getNat? s!"mcp.{i}.timeout_sec" |>.getD 30
      : McpServerConfig }
  return { base with
    provider := provider
    approval := approval
    budget := budget
    limits := limits
    logging := logging
    ui := ui
    mcpServers := mcp
    deniedCommands :=
      d.getStrArray? "security.denied_commands" |>.getD base.deniedCommands
    shellTimeoutSec := d.getNat? "security.shell_timeout_sec" |>.getD base.shellTimeoutSec
    persistSessions := d.getBool? "agent.persist_sessions" |>.getD base.persistSessions
    dataFencing := d.getBool? "security.data_fencing" |>.getD base.dataFencing
    prompt := promptCfg
  }

/-- Environment overrides, applied after the config file. -/
def applyEnv (c : Config) : IO Config := do
  let mut cfg := c
  if let some v ← IO.getEnv "LEANPRIME_BASE_URL" then
    cfg := { cfg with provider := { cfg.provider with baseUrl := v } }
  if let some v ← IO.getEnv "LEANPRIME_MODEL" then
    cfg := { cfg with provider := { cfg.provider with model := v } }
  if let some v ← IO.getEnv "LEANPRIME_API_KEY_ENV" then
    cfg := { cfg with provider := { cfg.provider with apiKeyEnv := v } }
  if let some v ← IO.getEnv "LEANPRIME_LOG_LEVEL" then
    if let some lvl := LogLevel.ofString? v then
      cfg := { cfg with logging := { cfg.logging with level := lvl } }
  if let some v ← IO.getEnv "LEANPRIME_APPROVAL" then
    if let some m := ApprovalMode.ofString? v then
      cfg := { cfg with approval := m }
  if (← IO.getEnv "NO_COLOR").isSome then
    cfg := { cfg with ui := { cfg.ui with color := false } }
  return cfg

/-- The default config file path, honouring XDG on Unix. -/
def defaultConfigPath : IO System.FilePath := do
  return (← configHome) / "config.toml"

/-- Read the API key from the environment.  Returns `none` rather than an
    error so `--doctor` can report the situation without failing. -/
def readApiKey (c : Config) : IO (Option String) := do
  match ← IO.getEnv c.provider.apiKeyEnv with
  | some k => if (trim k).isEmpty then return none else return some (trim k)
  | none =>
    -- fall back to the conventional names
    for name in defaultApiKeyEnvNames do
      if let some k ← IO.getEnv name then
        if !(trim k).isEmpty then return some (trim k)
    return none

/-- Load configuration from `path?` (or the default location when absent).
    A missing file is not an error. -/
def loadConfig (workspace : System.FilePath) (path? : Option System.FilePath)
    : IO (LPResult (Config × Option System.FilePath)) := do
  let base := defaultConfig workspace
  let path ← match path? with
    | some p => pure p
    | none => defaultConfigPath
  let exists_ ← path.pathExists
  if !exists_ then
    if path?.isSome then
      return .error (err .configuration s!"config file not found: {path}")
    return .ok (← applyEnv base, none)
  let src ← try IO.FS.readFile path
    catch e => return .error (err .configuration s!"cannot read {path}" (some (toString e)))
  match Toml.parse src with
  | .error e => return .error { e with detail := some s!"in {path}" }
  | .ok doc =>
    match applyToml base doc with
    | .error e => return .error { e with detail := some s!"in {path}" }
    | .ok cfg => return .ok (← applyEnv cfg, some path)

end LeanPrime
