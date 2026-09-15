/-
  LeanPrime.Agent.PromptLayers

  The prompt in force for a run, and the rules lifted out of it.

  An earlier revision merged six prompt sources by authority.  That is gone:
  `SystemPrompt.lean` is the only source, `LeanPrime.Prompt.Source` loads
  it, and this module is what the rest of the agent holds — the substituted
  text, where it came from, the directives, and the subset of those that can
  be checked mechanically.

  Nothing here adds instructions.  If the file is silent on something, so is
  the agent.
-/
import LeanPrime.Prompt.Source
import LeanPrime.Prompt.Compliance
import LeanPrime.Agent.Directives
import LeanPrime.Config.Schema
import LeanPrime.Config.Defaults

namespace LeanPrime

/-- The system prompt for a run, with everything derived from it. -/
structure PromptStack where
  /-- The final text sent to the model, after template substitution. -/
  text       : String
  /-- Which copy of `SystemPrompt.lean` produced it. -/
  origin     : PromptOrigin
  /-- Rules parsed out of the prompt. -/
  directives : List Directive
  /-- The subset that is checked against every reply. -/
  rules      : List (Nat × ComplianceRule)
  /-- `{{…}}` placeholders the prompt used that the loader does not know. -/
  unknownVars : List String
  deriving Inhabited

namespace PromptStack

def render (s : PromptStack) : String := s.text

def hasDirectives (s : PromptStack) : Bool := !s.directives.isEmpty

/-- Rules that will be enforced mechanically, not merely restated. -/
def enforcedCount (s : PromptStack) : Nat := s.rules.length

/-- A description of what is in force, for `--show-prompt` and `--doctor`. -/
def describe (s : PromptStack) : String :=
  let header :=
    [ s!"source            {s.origin}"
    , s!"length            {s.text.length} characters"
    , s!"directives        {s.directives.length}"
    , s!"enforced rules    {s.rules.length}" ]
  let unknown :=
    if s.unknownVars.isEmpty then []
    else [s!"unknown variables {String.intercalate ", " s.unknownVars}"]
  String.intercalate "\n" (header ++ unknown)

/-- The enforced rules, one per line. -/
def describeRules (s : PromptStack) : String :=
  if s.rules.isEmpty then "  (none — no rule in the prompt has a mechanically checkable shape)"
  else String.intercalate "\n"
    (s.rules.map fun (id, r) => s!"  ⊘ [{id}] {r.describe}")

end PromptStack

/-- Load and prepare the prompt for a run. -/
def buildPromptStack (cfg : Config) (workspace : System.FilePath)
    (vars : TemplateVars) : IO (LPResult PromptStack) := do
  match ← loadSystemPrompt workspace cfg.prompt.file with
  | .error e => return .error e
  | .ok loaded =>
    let text := applyTemplate vars loaded.text
    let directives :=
      if cfg.prompt.extractDirectives then extractDirectives loaded.text else []
    let rules :=
      if cfg.prompt.enforceCompliance then complianceRules directives else []
    return .ok {
      text := text
      origin := loaded.origin
      directives := directives
      rules := rules
      unknownVars := unknownPlaceholders loaded.text }

end LeanPrime
