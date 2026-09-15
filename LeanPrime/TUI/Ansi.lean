/-
  LeanPrime.TUI.Ansi

  Terminal styling, centralised so that colour can be switched off in one
  place (no TTY, NO_COLOR, `--json`) and never leaks into piped output.
-/
import LeanPrime.Util.Prelude

namespace LeanPrime.Ansi

/-- Style codes.  Kept to the 16-colour set so they render correctly in
    every terminal and in both light and dark themes. -/
def reset   : String := "\x1b[0m"
def bold    : String := "\x1b[1m"
def dim     : String := "\x1b[2m"
def red     : String := "\x1b[31m"
def green   : String := "\x1b[32m"
def yellow  : String := "\x1b[33m"
def blue    : String := "\x1b[34m"
def magenta : String := "\x1b[35m"
def cyan    : String := "\x1b[36m"
def grey    : String := "\x1b[90m"

/-- Wrap `s` in `code` when colour is enabled. -/
def style (enabled : Bool) (code s : String) : String :=
  if enabled then code ++ s ++ reset else s

end LeanPrime.Ansi
