/-
  LeanPrime.Prompt.Compliance

  Mechanical enforcement of the rules in `SystemPrompt.lean`.

  Re-stating a rule to a model is a request.  This module is the part that
  does not depend on the model agreeing: rules of a checkable shape are
  extracted into `ComplianceRule` values, every reply is checked against
  them in Lean, and a reply that breaks one is **rejected** — not warned
  about, not logged and passed on.  The model is handed the exact rule it
  broke and asked again, and the run does not proceed on a reply that fails.

  Scope, stated plainly because the difference matters: only rules with a
  mechanically decidable shape are enforced here.

      enforced          "always begin ... with the exact line: `X`"
                        "always end ... with `X`"
                        "always include \"X\""
                        "never use the word \"X\""

      not enforced      "always write clean code"
                        "never do anything risky"

  The second kind is still extracted as a directive, re-asserted through the
  run, and put to the model in the closing adherence check.  It simply is
  not something a string comparison can decide, and pretending otherwise
  would be the dishonest kind of "guarantee".
-/
import LeanPrime.Agent.Directives

namespace LeanPrime

/-- A rule that can be decided by looking at the text. -/
inductive ComplianceRule where
  | mustStartWith (needle : String)
  | mustEndWith (needle : String)
  | mustContain (needle : String)
  | mustNotContain (needle : String)
  deriving Repr, Inhabited, BEq

def ComplianceRule.describe : ComplianceRule → String
  | .mustStartWith s => s!"must begin with: {s}"
  | .mustEndWith s => s!"must end with: {s}"
  | .mustContain s => s!"must contain: {s}"
  | .mustNotContain s => s!"must not contain: {s}"

/-- Payload of a rule, for building the correction message. -/
def ComplianceRule.needle : ComplianceRule → String
  | .mustStartWith s | .mustEndWith s | .mustContain s | .mustNotContain s => s

/-! ### Extracting the payload

    Operators write the thing to match inside backticks or double quotes.
    Anything else is too ambiguous to act on, and guessing would produce
    rules that reject valid replies — worse than not enforcing at all. -/

/-- Text between the first pair of `` ` `` or `"` delimiters, if any. -/
def quotedPayload? (s : String) : Option String :=
  let between (delim : String) : Option String :=
    match s.splitOn delim with
    | _ :: mid :: _ => let t := trim mid; if t.isEmpty then none else some t
    | _ => none
  match between "`" with
  | some t => some t
  | none => between "\""

/-- Does the line talk about the beginning of the output? -/
private def mentionsStart (lower : String) : Bool :=
  ["begin", "start", "open with", "first line", "prefix"].any (containsSubstr lower)

private def mentionsEnd (lower : String) : Bool :=
  ["end with", "finish with", "close with", "last line", "suffix",
   "end your", "ending"].any (containsSubstr lower)

private def mentionsInclude (lower : String) : Bool :=
  ["include", "contain", "mention", "state the", "add the"].any (containsSubstr lower)

/-- Turn one directive into a checkable rule, when it has a checkable shape. -/
def ruleOf? (d : Directive) : Option ComplianceRule :=
  match quotedPayload? d.text with
  | none => none
  | some payload =>
    let lower := toLower d.text
    match d.force with
    | .prohibition =>
      -- "never use the word `x`", "do not mention `x`"
      some (.mustNotContain payload)
    | .obligation =>
      if mentionsStart lower then some (.mustStartWith payload)
      else if mentionsEnd lower then some (.mustEndWith payload)
      else if mentionsInclude lower then some (.mustContain payload)
      else none
    | .preference => none      -- a preference is not a hard check

/-- Every checkable rule in a directive list, paired with its directive id. -/
def complianceRules (ds : List Directive) : List (Nat × ComplianceRule) :=
  ds.filterMap fun d => (ruleOf? d).map (fun r => (d.id, r))

/-! ### Checking -/

structure Violation where
  directiveId : Nat
  rule        : ComplianceRule
  /-- What the reply did instead, for the correction message. -/
  observed    : String
  deriving Repr, Inhabited

/-- Compare ignoring surrounding whitespace, since a model's leading blank
    line is not a violation of "begin with". -/
private def normalized (s : String) : String := trim s

/-- Check one rule against a reply. -/
def checkRule (reply : String) (id : Nat) (rule : ComplianceRule) : Option Violation :=
  let body := normalized reply
  match rule with
  | .mustStartWith needle =>
    if body.startsWith needle then none
    else some { directiveId := id, rule := rule
                observed := s!"the reply begins: {truncate (normalized (body.take 80).toString) 80}" }
  | .mustEndWith needle =>
    if body.endsWith needle then none
    else
      let tailText := if body.length <= 80 then body else (body.drop (body.length - 80)).toString
      some { directiveId := id, rule := rule
             observed := s!"the reply ends: {normalized tailText}" }
  | .mustContain needle =>
    if containsSubstr body needle then none
    else some { directiveId := id, rule := rule, observed := "it is absent from the reply" }
  | .mustNotContain needle =>
    if !containsSubstrI body needle then none
    else some { directiveId := id, rule := rule, observed := "it appears in the reply" }

/-- Every rule the reply breaks. -/
def checkCompliance (rules : List (Nat × ComplianceRule)) (reply : String)
    : List Violation :=
  rules.filterMap fun (id, r) => checkRule reply id r

/-- Is this reply acceptable? -/
def compliant (rules : List (Nat × ComplianceRule)) (reply : String) : Bool :=
  (checkCompliance rules reply).isEmpty

/-- The correction handed back when a reply is rejected.

    Names the rule, quotes the payload exactly, and says what the reply did
    instead — a model cannot fix a violation it has only been told about in
    the abstract. -/
def correctionMessage (vs : List Violation) : String :=
  if vs.isEmpty then "" else
  String.intercalate "\n"
    ([ "Your reply was rejected: it breaks rules from the system prompt that are"
     , "checked mechanically. It has not been shown to anyone. Write it again."
     , "" ]
     ++ vs.map (fun v =>
          s!"  ✗ rule [{v.directiveId}] — {v.rule.describe}\n    {v.observed}")
     ++ [ ""
        , "Reproduce the required text exactly, character for character."
        , "Change nothing else about the substance of your answer." ])

/-- One-line summary for the transcript and the status bar. -/
def violationSummary (vs : List Violation) : String :=
  String.intercalate ", " (vs.map fun v => s!"[{v.directiveId}] {v.rule.describe}")

end LeanPrime
