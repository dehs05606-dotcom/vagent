/-
  Tests.Harness

  A small assertion harness.  No dependency: the point of the test suite is
  to check LeanPrime, so it should not drag in anything that could fail for
  unrelated reasons.
-/
import LeanPrime.Util.Prelude

namespace Tests

structure Results where
  passed : Nat := 0
  failed : Nat := 0
  names  : Array String := #[]
  deriving Inhabited

abbrev Runner := IO.Ref Results

def mkRunner : IO Runner := IO.mkRef {}

def record (r : Runner) (ok : Bool) (name : String) (detail : String := "") : IO Unit := do
  if ok then
    r.modify (fun s => { s with passed := s.passed + 1 })
  else
    r.modify (fun s => { s with failed := s.failed + 1, names := s.names.push name })
    IO.println s!"  FAIL  {name}{if detail.isEmpty then "" else s!"\n        {detail}"}"

def check (r : Runner) (name : String) (cond : Bool) : IO Unit :=
  record r cond name

def checkEq {α : Type} [BEq α] [ToString α] (r : Runner) (name : String) (actual expected : α)
    : IO Unit :=
  record r (actual == expected) name s!"expected {expected}, got {actual}"

def section_ (title : String) : IO Unit :=
  IO.println s!"\n{title}"

def summarize (r : Runner) : IO UInt32 := do
  let s ← r.get
  IO.println ""
  if s.failed == 0 then
    IO.println s!"{s.passed} passed, 0 failed"
    return 0
  else
    IO.println s!"{s.passed} passed, {s.failed} FAILED"
    for n in s.names do IO.println s!"  - {n}"
    return 1

end Tests
