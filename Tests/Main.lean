/-
  Tests.Main

  `lake exe lean-prime-tests` — the whole suite.  No network access is
  required; the model layer is tested through its wire-format functions.
-/
import Tests.Unit
import Tests.Security

open Tests

def main : IO UInt32 := do
  IO.println "lean-prime test suite"
  let r ← mkRunner
  runUnit r
  runSecurity r
  summarize r
