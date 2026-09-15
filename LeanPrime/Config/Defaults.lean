/-
  LeanPrime.Config.Defaults

  Built-in defaults.  These are chosen so that `lean-prime` runs correctly
  with no config file at all, given only an API key in the environment.
-/
import LeanPrime.Config.Schema
import LeanPrime.Util.Platform

namespace LeanPrime

/-- Environment variables consulted for the API key, in order. -/
def defaultApiKeyEnvNames : List String :=
  ["LEANPRIME_API_KEY", "OPENAI_API_KEY"]

def defaultProvider : ProviderConfig := {
  kind              := .openaiCompatible
  baseUrl           := "https://router.kiosapi.com/v1"
  model             := "oc/muse-spark-1.3-contributor"
  apiKeyEnv         := "LEANPRIME_API_KEY"
  timeoutSec        := 180
  connectTimeoutSec := 20
  maxTokens         := 8192
  temperature       := 0.2
  stream            := true
  maxRetries        := 4
  -- The configured router caps requests at 10/minute; 6.5s keeps us under it.
  minIntervalMs     := 6500
  extraHeaders      := []
}

def defaultBudget : Budget := {
  maxIterations   := 40
  maxToolCalls    := 120
  maxRepairRounds := 5
  wallClockSec    := 1800
  contextTokens   := 96000
}

def defaultLimits : OutputLimits := {
  maxBytes     := 32768
  headLines    := 120
  tailLines    := 60
  maxFileBytes := 262144
}

def defaultUi : UiConfig := {
  color := true, showPlan := true, showThinking := true, compact := false
}

/-- Commands that are refused outright regardless of approval mode.
    Matched against the first word of the command line. -/
def defaultDeniedCommands : List String :=
  ["shutdown", "reboot", "halt", "poweroff", "mkfs", "fdisk", "dd", "sudo", "su", "doas"]

def defaultConfig (ws : System.FilePath) : Config := {
  provider        := defaultProvider
  approval        := .auto
  output          := .tui
  budget          := defaultBudget
  limits          := defaultLimits
  logging         := { level := .info, file := none, trace := false }
  ui              := defaultUi
  mcpServers      := []
  workspace       := ws
  deniedCommands  := defaultDeniedCommands
  shellTimeoutSec := 120
  persistSessions := true
}

end LeanPrime
