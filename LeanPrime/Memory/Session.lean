/-
  LeanPrime.Memory.Session

  Session persistence and project memory.

  Two layers are durable:
    * the session — the conversation and what was touched, so `--resume`
      can continue intelligently;
    * project memory — durable facts about a repository (its build command,
      its conventions), keyed by workspace path so they survive across runs.

  Both are stored as JSON under the platform state directory.  Message
  content is redacted on the way out: a session file must never become a
  place where a credential comes to rest.
-/
import LeanPrime.Agent.State
import LeanPrime.Util.Platform
import LeanPrime.Util.Logging

open Lean

namespace LeanPrime

structure SessionRecord where
  id        : String
  task      : String
  workspace : String
  model     : String
  phase     : String
  summary   : String
  touched   : List String
  /-- Conversation, as role/text pairs. Tool call structure is not replayed;
      a resumed session continues from the transcript, not mid-tool-call. -/
  turns     : List (String × String)
  deriving Inhabited

namespace SessionRecord

def toJson (r : SessionRecord) : Json :=
  Json.mkObj
    [ ("id", .str r.id), ("task", .str r.task), ("workspace", .str r.workspace)
    , ("model", .str r.model), ("phase", .str r.phase), ("summary", .str r.summary)
    , ("touched", .arr (r.touched.toArray.map Json.str))
    , ("turns", .arr (r.turns.toArray.map fun (role, text) =>
        Json.mkObj [("role", .str role), ("text", .str text)])) ]

def ofJson? (j : Json) : Option SessionRecord :=
  let str (k : String) : String :=
    match j.getObjVal? k with | .ok (.str s) => s | _ => ""
  let arr (k : String) : Array Json :=
    match j.getObjVal? k with | .ok (.arr a) => a | _ => #[]
  if (str "id").isEmpty then none
  else some {
    id := str "id", task := str "task", workspace := str "workspace"
    model := str "model", phase := str "phase", summary := str "summary"
    touched := (arr "touched").toList.filterMap (fun x =>
      match x with | .str s => some s | _ => none)
    turns := (arr "turns").toList.filterMap (fun t =>
      match t.getObjVal? "role", t.getObjVal? "text" with
      | .ok (.str r), .ok (.str x) => some (r, x)
      | _, _ => none) }

/-- Build a record from live agent state. -/
def ofState (id task workspace model : String) (st : AgentState) (summary : String)
    : SessionRecord :=
  { id := id, task := task, workspace := workspace, model := model
    phase := st.phase.toString, summary := summary, touched := st.touchedFiles
    turns := st.messages.map (fun m => (m.role.toString, m.plainText)) }

/-- Restore the conversation for `--resume`. -/
def toMessages (r : SessionRecord) : List Message :=
  r.turns.map fun (role, text) =>
    let rl := match role with
      | "system" => Role.system | "assistant" => Role.assistant
      | "tool" => Role.tool | _ => Role.user
    Message.text rl text

end SessionRecord

def sessionsDir : IO System.FilePath := do
  return (← stateHome) / "sessions"

def sessionPath (id : String) : IO System.FilePath := do
  return (← sessionsDir) / s!"{id}.json"

/-- Persist a session.  Failures are logged, never fatal: losing a session
    file must not lose the user's work. -/
def saveSession (r : SessionRecord) (log : Logger) : IO Unit := do
  try
    let dir ← sessionsDir
    IO.FS.createDirAll dir
    let path ← sessionPath r.id
    IO.FS.writeFile path (redact r.toJson.pretty)
    IO.setAccessRights path { user := { read := true, write := true } }
    log.debug s!"session saved: {path}"
  catch e =>
    log.warn s!"could not save session: {e}"

def loadSession (id : String) : IO (LPResult SessionRecord) := do
  let path ← sessionPath id
  if !(← path.pathExists) then
    return .error (err .configuration s!"no such session: {id}"
      none (some "list sessions with `lean-prime --sessions`"))
  let src ← try IO.FS.readFile path
    catch e => return .error (err .file s!"cannot read session {id}" (some (toString e)))
  match Json.parse src with
  | .error e => return .error (err .parse s!"session {id} is corrupt" (some e))
  | .ok j => match SessionRecord.ofJson? j with
    | some r => return .ok r
    | none => return .error (err .parse s!"session {id} is missing required fields")

/-- List stored sessions, newest first by filename. -/
def listSessions : IO (List (String × String)) := do
  let dir ← sessionsDir
  if !(← dir.pathExists) then return []
  let entries ← try dir.readDir catch _ => pure #[]
  let mut out : List (String × String) := []
  for e in entries do
    if e.path.extension == some "json" then
      let src ← try IO.FS.readFile e.path catch _ => continue
      match Json.parse src with
      | .error _ => continue
      | .ok j => match SessionRecord.ofJson? j with
        | some r => out := out ++ [(r.id, r.task)]
        | none => continue
  return out

/-! ### Project memory -/

/-- Durable facts about one workspace. -/
structure ProjectMemory where
  workspace    : String
  buildCommand : Option String := none
  testCommand  : Option String := none
  notes        : List String := []
  deriving Inhabited

def ProjectMemory.toJson (m : ProjectMemory) : Json :=
  Json.mkObj
    [ ("workspace", .str m.workspace)
    , ("build_command", match m.buildCommand with | some c => .str c | none => .null)
    , ("test_command", match m.testCommand with | some c => .str c | none => .null)
    , ("notes", .arr (m.notes.toArray.map Json.str)) ]

/-- Memory file name derived from the workspace path, so two checkouts of
    the same project keep separate memory. -/
private def memoryKey (ws : String) : String :=
  let cleaned := ws.toList.map (fun c => if c.isAlphanum then c else '_')
  truncate (String.ofList cleaned) 80

def memoryPath (ws : String) : IO System.FilePath := do
  return (← stateHome) / "projects" / s!"{memoryKey ws}.json"

def saveProjectMemory (m : ProjectMemory) (log : Logger) : IO Unit := do
  try
    let path ← memoryPath m.workspace
    if let some parent := path.parent then IO.FS.createDirAll parent
    IO.FS.writeFile path (redact m.toJson.pretty)
  catch e => log.warn s!"could not save project memory: {e}"

def loadProjectMemory (ws : String) : IO (Option ProjectMemory) := do
  let path ← memoryPath ws
  if !(← path.pathExists) then return none
  let src ← try IO.FS.readFile path catch _ => return none
  match Json.parse src with
  | .error _ => return none
  | .ok j =>
    let str (k : String) : Option String :=
      match j.getObjVal? k with | .ok (.str s) => some s | _ => none
    return some {
      workspace := (str "workspace").getD ws
      buildCommand := str "build_command"
      testCommand := str "test_command"
      notes := match j.getObjVal? "notes" with
        | .ok (.arr a) => a.toList.filterMap (fun x => match x with | .str s => some s | _ => none)
        | _ => [] }

end LeanPrime
