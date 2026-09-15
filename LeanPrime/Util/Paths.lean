/-
  LeanPrime.Util.Paths

  Workspace path containment.  Every filesystem tool routes through
  `resolveInWorkspace`, which is the single choke point that prevents an
  LLM-proposed path from escaping the workspace root.

  The core is a pure function on path *segments* so that the containment
  property can be stated and proved in `LeanPrime.Verification.PathProofs`.
-/
import LeanPrime.Util.Prelude
import LeanPrime.Util.Errors

namespace LeanPrime

/-- Split a path into segments on both separators, discarding empties and
    `.` components.  Purely syntactic: no filesystem access. -/
def pathSegments (p : String) : List String :=
  let unified := p.replace "\\" "/"
  (unified.splitOn "/").filter (fun s => s != "" && s != ".")

/-- Resolve `..` against a segment list.  A `..` that would pop past the root
    is *dropped*, never allowed to escape.  This is the heart of the
    containment guarantee. -/
def normalizeGo : List String → List String → List String
  | acc, [] => acc.reverse
  | acc, s :: rest =>
    if s == ".." then
      match acc with
      | []     => normalizeGo [] rest        -- already at root: `..` is a no-op
      | _ :: t => normalizeGo t rest
    else
      normalizeGo (s :: acc) rest

def normalizeSegments (segs : List String) : List String := normalizeGo [] segs

/-- `true` when the segment list contains no upward traversal. -/
def segmentsContained (segs : List String) : Bool :=
  segs.all (fun s => s != "..")

/-- Is `p` an absolute path on either platform convention? -/
def isAbsolutePath (p : String) : Bool :=
  match p.toList with
  | '/' :: _ => true
  | '\\' :: _ => true
  | _ :: ':' :: sep :: _ => sep == '/' || sep == '\\'   -- Windows drive letter
  | _ => false

/-- Join normalized segments back into a relative path. -/
def joinSegments (segs : List String) : String := String.intercalate "/" segs

structure Workspace where
  root : System.FilePath
  /-- Unrestricted file access: paths are resolved as given, including
      absolute paths outside the root.

      Off by default.  `[execution] mode = "unrestricted"` turns it on, and
      `Workspace.resolveGoverned` — the containment function the proofs are
      about — is what runs when it is off. -/
  unrestricted : Bool := false
  deriving Inhabited

/-- Resolve a caller-supplied path against the workspace.

    Rules:
    * relative paths are normalized and joined to the root;
    * absolute paths are accepted only when they already lie under the root;
    * `..` can never climb above the root.

    Returns a structured `PermissionError` on violation. -/
def Workspace.resolveGoverned (ws : Workspace) (p : String) : LPResult System.FilePath :=
  let rootStr := ws.root.toString.replace "\\" "/"
  let rootSegs := normalizeSegments (pathSegments rootStr)
  if isAbsolutePath p then
    let pSegs := normalizeSegments (pathSegments p)
    if rootSegs.isPrefixOf pSegs then
      .ok (System.FilePath.mk ("/" ++ joinSegments pSegs))
    else
      .error (err .permission "path escapes the workspace"
        (some s!"path: {p}") (some s!"workspace root is {ws.root}"))
  else
    let segs := normalizeSegments (pathSegments p)
    if segmentsContained segs then
      .ok (ws.root / System.FilePath.mk (joinSegments segs))
    else
      .error (err .permission "path escapes the workspace" (some s!"path: {p}"))

/-- Resolve a caller-supplied path.

    In the governed default this is `resolveGoverned`, whose containment is
    proved in `LeanPrime.Verification.PathProofs`.  Under
    `[execution] mode = "unrestricted"` the path is taken as given: absolute
    paths anywhere on the machine resolve, and `..` climbs out of the
    workspace, because the operator asked for the prompt to be the only
    authority. -/
def Workspace.resolve (ws : Workspace) (p : String) : LPResult System.FilePath :=
  if ws.unrestricted then
    if isAbsolutePath p then .ok (System.FilePath.mk p)
    else .ok (ws.root / System.FilePath.mk p)
  else
    ws.resolveGoverned p

/-- Display a path relative to the workspace root when possible. -/
def Workspace.display (ws : Workspace) (p : System.FilePath) : String :=
  let r := ws.root.toString.replace "\\" "/"
  let s := p.toString.replace "\\" "/"
  if s.startsWith r then
    let rest := s.drop r.length |>.toString
    if rest.startsWith "/" then rest.drop 1 |>.toString else rest
  else s

end LeanPrime
