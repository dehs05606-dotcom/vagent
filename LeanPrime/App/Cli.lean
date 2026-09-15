/-
  LeanPrime.App.Cli

  Command line parsing.  Flags are the highest-precedence configuration
  layer, applied after defaults, the config file and the environment.
-/
import LeanPrime.Config.Loader
import LeanPrime.Util.Errors

namespace LeanPrime

/-- What the process was asked to do. -/
inductive Command where
  | run (task : Option String)
  | doctor
  | listSessions
  | resume (id : String)
  | version
  | help
  deriving Repr, Inhabited

structure CliOptions where
  command      : Command := .run none
  configPath   : Option System.FilePath := none
  model        : Option String := none
  baseUrl      : Option String := none
  approval     : Option ApprovalMode := none
  output       : Option OutputMode := none
  workspace    : Option System.FilePath := none
  logLevel     : Option LogLevel := none
  maxIterations : Option Nat := none
  noColor      : Bool := false
  quiet        : Bool := false
  /-- `--system-prompt <file>`: a file whose contents become the system prompt. -/
  systemPromptFile : Option System.FilePath := none
  /-- `--system-prompt-text <text>`: an inline system prompt. -/
  systemPromptText : Option String := none
  /-- `--append-system-prompt <text>`: extra instructions after the rest. -/
  appendSystemPrompt : Option String := none
  promptMode   : Option PromptMode := none
  /-- `--no-project-prompt`: ignore LEANPRIME.md / AGENTS.md / CLAUDE.md. -/
  noProjectPrompt : Bool := false
  /-- `--data-fencing`: mark external material as data rather than instruction. -/
  dataFencing  : Option Bool := none
  /-- `--show-prompt`: print the assembled system prompt and exit. -/
  showPrompt   : Bool := false
  deriving Inhabited

def usage : String :=
  String.intercalate "\n"
  [ "lean-prime — an autonomous terminal coding agent written in Lean 4"
  , ""
  , "USAGE"
  , "  lean-prime [options] [task]"
  , ""
  , "EXAMPLES"
  , "  lean-prime \"fix the failing authentication tests\""
  , "  lean-prime \"explain this repository's architecture\" --approval read-only"
  , "  lean-prime --json \"run the tests and report the result\""
  , "  lean-prime --doctor"
  , ""
  , "OPTIONS"
  , "  --model <name>          model to use"
  , "  --base-url <url>        provider base URL (OpenAI-compatible)"
  , "  --config <path>         configuration file (default: ~/.config/lean-prime/config.toml)"
  , "  --workspace <path>      workspace root (default: current directory)"
  , "  --approval <mode>       auto | ask | read-only | yolo"
  , ""
  , "SYSTEM PROMPT  (your instructions outrank the built-in ones)"
  , "  --system-prompt <file>       use this file as the system prompt"
  , "  --system-prompt-text <text>  use this text as the system prompt"
  , "  --append-system-prompt <t>   add instructions after everything else"
  , "  --prompt-mode <mode>         replace | prepend | append  (default: prepend)"
  , "                               replace = your text IS the system prompt"
  , "  --no-project-prompt          ignore LEANPRIME.md / AGENTS.md / CLAUDE.md"
  , "  --show-prompt                print the assembled prompt and exit"
  , "  --data-fencing               mark file and command output as data, not instruction"
  , ""
  , "  --json                  emit one JSON event per line instead of a transcript"
  , "  --plain                 transcript without colour or styling"
  , "  --max-iterations <n>    cap the agent loop"
  , "  --log-level <level>     trace | debug | info | warn | error"
  , "  --no-color              disable colour"
  , "  --quiet                 suppress the transcript; errors still go to stderr"
  , "  --resume <session>      continue a stored session"
  , "  --sessions              list stored sessions"
  , "  --doctor                check the environment and configuration"
  , "  --version               print the version"
  , "  -h, --help              this message"
  , ""
  , "ENVIRONMENT"
  , "  LEANPRIME_API_KEY       API key (also accepts OPENAI_API_KEY)"
  , "  LEANPRIME_BASE_URL      overrides the provider base URL"
  , "  LEANPRIME_MODEL         overrides the model"
  , "  LEANPRIME_APPROVAL      overrides the approval mode"
  , "  NO_COLOR                disables colour"
  ]

def versionString : String := "lean-prime 0.1.0 (Lean 4.34.0)"

/-- Parse arguments.  Unknown flags are an error rather than being ignored,
    so a typo never silently changes behaviour. -/
partial def parseArgs (args : List String) : LPResult CliOptions :=
  go args {} []
where
  go (rest : List String) (opts : CliOptions) (positional : List String)
      : LPResult CliOptions :=
    match rest with
    | [] =>
      match opts.command with
      | .run none =>
        if positional.isEmpty then .ok opts
        else .ok { opts with command := .run (some (String.intercalate " " positional.reverse)) }
      | _ => .ok opts
    | a :: more =>
      let needValue (flag : String) (k : String → CliOptions → LPResult CliOptions)
          : LPResult CliOptions :=
        match more with
        | v :: rest' => match k v opts with
          | .ok o => go rest' o positional
          | .error e => .error e
        | [] => .error (err .configuration s!"{flag} requires a value")
      match a with
      | "-h" | "--help" => .ok { opts with command := .help }
      | "--version" => .ok { opts with command := .version }
      | "--doctor" => go more { opts with command := .doctor } positional
      | "--sessions" => go more { opts with command := .listSessions } positional
      | "--json" => go more { opts with output := some .json } positional
      | "--plain" => go more { opts with output := some .plain, noColor := true } positional
      | "--no-color" => go more { opts with noColor := true } positional
      | "--no-project-prompt" => go more { opts with noProjectPrompt := true } positional
      | "--data-fencing" => go more { opts with dataFencing := some true } positional
      | "--no-data-fencing" => go more { opts with dataFencing := some false } positional
      | "--show-prompt" => go more { opts with showPrompt := true } positional
      | "--system-prompt" => needValue "--system-prompt" fun v o =>
          .ok { o with systemPromptFile := some (System.FilePath.mk v) }
      | "--system-prompt-text" => needValue "--system-prompt-text" fun v o =>
          .ok { o with systemPromptText := some v }
      | "--append-system-prompt" => needValue "--append-system-prompt" fun v o =>
          .ok { o with appendSystemPrompt := some v }
      | "--prompt-mode" => needValue "--prompt-mode" fun v o =>
          match PromptMode.ofString? v with
          | some m => .ok { o with promptMode := some m }
          | none => .error (err .configuration s!"unknown prompt mode: {v}"
              none (some "expected replace, prepend or append"))
      | "--quiet" => go more { opts with quiet := true } positional
      | "--resume" => needValue "--resume" fun v o =>
          .ok { o with command := .resume v }
      | "--model" => needValue "--model" fun v o => .ok { o with model := some v }
      | "--base-url" => needValue "--base-url" fun v o => .ok { o with baseUrl := some v }
      | "--config" => needValue "--config" fun v o =>
          .ok { o with configPath := some (System.FilePath.mk v) }
      | "--workspace" => needValue "--workspace" fun v o =>
          .ok { o with workspace := some (System.FilePath.mk v) }
      | "--approval" => needValue "--approval" fun v o =>
          match ApprovalMode.ofString? v with
          | some m => .ok { o with approval := some m }
          | none => .error (err .configuration s!"unknown approval mode: {v}"
              none (some "expected auto, ask, read-only or yolo"))
      | "--log-level" => needValue "--log-level" fun v o =>
          match LogLevel.ofString? v with
          | some l => .ok { o with logLevel := some l }
          | none => .error (err .configuration s!"unknown log level: {v}")
      | "--max-iterations" => needValue "--max-iterations" fun v o =>
          match v.toNat? with
          | some n => .ok { o with maxIterations := some n }
          | none => .error (err .configuration s!"--max-iterations expects a number, got {v}")
      | other =>
        if other.startsWith "-" && other.length > 1 then
          .error (err .configuration s!"unknown option: {other}"
            none (some "run `lean-prime --help` for the list of options"))
        else go more opts (other :: positional)

/-- Apply flags on top of a config already built from file and environment. -/
def applyCli (cfg : Config) (o : CliOptions) : Config :=
  let cfg := match o.model with
    | some m => { cfg with provider := { cfg.provider with model := m } } | none => cfg
  let cfg := match o.baseUrl with
    | some u => { cfg with provider := { cfg.provider with baseUrl := u } } | none => cfg
  let cfg := match o.approval with | some m => { cfg with approval := m } | none => cfg
  let cfg := match o.output with | some m => { cfg with output := m } | none => cfg
  let cfg := match o.logLevel with
    | some l => { cfg with logging := { cfg.logging with level := l } } | none => cfg
  let cfg := match o.maxIterations with
    | some n => { cfg with budget := { cfg.budget with maxIterations := n } } | none => cfg
  let cfg := if o.noColor then { cfg with ui := { cfg.ui with color := false } } else cfg
  let cfg := match o.dataFencing with
    | some b => { cfg with dataFencing := b } | none => cfg
  let cfg := match o.promptMode with
    | some m => { cfg with prompt := { cfg.prompt with mode := m } } | none => cfg
  let cfg := if o.noProjectPrompt
    then { cfg with prompt := { cfg.prompt with projectFiles := [] } } else cfg
  cfg

end LeanPrime
