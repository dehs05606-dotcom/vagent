/-
  LeanPrime.Model.Messages

  Wire-independent conversation types.

  Content is a list of parts rather than a bare `String` so that image and
  file parts can be added without changing every call site (see
  `ContentPart`).  Today only `.text` is serialised by the OpenAI-compatible
  provider; the others are rejected explicitly rather than silently dropped.
-/
import LeanPrime.Util.Prelude
import LeanPrime.Util.Errors

open Lean

namespace LeanPrime

inductive Role where
  | system | user | assistant | tool
  deriving Repr, DecidableEq, Inhabited

def Role.toString : Role → String
  | .system => "system" | .user => "user"
  | .assistant => "assistant" | .tool => "tool"

instance : ToString Role := ⟨Role.toString⟩

/-- A single piece of message content.  Multimodal-ready. -/
inductive ContentPart where
  | text (s : String)
  | imageUrl (url : String)
  | imageBase64 (mime : String) (data : String)
  deriving Repr, Inhabited

/-- A tool invocation requested by the model.  `arguments` is the raw JSON
    text exactly as the model produced it; it is parsed and validated by the
    tool registry, never trusted here. -/
structure ToolCallRequest where
  id        : String
  name      : String
  arguments : String
  deriving Repr, Inhabited

structure Message where
  role       : Role
  content    : List ContentPart := []
  toolCalls  : List ToolCallRequest := []
  /-- Set on `.tool` messages to correlate with the request. -/
  toolCallId : Option String := none
  name       : Option String := none
  deriving Repr, Inhabited

namespace Message

def text (r : Role) (s : String) : Message := { role := r, content := [.text s] }

def system (s : String) : Message := text .system s
def user (s : String) : Message := text .user s
def assistant (s : String) : Message := text .assistant s

/-- A tool result message correlated to the call that produced it. -/
def toolResult (callId name content : String) : Message :=
  { role := .tool, content := [.text content], toolCallId := some callId, name := some name }

/-- Flatten the textual parts of a message. -/
def plainText (m : Message) : String :=
  String.intercalate "\n"
    (m.content.filterMap fun p => match p with | .text s => some s | _ => none)

/-- Cheap token estimate (≈4 bytes per token) used for context budgeting.
    Deliberately an estimate: no tokenizer is bundled, and the budget only
    has to be conservative, not exact. -/
def estimateTokens (m : Message) : Nat :=
  let body := m.plainText.utf8ByteSize
  let tools := m.toolCalls.foldl (fun a c => a + c.arguments.utf8ByteSize + c.name.utf8ByteSize) 0
  (body + tools) / 4 + 8

end Message

/-- Wrap untrusted material (repository files, command output, MCP results)
    in an explicit, clearly delimited block.

    This is a defence-in-depth measure for prompt injection: the system
    prompt tells the model that anything inside these markers is *data*, and
    the executor independently enforces permissions regardless of what the
    model concludes. -/
def untrustedBlock (source : String) (body : String) : String :=
  "<<<UNTRUSTED-DATA source=\"" ++ source ++ "\">>>\n" ++
  body ++
  "\n<<<END-UNTRUSTED-DATA>>>"

/-- Declared schema of one tool, as sent to the provider. -/
structure ToolSchema where
  name        : String
  description : String
  /-- JSON Schema object for the parameters. -/
  parameters  : Json
  deriving Inhabited

/-- Reason the model stopped generating. -/
inductive FinishReason where
  | stop | length | toolCalls | contentFilter | other (s : String)
  deriving Repr, Inhabited

def FinishReason.ofString (s : String) : FinishReason :=
  match s with
  | "stop" => .stop
  | "length" => .length
  | "tool_calls" | "function_call" => .toolCalls
  | "content_filter" => .contentFilter
  | raw => .other raw

def FinishReason.toString : FinishReason → String
  | .stop => "stop" | .length => "length" | .toolCalls => "tool_calls"
  | .contentFilter => "content_filter" | .other s => s

instance : ToString FinishReason := ⟨FinishReason.toString⟩

structure Usage where
  promptTokens     : Nat := 0
  completionTokens : Nat := 0
  totalTokens      : Nat := 0
  deriving Repr, Inhabited

instance : HAdd Usage Usage Usage where
  hAdd a b := {
    promptTokens := a.promptTokens + b.promptTokens
    completionTokens := a.completionTokens + b.completionTokens
    totalTokens := a.totalTokens + b.totalTokens }

/-- A request to a model. -/
structure ModelRequest where
  messages    : List Message
  tools       : List ToolSchema := []
  temperature : Float := 0.2
  maxTokens   : Nat := 8192
  stream      : Bool := false
  /-- `auto`, `none`, or `required`. -/
  toolChoice  : String := "auto"
  deriving Inhabited

/-- A complete model response. -/
structure ModelResponse where
  content      : String := ""
  /-- Separate reasoning channel when the provider exposes one. -/
  reasoning    : String := ""
  toolCalls    : List ToolCallRequest := []
  finishReason : FinishReason := .stop
  usage        : Usage := {}
  model        : String := ""
  deriving Inhabited

/-- Incremental events emitted while streaming. -/
inductive StreamEvent where
  | textDelta (s : String)
  | reasoningDelta (s : String)
  | toolCallStarted (index : Nat) (id : String) (name : String)
  | toolCallArgsDelta (index : Nat) (s : String)
  | finished (reason : FinishReason)
  deriving Repr, Inhabited

end LeanPrime
