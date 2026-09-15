import LeanPrime.Model.OpenAI
open LeanPrime

def main : IO Unit := do
  let ws ← IO.currentDir
  let cfg := defaultConfig ws
  let some key ← readApiKey cfg | IO.println "no API key"; return
  let log : Logger := { Logger.default with minLevel := .info }
  let p := OpenAI.make cfg.provider key Curl.client log
  IO.println s!"provider={p.name} model={p.model}"
  -- 1. non-streaming
  let req : ModelRequest := {
    messages := [Message.system "You are terse.", Message.user "Say exactly: ALPHA"],
    maxTokens := 8192 }
  match ← p.chat req with
  | .error e => IO.println s!"CHAT ERROR: {e}"
  | .ok r => IO.println s!"chat: content={r.content.trimAscii.toString} finish={r.finishReason} usage={r.usage.totalTokens}"
  -- 2. streaming
  IO.println "stream: "
  let req2 : ModelRequest := {
    messages := [Message.user "Count: one two three"], maxTokens := 8192, stream := true }
  let out ← IO.getStdout
  match ← p.stream req2 (fun ev => match ev with
      | .textDelta s => out.putStr s *> out.flush
      | .finished r => out.putStrLn s!"\n[finish={r}]"
      | _ => pure ()) with
  | .error e => IO.println s!"STREAM ERROR: {e}"
  | .ok r => IO.println s!"stream total len={r.content.length}"
  -- 3. tool calling
  let schema : ToolSchema := {
    name := "read_file", description := "Read a file",
    parameters := Lean.Json.mkObj [
      ("type", .str "object"),
      ("properties", Lean.Json.mkObj [("path", Lean.Json.mkObj [("type", .str "string")])]),
      ("required", .arr #[.str "path"])] }
  let req3 : ModelRequest := {
    messages := [Message.user "Read the file README.md. Use the tool."],
    tools := [schema], maxTokens := 8192, stream := true }
  match ← p.stream req3 (fun _ => pure ()) with
  | .error e => IO.println s!"TOOL ERROR: {e}"
  | .ok r => IO.println s!"toolCalls={r.toolCalls.map (fun c => (c.name, c.arguments))} finish={r.finishReason}"
