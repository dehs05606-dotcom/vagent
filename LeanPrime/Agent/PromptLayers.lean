/-
  LeanPrime.Agent.PromptLayers

  The system prompt is assembled from ordered layers, not hardcoded.

  Before this existed, `systemPrompt` was a single function with the agent's
  operating instructions baked in, and there was no way for an operator to
  supply their own.  That is a real defect: the person running the agent
  should be the highest authority in the run, and instead the only authority
  was whatever the source happened to say.

  Now every source of instruction is a `PromptLayer` with

    * an explicit **authority** — operator layers outrank built-in ones;
    * a **pinned** flag — pinned layers are exempt from context trimming, so
      the operator's rules cannot be the thing that gets dropped when the
      conversation grows;
    * a **sticky** flag — sticky layers are re-asserted on a cadence, which
      is what actually keeps a long run on-instruction.

  `PromptMode.replace` drops the built-in baseline entirely: the operator's
  text becomes the whole system prompt.
-/
import LeanPrime.Agent.Directives
import LeanPrime.Config.Schema
import LeanPrime.Config.Defaults
import LeanPrime.Util.Platform

namespace LeanPrime

/-- Where a layer came from.  Kept so `--doctor` and the transcript can show
    the operator exactly which instructions are in force and from where —
    a prompt you cannot inspect is a prompt you cannot debug. -/
inductive LayerSource where
  | cliFlag
  | configInline
  | configFile (path : String)
  | projectFile (name : String)
  | environment (varName : String)
  | builtinBaseline
  | runtimeFacts
  deriving Repr, Inhabited

def LayerSource.toString : LayerSource → String
  | .cliFlag => "command line"
  | .configInline => "config [prompt].system"
  | .configFile p => s!"config file {p}"
  | .projectFile n => s!"project file {n}"
  | .environment v => s!"environment {v}"
  | .builtinBaseline => "built-in baseline"
  | .runtimeFacts => "runtime facts"

instance : ToString LayerSource := ⟨LayerSource.toString⟩

/-- Is this layer the operator speaking, as opposed to LeanPrime itself? -/
def LayerSource.isOperator : LayerSource → Bool
  | .builtinBaseline | .runtimeFacts => false
  | _ => true

structure PromptLayer where
  source    : LayerSource
  /-- Higher wins.  Operator layers sit above the baseline by construction. -/
  authority : Nat
  /-- Exempt from context trimming. -/
  pinned    : Bool
  /-- Re-asserted periodically during the run. -/
  sticky    : Bool
  text      : String
  deriving Inhabited

/-- Authority ladder.  The numbers are spaced so a layer can be inserted
    between two existing ones without renumbering. -/
def authorityOf : LayerSource → Nat
  | .cliFlag          => 100   -- typed for this run: the most specific intent
  | .configInline     => 90
  | .configFile _     => 90
  | .environment _    => 80
  | .projectFile _    => 70    -- the repository's own conventions
  | .builtinBaseline  => 20
  | .runtimeFacts     => 10

/-- The assembled prompt plus everything the run needs to keep honouring it. -/
structure PromptStack where
  layers     : List PromptLayer
  /-- Rules lifted from the operator layers. -/
  directives : List Directive
  deriving Inhabited

namespace PromptStack

/-- Layers in force, strongest first. -/
def ordered (s : PromptStack) : List PromptLayer :=
  (s.layers.toArray.qsort (fun a b => a.authority > b.authority)).toList

/-- Only the operator's own layers. -/
def operatorLayers (s : PromptStack) : List PromptLayer :=
  s.layers.filter (fun l => l.source.isOperator)

def hasOperatorPrompt (s : PromptStack) : Bool :=
  !s.operatorLayers.isEmpty

/-- Render the full system prompt.

    When the operator has supplied instructions, they are stated first and
    labelled as governing, so their position in the text agrees with their
    position in the authority ladder. -/
def render (s : PromptStack) : String :=
  let ls := s.ordered
  let body := ls.map fun l =>
    if l.source.isOperator then
      s!"# Operating instructions ({l.source})\n\n{l.text}"
    else
      l.text
  let header :=
    if s.hasOperatorPrompt then
      String.intercalate "\n"
        [ "The instructions below are in force for this run, strongest first."
        , "Sections marked 'Operating instructions' come from the operator and"
        , "govern everything that follows them, including your own defaults."
        , "" ]
    else ""
  header ++ String.intercalate "\n\n" body

/-- A compact description of what is in force, for `--doctor`. -/
def describe (s : PromptStack) : String :=
  let rows := s.ordered.map fun l =>
    s!"  {padLeft (toString l.authority) 4}  {padRight l.source.toString 34} \
       {(if l.pinned then "pinned " else "       ")}\
       {(if l.sticky then "sticky " else "       ")}{l.text.length} chars"
  String.intercalate "\n" rows

end PromptStack

/-- Read a prompt file, returning `none` when it does not exist and an error
    only when it exists but cannot be read. -/
def readPromptFile (p : System.FilePath) : IO (LPResult (Option String)) := do
  if !(← p.pathExists) then return .ok none
  try
    let s ← IO.FS.readFile p
    let t := trim s
    return .ok (if t.isEmpty then none else some t)
  catch e =>
    return .error (err .configuration s!"cannot read prompt file {p}" (some (toString e)))

/-- Collect every operator-supplied layer, in the order they are consulted.

    `cliText` is whatever the command line supplied; `cliFile` a file it
    named.  Both outrank the config file, which outranks the environment,
    which outranks the repository's own instructions. -/
def collectOperatorLayers (cfg : Config) (workspace : System.FilePath)
    (cliText : Option String) (cliFile : Option System.FilePath)
    : IO (LPResult (List PromptLayer)) := do
  let mut layers : List PromptLayer := []
  let add (src : LayerSource) (text : String) (ls : List PromptLayer) : List PromptLayer :=
    if (trim text).isEmpty then ls
    else ls ++ [{ source := src, authority := authorityOf src
                  pinned := true, sticky := true, text := trim text }]

  if let some t := cliText then
    layers := add .cliFlag t layers
  if let some f := cliFile then
    match ← readPromptFile f with
    | .error e => return .error e
    | .ok none =>
      -- A file named explicitly on the command line must exist; silently
      -- ignoring a typo here would look exactly like the prompt being
      -- disobeyed, which is the failure this whole module exists to fix.
      return .error (err .configuration s!"system prompt file not found: {f}")
    | .ok (some t) => layers := add .cliFlag t layers

  if let some t := cfg.prompt.text then
    layers := add .configInline t layers
  if let some f := cfg.prompt.file then
    match ← readPromptFile f with
    | .error e => return .error e
    | .ok none => return .error (err .configuration s!"system prompt file not found: {f}")
    | .ok (some t) => layers := add (.configFile f.toString) t layers

  if let some t ← IO.getEnv "LEANPRIME_SYSTEM_PROMPT" then
    layers := add (.environment "LEANPRIME_SYSTEM_PROMPT") t layers

  for name in cfg.prompt.projectFiles do
    match ← readPromptFile (workspace / name) with
    | .error _ => continue          -- an unreadable project file is not fatal
    | .ok none => continue
    | .ok (some t) =>
      layers := add (.projectFile name) t layers
      break                          -- first match wins

  return .ok layers

/-- Build the complete stack for a run. -/
def buildPromptStack (cfg : Config) (workspace : System.FilePath)
    (baseline : String) (runtimeFacts : String)
    (cliText : Option String) (cliFile : Option System.FilePath)
    : IO (LPResult PromptStack) := do
  match ← collectOperatorLayers cfg workspace cliText cliFile with
  | .error e => return .error e
  | .ok operator =>
    let baselineLayer : PromptLayer :=
      { source := .builtinBaseline, authority := authorityOf .builtinBaseline
        pinned := true, sticky := false, text := baseline }
    let factsLayer : PromptLayer :=
      { source := .runtimeFacts, authority := authorityOf .runtimeFacts
        pinned := true, sticky := false, text := runtimeFacts }
    -- `replace` means exactly that: with operator instructions present, the
    -- built-in operating instructions are dropped.  Runtime facts survive
    -- because they are environment description, not instruction.
    let layers :=
      match cfg.prompt.mode with
      | .replace =>
        if operator.isEmpty then [baselineLayer, factsLayer]
        else operator ++ [factsLayer]
      | .prepend | .append => operator ++ [baselineLayer, factsLayer]
    let directives :=
      if cfg.prompt.extractDirectives then
        extractDirectives (String.intercalate "\n" (operator.map PromptLayer.text))
      else []
    return .ok { layers := layers, directives := directives }

end LeanPrime
