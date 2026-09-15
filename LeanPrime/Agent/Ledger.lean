/-
  LeanPrime.Agent.Ledger

  An append-only, hash-chained record of every compliance decision in a run.

  The events emitted to the TUI are for a human watching.  They are also
  lossy: a stream that scrolls is not a record you can audit afterwards, and
  a sink can be swapped for one that drops events.  The ledger is the part
  that survives — an ordered chain where each entry folds in the digest of
  the entry before it, so an entry cannot be removed, reordered, or edited
  after the fact without breaking every digest downstream of it.

  This matters for the same reason the vault matters.  When the question is
  "did the agent actually follow the prompt", the answer has to come from a
  record that could not have been quietly tidied.

  ## What is recorded

  Every custody check, every compliance verdict, every guardian action,
  every adversarial review, every escalation, every rollback.  Enough to
  reconstruct why a run ended the way it did, and enough to show that a
  run which claims clean compliance really had it checked.

  ## Verification

  `LedgerChain.verify` walks the chain and recomputes every digest.  It
  returns the index of the first entry whose digest does not follow from
  its predecessor, or `none` when the chain is whole.
-/
import LeanPrime.Prompt.Vault
import LeanPrime.Prompt.Compliance

namespace LeanPrime

/-- What a ledger entry records. -/
inductive LedgerEvent where
  | runStarted (task : String) (promptFingerprint : String)
  | custodyCheck (checkpoint : Checkpoint) (intact : Bool) (detail : String)
  | complianceVerdict (passed : Bool) (ruleCount : Nat) (violations : String)
  | guardianVerdict (action : String) (severity : String) (detail : String)
  | adversarialReview (verdict : String) (score : Nat) (detail : String)
  | escalation (fromLevel : String) (toLevel : String) (reason : String)
  | rollback (toTurn : Nat) (reason : String)
  | quarantine (reason : String)
  | injectionBlocked (patterns : Nat) (tool : String)
  | anchorInjected (reason : String)
  | runEnded (phase : String) (summary : String)
  deriving Repr, Inhabited

def LedgerEvent.kind : LedgerEvent → String
  | .runStarted _ _ => "run-started"
  | .custodyCheck _ _ _ => "custody-check"
  | .complianceVerdict _ _ _ => "compliance-verdict"
  | .guardianVerdict _ _ _ => "guardian-verdict"
  | .adversarialReview _ _ _ => "adversarial-review"
  | .escalation _ _ _ => "escalation"
  | .rollback _ _ => "rollback"
  | .quarantine _ => "quarantine"
  | .injectionBlocked _ _ => "injection-blocked"
  | .anchorInjected _ => "anchor-injected"
  | .runEnded _ _ => "run-ended"

/-- The canonical serialisation an entry's digest is taken over.  Fixed
    shape on purpose: the digest has to be reproducible from the record
    alone, so nothing here may depend on formatting choices elsewhere. -/
def LedgerEvent.canonical : LedgerEvent → String
  | .runStarted task fp => s!"run-started|{task}|{fp}"
  | .custodyCheck cp intact detail => s!"custody-check|{cp}|{intact}|{detail}"
  | .complianceVerdict passed n vs => s!"compliance-verdict|{passed}|{n}|{vs}"
  | .guardianVerdict action sev detail => s!"guardian-verdict|{action}|{sev}|{detail}"
  | .adversarialReview verdict score detail => s!"adversarial-review|{verdict}|{score}|{detail}"
  | .escalation f t reason => s!"escalation|{f}|{t}|{reason}"
  | .rollback turn reason => s!"rollback|{turn}|{reason}"
  | .quarantine reason => s!"quarantine|{reason}"
  | .injectionBlocked n tool => s!"injection-blocked|{n}|{tool}"
  | .anchorInjected reason => s!"anchor-injected|{reason}"
  | .runEnded phase summary => s!"run-ended|{phase}|{summary}"

/-- Is this event a compliance failure of some kind?  Used for the run's
    closing integrity summary. -/
def LedgerEvent.isFailure : LedgerEvent → Bool
  | .custodyCheck _ intact _ => !intact
  | .complianceVerdict passed _ _ => !passed
  | .guardianVerdict action _ _ => action == "reject"
  | .adversarialReview verdict _ _ => verdict == "fail"
  | .quarantine _ => true
  | .rollback _ _ => true
  | _ => false

/-- One link in the chain. -/
structure LedgerEntry where
  index    : Nat
  /-- Milliseconds since the run started. -/
  atMs     : Nat
  event    : LedgerEvent
  /-- Digest of this entry's own content. -/
  digest   : UInt64
  /-- Digest folding in the previous entry's `chained` value. -/
  chained  : UInt64
  deriving Inhabited

/-- The genesis value the first entry chains from. -/
def ledgerGenesis : UInt64 := 14695981039346656037

/-- Fold an entry's content into the running chain digest. -/
def chainStep (prev : UInt64) (index atMs : Nat) (canonical : String) : UInt64 :=
  let body := digestFnv canonical
  let mixed := (prev ^^^ body) * 1099511628211
  mixed + index.toUInt64 * 31 + atMs.toUInt64

structure LedgerChain where
  entries : List LedgerEntry := []
  head    : UInt64 := ledgerGenesis
  deriving Inhabited

namespace LedgerChain

/-- Append an event.  The only way to add to a chain. -/
def append (c : LedgerChain) (atMs : Nat) (ev : LedgerEvent) : LedgerChain :=
  let index := c.entries.length
  let canonical := ev.canonical
  let digest := digestFnv canonical
  let chained := chainStep c.head index atMs canonical
  { entries := c.entries ++ [{ index := index, atMs := atMs, event := ev
                               digest := digest, chained := chained }]
    head := chained }

/-- Walk the chain and recompute every digest.  Returns the index of the
    first entry that does not follow from its predecessor. -/
def verify (c : LedgerChain) : Option Nat := Id.run do
  let mut prev := ledgerGenesis
  for e in c.entries do
    let canonical := e.event.canonical
    if digestFnv canonical != e.digest then return some e.index
    if chainStep prev e.index e.atMs canonical != e.chained then return some e.index
    prev := e.chained
  if prev != c.head then return some c.entries.length
  return none

def isIntact (c : LedgerChain) : Bool := (verify c).isNone

def length (c : LedgerChain) : Nat := c.entries.length

/-- Every entry recording a failure. -/
def failures (c : LedgerChain) : List LedgerEntry :=
  c.entries.filter (fun e => e.event.isFailure)

def failureCount (c : LedgerChain) : Nat := (failures c).length

/-- Entries of one kind. -/
def ofKind (c : LedgerChain) (kind : String) : List LedgerEntry :=
  c.entries.filter (fun e => e.event.kind == kind)

/-- A short seal for the whole run: the head digest, rendered. -/
def runSeal (c : LedgerChain) : String :=
  String.ofList (Nat.toDigits 16 (c.head % 0x1000000000000).toNat)

/-- One line per entry, for `--show-ledger` and the audit file. -/
def render (c : LedgerChain) : String :=
  if c.entries.isEmpty then "  (empty)"
  else String.intercalate "\n"
    (c.entries.map fun e =>
      let mark := if e.event.isFailure then "✗" else "·"
      s!"  {mark} [{e.index}] +{e.atMs}ms {truncate e.event.canonical 120}")

/-- The closing integrity statement.

    Deliberately explicit about the difference between "the record is whole"
    and "the run was compliant".  A chain can be intact and still record a
    run that failed every check; conflating the two would be the dishonest
    reading. -/
def integrityReport (c : LedgerChain) : String :=
  let chainState := match c.verify with
    | none => s!"intact ({c.length} entries, seal {c.runSeal})"
    | some i => s!"BROKEN at entry {i}"
  let fails := c.failureCount
  let complianceState :=
    if fails == 0 then s!"no compliance failures recorded"
    else s!"{fails} compliance failure(s) recorded"
  String.intercalate "\n"
    [ s!"ledger chain      {chainState}"
    , s!"compliance        {complianceState}" ]

end LedgerChain

end LeanPrime
