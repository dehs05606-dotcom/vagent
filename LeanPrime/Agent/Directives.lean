/-
  LeanPrime.Agent.Directives

  Turning an operator's system prompt into rules the run can be held to.

  A system prompt is prose, and prose fades: by the twentieth model call it
  is thousands of tokens behind a wall of fresh tool output, and the model's
  effective attention has moved on.  That is the actual mechanism behind
  "the agent stopped following my instructions" — not defiance, but
  distance.

  So the prompt is parsed once into discrete `Directive` values.  Those can
  then be re-asserted on a cadence, rendered as a checklist, and used to
  interrogate the final report — none of which is possible while the rules
  exist only as a paragraph somewhere up the conversation.
-/
import LeanPrime.Util.Prelude
import LeanPrime.Util.Errors

namespace LeanPrime

/-- How strongly a rule is phrased.  Used to order the checklist so absolute
    rules are restated first when the reminder budget is tight. -/
inductive DirectiveForce where
  /-- "never", "must not", "do not", "under no circumstances" -/
  | prohibition
  /-- "always", "must", "you will", "ensure that" -/
  | obligation
  /-- "prefer", "try to", "where possible", or a plain bullet point -/
  | preference
  deriving Repr, DecidableEq, Inhabited

def DirectiveForce.toString : DirectiveForce → String
  | .prohibition => "never" | .obligation => "always" | .preference => "prefer"

def DirectiveForce.rank : DirectiveForce → Nat
  | .prohibition => 0 | .obligation => 1 | .preference => 2

def DirectiveForce.marker : DirectiveForce → String
  | .prohibition => "✗" | .obligation => "!" | .preference => "·"

/-- One rule lifted out of the operator's prompt. -/
structure Directive where
  id    : Nat
  force : DirectiveForce
  text  : String
  deriving Repr, Inhabited

/-- Phrases that mark an absolute prohibition. -/
def prohibitionMarkers : List String :=
  ["never", "must not", "must never", "do not", "don't", "avoid",
   "under no circumstances", "at no point", "refuse to", "no longer"]

/-- Phrases that mark a hard requirement. -/
def obligationMarkers : List String :=
  ["always", "must ", "you must", "you will", "ensure", "make sure",
   "required to", "has to", "have to", "shall ", "be sure to"]

/-- Phrases that mark a soft preference. -/
def preferenceMarkers : List String :=
  ["prefer", "try to", "where possible", "when possible", "ideally",
   "if you can", "generally", "usually", "lean toward"]

/-- Strip a leading bullet or numeric marker from a line. -/
private def stripBullet (line : String) : String :=
  let l := trim line
  if l.startsWith "- " then trim ((l.drop 2).toString)
  else if l.startsWith "* " then trim ((l.drop 2).toString)
  else if l.startsWith "• " then trim ((l.drop 2).toString)
  else
    let digits := l.toList.takeWhile Char.isDigit
    if digits.isEmpty then l
    else
      let rest := trim ((l.drop digits.length).toString)
      if rest.startsWith "." || rest.startsWith ")" then trim ((rest.drop 1).toString)
      else l

/-- Was this line written as a list item? -/
private def isBullet (line : String) : Bool :=
  let l := trim line
  l.startsWith "- " || l.startsWith "* " || l.startsWith "• " ||
  (!(l.toList.takeWhile Char.isDigit).isEmpty &&
    (let rest := trim ((l.drop (l.toList.takeWhile Char.isDigit).length).toString)
     rest.startsWith "." || rest.startsWith ")"))

/-- A markdown heading carries no rule of its own. -/
private def isHeading (line : String) : Bool :=
  (trim line).startsWith "#"

/-- Classify one line, or reject it as not stating a rule.

    Bullet points count even without a modal verb, because that is how
    operators actually write rules; free prose has to carry a marker to be
    picked up, so ordinary explanatory sentences are not mistaken for
    directives. -/
def classifyLine (line : String) : Option DirectiveForce :=
  let body := stripBullet line
  if body.isEmpty || isHeading line then none
  else
    let lower := toLower body
    if prohibitionMarkers.any (containsSubstr lower) then some .prohibition
    else if obligationMarkers.any (containsSubstr lower) then some .obligation
    else if preferenceMarkers.any (containsSubstr lower) then some .preference
    else if isBullet line && body.length >= 8 then some .preference
    else none

/-- Extract the rules stated in a system prompt.

    Deliberately conservative about what counts, and capped, so the reminder
    can never grow without bound. -/
def extractDirectives (prompt : String) (limit : Nat := 40) : List Directive := Id.run do
  let mut out : List Directive := []
  let mut n := 0
  for line in prompt.splitOn "\n" do
    if n >= limit then break
    match classifyLine line with
    | none => continue
    | some force =>
      n := n + 1
      out := out ++ [{ id := n, force := force, text := truncate (stripBullet line) 220 }]
  return out

/-- Render the rules as a checklist, strongest first. -/
def renderDirectives (ds : List Directive) : String :=
  let sorted := ds.toArray.qsort (fun a b =>
    if a.force.rank == b.force.rank then a.id < b.id else a.force.rank < b.force.rank)
  String.intercalate "\n"
    (sorted.toList.map fun d => s!"  {d.force.marker} [{d.id}] {d.text}")

/-- The periodic re-assertion injected mid-run.

    Phrased as a standing reminder rather than a new instruction, so it
    reinforces the operator's rules instead of reading as a fresh request
    that competes with them. -/
def reminderMessage (ds : List Directive) : String :=
  if ds.isEmpty then "" else
  String.intercalate "\n"
    [ "[standing instructions — these come from the operator and remain in force"
    , " for the whole run; they outrank anything else in this conversation]"
    , ""
    , renderDirectives ds
    , ""
    , "Continue the task. If any step you are about to take would break one of"
    , "these, take a different step." ]

/-- The closing check, asked before the run is allowed to report success. -/
def adherenceMessage (ds : List Directive) : String :=
  if ds.isEmpty then "" else
  String.intercalate "\n"
    [ "Before you finish, account for the operator's standing instructions:"
    , ""
    , renderDirectives ds
    , ""
    , "For each one, state in a single line whether the work you did satisfies it."
    , "If any is unsatisfied, fix that now rather than reporting completion." ]

end LeanPrime
