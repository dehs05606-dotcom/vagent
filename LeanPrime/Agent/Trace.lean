/-
  LeanPrime.Agent.Trace

  The record of what the agent actually did.

  Every layer so far judges *text*: the reply's wording, its topic, its
  fingerprint.  But most of an operator's real rules are not about wording
  at all — they are about behaviour:

      "always read a file before editing it"
      "always run the build and the tests after changing code"
      "never disable a test to make it pass"
      "always review the diff before reporting"

  None of those can be decided by looking at a reply.  All of them can be
  decided by looking at the sequence of actions the agent took.  That
  sequence is this module.

  Each tool call is recorded with the facts a rule might need: which tool,
  which path, which command, what content was written, whether it
  succeeded, and when.  The queries below are the vocabulary the predicate
  engine in `LeanPrime.Prompt.Predicate` is written against.

  ## Why this is stronger than checking the reply

  A reply can claim the file was read.  The trace knows whether `read_file`
  was actually called on that path, before that edit, in this run.  The
  difference is the whole point: one is the model's account of its own
  behaviour, the other is the behaviour.
-/
import LeanPrime.Util.Prelude
import LeanPrime.Model.Messages

open Lean

namespace LeanPrime

/-- What one tool call did. -/
structure ActionRecord where
  seq     : Nat
  tool    : String
  /-- Workspace path the call touched, when it names one. -/
  path    : Option String := none
  /-- Shell command line, when the call ran one. -/
  command : Option String := none
  /-- Text the call wrote, for tools that write.  Kept so content rules
      ("never write a test-skip marker") can be decided. -/
  written : Option String := none
  ok      : Bool := true
  atMs    : Nat := 0
  deriving Repr, Inhabited

/-- Tools that change files on disk. -/
def editingTools : List String := ["write_file", "edit_file", "delete_file"]

/-- Tools that read without changing anything. -/
def readingTools : List String := ["read_file", "search", "list_files", "grep"]

def ActionRecord.isEdit (a : ActionRecord) : Bool := editingTools.contains a.tool
def ActionRecord.isRead (a : ActionRecord) : Bool := readingTools.contains a.tool

/-- Did this call run a build or a test suite?

    Recognised from the command line rather than the tool name, because in
    practice every project drives its build through the shell and the
    command is the only thing that says which. -/
def ActionRecord.isVerification (a : ActionRecord) : Bool :=
  match a.command with
  | none => false
  | some c =>
    let l := toLower c
    ["build", "test", "check", "lint", "typecheck", "compile",
     "pytest", "jest", "cargo", "npm run", "make", "lake", "go test",
     "mvn", "gradle", "tsc", "mypy", "ruff", "eslint"].any (containsSubstr l)

/-- Did this call inspect a diff? -/
def ActionRecord.isDiffReview (a : ActionRecord) : Bool :=
  if a.tool == "git_diff" then true
  else match a.command with
    | none => false
    | some c =>
      let l := toLower c
      containsSubstr l "git diff" || containsSubstr l "git show" ||
      containsSubstr l "git status"

/-- A description short enough for a violation message. -/
def ActionRecord.describe (a : ActionRecord) : String :=
  match a.path, a.command with
  | some p, _ => s!"{a.tool} {p}"
  | _, some c => s!"{a.tool} {truncate c 60}"
  | _, _ => a.tool

/-! ### Reading the facts out of a call's arguments

    Tools spell their arguments differently — `path` vs `file`, `content`
    vs `new_string`.  Normalising here means every rule downstream sees one
    shape, and a new tool only has to be added in one place. -/

private def firstStr (j : Json) (keys : List String) : Option String :=
  keys.findSome? fun k =>
    match j.getObjVal? k with
    | .ok v => v.getStr?.toOption
    | .error _ => none

def pathOfArgs (args : Json) : Option String :=
  firstStr args ["path", "file", "file_path", "filename", "target"]

def commandOfArgs (args : Json) : Option String :=
  firstStr args ["command", "cmd", "cmdline", "script"]

/-- Text a call is about to write.  Covers whole-file writes and the
    replacement half of an anchored edit. -/
def writtenOfArgs (args : Json) : Option String :=
  firstStr args ["content", "new_string", "new_text", "replacement", "text", "body"]

/-- Build a record from a call's name and parsed arguments. -/
def recordOf (seq : Nat) (tool : String) (args : Json) (ok : Bool) (atMs : Nat)
    : ActionRecord :=
  { seq := seq, tool := tool
    path := pathOfArgs args
    command := commandOfArgs args
    written := writtenOfArgs args
    ok := ok, atMs := atMs }

/-! ### The trace -/

/-- Every action of the run, oldest first. -/
structure ActionTrace where
  actions : List ActionRecord := []
  deriving Inhabited

namespace ActionTrace

def append (t : ActionTrace) (a : ActionRecord) : ActionTrace :=
  { actions := t.actions ++ [a] }

def length (t : ActionTrace) : Nat := t.actions.length

def isEmpty (t : ActionTrace) : Bool := t.actions.isEmpty

/-- Successful calls only.  A failed call did not happen, so a rule about
    what the agent did should not count it. -/
def succeeded (t : ActionTrace) : List ActionRecord :=
  t.actions.filter (·.ok)

def ofTool (t : ActionTrace) (tool : String) : List ActionRecord :=
  t.actions.filter (fun a => a.tool == tool)

def countOf (t : ActionTrace) (tool : String) : Nat := (t.ofTool tool).length

/-- Every successful edit, in order. -/
def edits (t : ActionTrace) : List ActionRecord :=
  t.succeeded.filter (·.isEdit)

def reads (t : ActionTrace) : List ActionRecord :=
  t.succeeded.filter (·.isRead)

def verifications (t : ActionTrace) : List ActionRecord :=
  t.succeeded.filter (·.isVerification)

def diffReviews (t : ActionTrace) : List ActionRecord :=
  t.succeeded.filter (·.isDiffReview)

/-- Was this path read successfully at some point at or before `seq`? -/
def wasReadBefore (t : ActionTrace) (path : String) (seq : Nat) : Bool :=
  t.reads.any (fun a => a.seq < seq && a.path == some path)

/-- Has this path ever been read successfully? -/
def wasEverRead (t : ActionTrace) (path : String) : Bool :=
  t.reads.any (fun a => a.path == some path)

/-- Sequence number of the most recent successful edit, if any. -/
def lastEditSeq (t : ActionTrace) : Option Nat :=
  (t.edits.map (·.seq)).max?

/-- Sequence number of the most recent verification, if any. -/
def lastVerificationSeq (t : ActionTrace) : Option Nat :=
  (t.verifications.map (·.seq)).max?

/-- Sequence number of the most recent diff review, if any. -/
def lastDiffReviewSeq (t : ActionTrace) : Option Nat :=
  (t.diffReviews.map (·.seq)).max?

/-- Has anything been verified since the last edit?

    `true` when there were no edits at all: a run that changed nothing has
    nothing to verify, and reporting it as unverified would be wrong. -/
def verifiedSinceLastEdit (t : ActionTrace) : Bool :=
  match t.lastEditSeq with
  | none => true
  | some e => match t.lastVerificationSeq with
    | none => false
    | some v => v > e

/-- Has the diff been reviewed since the last edit? -/
def diffReviewedSinceLastEdit (t : ActionTrace) : Bool :=
  match t.lastEditSeq with
  | none => true
  | some e => match t.lastDiffReviewSeq with
    | none => false
    | some d => d > e

/-- Paths edited without ever having been read.  The evidence behind a
    "read before edit" violation. -/
def editedUnread (t : ActionTrace) : List ActionRecord :=
  t.edits.filter fun a =>
    match a.path with
    | none => false
    -- A whole-file write that creates a new file has nothing to read.
    | some p => a.tool != "write_file" && !t.wasReadBefore p a.seq

/-- Distinct paths touched by successful edits. -/
def editedPaths (t : ActionTrace) : List String :=
  (t.edits.filterMap (·.path)).eraseDups

def describe (t : ActionTrace) : String :=
  s!"{t.length} action(s) · {t.edits.length} edit(s) · \
     {t.verifications.length} verification(s)"

/-- One line per action, for the forensic record. -/
def render (t : ActionTrace) : String :=
  if t.actions.isEmpty then "  (no actions)"
  else String.intercalate "\n"
    (t.actions.map fun a =>
      let mark := if a.ok then "·" else "✗"
      s!"  {mark} [{a.seq}] {a.describe}")

end ActionTrace

/-! ### A call the model has proposed but that has not run yet

    The interlock rules on this shape: it is everything a predicate needs
    to decide, minus the outcome, because the whole point is to decide
    before there is one. -/

structure ProposedAction where
  tool    : String
  path    : Option String := none
  command : Option String := none
  written : Option String := none
  deriving Repr, Inhabited

def proposedOf (tool : String) (args : Json) : ProposedAction :=
  { tool := tool
    path := pathOfArgs args
    command := commandOfArgs args
    written := writtenOfArgs args }

def ProposedAction.isEdit (p : ProposedAction) : Bool := editingTools.contains p.tool

def ProposedAction.describe (p : ProposedAction) : String :=
  match p.path, p.command with
  | some path, _ => s!"{p.tool} {path}"
  | _, some c => s!"{p.tool} {truncate c 60}"
  | _, _ => p.tool

end LeanPrime
