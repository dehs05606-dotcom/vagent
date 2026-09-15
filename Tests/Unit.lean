/-
  Tests.Unit

  Unit tests for the pure layers: string utilities, the TOML parser, path
  containment, the permission engine, the diff, the plan parser, and the
  agent state machine.
-/
import Tests.Harness
import LeanPrime.Config.Toml
import LeanPrime.Config.Loader
import LeanPrime.Util.Paths
import LeanPrime.Util.Diff
import LeanPrime.Security.Permissions
import LeanPrime.Agent.State
import LeanPrime.Agent.Planner
import LeanPrime.Model.OpenAI
import LeanPrime.Agent.PromptLayers
import LeanPrime.Prompt.Compliance
import LeanPrime.Agent.Directives
import LeanPrime.Agent.Loop

open LeanPrime Tests

namespace Tests

def runUnit (r : Runner) : IO Unit := do
  section_ "util"
  checkEq r "trim" (trim "  x  ") "x"
  checkEq r "truncate under limit" (truncate "abc" 5) "abc"
  checkEq r "truncate over limit" (truncate "abcdef" 3) "abc…"
  checkEq r "containsSubstr positive" (containsSubstr "hello world" "lo wo") true
  checkEq r "containsSubstr negative" (containsSubstr "hello" "xyz") false
  checkEq r "containsSubstrI" (containsSubstrI "HeLLo" "hello") true
  checkEq r "takeBytes never splits a character" (takeBytes "héllo" 3) "hé"
  check r "clampLines keeps short input" (clampLines "a\nb\nc" 10 10 == "a\nb\nc")
  check r "clampLines elides the middle"
    (containsSubstr (clampLines "1\n2\n3\n4\n5\n6\n7\n8" 2 2) "lines omitted")

  section_ "secret redaction"
  check r "redacts an sk- key"
    (!containsSubstr (redact "key is sk-ABCDEF1234567890") "ABCDEF1234567890")
  check r "redaction leaves a marker"
    (containsSubstr (redact "key is sk-ABCDEF1234567890") "REDACTED")
  check r "redacts api_key assignment"
    (containsSubstr (redact "api_key = supersecretvalue") "REDACTED")
  check r "redacts an Authorization header"
    (!containsSubstr (redact "Authorization: Bearer abcdef123456") "abcdef123456")

  section_ "toml"
  let doc := Toml.parse "# comment\ntitle = \"x\"\n\n[provider]\nmodel = \"m\"\ntimeout_sec = 30\nstream = true\ntemp = 0.25\nlist = [\"a\", \"b\"]\n"
  match doc with
  | .error e => check r "toml parses" false; IO.println (toString e)
  | .ok d =>
    check r "toml parses" true
    checkEq r "toml top-level string" (d.getStr? "title") (some "x")
    checkEq r "toml table string" (d.getStr? "provider.model") (some "m")
    checkEq r "toml nat" (d.getNat? "provider.timeout_sec") (some 30)
    checkEq r "toml bool" (d.getBool? "provider.stream") (some true)
    check r "toml float" ((d.getFloat? "provider.temp").getD 0.0 > 0.24)
    checkEq r "toml string array" (d.getStrArray? "provider.list") (some ["a", "b"])
  check r "toml rejects a malformed line"
    (match Toml.parse "this is not toml" with | .error _ => true | .ok _ => false)
  check r "toml keeps a # inside a quoted string"
    (match Toml.parse "a = \"x # y\"" with
     | .ok d => d.getStr? "a" == some "x # y" | .error _ => false)
  check r "toml multi-line array"
    (match Toml.parse "denied = [\"a\",\n  \"b\",\n  \"c\"]\nnext = 1\n" with
     | .ok d => d.getStrArray? "denied" == some ["a", "b", "c"] && d.getNat? "next" == some 1
     | .error _ => false)
  check r "toml multi-line array with a comment inside"
    (match Toml.parse "x = [\"a\",  # note\n  \"b\"]\n" with
     | .ok d => d.getStrArray? "x" == some ["a", "b"] | .error _ => false)
  check r "toml table header after a multi-line array"
    (match Toml.parse "x = [\"a\",\n \"b\"]\n[t]\ny = 2\n" with
     | .ok d => d.getNat? "t.y" == some 2 | .error _ => false)
  check r "toml array of tables"
    (match Toml.parse "[[mcp]]\ncommand = \"a\"\n[[mcp]]\ncommand = \"b\"\n" with
     | .ok d => d.getStr? "mcp.1.command" == some "b" | .error _ => false)

  section_ "paths"
  let ws : Workspace := { root := System.FilePath.mk "/work/project" }
  check r "resolves a relative path"
    (match ws.resolve "src/a.lean" with | .ok _ => true | .error _ => false)
  checkEq r "normalises .. away"
    (normalizeSegments (pathSegments "../../etc/passwd")) ["etc", "passwd"]
  checkEq r "normalises embedded .."
    (normalizeSegments (pathSegments "a/b/../c")) ["a", "c"]
  check r "relative traversal cannot escape"
    (match ws.resolve "../../../etc/passwd" with
     | .ok p => containsSubstr p.toString "/work/project"
     | .error _ => true)
  check r "absolute path outside the workspace is refused"
    (match ws.resolve "/etc/passwd" with | .error _ => true | .ok _ => false)
  check r "absolute path inside the workspace is allowed"
    (match ws.resolve "/work/project/src/a" with | .ok _ => true | .error _ => false)
  check r "windows-style traversal is refused"
    (match ws.resolve "..\\..\\Windows\\System32" with
     | .ok p => containsSubstr p.toString "/work/project"
     | .error _ => true)

  section_ "command classification"
  checkEq r "command head strips a path" (commandHead "/usr/bin/rm -rf x") "rm"
  checkEq r "command head skips env assignment" (commandHead "FOO=1 ls -la") "ls"
  checkEq r "ls is low risk" (classifyHead "ls -la").risk Risk.low
  checkEq r "git status is low risk" (classifyHead "git status").risk Risk.low
  checkEq r "git push is high risk" (classifyHead "git push origin main").risk Risk.high
  checkEq r "lake build is medium risk" (classifyHead "lake build").risk Risk.medium
  checkEq r "curl is high risk" (classifyHead "curl http://x").risk Risk.high
  checkEq r "an unknown command is high risk" (classifyHead "frobnicate").risk Risk.high
  checkEq r "chaining escalates ls to high"
    (classifyCommand [] "ls && rm -rf ~").risk Risk.high
  checkEq r "a denied command is forbidden"
    (classifyCommand ["rm"] "rm -rf /").risk Risk.forbidden
  checkEq r "deny list matches through a path"
    (classifyCommand ["sudo"] "/usr/bin/sudo rm -rf /").risk Risk.forbidden

  section_ "permission decisions"
  let autoP : Policy := { mode := .auto, deniedCommands := defaultDeniedCommands,
                          sessionGrants := [], approvedCommands := [],
                          unrestricted := false }
  check r "auto allows a read"
    (autoP.decide (classifyCommand [] "ls")).isAllow
  check r "auto does not allow rm"
    (!(autoP.decide (classifyCommand [] "rm -rf build")).isAllow)
  check r "auto denies a deny-listed command"
    (autoP.decide (classifyCommand defaultDeniedCommands "sudo rm -rf /")).isDeny
  let roP : Policy := { autoP with mode := .readOnly }
  check r "read-only denies a write"
    (roP.decide { permissions := [.writeFs], risk := .medium, summary := "w" }).isDeny
  check r "read-only allows a read"
    (roP.decide { permissions := [.readFs], risk := .low, summary := "rd" }).isAllow
  let yoloP : Policy := { autoP with mode := .yolo }
  check r "yolo allows high risk"
    (yoloP.decide { permissions := [.writeFs], risk := .high, summary := "w" }).isAllow
  check r "yolo still refuses the deny list"
    (yoloP.decide (classifyCommand defaultDeniedCommands "sudo x")).isDeny

  section_ "diff"
  checkEq r "identical text has no diff" (diffText "f" "a\nb" "a\nb") none
  check r "a one-line change is detected"
    ((diffText "f" "a\nb\nc" "a\nX\nc").isSome)
  checkEq r "change counts" (changeCount "a\nb\nc" "a\nX\nc") (1, 1)
  check r "diff renders the changed lines"
    (match diffText "f" "a\nb" "a\nX" with
     | some d => containsSubstr d "-b" && containsSubstr d "+X"
     | none => false)

  section_ "plan parsing"
  check r "parses a numbered plan"
    ((parsePlan "goal" "1. read the file\n2. fix it\n3. test it").isSome)
  checkEq r "plan step count"
    (((parsePlan "goal" "1. a\n2. b\n3. c").map (fun p => p.steps.length))) (some 3)
  check r "a single number is not a plan"
    ((parsePlan "goal" "I will do 1. thing").isNone)
  check r "prose is not a plan"
    ((parsePlan "goal" "I will read the file and fix it.").isNone)

  section_ "agent state machine"
  checkEq r "idle starts" (AgentPhase.idle.step .start) (some AgentPhase.understanding)
  checkEq r "completed absorbs finish" (AgentPhase.completed.step .finish) none
  checkEq r "completed absorbs tool requests" (AgentPhase.completed.step .toolRequested) none
  checkEq r "failed absorbs everything" (AgentPhase.failed.step .start) none
  checkEq r "cancel is always accepted"
    (AgentPhase.executing.step .cancelRequested) (some AgentPhase.cancelling)
  checkEq r "verification failure goes to diagnosing"
    (AgentPhase.verifying.step .verificationFailed) (some AgentPhase.diagnosing)
  check r "verification failure never completes"
    (AgentPhase.verifying.step .verificationFailed != some AgentPhase.completed)
  checkEq r "budget exhaustion fails"
    (AgentPhase.executing.step .budgetExhausted) (some AgentPhase.failed)
  check r "an illegal transition is rejected"
    ((AgentPhase.idle.step .toolFinished).isNone)

  section_ "verification outcomes"
  checkEq r "no checks is inconclusive"
    (VerificationResult.ofChecks []).outcome VerificationOutcome.inconclusive
  checkEq r "a failing check fails the whole result"
    (VerificationResult.ofChecks
      [{ name := "a", outcome := .passed, detail := "" },
       { name := "b", outcome := .failed, detail := "" }]).outcome VerificationOutcome.failed
  checkEq r "only inconclusive checks stay inconclusive"
    (VerificationResult.ofChecks
      [{ name := "a", outcome := .inconclusive, detail := "" }]).outcome
      VerificationOutcome.inconclusive
  check r "success needs a passing verification"
    (!({ lastVerification := some (VerificationResult.ofChecks []) : AgentState }).mayReportSuccess)
  check r "success is allowed after a pass"
    (({ lastVerification := some (VerificationResult.ofChecks
        [{ name := "tests", outcome := .passed, detail := "" }]) : AgentState }).mayReportSuccess)
  check r "no verification means no success claim"
    (!({ : AgentState }).mayReportSuccess)

  section_ "directive extraction"
  let prompt := "# Rules\n\
    - Always run the tests before reporting.\n\
    - Never delete a file without asking.\n\
    - Prefer small commits.\n\
    This paragraph is explanation, not a rule.\n\
    You must include the ticket number.\n"
  let ds := extractDirectives prompt
  checkEq r "extracts every stated rule" ds.length 4
  check r "a heading is not a directive"
    (!ds.any (fun d => containsSubstr d.text "Rules"))
  check r "plain explanatory prose is not a directive"
    (!ds.any (fun d => containsSubstr d.text "explanation"))
  check r "\"never\" is classified as a prohibition"
    (ds.any (fun d => d.force == .prohibition && containsSubstr d.text "delete"))
  check r "\"always\" is classified as an obligation"
    (ds.any (fun d => d.force == .obligation && containsSubstr d.text "tests"))
  check r "\"must\" in prose is classified as an obligation"
    (ds.any (fun d => d.force == .obligation && containsSubstr d.text "ticket"))
  check r "\"prefer\" is classified as a preference"
    (ds.any (fun d => d.force == .preference && containsSubstr d.text "commits"))
  check r "bullets keep their original wording"
    (ds.any (fun d => d.text == "Always run the tests before reporting."))
  checkEq r "an empty prompt yields no directives" (extractDirectives "").length 0
  check r "extraction is capped"
    ((extractDirectives (String.intercalate "\n"
        (List.replicate 100 "- Always do the thing.")) 10).length == 10)
  check r "prohibitions are restated first"
    (containsSubstr (renderDirectives ds) "✗")
  check r "the reminder carries the rules"
    (containsSubstr (reminderMessage ds) "delete a file")
  check r "no reminder without rules" ((reminderMessage []).isEmpty)
  check r "the adherence check carries the rules"
    (containsSubstr (adherenceMessage ds) "ticket number")

  section_ "prompt stack"
  let testStack : PromptStack := {
    text := "You are a test agent.\n- Never say hello."
    origin := .compiledIn
    directives := extractDirectives "You are a test agent.\n- Never say hello."
    rules := complianceRules (extractDirectives "You are a test agent.\n- Never say hello.")
    unknownVars := [] }
  check r "render returns the text"
    (testStack.render == "You are a test agent.\n- Never say hello.")
  check r "describe includes source"
    (containsSubstr testStack.describe "compiled into the binary")
  check r "describe includes directive count"
    (containsSubstr testStack.describe "directives")
  check r "describeRules formats mechanically checkable rules"
    (!testStack.describeRules.isEmpty)

  section_ "execution modes"
  checkEq r "parses governed" (ExecutionMode.ofString? "governed") (some ExecutionMode.governed)
  checkEq r "parses unrestricted" (ExecutionMode.ofString? "unrestricted") (some ExecutionMode.unrestricted)
  checkEq r "rejects nonsense" (ExecutionMode.ofString? "sideways") (none : Option ExecutionMode)

  section_ "pinned message trimming"
  check r "a pinned message survives a trim"
    (let pinned := { Message.user "OPERATOR RULE" with pinned := true }
     let bulk := List.replicate 50 (Message.user (String.ofList (List.replicate 400 'x')))
     let msgs := Message.system "sys" :: Message.user "task" :: pinned :: bulk
     let trimmed := trimHistory 400 msgs
     trimmed.any (fun m => containsSubstr m.plainText "OPERATOR RULE"))
  check r "trimming still drops bulk history"
    (let bulk := List.replicate 50 (Message.user (String.ofList (List.replicate 400 'x')))
     let msgs := Message.system "sys" :: Message.user "task" :: bulk
     (trimHistory 400 msgs).length < msgs.length)

  section_ "provider wire format"
  check r "a tool call reply parses"
    (match OpenAI.parseResponse "{\"choices\":[{\"message\":{\"content\":null,\"tool_calls\":[{\"id\":\"c1\",\"type\":\"function\",\"function\":{\"name\":\"read_file\",\"arguments\":\"{\\\"path\\\":\\\"a\\\"}\"}}]},\"finish_reason\":\"tool_calls\"}]}" with
     | .ok resp => resp.toolCalls.length == 1 && resp.toolCalls.head!.name == "read_file"
     | .error _ => false)
  check r "an error body surfaces as a provider error"
    (match OpenAI.parseResponse "{\"error\":{\"message\":\"nope\",\"code\":\"bad\"}}" with
     | .error e => e.kind == ErrorKind.provider | .ok _ => false)
  check r "malformed JSON is a parse error"
    (match OpenAI.parseResponse "not json" with
     | .error e => e.kind == ErrorKind.parse | .ok _ => false)
  check r "an overload body is transient"
    (OpenAI.transientErrorBody "{\"error\":{\"code\":\"system_cpu_overloaded\",\"message\":\"x\"}}")
  check r "an ordinary error is not transient"
    (!OpenAI.transientErrorBody "{\"error\":{\"code\":\"invalid_request\",\"message\":\"x\"}}")
  check r "HTTP 429 counts as rate limited" (OpenAI.isRateLimited 429 "")
  check r "rate-limit backoff is long" (OpenAI.backoffMs 0 true >= 15000)
  check r "ordinary backoff is short" (OpenAI.backoffMs 0 false <= 1000)

end Tests
