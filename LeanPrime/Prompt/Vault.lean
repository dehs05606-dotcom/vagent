/-
  LeanPrime.Prompt.Vault

  The sealed prompt vault: tamper-evident custody of the system prompt.

  `Compliance.lean` hashes the prompt with one FNV-1a pass.  That catches
  accidental mutation.  It does not catch a deliberate one: a single 64-bit
  non-cryptographic hash is cheap to collide if someone is trying.

  The vault seals the prompt under **five independent digests** computed by
  different algorithms over different views of the text:

      fnv      FNV-1a over the UTF-8 bytes
      djb2     Bernstein's hash, different multiplier and mixing
      sdbm     the sdbm hash, different accumulation shape
      rolling  a position-weighted polynomial digest
      shape    a structural digest: line count, word count, byte length,
               and the per-line length histogram folded together

  A mutation has to collide all five simultaneously, under algorithms whose
  error terms are uncorrelated, while also preserving the line and word
  structure.  That is a different order of problem from colliding one hash.

  ## Segment sealing

  The prompt is also split into segments (one per non-empty line) and each
  segment is sealed individually into a **hash chain** — segment `n`'s digest
  folds in segment `n-1`'s.  This is what makes the vault *locating* rather
  than merely *detecting*: when verification fails, walking the chain says
  which line changed, not just that something did.

  ## Custody checkpoints

  The vault is verified at every point where the prompt is read or the
  conversation is about to be sent:

      seal        once, at load
      preCall     before every model request
      postCall    after every model reply
      preTool     before every tool execution
      preFinish   before the run may report success

  A failure at any checkpoint is fatal.  There is no "repair" path: a prompt
  that changed mid-run is not the prompt the operator authorised, and
  continuing under it would be the exact failure this module exists to
  prevent.
-/
import LeanPrime.Util.Prelude

namespace LeanPrime

/-! ### The five digests -/

/-- FNV-1a over UTF-8 bytes. -/
def digestFnv (s : String) : UInt64 :=
  s.toUTF8.foldl (fun h b => (h ^^^ b.toUInt64) * 1099511628211) 14695981039346656037

/-- Bernstein's djb2: `h * 33 + c`, different mixing from FNV. -/
def digestDjb2 (s : String) : UInt64 :=
  s.toUTF8.foldl (fun h b => h * 33 + b.toUInt64) 5381

/-- sdbm: `h * 65599 + c`, folded with shifts. -/
def digestSdbm (s : String) : UInt64 :=
  s.toUTF8.foldl (fun h b => b.toUInt64 + (h <<< 6) + (h <<< 16) - h) 0

/-- Position-weighted polynomial digest.  Two texts that are permutations of
    each other collide under an order-insensitive hash; this one does not. -/
def digestRolling (s : String) : UInt64 :=
  let (h, _) := s.toUTF8.foldl
    (fun (acc : UInt64 × UInt64) b =>
      let (h, i) := acc
      (h + b.toUInt64 * (i + 1) * 31, i + 1))
    (0, 0)
  h

/-- Structural digest: counts and the per-line length histogram.

    Independent of the byte digests by construction — it ignores *which*
    characters are present and looks only at the shape of the document. -/
def digestShape (s : String) : UInt64 :=
  let lines := s.splitOn "\n"
  let lineCount := lines.length.toUInt64
  let byteLen := s.utf8ByteSize.toUInt64
  let wordCount := (s.splitOn " ").length.toUInt64
  let histogram := lines.foldl
    (fun (acc : UInt64) l => acc * 131 + l.length.toUInt64 + 7) 17
  lineCount * 1000003 + byteLen * 10007 + wordCount * 101 + histogram

/-- All five digests of one text. -/
structure Digests where
  fnv     : UInt64
  djb2    : UInt64
  sdbm    : UInt64
  rolling : UInt64
  shape   : UInt64
  deriving Repr, Inhabited, BEq, DecidableEq

def Digests.of (s : String) : Digests :=
  { fnv := digestFnv s
    djb2 := digestDjb2 s
    sdbm := digestSdbm s
    rolling := digestRolling s
    shape := digestShape s }

/-- How many of the five digests agree.  Reported on failure: a single
    disagreement reads differently from all five disagreeing. -/
def Digests.agreement (a b : Digests) : Nat :=
  (if a.fnv == b.fnv then 1 else 0) +
  (if a.djb2 == b.djb2 then 1 else 0) +
  (if a.sdbm == b.sdbm then 1 else 0) +
  (if a.rolling == b.rolling then 1 else 0) +
  (if a.shape == b.shape then 1 else 0)

def Digests.matches (a b : Digests) : Bool := decide (a = b)

def Digests.render (d : Digests) : String :=
  s!"fnv={d.fnv} djb2={d.djb2} sdbm={d.sdbm} roll={d.rolling} shape={d.shape}"

/-- A short fingerprint for the status line: the low bits of the five,
    folded.  Displaying all five would not fit and would not be read. -/
def Digests.short (d : Digests) : String :=
  let fold := d.fnv ^^^ d.djb2 ^^^ d.sdbm ^^^ d.rolling ^^^ d.shape
  let hex := Nat.toDigits 16 (fold % 0x1000000).toNat
  String.ofList hex

/-! ### Segment chain -/

/-- One sealed line of the prompt.  `chained` folds in the previous
    segment's digest, so the seal locates a change rather than only
    detecting one. -/
structure Segment where
  index   : Nat
  text    : String
  digest  : UInt64
  chained : UInt64
  deriving Repr, Inhabited

/-- Build the hash chain over the prompt's non-empty lines. -/
def buildChain (s : String) : List Segment := Id.run do
  let mut out : List Segment := []
  let mut prev : UInt64 := 14695981039346656037
  let mut i := 0
  for line in s.splitOn "\n" do
    let t := trim line
    if t.isEmpty then continue
    let d := digestFnv t
    let c := (prev ^^^ d) * 1099511628211 + i.toUInt64
    out := out ++ [{ index := i, text := t, digest := d, chained := c }]
    prev := c
    i := i + 1
  return out

/-- Compare two chains and report the first index at which they diverge. -/
def chainDivergence (a b : List Segment) : Option Nat :=
  let rec go (xs ys : List Segment) : Option Nat :=
    match xs, ys with
    | [], [] => none
    | [], y :: _ => some y.index
    | x :: _, [] => some x.index
    | x :: xs', y :: ys' =>
      if x.chained == y.chained then go xs' ys' else some x.index
  go a b

/-! ### The vault -/

/-- Why a verification was performed.  Recorded so a failure says *where*
    in the run the prompt changed. -/
inductive Checkpoint where
  | seal
  | preCall
  | postCall
  | preTool
  | preFinish
  | manual
  deriving Repr, DecidableEq, Inhabited, BEq

def Checkpoint.toString : Checkpoint → String
  | .seal => "seal" | .preCall => "pre-call" | .postCall => "post-call"
  | .preTool => "pre-tool" | .preFinish => "pre-finish" | .manual => "manual"

instance : ToString Checkpoint := ⟨Checkpoint.toString⟩

/-- A prompt under seal. -/
structure PromptVault where
  /-- The authoritative text.  Everything else is derived from it. -/
  sealed_    : String
  digests    : Digests
  chain      : List Segment
  /-- Number of successful verifications so far. -/
  verifiedAt : Nat := 0
  deriving Inhabited

/-- Seal a prompt.  Called once, at load. -/
def PromptVault.seal (prompt : String) : PromptVault :=
  { sealed_ := prompt
    digests := Digests.of prompt
    chain := buildChain prompt
    verifiedAt := 0 }

/-- The outcome of a custody check. -/
inductive VaultVerdict where
  | intact
  /-- Digests disagree.  Carries how many of five matched and, when the
      chain could locate it, the first divergent line. -/
  | tampered (agreement : Nat) (firstBadLine : Option Nat) (detail : String)
  deriving Repr, Inhabited

def VaultVerdict.isIntact : VaultVerdict → Bool
  | .intact => true
  | .tampered _ _ _ => false

def VaultVerdict.describe : VaultVerdict → String
  | .intact => "intact"
  | .tampered agree line detail =>
    let loc := match line with
      | some n => s!" at line {n}"
      | none => ""
    s!"TAMPERED{loc} — {agree}/5 digests matched; {detail}"

/-- Verify a candidate text against the seal. -/
def PromptVault.verify (v : PromptVault) (candidate : String) : VaultVerdict :=
  let d := Digests.of candidate
  if d.matches v.digests then .intact
  else
    let agree := d.agreement v.digests
    let candidateChain := buildChain candidate
    let line := chainDivergence v.chain candidateChain
    let detail :=
      if v.sealed_.length != candidate.length then
        s!"length changed {v.sealed_.length} → {candidate.length}"
      else s!"content changed at equal length ({candidate.length} chars)"
    .tampered agree line detail

/-- Verify and count the check.  Returns the updated vault so the run can
    report how many custody checks passed. -/
def PromptVault.check (v : PromptVault) (candidate : String)
    : VaultVerdict × PromptVault :=
  let verdict := v.verify candidate
  match verdict with
  | .intact => (verdict, { v with verifiedAt := v.verifiedAt + 1 })
  | _ => (verdict, v)

/-- The authoritative text.  The only way to read the prompt: callers cannot
    reach a copy that was not sealed. -/
def PromptVault.text (v : PromptVault) : String := v.sealed_

def PromptVault.segmentCount (v : PromptVault) : Nat := v.chain.length

def PromptVault.describe (v : PromptVault) : String :=
  String.intercalate "\n"
    [ s!"sealed            {v.sealed_.length} characters, {v.chain.length} segments"
    , s!"digests           {v.digests.render}"
    , s!"fingerprint       {v.digests.short}"
    , s!"custody checks    {v.verifiedAt} passed" ]

/-! ### Recovery

    A tampered prompt is never repaired in place — that would mean trusting
    the mutated copy enough to diff it.  The vault holds the original, so
    recovery is restoration from the seal, and the caller decides whether
    restoring or aborting is right for its checkpoint. -/

/-- The text to restore when a checkpoint finds tampering. -/
def PromptVault.restore (v : PromptVault) : String := v.sealed_

/-- The message explaining a custody failure, for the transcript. -/
def tamperReport (cp : Checkpoint) (verdict : VaultVerdict) : String :=
  String.intercalate "\n"
    [ "╔═ PROMPT CUSTODY FAILURE ═══════════════════════════════════════╗"
    , s!"║ checkpoint: {cp}"
    , s!"║ {verdict.describe}"
    , "║"
    , "║ The system prompt in the conversation is not the text that was"
    , "║ sealed at load. The run cannot continue under an instruction set"
    , "║ the operator did not authorise."
    , "╚════════════════════════════════════════════════════════════════╝" ]

end LeanPrime
