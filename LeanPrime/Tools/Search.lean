/-
  LeanPrime.Tools.Search

  Filename and content search, implemented in Lean rather than by shelling
  out to grep/rg.  That keeps the behaviour identical on every platform, lets
  the walker honour the same ignore rules the context engine uses, and means
  search needs no `execute` permission — it is a pure read.
-/
import LeanPrime.Tools.Tool
import LeanPrime.Tools.Filesystem

open Lean

namespace LeanPrime.Tools

open LeanPrime

/-- File extensions that are never worth reading as text. -/
def binaryExtensions : List String :=
  ["png", "jpg", "jpeg", "gif", "ico", "pdf", "zip", "gz", "tar", "xz", "7z",
   "exe", "dll", "so", "dylib", "o", "a", "class", "jar", "wasm", "olean",
   "mp3", "mp4", "mov", "woff", "woff2", "ttf", "otf", "bin", "lock"]

def isBinaryPath (p : System.FilePath) : Bool :=
  match p.extension with
  | some e => binaryExtensions.contains (toLower e)
  | none => false

/-- Recursively collect files under `root`, skipping ignored directories and
    stopping at `limit` results so a huge tree cannot stall the agent. -/
partial def walkFiles (root : System.FilePath) (limit : Nat)
    : IO (Array System.FilePath) := do
  let acc ← IO.mkRef (#[] : Array System.FilePath)
  let rec go (dir : System.FilePath) (depth : Nat) : IO Unit := do
    if depth > 24 then return
    if (← acc.get).size >= limit then return
    let entries ← try dir.readDir catch _ => pure #[]
    for e in entries do
      if (← acc.get).size >= limit then return
      let name := e.fileName
      if name.startsWith "." && name != "." && name != ".." &&
         !["`.github`"].contains name then
        -- hidden entries are skipped except where explicitly useful
        if ignoredDirs.contains name then continue
      if ← e.path.isDir then
        if ignoredDirs.contains name then continue
        go e.path (depth + 1)
      else
        acc.modify (·.push e.path)
  go root 0
  return ← acc.get

/-- Case-insensitive substring match used for filename queries. -/
def fileNameMatches (needle : String) (p : System.FilePath) : Bool :=
  containsSubstrI p.toString needle

def searchFiles : Tool where
  name := "search_files"
  description :=
    "Find files whose path contains the given substring. Case-insensitive. \
     Ignores build output and version-control directories."
  parameters := schemaObject
    [ ("query", schemaProp "string" "Substring to match against file paths")
    , ("max_results", schemaProp "integer" "Maximum results (default 100)") ]
    ["query"]
  required := ["query"]
  requirement := fun _ args =>
    { permissions := [.readFs], risk := .low
      summary := s!"find files matching {(argStr? args "query").getD "?"}" }
  run := fun ctx args => do
    let some query := argStr? args "query"
      | return .error (err .tool "missing string argument `query`")
    let maxResults := (argNat? args "max_results").getD 100
    let all ← walkFiles ctx.workspace.root 20000
    let hits := all.filter (fileNameMatches query)
    let shown := hits.toList.take maxResults
    let body := String.intercalate "\n" (shown.map ctx.workspace.display)
    let note := if hits.size > shown.length
      then s!"\n… {hits.size - shown.length} more matches not shown" else ""
    return .ok {
      ok := true
      content := frameData ctx.config.dataFencing s!"search_files:{query}"
        (if shown.isEmpty then "no matching files" else body ++ note)
      display := s!"search_files \"{query}\" — {hits.size} match(es)"
      metadata := Json.mkObj [("matches", .num (JsonNumber.fromNat hits.size))] }

/-- One content match. -/
private structure Hit where
  path : String
  line : Nat
  text : String

def searchText : Tool where
  name := "search_text"
  description :=
    "Search file contents for a literal substring and return matching lines with \
     their file and line number. Use this to locate symbols and call sites before reading files."
  parameters := schemaObject
    [ ("query", schemaProp "string" "Literal text to find")
    , ("path", schemaProp "string" "Optional subdirectory to restrict the search to")
    , ("extension", schemaProp "string" "Optional file extension filter, e.g. \"lean\"")
    , ("ignore_case", schemaProp "boolean" "Case-insensitive match (default false)")
    , ("max_results", schemaProp "integer" "Maximum matching lines (default 80)") ]
    ["query"]
  required := ["query"]
  requirement := fun _ args =>
    { permissions := [.readFs], risk := .low
      summary := s!"search for {(argStr? args "query").getD "?"}" }
  run := fun ctx args => do
    let some query := argStr? args "query"
      | return .error (err .tool "missing string argument `query`")
    if query.isEmpty then
      return .ok (ToolResult.failure "query must not be empty")
    let ignoreCase := (argBool? args "ignore_case").getD false
    let maxResults := (argNat? args "max_results").getD 80
    let ext? := argStr? args "extension"
    let searchRoot ← match argStr? args "path" with
      | none => pure ctx.workspace.root
      | some p => match ctx.workspace.resolve p with
        | .error e => return .error e
        | .ok r => pure r
    let files ← walkFiles searchRoot 20000
    let candidates := files.filter fun f =>
      !isBinaryPath f && (match ext? with
        | none => true
        | some e => f.extension == some e)
    let mut hits : Array Hit := #[]
    let mut scanned := 0
    for f in candidates do
      if hits.size >= maxResults then break
      let md ← try f.metadata catch _ => continue
      if md.byteSize.toNat > ctx.config.limits.maxFileBytes then continue
      let content ← try IO.FS.readFile f catch _ => continue
      scanned := scanned + 1
      for (line, idx) in content.splitOn "\n" |>.zipIdx do
        if hits.size >= maxResults then break
        let found := if ignoreCase then containsSubstrI line query else containsSubstr line query
        if found then
          hits := hits.push
            { path := ctx.workspace.display f, line := idx + 1, text := truncate (trim line) 200 }
    let body := String.intercalate "\n"
      (hits.toList.map fun h => s!"{h.path}:{h.line}: {h.text}")
    return .ok {
      ok := true
      content := frameData ctx.config.dataFencing s!"search_text:{query}"
        (if hits.isEmpty then s!"no matches in {scanned} files" else body)
      display := s!"search_text \"{truncate query 40}\" — {hits.size} hit(s) in {scanned} files"
      metadata := Json.mkObj
        [("hits", .num (JsonNumber.fromNat hits.size)),
         ("files_scanned", .num (JsonNumber.fromNat scanned))] }

end LeanPrime.Tools
