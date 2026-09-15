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
  out.putStrLn (Ansi.style color Ansi.bold "lean-prime")
  out.putStrLn (Ansi.style color Ansi.grey
    "describe the task, or press enter to exit")
  out.putStr "› "
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
  let events ← buildSink cfg opts interactive
  let env ← buildRunEnv cfg apiKey events interactive
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
    | _ =>
    match ← buildConfig opts with
    | .error e =>
      (← IO.getStderr).putStrLn (LPError.render e)
      return 2
    | .ok (cfg, cfgPath) =>
      let color := cfg.ui.color && (← (← IO.getStdout).isTty)
      match opts.command with
      | .help | .version => return 0     -- handled above
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
