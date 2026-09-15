/-
  LeanPrime.Model.Provider

  The abstraction every model backend implements.  The agent core depends on
  this record only, never on a concrete provider.
-/
import LeanPrime.Model.Messages
import LeanPrime.Config.Schema

namespace LeanPrime

/-- What a provider can do.  The agent adapts its strategy to these. -/
structure ProviderCapabilities where
  streaming   : Bool
  toolCalling : Bool
  reasoning   : Bool
  vision      : Bool
  deriving Repr, Inhabited

/-- A model backend. -/
structure ModelProvider where
  name         : String
  model        : String
  capabilities : ProviderCapabilities
  /-- Single-shot completion. -/
  chat         : ModelRequest → IO (LPResult ModelResponse)
  /-- Streaming completion.  `onEvent` is called as deltas arrive; the final
      assembled response is returned. -/
  stream       : ModelRequest → (StreamEvent → IO Unit) → IO (LPResult ModelResponse)

/-- Run a request, choosing streaming when both the config and the provider
    support it.  This is the single entry point used by the agent loop. -/
def ModelProvider.run (p : ModelProvider) (req : ModelRequest)
    (onEvent : StreamEvent → IO Unit) : IO (LPResult ModelResponse) := do
  if req.stream && p.capabilities.streaming then
    p.stream req onEvent
  else
    p.chat req

end LeanPrime
