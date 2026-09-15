/-
  LeanPrime.Config.Toml

  A deliberately small TOML subset parser.

  Rationale for writing this rather than taking a dependency: the agent needs
  exactly five value shapes (string, integer, float, boolean, string array)
  plus tables and array-of-tables.  A full TOML implementation would be a
  large third-party surface for no gain, and config parsing sits on the
  security boundary, so we keep it auditable and in-tree.

  Supported:
    # comments
    key = "string" | 12 | 1.5 | true | ["a", "b"]
    [table]           and   [table.sub]
    [[array_table]]
  Not supported (documented, and rejected with a clear error rather than
  silently mis-parsed): multi-line strings, inline tables, dates, nested
  arrays, dotted keys outside of headers.
-/
import LeanPrime.Util.Prelude
import LeanPrime.Util.Errors

namespace LeanPrime.Toml

open LeanPrime

/-- A parsed TOML scalar or array. -/
inductive Value where
  | str   (s : String)
  | int   (n : Int)
  | num   (f : Float)
  | bool  (b : Bool)
  | array (xs : List Value)
  deriving Inhabited, Repr

/-- A flat view of a TOML document: fully-qualified dotted key → value.
    `[server] port = 1` becomes `server.port`.  Array-of-tables entries are
    indexed: `mcp.0.command`. -/
structure Document where
  entries : List (String × Value)
  deriving Inhabited

namespace Document

def get? (d : Document) (key : String) : Option Value :=
  (d.entries.find? (fun e => e.1 == key)).map Prod.snd

def getStr? (d : Document) (key : String) : Option String :=
  match d.get? key with | some (.str s) => some s | _ => none

def getNat? (d : Document) (key : String) : Option Nat :=
  match d.get? key with
  | some (.int n) => if n >= 0 then some n.toNat else none
  | _ => none

def getFloat? (d : Document) (key : String) : Option Float :=
  match d.get? key with
  | some (.num f) => some f
  | some (.int n) => some (Float.ofInt n)
  | _ => none

def getBool? (d : Document) (key : String) : Option Bool :=
  match d.get? key with | some (.bool b) => some b | _ => none

def getStrArray? (d : Document) (key : String) : Option (List String) :=
  match d.get? key with
  | some (.array xs) =>
    some (xs.filterMap (fun v => match v with | .str s => some s | _ => none))
  | _ => none

/-- All distinct indices used under an array-of-tables prefix, in order. -/
def arrayIndices (d : Document) (prefix_ : String) : List Nat :=
  let pref := prefix_ ++ "."
  let idxs := d.entries.filterMap fun e =>
    if e.1.startsWith pref then
      let rest := (e.1.drop pref.length).toString
      match rest.splitOn "." with
      | h :: _ :: _ => h.toNat?
      | _ => none
    else none
  idxs.foldl (fun acc i => if acc.contains i then acc else acc ++ [i]) []

end Document

/-- Strip an unquoted trailing comment, respecting quoted strings. -/
private def stripComment (line : String) : String := Id.run do
  let mut out := ""
  let mut inStr := false
  let mut escaped := false
  for c in line.toList do
    if escaped then
      out := out.push c; escaped := false
    else if c == '\\' && inStr then
      out := out.push c; escaped := true
    else if c == '"' then
      inStr := !inStr; out := out.push c
    else if c == '#' && !inStr then
      break
    else
      out := out.push c
  return out

/-- Unescape a double-quoted TOML basic string body. -/
private def unescape (s : String) : String := Id.run do
  let mut out := ""
  let mut esc := false
  for c in s.toList do
    if esc then
      out := out.push (match c with
        | 'n' => '\n' | 't' => '\t' | 'r' => '\r'
        | '"' => '"'  | '\\' => '\\' | other => other)
      esc := false
    else if c == '\\' then esc := true
    else out := out.push c
  return out

/-- Split a bracketed array body on top-level commas. -/
private def splitTopLevel (s : String) : List String := Id.run do
  let mut parts : List String := []
  let mut cur := ""
  let mut inStr := false
  let mut esc := false
  for c in s.toList do
    if esc then cur := cur.push c; esc := false
    else if c == '\\' && inStr then cur := cur.push c; esc := true
    else if c == '"' then inStr := !inStr; cur := cur.push c
    else if c == ',' && !inStr then parts := parts ++ [cur]; cur := ""
    else cur := cur.push c
  if !(trim cur).isEmpty then parts := parts ++ [cur]
  return parts

/-- Parse a decimal float such as `1.5`, `-0.25` or `42`.  Deliberately does
    not accept exponent notation; the config schema has no use for it. -/
def parseFloat? (s : String) : Option Float :=
  let (neg, body) :=
    if s.startsWith "-" then (true, (s.drop 1).toString)
    else if s.startsWith "+" then (false, (s.drop 1).toString)
    else (false, s)
  match body.splitOn "." with
  | [whole] => (whole.toNat?).map (fun w =>
      let f := Float.ofNat w
      if neg then -f else f)
  | [whole, frac] => do
      let w ← if whole.isEmpty then some 0 else whole.toNat?
      let fr ← if frac.isEmpty then some 0 else frac.toNat?
      let scale := Float.ofNat (10 ^ frac.length)
      let f := Float.ofNat w + Float.ofNat fr / scale
      some (if neg then -f else f)
  | _ => none

mutual
/-- Parse a single TOML value from its textual form. -/
partial def parseValue (raw : String) : LPResult Value :=
  let v := trim raw
  if v.startsWith "\"" && v.endsWith "\"" && v.length >= 2 then
    .ok (.str (unescape ((v.drop 1).dropEnd 1).toString))
  else if v.startsWith "'" && v.endsWith "'" && v.length >= 2 then
    .ok (.str ((v.drop 1).dropEnd 1).toString)        -- literal string
  else if v.startsWith "[" && v.endsWith "]" then
    parseArray ((v.drop 1).dropEnd 1).toString
  else if v == "true" then .ok (.bool true)
  else if v == "false" then .ok (.bool false)
  else
    match v.toInt? with
    | some n => .ok (.int n)
    | none =>
      match parseFloat? v with
      | some f => .ok (.num f)
      | none => .error (err .configuration s!"cannot parse TOML value: {v}")

partial def parseArray (body : String) : LPResult Value := do
  let parts := splitTopLevel body
  let mut acc : List Value := []
  for p in parts do
    acc := acc ++ [← parseValue p]
  return .array acc
end

/-- Net bracket depth of a line, ignoring brackets inside quoted strings. -/
private def bracketBalance (s : String) : Int := Id.run do
  let mut depth : Int := 0
  let mut inStr := false
  let mut esc := false
  for c in s.toList do
    if esc then esc := false
    else if c == '\\' && inStr then esc := true
    else if c == '"' then inStr := !inStr
    else if !inStr then
      if c == '[' then depth := depth + 1
      else if c == ']' then depth := depth - 1
  return depth

/-- Join lines belonging to one array value that spans several source lines,
    keeping the line number of where the value started for error reporting.
    Table headers (`[x]`, `[[x]]`) are balanced on their own line and so are
    never joined. -/
private def logicalLines (src : String) : List (Nat × String) := Id.run do
  let mut out : List (Nat × String) := []
  let mut pending : Option (Nat × String) := none
  let mut lineNo := 0
  for rawLine in src.splitOn "\n" do
    lineNo := lineNo + 1
    let line := trim (stripComment rawLine)
    match pending with
    | some (startLine, acc) =>
      let joined := acc ++ " " ++ line
      if bracketBalance joined <= 0 then
        out := out ++ [(startLine, joined)]
        pending := none
      else
        pending := some (startLine, joined)
    | none =>
      if line.isEmpty then continue
      if bracketBalance line > 0 && !line.startsWith "[" then
        pending := some (lineNo, line)
      else
        out := out ++ [(lineNo, line)]
  -- an unterminated value is handed on as-is so `parseValue` reports it
  match pending with
  | some (startLine, acc) => out := out ++ [(startLine, acc)]
  | none => pure ()
  return out

/-- Parse a TOML document into a flat dotted-key map. -/
def parse (src : String) : LPResult Document := do
  let mut entries : List (String × Value) := []
  let mut table : String := ""
  let mut arrayCounts : List (String × Nat) := []
  for (lineNo, line) in logicalLines src do
    if line.isEmpty then continue
    if line.startsWith "[[" && line.endsWith "]]" then
      let name := trim ((line.drop 2).dropEnd 2).toString
      let idx := (arrayCounts.find? (fun c => c.1 == name)).map Prod.snd |>.getD 0
      arrayCounts := (arrayCounts.filter (fun c => c.1 != name)) ++ [(name, idx + 1)]
      table := s!"{name}.{idx}"
    else if line.startsWith "[" && line.endsWith "]" then
      table := trim ((line.drop 1).dropEnd 1).toString
      if table.isEmpty then
        throw (err .configuration s!"empty table header on line {lineNo}")
    else
      match line.splitOn "=" with
      | [] => throw (err .configuration s!"malformed line {lineNo}: {line}")
      | [_] => throw (err .configuration s!"expected `key = value` on line {lineNo}: {line}")
      | k :: rest =>
        let key := trim k
        let valueText := String.intercalate "=" rest
        match parseValue valueText with
        | .error e =>
          throw { e with detail := some s!"line {lineNo}: {line}" }
        | .ok v =>
          let full := if table.isEmpty then key else s!"{table}.{key}"
          entries := entries ++ [(full, v)]
  return { entries := entries }

end LeanPrime.Toml
