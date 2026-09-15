/-
  LeanPrime.Tools.Registry

  The set of tools exposed to the model, and lookup by name.

  A name the registry does not know is a hard error: the model cannot invent
  a tool, and an unknown name never reaches an executor.
-/
import LeanPrime.Tools.Filesystem
import LeanPrime.Tools.Search
import LeanPrime.Tools.Shell
import LeanPrime.Tools.Git

namespace LeanPrime

open LeanPrime.Tools

structure Registry where
  tools : List Tool

def Registry.find? (r : Registry) (name : String) : Option Tool :=
  r.tools.find? (fun t => t.name == name)

def Registry.schemas (r : Registry) : List ToolSchema :=
  r.tools.map Tool.schema

def Registry.names (r : Registry) : List String :=
  r.tools.map Tool.name

/-- Register extra tools (for example, ones discovered over MCP) while
    refusing to shadow a built-in name. -/
def Registry.extend (r : Registry) (extra : List Tool) : Registry :=
  { tools := r.tools ++ extra.filter (fun t => (r.find? t.name).isNone) }

/-- The built-in tool set. -/
def Registry.builtin : Registry where
  tools :=
    [ readFile, writeFile, editFile, listDirectory, deleteFile
    , searchFiles, searchText
    , shell, runBuild, runTests
    , gitStatus, gitDiff, gitLog, gitShow, gitAdd, gitCommit ]

/-- A read-only subset, used when the session is in read-only mode: the tools
    that could mutate are not even advertised to the model. -/
def Registry.readOnly : Registry where
  tools :=
    [ readFile, listDirectory, searchFiles, searchText
    , gitStatus, gitDiff, gitLog, gitShow ]

def Registry.forMode (m : ApprovalMode) : Registry :=
  match m with
  | .readOnly => Registry.readOnly
  | _ => Registry.builtin

end LeanPrime
