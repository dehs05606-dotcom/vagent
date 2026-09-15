/-
  LeanPrime.Prompt.Compiler

  Compiling the operator's prose into behavioural rules.

  `Compliance.lean` compiles a directive only when it carries a quoted
  payload — `` always end with `DONE` `` becomes a checkable rule, and
  everything else becomes nothing.  For a prompt written the way operators
  actually write them, that means almost nothing is enforced:

      "Always read a file before editing it."          → no rule
      "Always run the build and tests after changing." → no rule
      "Never disable a test to make it pass."          → no rule

  Every one of those is mechanically decidable.  Not against the reply's
  text — against the trace of what the agent did.  This module is the
  parser that recognises them.

  ## How it recognises

  Each pattern is a conjunction of required phrase groups, checked against
  the lower-cased directive.  A rule fires only when every group matches,
  which is what keeps "never delete the build directory" from compiling to
  the test-suppression rule just because both contain "delete".

  Recognition is deliberately narrow.  A directive that matches nothing
  compiles to no predicate, stays a directive, is restated through the run,
  and goes to the adversarial reviewer.  That is the honest outcome: a
  missed rule is handled by a weaker layer, whereas a wrongly-compiled rule
  blocks legitimate work and teaches the operator not to trust the system.

  ## What deliberately does not compile

  Rules needing a model of intent — "never refactor code the task did not
  ask you to touch", "keep the tone direct" — have no entry here.  They are
  not mechanically decidable and no amount of keyword matching makes them
  so.
-/
import LeanPrime.Prompt.Predicate
import LeanPrime.Agent.Directives

namespace LeanPrime

/-- Does the text contain at least one phrase from every group? -/
private def allGroups (lower : String) (groups : List (List String)) : Bool :=
  groups.all (fun g => g.any (containsSubstr lower))

/-! ### Marker vocabularies

    These are what the compiled predicates actually match against at
    runtime.  Written out as literals rather than regexes so a reader can
    see exactly what will and will not trip a rule. -/

/-- Ways a test gets suppressed, across the common frameworks. -/
def testSuppressionMarkers : List String :=
  [ ".skip(", ".only(", "xit(", "xdescribe(", "it.skip", "describe.skip"
  , "@ignore", "@disabled", "@skip", "#[ignore]"
  , "pytest.mark.skip", "pytest.mark.xfail", "unittest.skip"
  , "@test.ignore", "t.skip(", "testing.skip"
  , "sorry", "admit"                      -- proof assistants
  , "#[cfg(ignore)]", "--no-verify", "continue-on-error: true" ]

/-- Ways a check gets bypassed from the shell. -/
def bypassMarkers : List String :=
  [ "--no-verify", "--force", "-f origin", "--skip-checks"
  , "--no-gpg-sign", "skip_hooks", "husky --no" ]

/-- Destructive shell commands. -/
def destructiveMarkers : List String :=
  [ "rm -rf", "git reset --hard", "git clean -fd", "drop table"
  , "truncate table", "mkfs", "dd if=" ]

/-- Paths that are usually generated rather than authored. -/
def generatedPathMarkers : List String :=
  [ "node_modules/", "/dist/", "/build/", ".lake/", "target/debug"
  , "target/release", "__pycache__", ".venv/", "vendor/" ]

/-! ### The patterns

    Each entry: the phrase groups that must all match, and the predicate to
    emit.  Order matters only in that the first match wins, so the more
    specific patterns come first. -/

private def readBeforeEditPattern (lower : String) : Bool :=
  allGroups lower
    [ ["read", "inspect", "look at", "open"]
    , ["before"]
    , ["edit", "modify", "change", "write", "patch"] ]

private def verifyAfterEditPattern (lower : String) : Bool :=
  allGroups lower
    [ ["build", "test", "compile", "check"]
    , ["after", "following", "once"]
    , ["edit", "chang", "modif", "writ", "code"] ]

private def diffReviewPattern (lower : String) : Bool :=
  allGroups lower
    [ ["diff", "change set", "changes"]
    , ["review", "check", "read", "inspect", "look"]
    , ["before", "prior to"] ]

private def testSuppressionPattern (lower : String) : Bool :=
  allGroups lower
    [ ["never", "do not", "don't", "must not", "avoid"]
    , ["disable", "skip", "delete", "remove", "comment out", "suppress", "ignore"]
    , ["test", "spec", "assertion", "check"] ]

private def bypassPattern (lower : String) : Bool :=
  allGroups lower
    [ ["never", "do not", "don't", "must not", "avoid"]
    , ["bypass", "skip", "disable", "circumvent", "--no-verify", "override"]
    , ["hook", "check", "verification", "ci", "lint", "guard"] ]

private def destructivePattern (lower : String) : Bool :=
  allGroups lower
    [ ["never", "do not", "don't", "must not", "avoid"]
    , ["rm -rf", "destructive", "delete everything", "force push"
      , "reset --hard", "wipe", "drop"] ]

private def generatedPathPattern (lower : String) : Bool :=
  allGroups lower
    [ ["never", "do not", "don't", "must not", "avoid"]
    , ["edit", "modify", "change", "touch", "write"]
    , ["generated", "build output", "node_modules", "artifact", "vendored"] ]

private def testBeforeFinishPattern (lower : String) : Bool :=
  allGroups lower
    [ ["never", "do not", "don't", "must not"]
    , ["claim", "report", "say", "state", "declare"]
    , ["not observed", "without running", "unverified", "have not verified"
      , "untested", "not seen"] ]

/-- Compile one directive into a behavioural predicate, when it states one. -/
def predicateOf? (d : Directive) : Option BehaviorPredicate :=
  let lower := toLower d.text
  -- Prohibitions first: they are the specific ones, and a line like
  -- "never skip a test" also contains "test", which the verify pattern
  -- would otherwise claim.
  if testSuppressionPattern lower then
    some (.neverWriteMatching testSuppressionMarkers "a test-suppression marker")
  else if bypassPattern lower then
    some (.neverRunMatching bypassMarkers "a check bypass")
  else if destructivePattern lower then
    some (.neverRunMatching destructiveMarkers "a destructive command")
  else if generatedPathPattern lower then
    some (.neverEditPathMatching generatedPathMarkers "generated output")
  else if readBeforeEditPattern lower then
    some .readBeforeEdit
  else if diffReviewPattern lower then
    some .reviewDiffBeforeFinish
  else if verifyAfterEditPattern lower then
    some .verifyAfterEdit
  else if testBeforeFinishPattern lower then
    some .verifyAfterEdit
  else none

/-- Compile a directive list into the behavioural rules it states. -/
def compileBehaviorRules (ds : List Directive) : List BehaviorRule :=
  ds.filterMap fun d =>
    (predicateOf? d).map fun p =>
      { directiveId := d.id, predicate := p, level := p.defaultLevel }

/-- Directives that compiled to nothing.

    Surfaced by `--show-prompt` so the operator can see exactly which of
    their rules are being enforced mechanically and which are resting on
    restatement and review.  A system that quietly enforced a third of the
    prompt while implying it enforced all of it would be worse than one
    that enforced nothing. -/
def uncompiledDirectives (ds : List Directive) : List Directive :=
  ds.filter (fun d => (predicateOf? d).isNone)

/-- A report of what compiled and what did not. -/
structure CompilationReport where
  rules      : List BehaviorRule
  uncompiled : List Directive
  deriving Inhabited

def compileReport (ds : List Directive) : CompilationReport :=
  { rules := compileBehaviorRules ds, uncompiled := uncompiledDirectives ds }

def CompilationReport.describe (r : CompilationReport) : String :=
  let enforced :=
    if r.rules.isEmpty then
      ["  (none — no directive in this prompt states a mechanically checkable behaviour)"]
    else r.rules.map fun rule =>
      let mark := match rule.level with
        | .block => "⛔"
        | .warn => "⚠"
      s!"  {mark} {rule.describe}"
  let rest :=
    if r.uncompiled.isEmpty then []
    else
      [ ""
      , s!"  {r.uncompiled.length} directive(s) are not mechanically checkable."
      , "  They are restated through the run and put to the reviewer, but no"
      , "  predicate decides them:" ]
      ++ r.uncompiled.map (fun d => s!"    · [{d.id}] {truncate d.text 90}")
  String.intercalate "\n" (enforced ++ rest)

/-- Counts for the status line. -/
def CompilationReport.blockingCount (r : CompilationReport) : Nat :=
  (r.rules.filter (fun x => x.level == .block)).length

end LeanPrime
