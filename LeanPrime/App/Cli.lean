/-
  LeanPrime.App.Cli

  Command line parsing.  Flags are the highest-precedence configuration
  layer, applied after defaults, the config file and the environment.
-/
import LeanPrime.Config.Loader
import LeanPrime.Util.Errors
import LeanPrime.Model.Catalog

namespace LeanPrime

/-- What the process was asked to do. -/
inductive Command where
  | run (task : Option String)
  | doctor
  | listSessions
  | resume (id : String)
  | listModels
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
  /-- `--system-prompt <file>`: which copy of `SystemPrompt.lean` to load. -/
  systemPromptFile : Option System.FilePath := none
  /-- `--data-fencing`: mark external material as data rather than instruction. -/
  dataFencing  : Option Bool := none
  /-- `--unrestricted` / `--governed`: what governs the agent's actions. -/
  execution    : Option ExecutionMode := none
  /-- `--show-prompt`: print the system prompt in force and exit. -/
  showPrompt   : Bool := false
  /-- `--review` / `--no-review`: adversarial review of turn-ending replies. -/
  review       : Option Bool := none
  /-- `--no-custody`: skip the prompt-custody checkpoints. -/
  custody      : Option Bool := none
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
  , "SYSTEM PROMPT"
  , "  The entire system prompt is SystemPrompt.lean. There is no other source:"
  , "  nothing is prepended, appended or merged in from anywhere in the code."
  , ""
  , "  --system-prompt <file>       load this SystemPrompt.lean instead"
  , "  --show-prompt                print the prompt in force, and its rules, then exit"
  , "  --review                     have a second model call rule on every turn-ending"
  , "                               reply against the prompt's rules (one extra call each)"
  , "  --no-review                  turn that off"
  , "  --no-custody                 skip the prompt-custody checkpoints"
  , ""
  , "EXECUTION"
  , "  --governed                   the permission engine decides (default)"
  , "  --unrestricted               nothing vetoes the prompt: no approval prompts,"
  , "                               no deny list, no workspace containment"
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
  , "  --list-models           list the models available on the router"
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
      | "--list-models" => .ok { opts with command := .listModels }
      | "--json" => go more { opts with output := some .json } positional
      | "--plain" => go more { opts with output := some .plain, noColor := true } positional
      | "--no-color" => go more { opts with noColor := true } positional
      | "--data-fencing" => go more { opts with dataFencing := some true } positional
      | "--no-data-fencing" => go more { opts with dataFencing := some false } positional
      | "--show-prompt" => go more { opts with showPrompt := true } positional
      | "--review" => go more { opts with review := some true } positional
      | "--no-review" => go more { opts with review := some false } positional
      | "--no-custody" => go more { opts with custody := some false } positional
      | "--unrestricted" => go more { opts with execution := some .unrestricted } positional
      | "--governed" => go more { opts with execution := some .governed } positional
      | "--system-prompt" => needValue "--system-prompt" fun v o =>
          .ok { o with systemPromptFile := some (System.FilePath.mk v) }
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
  -- `--model` accepts a catalog alias or a unique prefix; anything else is
  -- passed to the router as written.
  let cfg := match o.model with
    | some m => { cfg with provider := { cfg.provider with model := resolveModel m } }
    | none => cfg
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
  let cfg := match o.execution with
    | some m => { cfg with execution := m } | none => cfg
  let cfg := match o.systemPromptFile with
    | some f => { cfg with prompt := { cfg.prompt with file := some f } } | none => cfg
  let cfg := match o.review with
    | some b => { cfg with prompt := { cfg.prompt with adversarialReview := b } }
    | none => cfg
  let cfg := match o.custody with
    | some b => { cfg with prompt := { cfg.prompt with vaultCustody := b } }
    | none => cfg
  cfg

end LeanPrime
