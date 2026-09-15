/-
  LeanPrime.App.Main

  Process lifecycle: parse, configure, dispatch, persist, exit.
-/
import LeanPrime.App.Bootstrap

namespace LeanPrime

/-- Read a task from stdin when none was given on the command line and the
    session is interactive. -/
private def promptForTask (color : Bool) : IO (Option String) := do
  let stdin ← IO.getStdin
  if !(← stdin.isTty) then return none
  let out ← IO.getStdout
  let width ← terminalWidth
  out.putStrLn ""
  for row in wordmarkFor width do
    out.putStrLn (centerStyled width (Ansi.style color Ansi.cyan row))
  out.putStrLn ""
  out.putStrLn (centerStyled width (Ansi.style color Ansi.grey s!"v{versionString}"))
  out.putStrLn ""
  out.putStrLn (centerStyled width (Ansi.style color Ansi.grey
    "describe the task, or press enter to exit"))
  out.putStrLn ""
  out.putStr (Ansi.style color Ansi.cyan "› ")
  out.flush
  let line ← stdin.getLine
  let t := trim line
  return if t.isEmpty then none else some t

/-- Execute one task and persist the session. -/
private def executeTask (cfg : Config) (opts : CliOptions) (task : String)
    (priorTurns : List Message) : IO UInt32 := do
  let some apiKey ← readApiKey cfg
    | let errOut ← IO.getStderr
      errOut.putStrLn (LPError.render (err .configuration
        s!"no API key found in {cfg.provider.apiKeyEnv}"
        none (some s!"export {cfg.provider.apiKeyEnv}=… , or run `lean-prime --doctor`")))
      return 2
  let interactive ← (← IO.getStdin).isTty
  let registry := Registry.forMode cfg.approval
  let prompts ← match ← buildPrompts cfg registry task with
    | .error e => (← IO.getStderr).putStrLn (LPError.render e); return 2
    | .ok p => pure p
  -- The opening screen, before any event is emitted.  Interactive TUI only:
  -- `--plain`, `--json` and a redirected stdout must stay byte-clean.
  let stdoutTty ← (← IO.getStdout).isTty
  if cfg.output == .tui && stdoutTty && !opts.quiet then
    let width ← terminalWidth
    printBanner (bannerInfoOf cfg registry prompts opts.configPath)
      width (cfg.ui.color && stdoutTty) task
  let events ← buildSink cfg opts interactive prompts
  let env ← buildRunEnv cfg apiKey events prompts interactive
  let env := if priorTurns.isEmpty then env
             else { env with pollSteer := pure [] }
  let outcome ← runAgent env task
  -- persist
  if cfg.persistSessions then
    let logger : Logger := { minLevel := cfg.logging.level, file := none, quiet := true }
    let id ← freshId "sess"
    saveSession (SessionRecord.ofState id task cfg.workspace.toString
      cfg.provider.model outcome.state outcome.summary) logger
  return match outcome.phase with
    | .completed => 0
    | .cancelled => 130
    | _ => 1

/-- Entry point. -/
def main (argv : List String) : IO UInt32 := do
  match parseArgs argv with
  | .error e =>
    (← IO.getStderr).putStrLn (LPError.render e)
    return 2
  | .ok opts =>
    match opts.command with
    | .help => IO.println usage; return 0
    | .version => IO.println versionString; return 0
    | .listModels => IO.println renderCatalog; return 0
    | _ =>
    match ← buildConfig opts with
    | .error e =>
      (← IO.getStderr).putStrLn (LPError.render e)
      return 2
    | .ok (cfg, cfgPath) =>
      let color := cfg.ui.color && (← (← IO.getStdout).isTty)
      match opts.command with
      | .help | .version => return 0     -- handled above
      | _ =>
      -- `--show-prompt` applies to any command: it answers "what instructions
      -- is this agent actually running under?", which is the first question
      -- when the agent is not behaving as told.
      if opts.showPrompt then
        let registry := Registry.forMode cfg.approval
        match ← buildPrompts cfg registry "(no task)" with
        | .error e => (← IO.getStderr).putStrLn (LPError.render e); return 2
        | .ok stack =>
          IO.println (Ansi.style color Ansi.bold "system prompt in force")
          IO.println (stack.describe)
          IO.println ""
          IO.println (Ansi.style color Ansi.bold "custody seal")
          IO.println ((PromptVault.seal stack.render).describe)
          if !stack.unknownVars.isEmpty then
            IO.println (Ansi.style color Ansi.yellow
              s!"\nwarning: the prompt uses {stack.unknownVars.length} unknown \
                 placeholder(s); they are left as written")
          if stack.directives.isEmpty then
            IO.println (Ansi.style color Ansi.grey "\nno directives extracted")
          else
            IO.println (Ansi.style color Ansi.bold
              s!"\n{stack.directives.length} directive(s)")
            IO.println (renderDirectives stack.directives)
            IO.println (Ansi.style color Ansi.bold
              s!"\n{stack.rules.length} of them are enforced on the reply text \
                 (a reply that breaks one is rejected)")
            IO.println stack.describeRules
            let report := compileReport stack.directives
            IO.println (Ansi.style color Ansi.bold
              s!"\n{report.rules.length} of them are enforced on behaviour \
                 ({report.blockingCount} block the call before it runs)")
            IO.println report.describe
          IO.println (Ansi.style color Ansi.bold "\n--- prompt as sent ---")
          IO.println stack.render
          return 0
      match opts.command with
      | .help | .version | .listModels => return 0
      | .doctor =>
        let checks ← runChecks cfg cfgPath
        report checks color
      | .listSessions =>
        let sessions ← listSessions
        if sessions.isEmpty then
          IO.println "no stored sessions"
        else
          for (id, task) in sessions do
            IO.println s!"  {padRight id 24} {truncate task 90}"
        return 0
      | .resume id =>
        match ← loadSession id with
        | .error e => (← IO.getStderr).putStrLn (LPError.render e); return 2
        | .ok rec =>
          IO.println s!"resuming session {rec.id}: {rec.task}"
          executeTask cfg opts rec.task rec.toMessages
      | .run task? =>
        let task ← match task? with
          | some t => pure (some t)
          | none => promptForTask color
        match task with
        | none => IO.println usage; return 0
        | some t => executeTask cfg opts t []

end LeanPrime
