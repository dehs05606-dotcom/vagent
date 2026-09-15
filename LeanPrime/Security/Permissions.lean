/-
  LeanPrime.Security.Permissions

  The permission engine.

  Design rule: `decide` is a *pure, total* function.  Nothing about the
  decision depends on IO, on the model, or on anything the model can
  influence beyond the command text itself.  That is what makes the
  invariants in `LeanPrime.Verification.SecurityProofs` provable, and it is
  why the model can never argue its way past the policy: the executor calls
  `decide` and obeys it.
-/
import LeanPrime.Util.Prelude
import LeanPrime.Util.Errors
import LeanPrime.Config.Schema

namespace LeanPrime

/-- Capabilities a tool may require. -/
inductive Permission where
  | readFs
  | writeFs
  | execute
  | network
  | git
  | process
  | admin
  deriving Repr, DecidableEq, Inhabited

def Permission.toString : Permission → String
  | .readFs => "read" | .writeFs => "write" | .execute => "execute"
  | .network => "network" | .git => "git" | .process => "process"
  | .admin => "admin"

instance : ToString Permission := ⟨Permission.toString⟩

/-- Does this permission modify the world? -/
def Permission.isMutating : Permission → Bool
  | .readFs => false
  | _ => true

/-- Risk assigned to a concrete request. -/
inductive Risk where
  | low | medium | high | forbidden
  deriving Repr, DecidableEq, Inhabited

def Risk.toString : Risk → String
  | .low => "low" | .medium => "medium" | .high => "high" | .forbidden => "forbidden"

instance : ToString Risk := ⟨Risk.toString⟩

def Risk.rank : Risk → Nat
  | .low => 0 | .medium => 1 | .high => 2 | .forbidden => 3

/-- The engine's verdict. -/
inductive Decision where
  | allow
  | ask (reason : String)
  | deny (reason : String)
  deriving Repr, Inhabited

def Decision.isAllow : Decision → Bool
  | .allow => true | _ => false

def Decision.isDeny : Decision → Bool
  | .deny _ => true | _ => false

/-- What a tool invocation needs in order to run. -/
structure Requirement where
  /-- Capabilities the tool needs. -/
  permissions : List Permission
  /-- Static risk floor declared by the tool itself. -/
  risk        : Risk
  /-- Human-readable summary shown in an approval prompt. -/
  summary     : String
  deriving Repr, Inhabited

/-- The active policy.  Built once from config; never mutated by the model. -/
structure Policy where
  mode            : ApprovalMode
  /-- Commands refused outright, matched on the first word. -/
  deniedCommands  : List String
  /-- Permissions the user granted for the rest of the session. -/
  sessionGrants   : List Permission
  /-- Exact command lines approved for the rest of the session. -/
  approvedCommands : List String
  deriving Inhabited

def Policy.ofConfig (c : Config) : Policy :=
  { mode := c.approval
    deniedCommands := c.deniedCommands
    sessionGrants := []
    approvedCommands := [] }

/-! ### Command classification -/

/-- First word of a command line, with any leading environment assignments
    and path prefix stripped: `/usr/bin/rm` and `FOO=1 rm` both yield `rm`. -/
def commandHead (cmdline : String) : String :=
  let words := splitNonEmpty cmdline " "
  let rec skipAssign : List String → String
    | [] => ""
    | w :: rest => if containsSubstr w "=" then skipAssign rest else w
  let w := skipAssign words
  match (w.replace "\\" "/").splitOn "/" with
  | [] => w
  | parts => parts.getLast!

/-- Commands that only observe. -/
def readOnlyCommands : List String :=
  ["ls", "pwd", "cat", "head", "tail", "wc", "file", "stat", "find", "grep",
   "rg", "fd", "tree", "which", "echo", "date", "env", "printenv", "du", "df",
   "diff", "sort", "uniq", "basename", "dirname", "realpath", "readlink"]

/-- Commands that build or test: they write to build directories but are the
    normal business of a coding agent. -/
def buildCommands : List String :=
  ["lake", "lean", "cargo", "go", "npm", "pnpm", "yarn", "bun", "make",
   "cmake", "gradle", "mvn", "pytest", "python", "python3", "node", "tsc",
   "jest", "vitest", "dotnet", "swift", "zig", "gcc", "clang", "g++"]

/-- Commands that mutate the machine beyond the workspace. -/
def highRiskCommands : List String :=
  ["rm", "rmdir", "mv", "chmod", "chown", "kill", "killall", "pkill",
   "curl", "wget", "ssh", "scp", "rsync", "apt", "apt-get", "yum", "dnf",
   "brew", "pip", "pip3", "docker", "systemctl", "service", "crontab", "nc"]

/-- Git subcommands that rewrite or publish history. -/
def dangerousGitSubcommands : List String :=
  ["push", "reset", "clean", "rebase", "filter-branch", "gc", "prune",
   "reflog", "update-ref", "remote", "config"]

/-- Shell metacharacters that let one approved command smuggle another.
    Their presence raises risk: the head word no longer describes what runs. -/
def hasShellChaining (cmdline : String) : Bool :=
  ["&&", "||", ";", "|", "`", "$(", ">", ">>", "<"].any (containsSubstr cmdline)

/-- Classify the *head word* of a command, ignoring chaining.
    Split out from `classifyCommand` so that the deny-list check and the
    chaining escalation each stay small enough to reason about. -/
def classifyHead (cmdline : String) : Requirement :=
  let head := commandHead cmdline
  if head == "git" then
    let sub := (splitNonEmpty cmdline " ").drop 1 |>.head? |>.getD ""
    if dangerousGitSubcommands.contains sub then
      { permissions := [.git, .writeFs], risk := .high,
        summary := s!"git {sub} modifies or publishes repository state" }
    else
      { permissions := [.git, .readFs], risk := .low,
        summary := s!"git {sub} inspects repository state" }
  else if readOnlyCommands.contains head then
    { permissions := [.readFs], risk := .low, summary := s!"`{head}` reads only" }
  else if buildCommands.contains head then
    { permissions := [.execute, .readFs, .writeFs], risk := .medium,
      summary := s!"`{head}` builds or runs project code" }
  else if highRiskCommands.contains head then
    { permissions :=
        if ["curl", "wget", "ssh", "scp", "rsync", "nc"].contains head then
          [.network, .execute]
        else if ["kill", "killall", "pkill"].contains head then [.process]
        else [.writeFs, .execute],
      risk := .high,
      summary := s!"`{head}` can affect state outside the workspace" }
  else
    { permissions := [.execute], risk := .high,
      summary := s!"`{head}` is not a recognised command" }

/-- Raise a requirement to `high` when the command line contains shell
    chaining, because then the head word no longer determines what runs. -/
def escalateChaining (cmdline : String) (base : Requirement) : Requirement :=
  if hasShellChaining cmdline && base.risk.rank < Risk.high.rank then
    { permissions := base.permissions
      risk := Risk.high
      summary := base.summary ++
        "; contains shell chaining, so the effective command is not determined by its first word" }
  else base

/-- Classify a raw shell command line into a requirement.

    Deliberately conservative: the deny list wins over everything, an
    unrecognised command is `high`, and chaining escalates. -/
def classifyCommand (denied : List String) (cmdline : String) : Requirement :=
  if denied.contains (commandHead cmdline) then
    { permissions := [.admin], risk := .forbidden,
      summary := s!"`{commandHead cmdline}` is on the deny list" }
  else if (commandHead cmdline).isEmpty then
    { permissions := [], risk := .forbidden, summary := "empty command" }
  else
    escalateChaining cmdline (classifyHead cmdline)

/-! ### The decision function -/

/-- Decide whether a requirement may run under a policy.

    Order of checks is significant and is what the proofs rely on:
    1. `forbidden` is refused in every mode, including `yolo`;
    2. `readOnly` refuses anything mutating;
    3. otherwise the approval mode decides. -/
def Policy.decide (p : Policy) (r : Requirement) : Decision :=
  if r.risk == .forbidden then
    .deny r.summary
  else if p.mode == .readOnly && r.permissions.any Permission.isMutating then
    .deny s!"session is read-only; {r.summary}"
  else
    match p.mode with
    | .yolo => .allow
    | .readOnly => .allow          -- non-mutating, already checked above
    | .ask =>
      if r.permissions.any Permission.isMutating then .ask r.summary else .allow
    | .auto =>
      match r.risk with
      | .low => .allow
      | .medium =>
        if r.permissions.all (fun perm => p.sessionGrants.contains perm) then .allow
        else if r.permissions.any (fun perm => perm == .admin || perm == .network) then
          .ask r.summary
        else .allow
      | .high => .ask r.summary
      | .forbidden => .deny r.summary

/-- Record a session-wide grant for every permission a requirement needed. -/
def Policy.grantSession (p : Policy) (r : Requirement) : Policy :=
  { p with sessionGrants :=
      r.permissions.foldl (fun acc perm =>
        if acc.contains perm then acc else perm :: acc) p.sessionGrants }

/-- Remember an exact command line as approved for the session. -/
def Policy.approveCommand (p : Policy) (cmdline : String) : Policy :=
  if p.approvedCommands.contains cmdline then p
  else { p with approvedCommands := cmdline :: p.approvedCommands }

end LeanPrime
