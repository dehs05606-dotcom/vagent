/-
  LeanPrime.TUI.StatusBar

  A two-line status block pinned below a scrolling transcript.

  Not a full-screen interface: no alternate screen buffer, no cursor
  addressing, no redraw of anything the user has already read.  Scrollback
  stays intact and the output is still a normal terminal transcript you can
  pipe, copy or search.  The only thing that moves is the two-line block at
  the bottom, which is erased before each new transcript line and redrawn
  after it.

  The sequences used are the conservative ones — carriage return, cursor up,
  erase-line — so the block behaves the same under tmux, screen and a plain
  tty.  Without a TTY the block is not drawn at all, which is what keeps
  `--json` and piped output clean.

      ────────────────────────────────────────────────────────────────
      ▌ executing · edit_file src/auth.ts              4 tools · 12.4k
      ▌ SystemPrompt.lean · 6 rules · 2 enforced · unrestricted
      ────────────────────────────────────────────────────────────────
-/
import LeanPrime.TUI.Ansi
import LeanPrime.Agent.State

namespace LeanPrime

open LeanPrime.Ansi

/-- What the two lines show.  Held in one structure so the renderer updates
    fields independently and redraws from a single consistent snapshot. -/
structure StatusModel where
  phase       : AgentPhase := .idle
  /-- Current activity: the tool running, or what the model is doing. -/
  activity    : String := "starting"
  toolCount   : Nat := 0
  tokens      : Nat := 0
  /-- Where the system prompt came from, short form. -/
  promptOrigin : String := ""
  directives  : Nat := 0
  enforced    : Nat := 0
  mode        : String := "governed"
  /-- Set while a reply is being re-requested for breaking a rule. -/
  complianceRetry : Option Nat := none
  /-- Cumulative compliance pass/fail for the status line. -/
  compliancePasses : Nat := 0
  complianceFailures : Nat := 0
  /-- Injection attempts blocked. -/
  injectionBlocks : Nat := 0
  deriving Inhabited

/-- Terminal width, best effort.  `COLUMNS` is exported by most shells; the
    fallback is the conventional 80 rather than something adaptive, because
    a status line that guesses wrong and wraps is worse than one that is
    slightly narrow. -/
def terminalWidth : IO Nat := do
  match ← IO.getEnv "COLUMNS" with
  | some c => return (c.toNat?.getD 80).max 40
  | none => return 80

/-- Human-readable token count: 12400 becomes "12.4k". -/
def formatTokens (n : Nat) : String :=
  if n < 1000 then toString n
  else
    let thousands := n / 1000
    let tenths := (n % 1000) / 100
    if thousands >= 100 then s!"{thousands}k" else s!"{thousands}.{tenths}k"

/-- Fit `left` and `right` onto one line of `width`, right-aligning `right`
    and truncating `left` if they would collide. -/
def layoutLine (width : Nat) (left right : String) : String :=
  let gutterWidth := 2                     -- the "▌ " prefix
  let avail := if width > gutterWidth then width - gutterWidth else width
  if right.isEmpty then
    truncate left avail
  else if left.length + right.length + 2 <= avail then
    left ++ String.ofList (List.replicate (avail - left.length - right.length) ' ') ++ right
  else
    let leftRoom := if avail > right.length + 2 then avail - right.length - 2 else 0
    let cut := truncate left leftRoom
    cut ++ String.ofList (List.replicate (avail - cut.length - right.length) ' ') ++ right

/-- The two content lines, without the surrounding rules. -/
def StatusModel.lines (m : StatusModel) (width : Nat) : String × String :=
  let activity := match m.complianceRetry with
    | some n => s!"rejected reply · re-requesting (attempt {n})"
    | none => m.activity
  let first := layoutLine width
    s!"{m.phase} · {activity}"
    s!"{m.toolCount} tools · {formatTokens m.tokens}"
  let ruleText :=
    if m.directives == 0 then "no directives"
    else s!"{m.directives} rules · {m.enforced} enforced"
  let compText :=
    if m.compliancePasses + m.complianceFailures == 0 then ""
    else
      let inj := if m.injectionBlocks > 0 then s!" · {m.injectionBlocks} blocked" else ""
      s!" · {m.compliancePasses}✓/{m.complianceFailures}✗{inj}"
  let second := layoutLine width
    s!"{m.promptOrigin} · {ruleText}{compText}"
    m.mode
  (first, second)

/-- A drawable, erasable status block. -/
structure StatusBar where
  /-- Current contents. -/
  model   : IO.Ref StatusModel
  /-- Whether the block is currently on screen and must be erased first. -/
  drawn   : IO.Ref Bool
  enabled : Bool
  color   : Bool

/-- Erase the block if it is on screen.  Four lines: two rules, two content. -/
def StatusBar.erase (b : StatusBar) : IO Unit := do
  if !b.enabled then return
  if !(← b.drawn.get) then return
  let out ← IO.getStdout
  -- move to the start of the line, then up over the four drawn lines,
  -- clearing each as we pass it
  out.putStr "\r\x1b[2K"
  for _ in [0:3] do
    out.putStr "\x1b[1A\x1b[2K"
  out.flush
  b.drawn.set false

/-- Draw the block at the cursor. -/
def StatusBar.draw (b : StatusBar) : IO Unit := do
  if !b.enabled then return
  if ← b.drawn.get then b.erase
  let m ← b.model.get
  let width ← terminalWidth
  let (first, second) := m.lines width
  let rule := String.ofList (List.replicate width '─')
  let out ← IO.getStdout
  let accent := match m.mode with
    | "unrestricted" => Ansi.yellow
    | _ => Ansi.cyan
  out.putStrLn (style b.color Ansi.grey rule)
  out.putStrLn (style b.color accent "▌" ++ " " ++ style b.color Ansi.bold first)
  out.putStrLn (style b.color accent "▌" ++ " " ++ style b.color Ansi.grey second)
  out.putStrLn (style b.color Ansi.grey rule)
  out.flush
  b.drawn.set true

/-- Update fields and redraw. -/
def StatusBar.update (b : StatusBar) (f : StatusModel → StatusModel) : IO Unit := do
  b.model.modify f
  b.draw

/-- Print a transcript line above the block: erase, print, redraw. -/
def StatusBar.println (b : StatusBar) (s : String) : IO Unit := do
  if !b.enabled then
    (← IO.getStdout).putStrLn s
    return
  b.erase
  let out ← IO.getStdout
  out.putStrLn s
  b.draw

/-- Write without a newline, for streamed model text.

    The block is erased for the duration of the stream and redrawn when the
    paragraph closes; redrawing it after every token would flicker and would
    cost a full block repaint per delta. -/
def StatusBar.print (b : StatusBar) (s : String) : IO Unit := do
  if b.enabled then b.erase
  let out ← IO.getStdout
  out.putStr s
  out.flush

def mkStatusBar (enabled color : Bool) (initial : StatusModel) : IO StatusBar := do
  let model ← IO.mkRef initial
  let drawn ← IO.mkRef false
  return { model := model, drawn := drawn, enabled := enabled, color := color }

end LeanPrime
