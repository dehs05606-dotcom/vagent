/-
  LeanPrime.Model.Http

  The only place in LeanPrime that performs network I/O.

  Why an external binary:
    Lean 4 ships no HTTP client and no TLS stack.  The alternatives are an
    FFI binding to libcurl (a native dependency plus an `extern` surface that
    would have to be audited and built per platform) or driving the `curl`
    executable.  We drive the executable, behind the `HttpClient` interface
    below, so that:
      * the rest of the agent never sees a transport detail;
      * a future in-process client can be dropped in by providing another
        `HttpClient` without touching the model layer;
      * `--doctor` can check for the dependency and report it.

  Credential handling:
    Secret headers are NEVER passed as process arguments, because arguments
    are world-readable via /proc and `ps`.  They are written into a curl
    config file created inside a 0700 temporary directory with 0600
    permissions, and the directory is removed when the request completes.
-/
import LeanPrime.Util.Prelude
import LeanPrime.Util.Errors
import LeanPrime.Util.Platform

namespace LeanPrime

/-- An outbound HTTP request. -/
structure HttpRequest where
  url        : String
  method     : String := "POST"
  /-- Headers safe to log. -/
  headers    : List (String × String) := []
  /-- Headers carrying credentials.  Never logged, never in argv. -/
  secretHeaders : List (String × String) := []
  body       : Option String := none
  timeoutSec : Nat := 120
  connectTimeoutSec : Nat := 20
  deriving Inhabited

structure HttpResponse where
  status : Nat
  body   : String
  deriving Inhabited, Repr

/-- `2xx` -/
def HttpResponse.ok (r : HttpResponse) : Bool := r.status >= 200 && r.status < 300

/-- Retryable transport / server conditions. -/
def HttpResponse.retryable (r : HttpResponse) : Bool :=
  r.status == 408 || r.status == 429 || (r.status >= 500 && r.status < 600) || r.status == 0

/-- Escape a value for a curl config file (`name = "value"`). -/
private def curlEscape (s : String) : String :=
  s.replace "\\" "\\\\" |>.replace "\"" "\\\""

/-- Render a curl config file body for a request. -/
private def curlConfig (req : HttpRequest) (bodyFile : Option System.FilePath)
    (extraOpts : List String) : String :=
  let lines :=
    [ s!"url = \"{curlEscape req.url}\""
    , s!"request = \"{curlEscape req.method}\""
    , s!"max-time = {req.timeoutSec}"
    , s!"connect-timeout = {req.connectTimeoutSec}"
    , "silent"
    , "show-error"
    , "location"
    ]
    ++ (req.headers.map fun (k, v) => s!"header = \"{curlEscape k}: {curlEscape v}\"")
    ++ (req.secretHeaders.map fun (k, v) => s!"header = \"{curlEscape k}: {curlEscape v}\"")
    ++ (match bodyFile with
        | some f => [s!"data-binary = \"@{curlEscape f.toString}\""]
        | none => [])
    ++ extraOpts
  String.intercalate "\n" lines ++ "\n"

/-- Abstract transport so the model layer never names `curl`. -/
structure HttpClient where
  /-- Perform a request and return the complete response. -/
  request : HttpRequest → IO (LPResult HttpResponse)
  /-- Perform a request, invoking `onLine` for each response line as it
      arrives.  Returns the final status and the accumulated body. -/
  stream  : HttpRequest → (String → IO Unit) → IO (LPResult HttpResponse)

namespace Curl

/-- Write the request's body and config into `dir`, returning the config path. -/
private def materialize (dir : System.FilePath) (req : HttpRequest)
    (extraOpts : List String) : IO System.FilePath := do
  let bodyFile ← match req.body with
    | none => pure none
    | some b =>
      let f := dir / "body"
      IO.FS.writeFile f b
      IO.setAccessRights f { user := { read := true, write := true } }
      pure (some f)
  let cfg := dir / "curl.cfg"
  IO.FS.writeFile cfg (curlConfig req bodyFile extraOpts)
  -- 0600: the config file holds the Authorization header.
  IO.setAccessRights cfg { user := { read := true, write := true } }
  return cfg

/-- Non-streaming request. -/
def request (req : HttpRequest) : IO (LPResult HttpResponse) := do
  try
    IO.FS.withTempDir fun dir => do
      let outFile := dir / "out"
      let cfg ← materialize dir req
        [ s!"output = \"{curlEscape outFile.toString}\""
        , "write-out = \"%{http_code}\"" ]
      let res ← IO.Process.output { cmd := "curl", args := #["--config", cfg.toString] }
      if res.exitCode != 0 && (trim res.stdout).isEmpty then
        return .error (err .network "HTTP request failed"
          (some (trim res.stderr)) (some "check network access and the base_url"))
      let status := (trim res.stdout).toNat?.getD 0
      let body ← if ← outFile.pathExists then IO.FS.readFile outFile else pure ""
      return .ok { status := status, body := body }
  catch e =>
    return .error (err .network "HTTP transport error" (some (toString e))
      (some "is `curl` installed and on PATH?"))

/-- Recover the HTTP status code from a curl `--dump-header` file.
    Follows redirects by taking the last status line present. -/
private def statusFromHeaders (f : System.FilePath) : IO Nat := do
  if !(← f.pathExists) then return 0
  let txt ← try IO.FS.readFile f catch _ => pure ""
  let codes := (txt.splitOn "\n").filterMap fun line =>
    let l := trim line
    if l.startsWith "HTTP/" then
      match (l.splitOn " ") with
      | _ :: code :: _ => code.toNat?
      | _ => none
    else none
  return codes.getLast?.getD 0

/-- Streaming request.  `onLine` receives each line of the response body as
    soon as curl flushes it, which for an SSE endpoint is per event. -/
def stream (req : HttpRequest) (onLine : String → IO Unit)
    : IO (LPResult HttpResponse) := do
  try
    IO.FS.withTempDir fun dir => do
      let headerFile := dir / "headers"
      let cfg ← materialize dir req
        ["no-buffer", s!"dump-header = \"{curlEscape headerFile.toString}\""]
      let child ← IO.Process.spawn {
        cmd := "curl", args := #["--config", cfg.toString],
        stdout := .piped, stderr := .piped, stdin := .null }
      let mut acc := ""
      repeat
        let line ← child.stdout.getLine
        if line.isEmpty then break
        acc := acc ++ line
        onLine (line.trimAsciiEnd.toString)
      let code ← child.wait
      if code != 0 && acc.isEmpty then
        let e ← child.stderr.readToEnd
        return .error (err .network "streaming HTTP request failed" (some (trim e)))
      -- curl exits 0 even on HTTP errors, so read the real status from the
      -- dumped response headers rather than assuming success.
      let status ← statusFromHeaders headerFile
      return .ok { status := status, body := acc }
  catch e =>
    return .error (err .network "HTTP streaming transport error" (some (toString e)))

def client : HttpClient := { request := request, stream := stream }

end Curl

/-- Exponential backoff retry around any `HttpClient`. -/
def httpWithRetry (c : HttpClient) (req : HttpRequest) (maxRetries : Nat)
    : IO (LPResult HttpResponse) := do
  let mut attempt := 0
  let mut last : LPResult HttpResponse :=
    .error (err .network "no attempt made")
  repeat
    last ← c.request req
    match last with
    | .ok r => if !r.retryable then return .ok r
    | .error _ => pure ()
    if attempt >= maxRetries then break
    -- 500ms, 1s, 2s, 4s …
    IO.sleep (UInt32.ofNat (500 * 2 ^ attempt))
    attempt := attempt + 1
  return last

end LeanPrime
