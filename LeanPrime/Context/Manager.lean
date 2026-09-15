/-
  LeanPrime.Context.Manager

  Project discovery and context budgeting.

  The agent never ships the repository to the model.  It builds a snapshot
  once, ranks files against the task, and spends a fixed token budget on the
  highest-scoring material.  Everything it includes is wrapped as untrusted
  data.
-/
import LeanPrime.Tools.Registry
import LeanPrime.Tools.Process
import LeanPrime.Util.Paths

open Lean

namespace LeanPrime

open LeanPrime.Tools

/-- One file, with what we know about it without reading it. -/
structure FileEntry where
  path     : String
  bytes    : Nat
  /-- Lower is more recently modified; 0 when unknown. -/
  modified : Nat
  deriving Inhabited, Repr

/-- What the agent learned about the repository before planning. -/
structure ProjectSnapshot where
  root        : System.FilePath
  kind        : ProjectKind
  isGit       : Bool
  branch      : String
  gitStatus   : String
  files       : Array FileEntry
  /-- Contents of small, high-value files (README, manifests). -/
  keyFiles    : List (String × String)
  deriving Inhabited

/-- Files worth showing the model up front, if they exist and are small. -/
def keyFileNames : List String :=
  ["README.md", "README", "readme.md", "CLAUDE.md", "AGENTS.md", "CONTRIBUTING.md",
   "lakefile.lean", "lakefile.toml", "lean-toolchain", "Cargo.toml", "go.mod",
   "package.json", "pyproject.toml", "Makefile", "justfile"]

/-- Gather everything the agent needs before it plans.

    File metadata for the whole tree is collected concurrently with the git
    queries, since neither depends on the other. -/
def scanProject (ws : Workspace) (maxFiles : Nat := 4000) : IO ProjectSnapshot := do
  let gitTask ← IO.asTask do
    let isRepo ← isGitRepo ws.root
    if !isRepo then return (false, "", "")
    let branch ← match ← runProcess "git" #["rev-parse", "--abbrev-ref", "HEAD"] ws.root 15 with
      | .ok r => pure (trim r.stdout)
      | .error _ => pure ""
    let status ← match ← runProcess "git" #["status", "--short"] ws.root 20 with
      | .ok r => pure (trim r.stdout)
      | .error _ => pure ""
    return (true, branch, status)
  let kind ← detectProject ws.root
  let paths ← walkFiles ws.root maxFiles
  let mut files : Array FileEntry := #[]
  for p in paths do
    let (bytes, mtime) ← try
        let md ← p.metadata
        pure (md.byteSize.toNat, md.modified.sec.toNat)
      catch _ => pure (0, 0)
    files := files.push { path := ws.display p, bytes := bytes, modified := mtime }
  let (isGit, branch, status) ← match ← IO.wait gitTask with
    | .ok t => pure t
    | .error _ => pure (false, "", "")
  let mut keyFiles : List (String × String) := []
  for name in keyFileNames do
    let p := ws.root / name
    if ← p.pathExists then
      let md ← try p.metadata catch _ => continue
      if md.byteSize.toNat <= 16384 then
        let content ← try IO.FS.readFile p catch _ => continue
        keyFiles := keyFiles ++ [(name, content)]
  return {
    root := ws.root, kind := kind, isGit := isGit, branch := branch,
    gitStatus := status, files := files, keyFiles := keyFiles }

/-! ### Relevance ranking -/

/-- Words in the task worth matching against paths. -/
def taskTerms (task : String) : List String :=
  let raw := (toLower task).toList.map (fun c => if c.isAlphanum then c else ' ')
  (splitNonEmpty (String.ofList raw) " ").filter (fun w => w.length >= 3)

/-- Source extensions, scored above data and docs. -/
def sourceExtensions : List String :=
  ["lean", "rs", "go", "ts", "tsx", "js", "jsx", "py", "java", "kt", "c", "h",
   "cpp", "hpp", "cs", "rb", "swift", "zig", "ml", "hs", "scala", "php"]

/-- Score a file against the task.  Higher is more relevant.

    Deliberately simple and explainable: term hits in the path dominate,
    source files outrank data, tests get a small bump because the agent
    usually needs them, and recently-modified files edge ahead of stale
    ones. -/
def scoreFile (terms : List String) (touched : List String) (e : FileEntry)
    (newestMtime : Nat) : Nat :=
  let lowerPath := toLower e.path
  let termHits := terms.foldl (fun acc t => if containsSubstr lowerPath t then acc + 40 else acc) 0
  let ext := (e.path.splitOn ".").getLast!
  let extScore := if sourceExtensions.contains (toLower ext) then 15 else 0
  let testScore := if containsSubstr lowerPath "test" || containsSubstr lowerPath "spec"
                   then 8 else 0
  let touchedScore := if touched.contains e.path then 60 else 0
  let depth := (e.path.splitOn "/").length
  let shallowScore := if depth <= 2 then 6 else 0
  -- recency: at most 10 points, scaled against the newest file in the tree
  let recency := if newestMtime == 0 || e.modified == 0 then 0
                 else if e.modified * 100 >= newestMtime * 99 then 10
                 else if e.modified * 100 >= newestMtime * 95 then 5
                 else 0
  termHits + extScore + testScore + touchedScore + shallowScore + recency

/-- Rank the tree against a task, most relevant first. -/
def rankFiles (snap : ProjectSnapshot) (task : String) (touched : List String)
    : Array FileEntry :=
  let terms := taskTerms task
  let newest := snap.files.foldl (fun acc e => max acc e.modified) 0
  let scored := snap.files.map (fun e => (scoreFile terms touched e newest, e))
  let sorted := scored.qsort (fun a b => a.1 > b.1)
  sorted.map Prod.snd

/-! ### Budgeting -/

/-- Rough token estimate for a blob of text. -/
def estimateTokens (s : String) : Nat := s.utf8ByteSize / 4 + 1

/-- Build the context block handed to the model with the task.

    Spends at most `tokenBudget` estimated tokens, in priority order:
    project facts, git state, key files, then the ranked file listing. -/
def buildContext (snap : ProjectSnapshot) (task : String) (touched : List String)
    (tokenBudget : Nat) (fence : Bool) : String := Id.run do
  let mut parts : Array String := #[]
  let mut spent := 0
  -- 1. facts (always included; tiny)
  let facts := String.intercalate "\n"
    [ s!"Project type: {snap.kind}"
    , s!"Workspace: {snap.root}"
    , s!"Files tracked: {snap.files.size}"
    , s!"Git repository: {if snap.isGit then "yes" else "no"}"
    , if snap.isGit then s!"Branch: {snap.branch}" else "" ]
  parts := parts.push facts
  spent := spent + estimateTokens facts
  -- 2. working tree state
  if snap.isGit && !snap.gitStatus.isEmpty then
    let block := frameData fence "git:status" (clampLines snap.gitStatus 60 10)
    if spent + estimateTokens block < tokenBudget then
      parts := parts.push ("## Uncommitted changes\n" ++ block)
      spent := spent + estimateTokens block
  -- 3. key files, largest value first
  for (name, content) in snap.keyFiles do
    let trimmed := clampLines content 80 0
    let block := frameData fence s!"file:{name}" trimmed
    if spent + estimateTokens block < tokenBudget * 6 / 10 then
      parts := parts.push s!"## {name}\n{block}"
      spent := spent + estimateTokens block
  -- 4. ranked listing, filling whatever budget remains
  let ranked := rankFiles snap task touched
  let mut listing : Array String := #[]
  for e in ranked do
    let line := s!"{e.path} ({e.bytes} bytes)"
    if spent + estimateTokens line >= tokenBudget then break
    listing := listing.push line
    spent := spent + estimateTokens line
  if !listing.isEmpty then
    parts := parts.push
      ("## Files, most relevant to this task first\n" ++
       frameData fence "repository:listing" (String.intercalate "\n" listing.toList))
  return String.intercalate "\n\n" parts.toList

end LeanPrime
