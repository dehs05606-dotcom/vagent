/-
  LeanPrime.TUI.Banner

  The opening screen.

  Shown once, at the top of an interactive run, above the transcript.  It
  answers the questions you have before the agent does anything:

      what is this            the wordmark and version
      what model              the right of the status line
      what will it do on its own    the left of the status line
      what is it running under      the prompt source and rule counts
      what is the task        the framed line

  Everything in it is a fact read from the resolved configuration.  Nothing
  is decorative-but-wrong: if the prompt has no enforced rules the banner
  says so, because a banner that implies more enforcement than exists is
  the worst place to be reassuring.

  Not drawn when stdout is not a TTY, under `--plain`, `--json` or
  `--quiet`, so piped output stays byte-clean.
-/
import LeanPrime.TUI.Ansi
import LeanPrime.Model.Catalog
import LeanPrime.Config.Schema

namespace LeanPrime

open LeanPrime.Ansi

/-! ### The wordmark

    Five rows of block characters.  `█` is one column wide in every terminal
    font that has it, so the rows line up and `String.length` measures the
    drawn width correctly for centring. -/

def wordmarkWide : List String :=
  [ "█     █████  ███  █   █   ████  ████  █████ █   █ █████"
  , "█     █     █   █ ██  █   █   █ █   █   █   ██ ██ █    "
  , "█     ████  █████ █ █ █   ████  ████    █   █ █ █ ████ "
  , "█     █     █   █ █  ██   █     █  █    █   █   █ █    "
  , "█████ █████ █   █ █   █   █     █   █ █████ █   █ █████" ]

/-- A narrow terminal gets the name rather than a wordmark that wraps. -/
def wordmarkNarrow : List String := ["L E A N   P R I M E"]

def wordmarkFor (width : Nat) : List String :=
  if width >= 60 then wordmarkWide else wordmarkNarrow

/-- Centre a line in `width` columns. -/
def center (width : Nat) (s : String) : String :=
  if s.length >= width then s
  else String.ofList (List.replicate ((width - s.length) / 2) ' ') ++ s

/-! ### What the banner needs to know -/

structure BannerInfo where
  version      : String
  model        : String
  /-- Approval mode, rendered as the autonomy statement. -/
  approval     : ApprovalMode
  /-- `governed` or `unrestricted`. -/
  execution    : ExecutionMode
  toolCount    : Nat
  directives   : Nat
  /-- Rules enforced on the reply text. -/
  textRules    : Nat
  /-- Rules enforced on behaviour, and how many block a call outright. -/
  behaviorRules : Nat
  blockingRules : Nat
  /-- Short form of where the prompt came from. -/
  promptOrigin : String
  /-- Whether a config file was found, and where. -/
  configPath   : Option String
  deriving Inhabited

/-- The autonomy statement: what the agent will do without being asked.

    Phrased as consequence rather than mode name, because "auto" tells a
    new user nothing and "all actions require approval" tells them
    everything. -/
def BannerInfo.autonomyLine (b : BannerInfo) : String :=
  match b.execution, b.approval with
  | .unrestricted, _ => "Unrestricted · nothing vetoes the prompt"
  | .governed, .readOnly => "Read-only · no action will change anything"
  | .governed, .ask => "Ask · every side effect needs approval"
  | .governed, .auto => "Auto · safe actions run, the rest ask"
  | .governed, .yolo => "Yolo · everything runs except the deny list"

/-- A tick when a capability is present, a cross when it is not. -/
private def mark (c : Bool) (on : Bool) : String :=
  if on then style c green "✓" else style c red "✗"

/-- The capability row: what is loaded and what is enforcing. -/
def BannerInfo.capabilityLine (b : BannerInfo) (c : Bool) : String :=
  let tools := s!"Tools ({b.toolCount}) " ++ mark c (b.toolCount > 0)
  let rules := s!"Rules ({b.directives}) " ++ mark c (b.directives > 0)
  let enforced :=
    s!"Enforced ({b.textRules + b.behaviorRules}) " ++
      mark c (b.textRules + b.behaviorRules > 0)
  let gate :=
    s!"Gate ({b.blockingRules}) " ++ mark c (b.blockingRules > 0)
  String.intercalate "  " [tools, rules, enforced, gate]

/-- The same row for a narrow terminal: counts only, no labels. -/
def BannerInfo.capabilityLineCompact (b : BannerInfo) (c : Bool) : String :=
  String.intercalate " "
    [ s!"T{b.toolCount}", mark c (b.toolCount > 0)
    , s!"R{b.directives}", mark c (b.directives > 0)
    , s!"E{b.textRules + b.behaviorRules}", mark c (b.textRules + b.behaviorRules > 0)
    , s!"G{b.blockingRules}", mark c (b.blockingRules > 0) ]

/-- Visible length, ignoring ANSI escapes, so a coloured line still centres.
    Counts everything outside `ESC … m` runs. -/
def visibleLength (s : String) : Nat := Id.run do
  let mut n := 0
  let mut inEscape := false
  for ch in s.toList do
    if inEscape then
      if ch == 'm' then inEscape := false
    else if ch == '\x1b' then inEscape := true
    else n := n + 1
  return n

/-- The longest of these that fits in `width`, falling back to the last one
    truncated.  Choosing a shorter phrasing beats truncating a longer one:
    a hint cut off mid-flag is worse than a terser hint. -/
def fitText (width : Nat) (options : List String) : String :=
  match options.find? (fun s => s.length <= width) with
  | some s => s
  | none => match options.getLast? with
    | some s => truncate s width
    | none => ""

/-- Centre a line that may contain colour codes. -/
def centerStyled (width : Nat) (s : String) : String :=
  let vis := visibleLength s
  if vis >= width then s
  else String.ofList (List.replicate ((width - vis) / 2) ' ') ++ s

/-! ### The framed task line

    The box in the reference design is an input prompt.  This agent takes
    its task on the command line rather than at a prompt, so the box shows
    the task it is about to run — same position, same weight, and it is the
    thing you most want to re-read before the agent starts moving. -/

def taskBox (width : Nat) (c : Bool) (task : String) : List String :=
  let inner := if width > 6 then width - 4 else width
  let body := truncate (trim task) (if inner > 4 then inner - 4 else inner)
  let bar := String.ofList (List.replicate (inner + 2) '─')
  [ style c grey ("╭" ++ bar ++ "╮")
  , style c grey "│ " ++ style c cyan "› " ++ style c bold (padRight body (if inner > 2 then inner - 2 else inner)) ++ style c grey " │"
  , style c grey ("╰" ++ bar ++ "╯") ]

/-! ### Assembly -/

/-- The full opening screen, as lines ready to print. -/
def renderBanner (b : BannerInfo) (width : Nat) (c : Bool) (task : String)
    : List String :=
  let w := width
  let art := (wordmarkFor w).map fun row =>
    centerStyled w (style c cyan row)
  let version := centerStyled w (style c grey s!"v{b.version}")
  -- Hint text is chosen to fit rather than truncated, because a hint cut
  -- off mid-flag is worse than a shorter hint.
  let tip := centerStyled w (style c grey (fitText w
    [ "TIP: run with --show-prompt to see every rule in force"
    , "TIP: --show-prompt lists every rule"
    , "--show-prompt" ]))
  let hints1 := centerStyled w (style c grey (fitText w
    [ "--unrestricted to remove the permission engine · --review for adversarial review"
    , "--unrestricted · --review"
    , "--review" ]))
  let hints2 := centerStyled w (style c grey (fitText w
    [ "--list-models to switch model · --json for a machine-readable stream"
    , "--list-models · --json"
    , "--json" ]))
  let capsText := b.capabilityLine c
  let caps :=
    if visibleLength capsText <= w then centerStyled w capsText
    else centerStyled w (b.capabilityLineCompact c)
  -- The status row: autonomy on the left, model on the right.  `left` is
  -- what gets truncated when they collide, because the model name is short
  -- and is the half you cannot reconstruct from context.
  let right := shortModelName b.model
  let left := truncate b.autonomyLine
    (if w > right.length + 3 then w - right.length - 3 else w)
  let gap :=
    if left.length + right.length < w then w - left.length - right.length else 1
  let statusRow :=
    style c bold left ++ String.ofList (List.replicate gap ' ') ++ style c magenta right
  let promptRow :=
    let ruleText :=
      if b.directives == 0 then "no rules extracted"
      else s!"{b.directives} rules · {b.textRules} on text · {b.behaviorRules} on behaviour"
    let cfg := match b.configPath with
      | some p => p
      | none => "no config file"
    let cfgFit := truncate cfg (w / 2)
    let l := truncate s!"{b.promptOrigin} · {ruleText}"
      (if w > cfgFit.length + 3 then w - cfgFit.length - 3 else w)
    let g := if l.length + cfgFit.length < w then w - l.length - cfgFit.length else 1
    style c grey l ++ String.ofList (List.replicate g ' ') ++ style c grey cfgFit
  [""] ++ art ++ [""] ++ [version, ""] ++ [tip, ""] ++ [hints1, hints2, ""]
    ++ [caps, ""] ++ [statusRow] ++ taskBox w c task ++ [promptRow, ""]

/-- Print it. -/
def printBanner (b : BannerInfo) (width : Nat) (c : Bool) (task : String) : IO Unit := do
  let out ← IO.getStdout
  for l in renderBanner b width c task do
    out.putStrLn l
  out.flush

end LeanPrime
