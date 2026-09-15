/-
  LeanPrime.Util.Diff

  A small line diff used to show what an edit actually changed.

  It trims the common prefix and suffix and reports the differing block.
  That is not a minimal edit script (no Myers algorithm here), but for the
  single-hunk edits the agent performs it produces exactly the right output,
  and it is short enough to audit.  Whole-file rewrites degrade gracefully to
  one large hunk, which is the honest representation of that change.
-/
import LeanPrime.Util.Prelude

namespace LeanPrime

structure Hunk where
  /-- 1-based line number in the original file where the change starts. -/
  start   : Nat
  removed : List String
  added   : List String
  deriving Repr, Inhabited

/-- Number of leading elements two lists share. -/
private def commonPrefixLen : List String → List String → Nat
  | a :: as, b :: bs => if a == b then 1 + commonPrefixLen as bs else 0
  | _, _ => 0

/-- Compute the single differing block between two line lists. -/
def diffLines (old new : List String) : Option Hunk :=
  let pre := commonPrefixLen old new
  let oldRest := old.drop pre
  let newRest := new.drop pre
  let suf := commonPrefixLen oldRest.reverse newRest.reverse
  let suf := min suf (min oldRest.length newRest.length)
  let removed := oldRest.take (oldRest.length - suf)
  let added := newRest.take (newRest.length - suf)
  if removed.isEmpty && added.isEmpty then none
  else some { start := pre + 1, removed := removed, added := added }

/-- Render a hunk in a familiar unified-diff shape. -/
def renderHunk (path : String) (h : Hunk) (maxLines : Nat := 60) : String :=
  let header := s!"--- {path}\n+++ {path}\n@@ -{h.start},{h.removed.length} +{h.start},{h.added.length} @@"
  let minus := h.removed.map (fun l => "-" ++ l)
  let plus := h.added.map (fun l => "+" ++ l)
  let body := minus ++ plus
  let body := if body.length <= maxLines then body
              else body.take maxLines ++ [s!"… [{body.length - maxLines} more diff lines] …"]
  String.intercalate "\n" (header :: body)

/-- Full diff of two file contents, or `none` when they are identical. -/
def diffText (path old new : String) (maxLines : Nat := 60) : Option String :=
  (diffLines (old.splitOn "\n") (new.splitOn "\n")).map (renderHunk path · maxLines)

/-- Count of changed lines, for reporting. -/
def changeCount (old new : String) : Nat × Nat :=
  match diffLines (old.splitOn "\n") (new.splitOn "\n") with
  | none => (0, 0)
  | some h => (h.removed.length, h.added.length)

end LeanPrime
