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

/-- What governs the agent's actions.

    This is a deliberate fork in the design, not a slider.  Under `governed`
    the permission engine rules on every call and the theorems in
    `LeanPrime.Verification.SecurityProofs` describe what cannot happen.
    Under `unrestricted` the system prompt is the only authority and those
    theorems do not apply — which is why they are all stated for the
    governed case rather than claimed unconditionally. -/
inductive ExecutionMode where
  /-- The permission engine decides.  Default. -/
  | governed
  /-- Nothing vetoes the prompt: no approval prompts, no risk classification,
      no deny list, no workspace containment. -/
  | unrestricted
  deriving Repr, DecidableEq, Inhabited

def ExecutionMode.toString : ExecutionMode → String
  | .governed => "governed" | .unrestricted => "unrestricted"

instance : ToString ExecutionMode := ⟨ExecutionMode.toString⟩

def ExecutionMode.ofString? (s : String) : Option ExecutionMode :=
  match toLower (trim s) with
  | "governed" | "normal" | "safe" => some .governed
  | "unrestricted" | "full" | "full-access" | "none" => some .unrestricted
  | _ => none

/-- How the one system prompt is enforced.

    There is no setting here for *where* the prompt comes from beyond a
    single path, because there is only one source: `SystemPrompt.lean`.
    See `LeanPrime.Prompt.Source`. -/
structure PromptConfig where
  /-- Override for which copy of `SystemPrompt.lean` to load. -/
  file        : Option System.FilePath
  /-- Re-assert the prompt's directives every N model calls.  0 disables.

      A long run is where adherence actually breaks: the instruction is
      thousands of tokens back and competing with fresh tool output.
      Periodic re-assertion is the fix. -/
  reminderEvery : Nat
  /-- Extract imperative rules and restate them as an explicit checklist. -/
  extractDirectives : Bool
  /-- Before finishing, require the model to account for each directive. -/
  adherenceCheck : Bool
  /-- Reject a reply that breaks a mechanically checkable rule and ask
      again, rather than passing it on.  See `LeanPrime.Prompt.Compliance`. -/
  enforceCompliance : Bool
  /-- How many times a rejected reply may be re-requested before the run
      gives up and reports the violation. -/
  maxComplianceRetries : Nat
  /-- Restate the directives immediately before every model call, in
      addition to keeping them at the top of the conversation.  Costs tokens;
      buys the strongest recency position there is. -/
  restateBeforeEveryCall : Bool
  /-- Seal the prompt under five digests and verify custody at every
      checkpoint.  See `LeanPrime.Prompt.Vault`. -/
  vaultCustody : Bool
  /-- Send each turn-ending reply to a fresh model call that rules on it
      against the directives.  Costs one extra call per reviewed reply.
      See `LeanPrime.Agent.Adversary`. -/
  adversarialReview : Bool
  /-- Rewrite rounds allowed when the adversarial reviewer fails a reply. -/
  maxReviewRewrites : Nat
  /-- Below this review score, a `warn` is treated as a `fail`. -/
  minReviewScore : Nat
  /-- Let the sentinel roll the conversation back to the last clean
      checkpoint when replies keep failing.  See `LeanPrime.Agent.Sentinel`. -/
  sentinelRollback : Bool
  /-- Consecutive non-compliant turns before the run is halted.  0 disables
      the streak ladder (the deadman and weight budget still apply). -/
  haltAfterFailures : Nat
  deriving Inhabited

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
  /-- Wrap external material in an explicit data fence that tells the model
      the content is data rather than instruction.

      Off by default: the agent follows the instructions it is given,
      including ones it finds in the repository it is working on.  Turn it on
      when pointing the agent at a codebase you do not control.  Either way
      the permission engine still rules on every action. -/
  dataFencing     : Bool
  /-- How the system prompt is loaded and enforced. -/
  prompt          : PromptConfig
  /-- What governs the agent's actions. -/
  execution       : ExecutionMode
  deriving Inhabited

/-- Convenience: is the run unrestricted? -/
def Config.unrestricted (c : Config) : Bool := c.execution == .unrestricted

/-- Require a passing verification before the run may report success.

    Governed runs always do.  An unrestricted run does only if its prompt
    asks for it, because a gate the operator did not ask for is exactly the
    kind of thing `unrestricted` exists to remove. -/
def Config.requireVerification (c : Config) : Bool := !c.unrestricted

end LeanPrime
