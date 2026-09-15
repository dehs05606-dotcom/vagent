/-
  LeanPrime.Prompt.Predicate

  Behavioural rules, as data you can decide.

  `ComplianceRule` in `Compliance.lean` decides rules about the *text* of a
  reply.  This module decides rules about the *behaviour* of the run, by
  evaluating predicates against the action trace.

  Each predicate answers two different questions, and the distinction is the
  point of the module:

      checkProposed   may this action run, given everything done so far?
      checkFinal      was the rule satisfied, given the whole run?

  The first is enforcement *before* the fact.  A reply that violates a text
  rule can be thrown away and re-requested at no cost; an action that
  violates a behavioural rule has already happened by the time you notice.
  So the strongest thing this module does is block the call.

  ## Enforcement levels

  A predicate that blocks a legitimate action is worse than one that misses
  a violation, because the first stops real work and the second is caught
  later by `checkFinal` anyway.  So each predicate carries a level:

      block   high confidence; the action is refused and the model told why
      warn    lower confidence; recorded, reported, not refused

  Compiled rules default to `warn` unless the pattern behind them is
  specific enough that a false positive is implausible.

  ## What is deliberately not here

  "Never refactor code the task did not ask you to touch" is a real rule
  that no predicate in this module decides, because deciding it needs a
  model of what the task asked for.  It stays a directive, is restated, and
  goes to the adversarial reviewer.  Pretending a keyword match decides it
  would produce confident wrong answers, which is worse than an honest gap.
-/
import LeanPrime.Agent.Trace

namespace LeanPrime

/-- How hard a predicate is enforced. -/
inductive Enforcement where
  | block
  | warn
  deriving Repr, DecidableEq, Inhabited, BEq

def Enforcement.toString : Enforcement → String
  | .block => "block" | .warn => "warn"

instance : ToString Enforcement := ⟨Enforcement.toString⟩

/-- A rule about what the agent does, rather than what it says. -/
inductive BehaviorPredicate where
  /-- A file must have been read before it is edited. -/
  | readBeforeEdit
  /-- A build or test run must follow the last edit before the run finishes. -/
  | verifyAfterEdit
  /-- The diff must be reviewed after the last edit before the run finishes. -/
  | reviewDiffBeforeFinish
  /-- Writing text containing any of these markers is a violation.
      `label` names what the markers mean, for the message. -/
  | neverWriteMatching (markers : List String) (label : String)
  /-- This tool may never be called. -/
  | neverCallTool (tool : String)
  /-- A shell command containing any of these is a violation. -/
  | neverRunMatching (markers : List String) (label : String)
  /-- Paths matching any of these may not be edited. -/
  | neverEditPathMatching (markers : List String) (label : String)
  /-- At most `n` calls to this tool. -/
  | maxCallsOf (tool : String) (n : Nat)
  /-- At least one successful call to one of these tools before finishing. -/
  | requireToolBeforeFinish (tools : List String) (label : String)
  deriving Repr, Inhabited

def BehaviorPredicate.describe : BehaviorPredicate → String
  | .readBeforeEdit => "a file must be read before it is edited"
  | .verifyAfterEdit => "the build or tests must run after the last edit"
  | .reviewDiffBeforeFinish => "the diff must be reviewed before reporting"
  | .neverWriteMatching _ label => s!"never write {label}"
  | .neverCallTool tool => s!"never call `{tool}`"
  | .neverRunMatching _ label => s!"never run {label}"
  | .neverEditPathMatching _ label => s!"never edit {label}"
  | .maxCallsOf tool n => s!"at most {n} call(s) to `{tool}`"
  | .requireToolBeforeFinish _ label => s!"{label} before reporting"

/-- The default level for each predicate.

    `block` only where a false positive is implausible: a literal
    test-suppression marker in written text, a forbidden tool by name, a
    path pattern the operator wrote out.  Everything whose evidence is
    circumstantial warns instead. -/
def BehaviorPredicate.defaultLevel : BehaviorPredicate → Enforcement
  | .neverWriteMatching _ _ => .block
  | .neverCallTool _ => .block
  | .neverRunMatching _ _ => .block
  | .neverEditPathMatching _ _ => .block
  | .maxCallsOf _ _ => .block
  | .readBeforeEdit => .warn
  | .verifyAfterEdit => .warn
  | .reviewDiffBeforeFinish => .warn
  | .requireToolBeforeFinish _ _ => .warn

/-- One rule in force, carrying the directive it came from. -/
structure BehaviorRule where
  directiveId : Nat
  predicate   : BehaviorPredicate
  level       : Enforcement
  deriving Repr, Inhabited

def BehaviorRule.describe (r : BehaviorRule) : String :=
  s!"[{r.directiveId}] {r.predicate.describe}"

/-- A rule that was broken. -/
structure BehaviorViolation where
  rule     : BehaviorRule
  /-- What specifically broke it. -/
  evidence : String
  deriving Repr, Inhabited

def BehaviorViolation.describe (v : BehaviorViolation) : String :=
  s!"{v.rule.describe} — {v.evidence}"

/-! ### Matching helpers -/

private def matchesAny (text : String) (markers : List String) : Option String :=
  let l := toLower text
  markers.find? (fun m => containsSubstr l (toLower m))

/-! ### Pre-execution: may this action run?

    Only predicates whose evidence is present *before* the call can decide
    here.  `verifyAfterEdit` cannot — there is nothing to check until the
    run is about to finish — so it abstains, and `checkFinal` catches it. -/

def checkProposed (rule : BehaviorRule) (trace : ActionTrace) (p : ProposedAction)
    : Option BehaviorViolation :=
  let hit (evidence : String) : Option BehaviorViolation :=
    some { rule := rule, evidence := evidence }
  match rule.predicate with
  | .readBeforeEdit =>
    if !p.isEdit then none
    else if p.tool == "write_file" then none   -- a fresh write has nothing to read
    else match p.path with
      | none => none
      | some path =>
        if trace.wasEverRead path then none
        else hit s!"`{path}` has not been read in this run"
  | .neverWriteMatching markers label =>
    match p.written with
    | none => none
    | some text => match matchesAny text markers with
      | some m => hit s!"the text to be written contains `{m}` ({label})"
      | none => none
  | .neverCallTool tool =>
    if p.tool == tool then hit s!"`{tool}` is forbidden by the prompt" else none
  | .neverRunMatching markers label =>
    match p.command with
    | none => none
    | some c => match matchesAny c markers with
      | some m => hit s!"the command contains `{m}` ({label})"
      | none => none
  | .neverEditPathMatching markers label =>
    if !p.isEdit then none
    else match p.path with
      | none => none
      | some path => match matchesAny path markers with
        | some m => hit s!"`{path}` matches `{m}` ({label})"
        | none => none
  | .maxCallsOf tool n =>
    if p.tool != tool then none
    else if trace.countOf tool >= n then
      hit s!"`{tool}` has already been called {trace.countOf tool} time(s), limit is {n}"
    else none
  -- Nothing to decide before the fact.
  | .verifyAfterEdit => none
  | .reviewDiffBeforeFinish => none
  | .requireToolBeforeFinish _ _ => none

/-- The refusal handed back when a call is blocked.

    Written as a tool result rather than an error: the agent should adapt
    and take a different route, not die.  It names the rule, the directive
    it came from and the evidence, because a refusal the model cannot act
    on just produces the same call again. -/
def blockMessage (v : BehaviorViolation) : String :=
  String.intercalate "\n"
    [ "REFUSED — this call breaks a rule from the operator's system prompt."
    , ""
    , s!"  rule [{v.rule.directiveId}]: {v.rule.predicate.describe}"
    , s!"  why:  {v.evidence}"
    , ""
    , "The action was NOT performed. Satisfy the rule first, then try again."
    , match v.rule.predicate with
      | .readBeforeEdit => "Call read_file on that path before editing it."
      | .neverWriteMatching _ _ =>
        "Fix the underlying problem instead of suppressing the check."
      | .maxCallsOf _ _ => "Take a different approach; this route is exhausted."
      | _ => "Choose a different approach." ]

/-! ### Post-hoc: was the rule satisfied over the whole run?

    Evaluated before the run is allowed to report success. -/

def checkFinal (rule : BehaviorRule) (trace : ActionTrace)
    : Option BehaviorViolation :=
  let hit (evidence : String) : Option BehaviorViolation :=
    some { rule := rule, evidence := evidence }
  match rule.predicate with
  | .readBeforeEdit =>
    match trace.editedUnread with
    | [] => none
    | bad =>
      let names := (bad.filterMap (·.path)).eraseDups
      hit s!"edited without reading: {String.intercalate ", " (names.take 5)}"
  | .verifyAfterEdit =>
    if trace.verifiedSinceLastEdit then none
    else if trace.edits.isEmpty then none
    else hit s!"{trace.edits.length} edit(s) were made and nothing was built or tested after the last one"
  | .reviewDiffBeforeFinish =>
    if trace.diffReviewedSinceLastEdit then none
    else if trace.edits.isEmpty then none
    else hit "the diff was not reviewed after the last edit"
  | .requireToolBeforeFinish tools label =>
    if tools.any (fun t => trace.countOf t > 0) then none
    else hit s!"{label}: none of {String.intercalate ", " tools} was called"
  | .maxCallsOf tool n =>
    let c := trace.countOf tool
    if c <= n then none else hit s!"`{tool}` was called {c} time(s), limit is {n}"
  -- The "never" predicates are enforced at the gate; if one got past it the
  -- trace still carries the evidence, so re-check rather than assume.
  | .neverCallTool tool =>
    if trace.countOf tool == 0 then none
    else hit s!"`{tool}` was called {trace.countOf tool} time(s)"
  | .neverWriteMatching markers label =>
    let bad := trace.edits.filter fun a =>
      match a.written with
      | none => false
      | some t => (matchesAny t markers).isSome
    if bad.isEmpty then none
    else hit s!"{bad.length} write(s) contained {label}"
  | .neverRunMatching markers label =>
    let bad := trace.succeeded.filter fun a =>
      match a.command with
      | none => false
      | some c => (matchesAny c markers).isSome
    if bad.isEmpty then none
    else hit s!"{bad.length} command(s) matched {label}"
  | .neverEditPathMatching markers label =>
    let bad := trace.edits.filter fun a =>
      match a.path with
      | none => false
      | some p => (matchesAny p markers).isSome
    if bad.isEmpty then none
    else hit s!"{bad.length} edit(s) touched {label}"

/-- Every rule the proposed action breaks, worst level first. -/
def checkAllProposed (rules : List BehaviorRule) (trace : ActionTrace)
    (p : ProposedAction) : List BehaviorViolation :=
  rules.filterMap (fun r => checkProposed r trace p)

/-- Violations that should actually stop the call. -/
def blockingViolations (vs : List BehaviorViolation) : List BehaviorViolation :=
  vs.filter (fun v => v.rule.level == .block)

def checkAllFinal (rules : List BehaviorRule) (trace : ActionTrace)
    : List BehaviorViolation :=
  rules.filterMap (fun r => checkFinal r trace)

/-- The message put to the model when the run wants to finish but
    behavioural rules are unsatisfied. -/
def finalViolationMessage (vs : List BehaviorViolation) : String :=
  if vs.isEmpty then "" else
  String.intercalate "\n"
    ([ "You cannot report this done yet. The operator's system prompt states"
     , "rules about how the work is carried out, and the record of what you"
     , "actually did does not satisfy them:"
     , "" ]
     ++ vs.map (fun v => s!"  ✗ {v.describe}")
     ++ [ ""
        , "These are checked against the actual tool calls in this run, not"
        , "against your description of them. Do the missing work now — then"
        , "report." ])

end LeanPrime
