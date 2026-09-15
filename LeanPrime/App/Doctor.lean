/-
  LeanPrime.App.Doctor

  Environment diagnostics.

  Reports whether the API key is *present*, never what it is.  Every check
  says what to do when it fails, because a diagnostic that only says "no" is
  not a diagnostic.
-/
import LeanPrime.Config.Loader
import LeanPrime.Tools.Process
import LeanPrime.Model.Http
import LeanPrime.TUI.Ansi

namespace LeanPrime

open LeanPrime.Ansi

inductive CheckStatus where
  | pass | warn | fail
  deriving Repr, DecidableEq, Inhabited

structure DoctorCheck where
  name   : String
  status : CheckStatus
  detail : String
  remedy : String := ""
  deriving Inhabited

private def ok (n d : String) : DoctorCheck := { name := n, status := .pass, detail := d }
private def warn (n d r : String) : DoctorCheck :=
  { name := n, status := .warn, detail := d, remedy := r }
private def fail (n d r : String) : DoctorCheck :=
  { name := n, status := .fail, detail := d, remedy := r }

/-- Run every environment check. -/
def runChecks (cfg : Config) (cfgPath : Option System.FilePath) : IO (List DoctorCheck) := do
  let mut checks : List DoctorCheck := []

  checks := checks ++ [ok "platform" s!"{detectPlatform}"]

  -- Lean toolchain: the agent works on Lean projects, and builds its own.
  if ← hasExecutable "lean" then
    match ← runProcess "lean" #["--version"] (← IO.currentDir) 20 with
    | .ok r => checks := checks ++ [ok "lean" (trim r.stdout)]
    | .error _ => checks := checks ++ [warn "lean" "present but did not respond" "reinstall with elan"]
  else
    checks := checks ++ [warn "lean" "not on PATH"
      "install with: curl https://elan.lean-lang.org/elan-init.sh -sSf | sh"]

  if ← hasExecutable "lake" then
    checks := checks ++ [ok "lake" "available"]
  else
    checks := checks ++ [warn "lake" "not on PATH" "ships with the Lean toolchain via elan"]

  -- curl is the HTTP transport.
  if ← hasExecutable "curl" then
    checks := checks ++ [ok "curl" "available (HTTP transport)"]
  else
    checks := checks ++ [fail "curl" "not on PATH"
      "lean-prime uses curl for HTTPS; install it with your package manager"]

  if ← hasExecutable "git" then
    checks := checks ++ [ok "git" "available"]
  else
    checks := checks ++ [warn "git" "not on PATH" "git tools and diff review will be unavailable"]

  -- configuration
  match cfgPath with
  | some p => checks := checks ++ [ok "config" s!"loaded from {p}"]
  | none => checks := checks ++ [warn "config" "using built-in defaults"
      s!"write one at {← defaultConfigPath} to change the model or approval mode"]

  checks := checks ++ [ok "provider" s!"{cfg.provider.kind} at {cfg.provider.baseUrl}"]
  checks := checks ++ [ok "model" cfg.provider.model]
  checks := checks ++ [ok "approval mode" cfg.approval.toString]

  -- credentials: presence only
  match ← readApiKey cfg with
  | some k =>
    checks := checks ++
      [ok "api key" s!"present in the environment ({k.length} characters, value not shown)"]
  | none =>
    checks := checks ++ [fail "api key" s!"{cfg.provider.apiKeyEnv} is not set"
      s!"export {cfg.provider.apiKeyEnv}=… (never commit it to the repository)"]

  -- workspace
  if ← cfg.workspace.pathExists then
    let probe := cfg.workspace / ".lean-prime-write-probe"
    let writable ← try
        IO.FS.writeFile probe ""
        IO.FS.removeFile probe
        pure true
      catch _ => pure false
    if writable then
      checks := checks ++ [ok "workspace" s!"{cfg.workspace} (writable)"]
    else
      checks := checks ++ [warn "workspace" s!"{cfg.workspace} is not writable"
        "the agent will be able to read but not modify this directory"]
  else
    checks := checks ++ [fail "workspace" s!"{cfg.workspace} does not exist" "pass --workspace"]

  -- connectivity, only when a key exists
  if (← readApiKey cfg).isSome then
    let url := (if cfg.provider.baseUrl.endsWith "/"
                then (cfg.provider.baseUrl.dropEnd 1).toString
                else cfg.provider.baseUrl) ++ "/models"
    let key := (← readApiKey cfg).getD ""
    let req : HttpRequest := {
      url := url, method := "GET",
      secretHeaders := [("Authorization", s!"Bearer {key}")],
      body := none, timeoutSec := 25, connectTimeoutSec := 10 }
    match ← Curl.request req with
    | .error e => checks := checks ++ [fail "connectivity" e.message
        "check network access, proxy settings and the base URL"]
    | .ok resp =>
      if resp.ok then
        checks := checks ++ [ok "connectivity" s!"provider reachable (HTTP {resp.status})"]
      else if resp.status == 401 || resp.status == 403 then
        checks := checks ++ [fail "connectivity" s!"provider rejected the credentials (HTTP {resp.status})"
          "check that the API key is valid for this base URL"]
      else
        checks := checks ++ [warn "connectivity" s!"provider answered HTTP {resp.status}"
          "the endpoint is reachable but did not accept the request"]

  return checks

/-- Print the report.  Returns the process exit code. -/
def report (checks : List DoctorCheck) (color : Bool) : IO UInt32 := do
  let out ← IO.getStdout
  out.putStrLn (style color bold "lean-prime --doctor")
  out.putStrLn ""
  for c in checks do
    let mark := match c.status with
      | .pass => style color green "✓"
      | .warn => style color yellow "!"
      | .fail => style color red "✗"
    out.putStrLn s!"  {mark} {padRight c.name 14} {c.detail}"
    if c.status != .pass && !c.remedy.isEmpty then
      out.putStrLn (style color grey s!"                   → {c.remedy}")
  out.putStrLn ""
  let failures := checks.filter (fun c => c.status == .fail)
  let warnings := checks.filter (fun c => c.status == .warn)
  if failures.isEmpty then
    out.putStrLn (style color green s!"ready · {warnings.length} warning(s)")
    return 0
  else
    out.putStrLn (style color red s!"{failures.length} problem(s) must be fixed before running")
    return 1

end LeanPrime
