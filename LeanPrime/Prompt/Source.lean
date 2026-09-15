/-
  LeanPrime.Prompt.Source

  Loading the system prompt.  There is exactly one source: `SystemPrompt.lean`.

  Previous revisions of this agent accepted a prompt from six places — a
  flag, a config key, a config file, an environment variable, a project
  file, and a hardcoded baseline — and merged them by authority.  That is
  flexible and it is also unanswerable: when the agent misbehaves you cannot
  say what it was told without reconstructing a merge.  One file has one
  answer.

  Resolution order is about *which copy* of that one file, never about
  combining several:

      1. --system-prompt <path>
      2. $LEANPRIME_SYSTEM_PROMPT_FILE
      3. <workspace>/SystemPrompt.lean
      4. <executable directory>/SystemPrompt.lean
      5. the copy compiled into the binary

  Nothing is appended to whatever wins.  If the text says nothing about
  tools, the model is told nothing about tools.
-/
import LeanPrime.Util.Prelude
import LeanPrime.Util.Errors
import LeanPrime.Util.Platform

namespace LeanPrime

/-- Marks the start of the prompt body inside `SystemPrompt.lean`. -/
def promptBeginMarker : String := "-- BEGIN SYSTEM PROMPT --"

/-- Marks the end of the prompt body. -/
def promptEndMarker : String := "-- END SYSTEM PROMPT --"

/-- Where the prompt in force came from.  Reported by `--show-prompt` so the
    question "what was it told" always has a one-line answer. -/
inductive PromptOrigin where
  | flagFile (path : String)
  | envFile (path : String)
  | workspaceFile (path : String)
  | installFile (path : String)
  | compiledIn
  deriving Repr, Inhabited

def PromptOrigin.toString : PromptOrigin → String
  | .flagFile p => s!"--system-prompt {p}"
  | .envFile p => s!"$LEANPRIME_SYSTEM_PROMPT_FILE → {p}"
  | .workspaceFile p => s!"{p} (workspace)"
  | .installFile p => s!"{p} (install directory)"
  | .compiledIn => "compiled into the binary"

instance : ToString PromptOrigin := ⟨PromptOrigin.toString⟩

/-- Extract the text between the markers.

    A file that has the markers but nothing between them is an error, not an
    empty prompt: silently running with no instructions is exactly the
    failure this module exists to make impossible. -/
def extractBetweenMarkers (src : String) (where_ : String) : LPResult String :=
  match src.splitOn promptBeginMarker with
  | [] | [_] =>
    .error (err .configuration s!"{where_} has no {promptBeginMarker} marker"
      none (some "the loader reads the text between the BEGIN and END markers"))
  | _ :: afterBegin =>
    let rest := String.intercalate promptBeginMarker afterBegin
    match rest.splitOn promptEndMarker with
    | [] | [_] =>
      .error (err .configuration s!"{where_} has no {promptEndMarker} marker")
    | body :: _ =>
      let t := trim body
      if t.isEmpty then
        .error (err .configuration s!"{where_} contains an empty system prompt"
          none (some "write the prompt between the BEGIN and END markers"))
      else .ok t

/-- Read and extract from a file, or `none` when the file is absent. -/
def loadPromptFile (p : System.FilePath) : IO (LPResult (Option String)) := do
  if !(← p.pathExists) then return .ok none
  let src ← try IO.FS.readFile p
    catch e => return .error (err .configuration s!"cannot read {p}" (some (toString e)))
  match extractBetweenMarkers src p.toString with
  | .error e => return .error e
  | .ok body => return .ok (some body)

/-- Directory holding the running executable, used for the install-dir copy. -/
def executableDir : IO (Option System.FilePath) := do
  try
    let exe ← IO.appPath
    return exe.parent
  catch _ => return none

/-- The prompt in force, and where it came from. -/
structure LoadedPrompt where
  text   : String
  origin : PromptOrigin
  deriving Inhabited

/-- The system prompt, compiled into the binary as a fallback.
    The runtime loader reads `SystemPrompt.lean` from disk first; this copy
    is used only when no file is found. -/
def compiledSystemPrompt : String := "
-- BEGIN SYSTEM PROMPT --

You are LEAN PRIME, an autonomous software engineering agent working in a terminal.

# Method

You do not answer from memory. You inspect the repository, form a plan, call tools,
read the real output, and check the result before you report.

Loop: understand -> inspect -> plan -> act -> observe -> verify -> report.

- Always read a file before editing it.
- Always prefer edit_file with an exact unique anchor over rewriting a whole file.
- Always run the build and the tests after changing code.
- Never disable, skip or delete a test to make it pass.
- Never refactor code the task did not ask you to touch.
- Always review the diff before reporting.
- Never claim a result you have not observed.

# Reporting

Call tools rather than describing what you would do. When there is nothing left to
call, write the report as plain prose: what you changed, what you ran, what happened.

# Environment

Project: {{PROJECT_KIND}}
Workspace: {{WORKSPACE}}
Branch: {{GIT_BRANCH}}
Mode: {{MODE}}

Tools available:
{{TOOL_DETAIL}}

-- END SYSTEM PROMPT --
"

/-- Resolve the one system prompt for this run. -/
def loadSystemPrompt (workspace : System.FilePath) (flagPath : Option System.FilePath)
    : IO (LPResult LoadedPrompt) := do
  -- 1. explicit flag: must exist, because a typo here is indistinguishable
  --    from the prompt being ignored
  if let some p := flagPath then
    match ← loadPromptFile p with
    | .error e => return .error e
    | .ok none => return .error (err .configuration s!"system prompt file not found: {p}")
    | .ok (some t) => return .ok { text := t, origin := .flagFile p.toString }
  -- 2. environment, same rule
  if let some v ← IO.getEnv "LEANPRIME_SYSTEM_PROMPT_FILE" then
    let p := System.FilePath.mk v
    match ← loadPromptFile p with
    | .error e => return .error e
    | .ok none =>
      return .error (err .configuration
        s!"LEANPRIME_SYSTEM_PROMPT_FILE points at a file that does not exist: {p}")
    | .ok (some t) => return .ok { text := t, origin := .envFile p.toString }
  -- 3. workspace
  let wsFile := workspace / "SystemPrompt.lean"
  match ← loadPromptFile wsFile with
  | .error e => return .error e
  | .ok (some t) => return .ok { text := t, origin := .workspaceFile wsFile.toString }
  | .ok none =>
    -- 4. next to the executable
    match ← executableDir with
    | some dir =>
      let instFile := dir / "SystemPrompt.lean"
      match ← loadPromptFile instFile with
      | .error e => return .error e
      | .ok (some t) => return .ok { text := t, origin := .installFile instFile.toString }
      | .ok none => pure ()
    | none => pure ()
    -- 5. compiled in
    match extractBetweenMarkers compiledSystemPrompt "the compiled-in prompt" with
    | .error e => return .error e
    | .ok t => return .ok { text := t, origin := .compiledIn }

/-! ### Template substitution -/

/-- Values available to `{{...}}` placeholders. -/
structure TemplateVars where
  tools       : String := ""
  toolDetail  : String := ""
  projectKind : String := ""
  workspace   : String := ""
  gitBranch   : String := ""
  gitStatus   : String := ""
  mode        : String := ""
  task        : String := ""
  deriving Inhabited

/-- Every placeholder the loader understands, for documentation and for the
    unknown-placeholder warning below. -/
def templateNames : List String :=
  ["TOOLS", "TOOL_DETAIL", "PROJECT_KIND", "WORKSPACE", "GIT_BRANCH",
   "GIT_STATUS", "MODE", "TASK"]

/-- Substitute placeholders.  A placeholder the prompt does not use costs
    nothing, and one it uses that we do not know is left alone rather than
    blanked, so a typo is visible in the prompt instead of silently erasing
    a line. -/
def applyTemplate (v : TemplateVars) (body : String) : String :=
  body
    |>.replace "{{TOOLS}}" v.tools
    |>.replace "{{TOOL_DETAIL}}" v.toolDetail
    |>.replace "{{PROJECT_KIND}}" v.projectKind
    |>.replace "{{WORKSPACE}}" v.workspace
    |>.replace "{{GIT_BRANCH}}" v.gitBranch
    |>.replace "{{GIT_STATUS}}" v.gitStatus
    |>.replace "{{MODE}}" v.mode
    |>.replace "{{TASK}}" v.task

/-- Placeholders present in the text that the loader does not recognise. -/
def unknownPlaceholders (body : String) : List String :=
  let pieces := (body.splitOn "{{").drop 1
  let names := pieces.filterMap fun piece =>
    match piece.splitOn "}}" with
    | name :: _ :: _ => some (trim name)
    | _ => none
  (names.filter (fun n => !templateNames.contains n)).eraseDups

end LeanPrime
