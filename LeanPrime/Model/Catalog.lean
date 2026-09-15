/-
  LeanPrime.Model.Catalog

  The models available on the configured router, as data.

  Two things this buys over typing the wire id into config every time:

    * `--model muse-1.3` resolves to `oc/muse-spark-1.3-contributor`, so the
      long vendor-prefixed ids stay out of muscle memory;
    * `--list-models` prints what is actually selectable, which is the first
      question when a run fails with "model not found".

  ## On capabilities

  Each entry records only what can be known without guessing: the wire id,
  a short alias, and the facts the router itself states about the model.
  Context and output limits are deliberately **not** recorded, because they
  are per-model figures this project has no authoritative source for, and a
  wrong number here would be worse than no number — it would look like a
  guarantee.  `max_tokens` is therefore a setting to tune per model, and a
  request above what a model supports comes back as a provider error rather
  than being silently clamped.
-/
import LeanPrime.Util.Prelude

namespace LeanPrime

/-- One selectable model. -/
structure ModelEntry where
  /-- The id sent on the wire. -/
  id      : String
  /-- Short name accepted by `--model`. -/
  alias_  : String
  /-- Who publishes it, as far as the id says. -/
  vendor  : String
  /-- The model's name states it handles images. -/
  vision  : Bool := false
  /-- The model's name states it is free to call. -/
  free    : Bool := false
  /-- The model's name marks it as a preview or experiment. -/
  preview : Bool := false
  deriving Repr, Inhabited

/-- Models available on the configured kios router.

    The aliases are chosen to be the shortest unambiguous form of each id. -/
def kiosCatalog : List ModelEntry :=
  [ { id := "oc/muse-spark-1.3-contributor"
      alias_ := "muse-1.3", vendor := "oc" }
  , { id := "oc/muse-spark-1.2-contributor"
      alias_ := "muse-1.2", vendor := "oc" }
  , { id := "atria-asi/atria-dawn-preview"
      alias_ := "atria-dawn", vendor := "atria-asi", preview := true }
  , { id := "deepseek-v4-flash-vision-exp-free"
      alias_ := "deepseek-v4", vendor := "deepseek"
      vision := true, free := true, preview := true }
  , { id := "ling-3.0-flash-fin"
      alias_ := "ling-3.0", vendor := "ling" } ]

namespace ModelEntry

/-- Tags shown next to the id in `--list-models`. -/
def tags (m : ModelEntry) : List String :=
  (if m.vision then ["vision"] else []) ++
  (if m.free then ["free"] else []) ++
  (if m.preview then ["preview"] else [])

def describe (m : ModelEntry) : String :=
  let t := m.tags
  let suffix := if t.isEmpty then "" else s!"  [{String.intercalate ", " t}]"
  s!"{padRight m.alias_ 14} {m.id}{suffix}"

end ModelEntry

/-- Resolve what the user typed to a wire id.

    Accepts the full id, the alias, or a unique prefix of either.  Anything
    unrecognised is passed through unchanged rather than rejected: the
    catalog is a convenience, not a whitelist, and a router that gains a
    model tomorrow must still be reachable today. -/
def resolveModel (input : String) : String :=
  let t := trim input
  if t.isEmpty then t else
  let lower := toLower t
  match kiosCatalog.find? (fun m => toLower m.id == lower || toLower m.alias_ == lower) with
  | some m => m.id
  | none =>
    let prefixMatches := kiosCatalog.filter fun m =>
      (toLower m.alias_).startsWith lower || (toLower m.id).startsWith lower
    match prefixMatches with
    | [m] => m.id
    | _ => t          -- ambiguous or unknown: send it as written

/-- Is this id one the catalog knows? -/
def knownModel (id : String) : Bool :=
  kiosCatalog.any (fun m => m.id == id)

/-- The catalog entry for an id, if it is one we know. -/
def modelEntry? (id : String) : Option ModelEntry :=
  kiosCatalog.find? (fun m => m.id == id)

/-- A short display name for the status line: the alias when we know the
    model, otherwise the id with its vendor prefix dropped. -/
def shortModelName (id : String) : String :=
  match modelEntry? id with
  | some m => m.alias_
  | none => match (id.splitOn "/").getLast? with
    | some tail => tail
    | none => id

/-- The `--list-models` body. -/
def renderCatalog : String :=
  String.intercalate "\n"
    ([ "models on the configured router"
     , "" ]
     ++ kiosCatalog.map (fun m => s!"  {m.describe}")
     ++ [ ""
        , "Select one with --model <alias> or [provider] model in config.toml."
        , "An id not listed here is sent to the router as written."
        , ""
        , "Context and output limits are per-model and are not recorded here."
        , "If a run fails with a length or limit error, lower max_tokens." ])

end LeanPrime
