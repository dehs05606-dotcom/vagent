/-
  LeanPrime.Util.Prelude

  Common imports and small string/collection helpers used across the whole
  code base.  Everything here is deliberately dependency-free so that any
  module may import it without creating cycles.
-/
import Lean.Data.Json
import Lean.Elab.Deriving.FromToJson
import Std.Data.HashMap
import Std.Sync.Channel

open Lean

namespace LeanPrime

/-- ASCII trim.  `String.trim` is deprecated in Lean 4.34 and now returns a
    `String.Slice`; we centralise the conversion in one place. -/
def trim (s : String) : String := s.trimAscii.toString

/-- Split on a separator string, dropping empty fragments. -/
def splitNonEmpty (s sep : String) : List String :=
  (s.splitOn sep).filter (fun p => !(trim p).isEmpty)

/-- Truncate a string to `n` characters, appending an ellipsis marker when cut. -/
def truncate (s : String) (n : Nat) : String :=
  if s.length <= n then s else s.take n |>.toString ++ "…"

/-- Keep the first `head` and last `tail` lines of a long text, replacing the
    middle with a marker.  Used to bound tool output injected into the model
    context. -/
def clampLines (s : String) (head tail : Nat) : String :=
  let ls := s.splitOn "\n"
  let n := ls.length
  if n <= head + tail then s
  else
    let front := ls.take head
    let back := ls.drop (n - tail)
    let omitted := n - head - tail
    String.intercalate "\n"
      (front ++ [s!"… [{omitted} lines omitted] …"] ++ back)

/-- Take the longest prefix of `s` whose UTF-8 encoding fits in `n` bytes.
    Never splits a character. -/
def takeBytes (s : String) (n : Nat) : String := Id.run do
  let mut acc := ""
  let mut used := 0
  for c in s.toList do
    let w := String.ofList [c] |>.utf8ByteSize
    if used + w > n then break
    acc := acc.push c
    used := used + w
  return acc

/-- Clamp by bytes as well as lines; tool output must never blow the context. -/
def clampOutput (s : String) (maxBytes : Nat) (head tail : Nat) : String :=
  let byLines := clampLines s head tail
  if byLines.utf8ByteSize <= maxBytes then byLines
  else
    let cut := takeBytes byLines maxBytes
    cut ++ s!"\n… [truncated at {maxBytes} bytes] …"

/-- `true` when `needle` occurs anywhere in `hay` (case sensitive). -/
def containsSubstr (hay needle : String) : Bool :=
  if needle.isEmpty then true
  else (hay.splitOn needle).length > 1

def toLower (s : String) : String := s.map Char.toLower

def containsSubstrI (hay needle : String) : Bool :=
  containsSubstr (toLower hay) (toLower needle)

/-- Left-pad / right-pad to a fixed display width. -/
def padRight (s : String) (n : Nat) : String :=
  if s.length >= n then s else s ++ String.ofList (List.replicate (n - s.length) ' ')

def padLeft (s : String) (n : Nat) : String :=
  if s.length >= n then s else String.ofList (List.replicate (n - s.length) ' ') ++ s

/-- Wall-clock milliseconds, used for durations and ids. -/
def nowMs : IO Nat := do
  let t ← IO.monoMsNow
  return t

/-- A short, collision-resistant-enough identifier for sessions / calls. -/
def freshId (prefix_ : String) : IO String := do
  let ms ← IO.monoNanosNow
  let r ← IO.rand 0 0xFFFFFF
  return s!"{prefix_}_{ms % 0xFFFFFFFF}{r}"

end LeanPrime
