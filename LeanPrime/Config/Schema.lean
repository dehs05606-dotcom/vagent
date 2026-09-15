/-
  LeanPrime.Config.Schema

  The complete configuration surface of the agent, as typed data.

  Secrets are never stored in this structure as literals: the config records
  the *name of the environment variable* holding the API key, and the key is
  read at call time and never logged, serialised or printed.
-/
import LeanPrime.Util.Prelude
import LeanPrime.Util.Errors
import LeanPrime.Util.Logging

namespace LeanPrime

/-- How the permission engine treats a request that needs a decision. -/
inductive ApprovalMode where
  /-- Execute anything classified as reversible/safe without asking. -/
  | auto
  /-- Ask the user before every side-effecting tool. -/
  | ask
  /-- Never execute side-effecting tools; read-only session. -/
  | readOnly
  /-- Execute everything without asking.  Requires an explicit opt-in. -/
  | yolo
  deriving Repr, DecidableEq, Inhabited

def ApprovalMode.toString : ApprovalMode → String
  | .auto => "auto" | .ask => "ask" | .readOnly => "read-only" | .yolo => "yolo"

instance : ToString ApprovalMode := ⟨ApprovalMode.toString⟩

def ApprovalMode.ofString? (s : String) : Option ApprovalMode :=
  match toLower (trim s) with
  | "auto" => some .auto
  | "ask"  => some .ask
  | "read-only" | "readonly" | "read_only" => some .readOnly
  | "yolo" | "danger" => some .yolo
  | _ => none

/-- Which output surface the process drives. -/
inductive OutputMode where
  | tui | plain | json
  deriving Repr, DecidableEq, Inhabited

def OutputMode.toString : OutputMode → String
  | .tui => "tui" | .plain => "plain" | .json => "json"

instance : ToString OutputMode := ⟨OutputMode.toString⟩

/-- Provider wire protocol.  Only OpenAI-compatible chat completions are
    implemented today; the constructor set is what the router abstraction
    dispatches on. -/
inductive ProviderKind where
  | openaiCompatible
  | anthropic
  | gemini
  deriving Repr, DecidableEq, Inhabited

def ProviderKind.toString : ProviderKind → String
  | .openaiCompatible => "openai-compatible"
  | .anthropic => "anthropic"
  | .gemini => "gemini"

instance : ToString ProviderKind := ⟨ProviderKind.toString⟩

def ProviderKind.ofString? (s : String) : Option ProviderKind :=
  match toLower (trim s) with
  | "openai-compatible" | "openai" | "openai_compatible" => some .openaiCompatible
  | "anthropic" => some .anthropic
  | "gemini" | "google" => some .gemini
  | _ => none

/-- Everything needed to talk to one model endpoint. -/
structure ProviderConfig where
  kind          : ProviderKind
  baseUrl       : String
  model         : String
  /-- Name of the environment variable holding the API key.  Never the key. -/
  apiKeyEnv     : String
  timeoutSec    : Nat
  connectTimeoutSec : Nat
  maxTokens     : Nat
  temperature   : Float
  stream        : Bool
  maxRetries    : Nat
  /-- Minimum gap between outbound model requests, in milliseconds.
      Routed providers commonly enforce a per-minute request cap; pacing
      requests client-side avoids burning retries on HTTP 429. -/
  minIntervalMs : Nat
  /-- Extra `Header: value` lines sent with every request. -/
  extraHeaders  : List String
  deriving Inhabited

/-- Bounds that stop a runaway autonomous loop. -/
structure Budget where
  maxIterations   : Nat
  maxToolCalls    : Nat
  maxRepairRounds : Nat
  wallClockSec    : Nat
  contextTokens   : Nat
  deriving Inhabited, Repr

/-- Limits applied to every tool result before it may enter model context. -/
structure OutputLimits where
  maxBytes     : Nat
  headLines    : Nat
  tailLines    : Nat
  maxFileBytes : Nat
  deriving Inhabited, Repr

/-- One configured MCP server. -/
structure McpServerConfig where
  name    : String
  command : String
  args    : List String
  enabled : Bool
  timeoutSec : Nat
  deriving Inhabited, Repr

structure LoggingConfig where
  level   : LogLevel
  file    : Option System.FilePath
  trace   : Bool
  deriving Inhabited

structure UiConfig where
  color       : Bool
  showPlan    : Bool
  showThinking : Bool
  compact     : Bool
  deriving Inhabited, Repr

/-- The root configuration object. -/
structure Config where
  provider     : ProviderConfig
  approval     : ApprovalMode
  output       : OutputMode
  budget       : Budget
  limits       : OutputLimits
  logging      : LoggingConfig
  ui           : UiConfig
  mcpServers   : List McpServerConfig
  /-- Workspace root.  All filesystem tools are confined to it. -/
  workspace    : System.FilePath
  /-- Commands the user has permanently forbidden, matched on the first word. -/
  deniedCommands : List String
  /-- Shell command timeout in seconds. -/
  shellTimeoutSec : Nat
  /-- Persist sessions to disk. -/
  persistSessions : Bool
  deriving Inhabited

end LeanPrime
