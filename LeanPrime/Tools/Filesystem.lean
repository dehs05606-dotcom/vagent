/-
  LeanPrime.Tools.Filesystem

  File tools.  Every path goes through `Workspace.resolve`, which is proved
  to be escape-free in `LeanPrime.Verification.PathProofs`.

  `edit_file` performs an exact, unique string replacement rather than a
  whole-file rewrite: it fails loudly when the anchor text is missing or
  ambiguous, which is what stops a model from silently destroying a file it
  only partially understood.
-/
import LeanPrime.Tools.Tool
import LeanPrime.Util.Diff

open Lean

namespace LeanPrime.Tools

open LeanPrime

/-- Resolve a path argument, or produce a structured error. -/
private def resolveArg (ctx : ToolContext) (args : Json) (key : String)
    : LPResult System.FilePath :=
  match argStr? args key with
  | none => throw (err .tool s!"missing string argument `{key}`")
  | some p => ctx.workspace.resolve p

/-- Read a text file, refusing binaries and oversized files. -/
def readFile : Tool where
  name := "read_file"
  description :=
    "Read a UTF-8 text file from the workspace. Returns the file contents with line numbers. \
     Use this before editing any file."
  parameters := schemaObject
    [ ("path", schemaProp "string" "Workspace-relative path to the file")
    , ("start_line", schemaProp "integer" "Optional 1-based first line to return")
    , ("max_lines", schemaProp "integer" "Optional maximum number of lines to return") ]
    ["path"]
  required := ["path"]
  requirement := fun _ args =>
    { permissions := [.readFs], risk := .low
      summary := s!"read {(argStr? args "path").getD "?"}" }
  run := fun ctx args => do
    match resolveArg ctx args "path" with
    | .error e => return .error e
    | .ok path =>
      if !(← path.pathExists) then
        return .ok (ToolResult.failure s!"file not found: {ctx.workspace.display path}")
      if ← path.isDir then
        return .ok (ToolResult.failure s!"{ctx.workspace.display path} is a directory; use list_directory")
      let md ← path.metadata
      if md.byteSize.toNat > ctx.config.limits.maxFileBytes then
        return .ok (ToolResult.failure
          s!"file is {md.byteSize} bytes, above the {ctx.config.limits.maxFileBytes} byte limit; \
             read a range with start_line/max_lines or search it instead")
      let content ← try IO.FS.readFile path
        catch e => return .ok (ToolResult.failure s!"cannot read file: {e}")
      let allLines := content.splitOn "\n"
      let start := (argNat? args "start_line").getD 1
      let start := if start == 0 then 1 else start
      let maxLines := (argNat? args "max_lines").getD allLines.length
      let selected := (allLines.drop (start - 1)).take maxLines
      let numbered := selected.zipIdx.map (fun (l, i) => s!"{padLeft (toString (start + i)) 6}  {l}")
      let body := String.intercalate "\n" numbered
      let clamped := clampOutput body ctx.config.limits.maxBytes
        ctx.config.limits.headLines ctx.config.limits.tailLines
      return .ok {
        ok := true
        content := frameData ctx.config.dataFencing s!"file:{ctx.workspace.display path}" clamped
        display := s!"read {ctx.workspace.display path} ({allLines.length} lines)"
        metadata := Json.mkObj
          [("path", .str (ctx.workspace.display path)),
           ("lines", .num (JsonNumber.fromNat allLines.length))] }

/-- Create or overwrite a file. -/
def writeFile : Tool where
  name := "write_file"
  description :=
    "Create a new file or completely replace an existing one. \
     Prefer edit_file for changes to an existing file."
  parameters := schemaObject
    [ ("path", schemaProp "string" "Workspace-relative path")
    , ("content", schemaProp "string" "Full file contents") ]
    ["path", "content"]
  required := ["path", "content"]
  requirement := fun _ args =>
    { permissions := [.writeFs], risk := .medium
      summary := s!"write {(argStr? args "path").getD "?"}" }
  run := fun ctx args => do
    match resolveArg ctx args "path" with
    | .error e => return .error e
    | .ok path =>
      let some content := argStr? args "content"
        | return .error (err .tool "missing string argument `content`")
      let existed ← path.pathExists
      let old ← if existed then (try IO.FS.readFile path catch _ => pure "") else pure ""
      if let some parent := path.parent then
        try IO.FS.createDirAll parent catch e =>
          return .ok (ToolResult.failure s!"cannot create directory: {e}")
      try IO.FS.writeFile path content
        catch e => return .ok (ToolResult.failure s!"cannot write file: {e}")
      let (removed, added) := changeCount old content
      let verb := if existed then "updated" else "created"
      let diff := (diffText (ctx.workspace.display path) old content).getD ""
      return .ok {
        ok := true
        content := s!"{verb} {ctx.workspace.display path} (-{removed}/+{added} lines)\n{diff}"
        display := s!"{verb} {ctx.workspace.display path} (-{removed}/+{added})"
        metadata := Json.mkObj
          [("path", .str (ctx.workspace.display path)), ("created", .bool (!existed)),
           ("removed", .num (JsonNumber.fromNat removed)),
           ("added", .num (JsonNumber.fromNat added))] }

/-- Exact, unique string replacement inside a file. -/
def editFile : Tool where
  name := "edit_file"
  description :=
    "Replace an exact block of text in a file. `old_string` must appear EXACTLY ONCE in the file, \
     including whitespace and indentation. Read the file first. \
     The edit fails without modifying anything if the text is absent or appears more than once."
  parameters := schemaObject
    [ ("path", schemaProp "string" "Workspace-relative path")
    , ("old_string", schemaProp "string" "Exact text to replace; must be unique in the file")
    , ("new_string", schemaProp "string" "Replacement text")
    , ("replace_all", schemaProp "boolean" "Replace every occurrence instead of requiring uniqueness") ]
    ["path", "old_string", "new_string"]
  required := ["path", "old_string", "new_string"]
  requirement := fun _ args =>
    { permissions := [.writeFs], risk := .medium
      summary := s!"edit {(argStr? args "path").getD "?"}" }
  run := fun ctx args => do
    match resolveArg ctx args "path" with
    | .error e => return .error e
    | .ok path =>
      let some oldStr := argStr? args "old_string"
        | return .error (err .tool "missing string argument `old_string`")
      let some newStr := argStr? args "new_string"
        | return .error (err .tool "missing string argument `new_string`")
      let replaceAll := (argBool? args "replace_all").getD false
      if !(← path.pathExists) then
        return .ok (ToolResult.failure s!"file not found: {ctx.workspace.display path}")
      let content ← try IO.FS.readFile path
        catch e => return .ok (ToolResult.failure s!"cannot read file: {e}")
      if oldStr.isEmpty then
        return .ok (ToolResult.failure "old_string must not be empty")
      let occurrences := (content.splitOn oldStr).length - 1
      if occurrences == 0 then
        return .ok (ToolResult.failure
          s!"old_string not found in {ctx.workspace.display path}; \
             re-read the file and copy the exact text including indentation")
      if occurrences > 1 && !replaceAll then
        return .ok (ToolResult.failure
          s!"old_string appears {occurrences} times in {ctx.workspace.display path}; \
             include more surrounding context to make it unique, or set replace_all")
      let updated :=
        if replaceAll then content.replace oldStr newStr
        else
          match content.splitOn oldStr with
          | before :: after => before ++ newStr ++ String.intercalate oldStr after
          | [] => content
      if updated == content then
        return .ok (ToolResult.failure "edit would not change the file")
      try IO.FS.writeFile path updated
        catch e => return .ok (ToolResult.failure s!"cannot write file: {e}")
      let (removed, added) := changeCount content updated
      let diff := (diffText (ctx.workspace.display path) content updated).getD ""
      return .ok {
        ok := true
        content := s!"edited {ctx.workspace.display path} ({occurrences} replacement(s), -{removed}/+{added} lines)\n{diff}"
        display := s!"edit {ctx.workspace.display path} (-{removed}/+{added})"
        metadata := Json.mkObj
          [("path", .str (ctx.workspace.display path)),
           ("replacements", .num (JsonNumber.fromNat occurrences))] }

/-- Directory names never worth walking into. -/
def ignoredDirs : List String :=
  [".git", ".lake", "node_modules", "target", "build", "dist", "out",
   ".venv", "venv", "__pycache__", ".next", ".cache", ".idea", ".mypy_cache"]

def listDirectory : Tool where
  name := "list_directory"
  description := "List the entries of a directory in the workspace."
  parameters := schemaObject
    [ ("path", schemaProp "string" "Workspace-relative directory (default: workspace root)") ] []
  requirement := fun _ args =>
    { permissions := [.readFs], risk := .low
      summary := s!"list {(argStr? args "path").getD "."}" }
  run := fun ctx args => do
    let rel := (argStr? args "path").getD "."
    match ctx.workspace.resolve rel with
    | .error e => return .error e
    | .ok path =>
      if !(← path.pathExists) then
        return .ok (ToolResult.failure s!"directory not found: {rel}")
      if !(← path.isDir) then
        return .ok (ToolResult.failure s!"{rel} is not a directory")
      let entries ← try path.readDir catch e =>
        return .ok (ToolResult.failure s!"cannot list directory: {e}")
      let mut lines : Array String := #[]
      for e in entries do
        let isDir ← e.path.isDir
        let name := e.fileName
        if isDir then
          lines := lines.push (if ignoredDirs.contains name then s!"{name}/  (skipped)" else s!"{name}/")
        else
          let sz ← try (do return (← e.path.metadata).byteSize) catch _ => pure 0
          lines := lines.push s!"{name}  ({sz} bytes)"
      let sorted := lines.qsort (· < ·)
      let body := String.intercalate "\n" sorted.toList
      return .ok {
        ok := true
        content := frameData ctx.config.dataFencing s!"dir:{rel}" (clampOutput body ctx.config.limits.maxBytes 200 40)
        display := s!"list {rel} ({sorted.size} entries)"
        metadata := Json.mkObj [("path", .str rel), ("count", .num (JsonNumber.fromNat sorted.size))] }

def deleteFile : Tool where
  name := "delete_file"
  description := "Delete a file from the workspace. Cannot delete directories."
  parameters := schemaObject [("path", schemaProp "string" "Workspace-relative path")] ["path"]
  required := ["path"]
  requirement := fun _ args =>
    { permissions := [.writeFs], risk := .high
      summary := s!"delete {(argStr? args "path").getD "?"}" }
  run := fun ctx args => do
    match resolveArg ctx args "path" with
    | .error e => return .error e
    | .ok path =>
      if !(← path.pathExists) then
        return .ok (ToolResult.failure s!"file not found: {ctx.workspace.display path}")
      if ← path.isDir then
        return .ok (ToolResult.failure "refusing to delete a directory")
      try IO.FS.removeFile path
        catch e => return .ok (ToolResult.failure s!"cannot delete: {e}")
      return .ok (ToolResult.success s!"deleted {ctx.workspace.display path}"
        s!"delete {ctx.workspace.display path}")

end LeanPrime.Tools
