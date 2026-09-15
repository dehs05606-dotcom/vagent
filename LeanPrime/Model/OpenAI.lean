/-
  LeanPrime.Model.OpenAI

  OpenAI-compatible `/chat/completions` client: request serialisation,
  response parsing, and SSE stream assembly (including incremental tool
  calls, which arrive as indexed argument fragments).
-/
import LeanPrime.Model.Provider
import LeanPrime.Model.Http
import LeanPrime.Config.Loader

open Lean

namespace LeanPrime.OpenAI

open LeanPrime

/-! ### JSON access helpers (total, never throw) -/

def objField? (j : Json) (k : String) : Option Json :=
  match j.getObjVal? k with
  | .ok v => if v.isNull then none else some v
  | .error _ => none

def strField? (j : Json) (k : String) : Option String :=
  (objField? j k).bind fun v => v.getStr?.toOption

def natField? (j : Json) (k : String) : Option Nat :=
  (objField? j k).bind fun v => v.getNat?.toOption

def arrField? (j : Json) (k : String) : Option (Array Json) :=
  (objField? j k).bind fun v => v.getArr?.toOption

/-! ### Request serialisation -/

private def partToJson : ContentPart → LPResult Json
  | .text s => .ok (Json.mkObj [("type", Json.str "text"), ("text", Json.str s)])
  | .imageUrl u => .ok (Json.mkObj
      [("type", Json.str "image_url"),
       ("image_url", Json.mkObj [("url", Json.str u)])])
  | .imageBase64 mime data => .ok (Json.mkObj
      [("type", Json.str "image_url"),
       ("image_url", Json.mkObj [("url", Json.str s!"data:{mime};base64,{data}")])])

/-- Serialise one message.  Plain single-text content is emitted as a bare
    string, which every OpenAI-compatible server accepts; multi-part content
    uses the array form. -/
def messageToJson (m : Message) : LPResult Json := do
  let contentJson : Json ←
    match m.content with
    | [] => pure (Json.str "")
    | [.text s] => pure (Json.str s)
    | parts =>
      let mut arr : Array Json := #[]
      for p in parts do
        arr := arr.push (← partToJson p)
      pure (Json.arr arr)
  let base : List (String × Json) :=
    [("role", Json.str m.role.toString), ("content", contentJson)]
  let withTools :=
    if m.toolCalls.isEmpty then base
    else base ++ [("tool_calls", Json.arr (m.toolCalls.toArray.map fun c =>
      Json.mkObj
        [ ("id", Json.str c.id)
        , ("type", Json.str "function")
        , ("function", Json.mkObj
            [("name", Json.str c.name), ("arguments", Json.str c.arguments)]) ]))]
  let withId := match m.toolCallId with
    | some i => withTools ++ [("tool_call_id", Json.str i)]
    | none => withTools
  let withName := match m.name with
    | some n => withId ++ [("name", Json.str n)]
    | none => withId
  return Json.mkObj withName

def toolSchemaToJson (t : ToolSchema) : Json :=
  Json.mkObj
    [ ("type", Json.str "function")
    , ("function", Json.mkObj
        [ ("name", Json.str t.name)
        , ("description", Json.str t.description)
        , ("parameters", t.parameters) ]) ]

def requestToJson (model : String) (r : ModelRequest) : LPResult Json := do
  let mut msgs : Array Json := #[]
  for m in r.messages do
    msgs := msgs.push (← messageToJson m)
  let base : List (String × Json) :=
    [ ("model", Json.str model)
    , ("messages", Json.arr msgs)
    , ("max_tokens", Json.num (JsonNumber.fromNat r.maxTokens))
    , ("temperature", toJson r.temperature)
    , ("stream", Json.bool r.stream) ]
  let withTools :=
    if r.tools.isEmpty then base
    else base ++
      [ ("tools", Json.arr (r.tools.toArray.map toolSchemaToJson))
      , ("tool_choice", Json.str r.toolChoice) ]
  return Json.mkObj withTools

/-! ### Response parsing -/

/-- Provider-side error codes that are worth retrying rather than surfacing.
    `system_cpu_overloaded` is emitted by routed backends under load. -/
def transientErrorCodes : List String :=
  ["system_cpu_overloaded", "rate_limit_exceeded", "server_error",
   "overloaded_error", "service_unavailable", "upstream_error"]

/-- Extract a provider error object, if the body is one. -/
def parseErrorBody (body : String) : Option String :=
  match Json.parse body with
  | .error _ => none
  | .ok j =>
    match objField? j "error" with
    | some e => some ((strField? e "message").getD e.compress)
    | none => none

/-- `true` when the body is a provider error that should be retried. -/
def transientErrorBody (body : String) : Bool :=
  match Json.parse body with
  | .error _ => false
  | .ok j =>
    match objField? j "error" with
    | none => false
    | some e =>
      let code := (strField? e "code").getD ""
      let msg := toLower ((strField? e "message").getD "")
      transientErrorCodes.contains code
        || containsSubstr msg "overloaded"
        || containsSubstr msg "try again"
        || containsSubstr msg "temporarily"

def parseToolCalls (arr : Array Json) : List ToolCallRequest :=
  arr.toList.filterMap fun c =>
    match objField? c "function" with
    | none => none
    | some f =>
      match strField? f "name" with
      | none => none
      | some name => some {
          id := (strField? c "id").getD name
          name := name
          arguments := (strField? f "arguments").getD "{}" }

def parseUsage (j : Json) : Usage :=
  match objField? j "usage" with
  | none => {}
  | some u => {
      promptTokens     := (natField? u "prompt_tokens").getD 0
      completionTokens := (natField? u "completion_tokens").getD 0
      totalTokens      := (natField? u "total_tokens").getD 0 }

def parseResponse (body : String) : LPResult ModelResponse := do
  match Json.parse body with
  | .error e =>
    throw (err .parse "provider returned malformed JSON"
      (some (truncate body 400)) (some e))
  | .ok j =>
    if let some msg := parseErrorBody body then
      throw (err .provider "provider returned an error" (some msg))
    let choices := (arrField? j "choices").getD #[]
    let some choice := choices[0]?
      | throw (err .provider "provider response contained no choices"
          (some (truncate body 400)))
    let some message := objField? choice "message"
      | throw (err .provider "choice contained no message" (some (truncate body 400)))
    return {
      content   := (strField? message "content").getD ""
      reasoning := (strField? message "reasoning_content").getD
                     ((strField? message "reasoning").getD "")
      toolCalls := parseToolCalls ((arrField? message "tool_calls").getD #[])
      finishReason := FinishReason.ofString ((strField? choice "finish_reason").getD "stop")
      usage := parseUsage j
      model := (strField? j "model").getD "" }

/-! ### Streaming

    A partially received tool call, accumulated across SSE chunks. -/
structure PartialCall where
  id   : String := ""
  name : String := ""
  args : String := ""
  deriving Inhabited, Repr

/-- Merge one streaming delta into the accumulator state. -/
structure StreamState where
  content   : String := ""
  reasoning : String := ""
  calls     : Array PartialCall := #[]
  finish    : FinishReason := .stop
  usage     : Usage := {}
  model     : String := ""
  /-- Whether any well-formed SSE `data:` payload was seen.  Distinguishes
      "the model produced nothing" from "the server never streamed". -/
  sawData   : Bool := false
  deriving Inhabited

def StreamState.ensureIndex (s : StreamState) (i : Nat) : StreamState :=
  if i < s.calls.size then s
  else { s with calls := s.calls ++ Array.replicate (i + 1 - s.calls.size) ({} : PartialCall) }

/-- Apply one `data:` payload, emitting events for the UI. -/
def applyChunk (st : StreamState) (j : Json) (emit : StreamEvent → IO Unit)
    : IO StreamState := do
  let mut s := { st with sawData := true }
  if let some m := strField? j "model" then s := { s with model := m }
  if let some u := objField? j "usage" then
    s := { s with usage := parseUsage (Json.mkObj [("usage", u)]) }
  let choices := (arrField? j "choices").getD #[]
  for choice in choices do
    if let some fr := strField? choice "finish_reason" then
      s := { s with finish := FinishReason.ofString fr }
    let some delta := objField? choice "delta" | continue
    if let some c := strField? delta "content" then
      if !c.isEmpty then
        s := { s with content := s.content ++ c }
        emit (.textDelta c)
    let reasoning := (strField? delta "reasoning_content").getD
                       ((strField? delta "reasoning").getD "")
    if !reasoning.isEmpty then
      s := { s with reasoning := s.reasoning ++ reasoning }
      emit (.reasoningDelta reasoning)
    for tc in (arrField? delta "tool_calls").getD #[] do
      let idx := (natField? tc "index").getD 0
      s := s.ensureIndex idx
      let cur := s.calls[idx]!
      let mut next := cur
      if let some i := strField? tc "id" then
        if !i.isEmpty then next := { next with id := i }
      if let some f := objField? tc "function" then
        if let some n := strField? f "name" then
          if !n.isEmpty then next := { next with name := next.name ++ n }
        if let some a := strField? f "arguments" then
          if !a.isEmpty then
            next := { next with args := next.args ++ a }
            emit (.toolCallArgsDelta idx a)
      if cur.name.isEmpty && !next.name.isEmpty then
        emit (.toolCallStarted idx next.id next.name)
      s := { s with calls := s.calls.set! idx next }
  return s

def StreamState.finalize (s : StreamState) : ModelResponse :=
  let calls := s.calls.toList.filterMap fun c =>
    if c.name.isEmpty then none
    else some { id := if c.id.isEmpty then c.name else c.id,
                name := c.name,
                arguments := if c.args.isEmpty then "{}" else c.args : ToolCallRequest }
  { content := s.content
    reasoning := s.reasoning
    toolCalls := calls
    finishReason := if !calls.isEmpty then .toolCalls else s.finish
    usage := s.usage
    model := s.model }

/-! ### Provider construction -/

/-- Backoff before the next attempt, in milliseconds.

    A rate-limit answer is different in kind from a transient server error:
    the limit is usually per minute, so a sub-second retry is guaranteed to
    fail again and merely spends an attempt.  Those wait far longer. -/
def backoffMs (attempt : Nat) (rateLimited : Bool) : Nat :=
  if rateLimited then
    let ms := 15000 * (attempt + 1)
    if ms > 60000 then 60000 else ms
  else
    let ms := 600 * 2 ^ attempt
    if ms > 8000 then 8000 else ms

/-- Does this response mean "you are sending too many requests"? -/
def isRateLimited (status : Nat) (body : String) : Bool :=
  status == 429 || containsSubstrI body "rate limit" || containsSubstrI body "too many requests"

/-- Pace outbound requests so a per-minute provider cap is not tripped. -/
def throttle (lastRef : IO.Ref Nat) (minIntervalMs : Nat) : IO Unit := do
  if minIntervalMs == 0 then return
  let now ← IO.monoMsNow
  let last ← lastRef.get
  if last != 0 && now < last + minIntervalMs then
    IO.sleep (UInt32.ofNat (last + minIntervalMs - now))
  lastRef.set (← IO.monoMsNow)


private def endpoint (baseUrl : String) : String :=
  let b := if baseUrl.endsWith "/" then (baseUrl.dropEnd 1).toString else baseUrl
  b ++ "/chat/completions"

/-- Build an OpenAI-compatible provider from config.

    `apiKey` is captured here and only ever reaches the transport through
    `secretHeaders`, which the transport keeps out of process arguments. -/
def make (cfg : ProviderConfig) (apiKey : String) (http : HttpClient)
    (log : Logger) : IO ModelProvider := do
  let lastRequest ← IO.mkRef (0 : Nat)
  let secret : List (String × String) :=
    if apiKey.isEmpty then [] else [("Authorization", s!"Bearer {apiKey}")]
  let headers : List (String × String) :=
    [("Content-Type", "application/json")] ++
    (cfg.extraHeaders.filterMap fun h =>
      match h.splitOn ":" with
      | k :: rest => some (trim k, trim (String.intercalate ":" rest))
      | _ => none)
  let mkReq (body : String) : HttpRequest := {
    url := endpoint cfg.baseUrl
    method := "POST"
    headers := headers
    secretHeaders := secret
    body := some body
    timeoutSec := cfg.timeoutSec
    connectTimeoutSec := cfg.connectTimeoutSec }
  return {
    name := cfg.kind.toString
    model := cfg.model
    capabilities := { streaming := true, toolCalling := true, reasoning := true, vision := false }
    chat := fun req => do
      match requestToJson cfg.model { req with stream := false } with
      | .error e => return .error e
      | .ok j =>
        log.trace s!"model request: {truncate j.compress 600}"
        let body := j.compress
        let mut attempt := 0
        let mut lastErr := err .provider "no attempt made"
        let mut limited := false
        repeat
          throttle lastRequest cfg.minIntervalMs
          match ← http.request (mkReq body) with
          | .error e => lastErr := e; limited := false
          | .ok resp =>
            if resp.ok && !transientErrorBody resp.body then
              return parseResponse resp.body
            let detail := (parseErrorBody resp.body).getD (truncate resp.body 400)
            limited := isRateLimited resp.status resp.body
            lastErr := err .provider s!"provider returned HTTP {resp.status}" (some detail)
            if !(resp.retryable || transientErrorBody resp.body || limited) then
              return .error lastErr
          if attempt >= cfg.maxRetries then break
          let wait := backoffMs attempt limited
          log.debug s!"retrying model request in {wait}ms (attempt {attempt + 1}): {lastErr.message}"
          IO.sleep (UInt32.ofNat wait)
          attempt := attempt + 1
        return .error lastErr
    stream := fun req emit => do
      match requestToJson cfg.model { req with stream := true } with
      | .error e => return .error e
      | .ok j =>
       let body := j.compress
       let mut attempt := 0
       let mut lastErr := err .provider "no attempt made"
       let mut limited := false
       repeat
        throttle lastRequest cfg.minIntervalMs
        let stRef ← IO.mkRef ({} : StreamState)
        let onLine : String → IO Unit := fun line => do
          let l := trim line
          if l.isEmpty then return
          unless l.startsWith "data:" do return
          let payload := trim (l.drop 5).toString
          if payload == "[DONE]" then return
          match Json.parse payload with
          | .error _ => return       -- keep-alives and comments are ignored
          | .ok chunk =>
            let st ← stRef.get
            stRef.set (← applyChunk st chunk emit)
        let attemptResult ← http.stream (mkReq body) onLine
        match attemptResult with
        | .error e => lastErr := e
        | .ok resp =>
          let st ← stRef.get
          if st.sawData then
            let final := st.finalize
            emit (.finished final.finishReason)
            return .ok final
          -- No SSE payload: either an error document or a non-streaming server.
          limited := isRateLimited resp.status resp.body
          if transientErrorBody resp.body || resp.retryable || limited then
            lastErr := err .provider
              s!"provider unavailable (HTTP {resp.status})"
              (some ((parseErrorBody resp.body).getD (truncate resp.body 200)))
          else if let some msg := parseErrorBody resp.body then
            return .error (err .provider "provider returned an error" (some msg))
          else
            match parseResponse resp.body with
            | .ok r =>
              if !r.content.isEmpty then emit (.textDelta r.content)
              emit (.finished r.finishReason)
              return .ok r
            | .error e => return .error e
        if attempt >= cfg.maxRetries then break
        let wait := backoffMs attempt limited
        log.debug s!"retrying model stream in {wait}ms (attempt {attempt + 1}): {lastErr.message}"
        IO.sleep (UInt32.ofNat wait)
        attempt := attempt + 1
       return .error lastErr }

end LeanPrime.OpenAI
