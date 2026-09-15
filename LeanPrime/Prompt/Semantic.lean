/-
  LeanPrime.Prompt.Semantic

  Semantic compliance checking: topic adherence, behavioral drift detection,
  and intent matching.

  `Compliance.lean` enforces exact textual rules — "must contain X", "never
  say Y".  This module enforces *semantic* rules: the reply must stay on
  topic, must not drift into a persona the prompt forbids, and must not
  exhibit intent patterns the prompt prohibits.

  ## Topic adherence

  The system prompt declares a domain (coding, writing, analysis, etc.)
  through the task it receives.  The agent extracts topic keywords at the
  start and, on every reply, checks that the reply shares enough of those
  keywords to be considered on-topic.  A reply that drifts into a
  completely unrelated domain is flagged.

  ## Behavioral fingerprinting

  The system prompt defines a persona — tone, style, constraints.  The
  agent builds a "behavioral fingerprint" from the prompt: a set of
  characteristic phrases and patterns the agent should exhibit.  If a
  reply's fingerprint diverges beyond a threshold, it is flagged as
  behavioral drift.

  ## Intent classification

  Every reply is classified into one of a small set of intent categories:
  answer, question, refusal, instruction, identity-claim, meta-commentary.
  The prompt may restrict certain intents — for example, forbidding
  identity-claims or meta-commentary.

  ## Tone consistency

  The prompt's tone is fingerprinted by presence/absence of formality
  markers, hedging language, assertiveness markers, etc.  A reply whose
  tone fingerprint deviates strongly from the prompt's expected tone is
  flagged.

  All of these checks are conservative: they flag, not reject.  The
  mechanical compliance check in `Compliance.lean` is the one that rejects;
  semantic drift is reported as a warning and fed back to the model as a
  course-correction instruction.
-/
import LeanPrime.Util.Prelude
import LeanPrime.Agent.Directives

namespace LeanPrime

/-! ### Topic keywords -/

private def stopWords : List String :=
  ["the", "a", "an", "is", "are", "was", "were", "be", "been", "being",
   "have", "has", "had", "do", "does", "did", "will", "would", "could",
   "should", "may", "might", "can", "shall", "it", "its", "this", "that",
   "these", "those", "i", "you", "we", "they", "he", "she", "my", "your",
   "our", "their", "his", "her", "and", "or", "but", "if", "then", "else",
   "when", "where", "how", "what", "which", "who", "whom", "not", "no",
   "yes", "all", "any", "each", "every", "some", "many", "few", "more",
   "most", "other", "such", "only", "just", "also", "very", "too", "so",
   "than", "as", "with", "from", "for", "to", "of", "in", "on", "at",
   "by", "about", "into", "through", "during", "before", "after", "above",
   "below", "between", "out", "up", "down", "off", "over", "under"]

/-- Extract significant words from text, filtering stop words and short tokens. -/
def extractKeywords (text : String) (limit : Nat := 50) : List String :=
  let words := (toLower text).splitOn " "
  let significant := words.filter fun w =>
    let clean := String.ofList (w.toList.filter Char.isAlpha)
    clean.length >= 4 && !stopWords.contains clean
  let unique := significant.eraseDups
  unique.take limit

/-- Jaccard similarity between two keyword sets. -/
def keywordOverlap (a b : List String) : Float :=
  if a.isEmpty || b.isEmpty then 0.0
  else
    let intersection := a.filter (fun w => b.contains w)
    let union := (a ++ b).eraseDups
    if union.isEmpty then 0.0
    else intersection.length.toFloat / union.length.toFloat

/-- Is the reply on-topic relative to the prompt and task? -/
structure TopicResult where
  overlap    : Float
  onTopic    : Bool
  promptKeys : List String
  replyKeys  : List String
  deriving Repr, Inhabited

def checkTopic (promptText taskText replyText : String)
    (threshold : Float := 0.05) : TopicResult :=
  let promptKeys := extractKeywords (promptText ++ " " ++ taskText)
  let replyKeys := extractKeywords replyText
  let overlap := keywordOverlap promptKeys replyKeys
  { overlap := overlap
    onTopic := overlap >= threshold
    promptKeys := promptKeys.take 10
    replyKeys := replyKeys.take 10 }

/-! ### Intent classification -/

inductive ReplyIntent where
  | answer
  | question
  | refusal
  | instruction
  | identityClaim
  | metaCommentary
  | codeOutput
  | unknown
  deriving Repr, DecidableEq, Inhabited, BEq

def ReplyIntent.toString : ReplyIntent → String
  | .answer => "answer"
  | .question => "question"
  | .refusal => "refusal"
  | .instruction => "instruction"
  | .identityClaim => "identity-claim"
  | .metaCommentary => "meta-commentary"
  | .codeOutput => "code-output"
  | .unknown => "unknown"

instance : ToString ReplyIntent := ⟨ReplyIntent.toString⟩

private def identityPhrases : List String :=
  ["i am", "my name is", "i'm called", "i was created by",
   "i'm an ai", "i am an ai", "as an ai", "as a language model",
   "i don't have feelings", "i cannot feel", "i'm a", "i am a"]

private def refusalPhrases : List String :=
  ["i cannot", "i can't", "i'm unable", "i am unable", "i must decline",
   "i won't", "i will not", "i'm not able", "that's not something i",
   "i'm sorry but i can't", "i apologize but", "i refuse"]

private def metaPhrases : List String :=
  ["let me think about", "i'll now", "first, i will", "my approach",
   "here's my plan", "let me explain my", "i'm going to start by",
   "the reason i", "my reasoning", "as i mentioned earlier"]

private def questionPhrases : List String :=
  ["could you", "can you", "would you", "do you want", "shall i",
   "what would you like", "how should i", "is that correct",
   "does that make sense", "any questions"]

private def instructionPhrases : List String :=
  ["you should", "you must", "you need to", "please do", "make sure you",
   "do not forget", "remember to", "be sure to", "ensure that"]

/-- Classify a reply's primary intent. -/
def classifyIntent (reply : String) : ReplyIntent :=
  let lower := toLower reply
  let has (phrases : List String) : Bool :=
    phrases.any (containsSubstr lower)
  if has identityPhrases then .identityClaim
  else if has refusalPhrases then .refusal
  else if has metaPhrases then .metaCommentary
  else if has questionPhrases then .question
  else if has instructionPhrases then .instruction
  else if containsSubstr reply "```" || containsSubstr reply "def " ||
          containsSubstr reply "fn " || containsSubstr reply "function " then .codeOutput
  else .answer

/-! ### Behavioral fingerprinting -/

structure BehavioralFingerprint where
  formalityScore  : Float
  hedgingScore    : Float
  assertiveness   : Float
  technicalDensity : Float
  avgSentenceLen  : Float
  deriving Repr, Inhabited

private def formalMarkers : List String :=
  ["therefore", "consequently", "furthermore", "moreover", "nevertheless",
   "notwithstanding", "pursuant", "accordingly", "whereby", "herein",
   "henceforth", "thereby", "wherein"]

private def hedgeMarkers : List String :=
  ["perhaps", "maybe", "possibly", "might", "could", "it seems",
   "appears to", "somewhat", "relatively", "arguably", "potentially",
   "likely", "unlikely", "it's possible", "in some cases"]

private def assertiveMarkers : List String :=
  ["definitely", "certainly", "absolutely", "clearly", "obviously",
   "without doubt", "undoubtedly", "must", "always", "never",
   "guaranteed", "proven", "confirmed"]

private def technicalMarkers : List String :=
  ["function", "variable", "parameter", "algorithm", "implementation",
   "interface", "module", "compile", "runtime", "exception", "syntax",
   "api", "endpoint", "database", "query", "schema", "binary",
   "thread", "mutex", "async", "await", "callback"]

private def countMarkers (text : String) (markers : List String) : Nat :=
  let lower := toLower text
  markers.foldl (fun count marker =>
    if containsSubstr lower marker then count + 1 else count) 0

private def sentenceCount (text : String) : Nat :=
  let endings := text.toList.filter (fun c => c == '.' || c == '!' || c == '?')
  endings.length.max 1

/-- Build a fingerprint from a block of text. -/
def fingerprint (text : String) : BehavioralFingerprint :=
  let words := (text.splitOn " ").length.max 1
  let formal := countMarkers text formalMarkers
  let hedge := countMarkers text hedgeMarkers
  let assert_ := countMarkers text assertiveMarkers
  let tech := countMarkers text technicalMarkers
  let sents := sentenceCount text
  { formalityScore := formal.toFloat / words.toFloat * 100.0
    hedgingScore := hedge.toFloat / words.toFloat * 100.0
    assertiveness := assert_.toFloat / words.toFloat * 100.0
    technicalDensity := tech.toFloat / words.toFloat * 100.0
    avgSentenceLen := words.toFloat / sents.toFloat }

/-- Distance between two fingerprints (Euclidean, weighted). -/
def fingerprintDistance (a b : BehavioralFingerprint) : Float :=
  let d1 := (a.formalityScore - b.formalityScore) * 2.0
  let d2 := (a.hedgingScore - b.hedgingScore) * 1.5
  let d3 := (a.assertiveness - b.assertiveness) * 1.5
  let d4 := (a.technicalDensity - b.technicalDensity) * 1.0
  let d5 := (a.avgSentenceLen - b.avgSentenceLen) * 0.1
  Float.sqrt (d1*d1 + d2*d2 + d3*d3 + d4*d4 + d5*d5)

/-! ### Drift detection -/

inductive DriftSeverity where
  | none_
  | mild
  | moderate
  | severe
  deriving Repr, DecidableEq, Inhabited, BEq

def DriftSeverity.toString : DriftSeverity → String
  | .none_ => "none" | .mild => "mild" | .moderate => "moderate" | .severe => "severe"

instance : ToString DriftSeverity := ⟨DriftSeverity.toString⟩

structure DriftReport where
  severity        : DriftSeverity
  topicResult     : TopicResult
  intent          : ReplyIntent
  distance        : Float
  baseline        : BehavioralFingerprint
  current         : BehavioralFingerprint
  forbiddenIntents : List ReplyIntent
  deriving Repr, Inhabited

def DriftReport.isDrifting (r : DriftReport) : Bool :=
  r.severity != .none_

def DriftReport.describe (r : DriftReport) : String :=
  let parts : List String := Id.run do
    let mut p : List String := []
    if !r.topicResult.onTopic then
      p := p ++ [s!"off-topic (overlap: {r.topicResult.overlap})"]
    if r.forbiddenIntents.contains r.intent then
      p := p ++ [s!"forbidden intent: {r.intent}"]
    if r.distance > 5.0 then
      p := p ++ [s!"behavioral drift (distance: {r.distance})"]
    return p
  if parts.isEmpty then "no drift detected"
  else s!"drift [{r.severity}]: " ++ String.intercalate ", " parts

/-- The course-correction message fed back when drift is detected. -/
def driftCorrectionMessage (report : DriftReport) : String :=
  String.intercalate "\n"
    [ "[COURSE CORRECTION — behavioral drift detected]"
    , ""
    , s!"  Severity: {report.severity}"
    , s!"  {report.describe}"
    , ""
    , "Your reply is drifting from the system prompt's intended behavior."
    , "Re-read the system prompt and realign your response."
    , "Stay on the task. Follow the prompt's persona and constraints exactly." ]

/-- Full drift analysis of a reply. -/
def analyzeDrift (promptText taskText replyText : String)
    (forbiddenIntents : List ReplyIntent := [])
    (driftThreshold : Float := 8.0) : DriftReport :=
  let topicResult := checkTopic promptText taskText replyText
  let intent := classifyIntent replyText
  let baseline := fingerprint (promptText ++ " " ++ taskText)
  let current := fingerprint replyText
  let distance := fingerprintDistance baseline current
  let intentForbidden := forbiddenIntents.contains intent
  let severity :=
    if !topicResult.onTopic && intentForbidden then .severe
    else if !topicResult.onTopic || distance > driftThreshold * 2.0 then .moderate
    else if intentForbidden || distance > driftThreshold then .mild
    else .none_
  { severity := severity
    topicResult := topicResult
    intent := intent
    distance := distance
    baseline := baseline
    current := current
    forbiddenIntents := forbiddenIntents }

/-! ### Semantic rule extraction

    Extract semantic constraints from directives that cannot be checked
    mechanically but can be checked through keyword/topic analysis. -/

/-- A semantic constraint extracted from a directive. -/
inductive SemanticConstraint where
  | stayOnTopic (keywords : List String)
  | forbidIntent (intent : ReplyIntent)
  | maintainTone (baseline : BehavioralFingerprint)
  | requireTechnical
  | requireFormal
  | requireConcise (maxSentences : Nat)
  deriving Repr, Inhabited

def SemanticConstraint.describe : SemanticConstraint → String
  | .stayOnTopic ks => s!"stay on topic ({String.intercalate ", " (ks.take 5)})"
  | .forbidIntent i => s!"forbidden intent: {i}"
  | .maintainTone _ => "maintain tone consistency"
  | .requireTechnical => "use technical language"
  | .requireFormal => "use formal language"
  | .requireConcise n => s!"keep responses under {n} sentences"

private def mentionsConcise (lower : String) : Bool :=
  ["concise", "brief", "short", "terse", "succinct", "few words"].any (containsSubstr lower)

private def mentionsTechnical (lower : String) : Bool :=
  ["technical", "code", "programming", "developer", "engineering"].any (containsSubstr lower)

private def mentionsFormal (lower : String) : Bool :=
  ["formal", "professional", "polished", "proper"].any (containsSubstr lower)

/-- Extract semantic constraints from the directive list. -/
def extractSemanticConstraints (ds : List Directive) (promptText : String)
    : List SemanticConstraint :=
  Id.run do
  let mut constraints : List SemanticConstraint := []
  constraints := constraints ++ [.stayOnTopic (extractKeywords promptText 30)]
  constraints := constraints ++ [.maintainTone (fingerprint promptText)]
  for d in ds do
    let lower := toLower d.text
    if mentionsConcise lower then
      constraints := constraints ++ [.requireConcise 10]
    if mentionsTechnical lower then
      constraints := constraints ++ [.requireTechnical]
    if mentionsFormal lower then
      constraints := constraints ++ [.requireFormal]
    if containsSubstr lower "identity" || containsSubstr lower "who you are" then
      constraints := constraints ++ [.forbidIntent .identityClaim]
    if containsSubstr lower "meta" || containsSubstr lower "explain your reasoning" then
      constraints := constraints ++ [.forbidIntent .metaCommentary]
  return constraints

/-- Check a reply against semantic constraints.  Returns violated constraints. -/
def checkSemanticConstraints (constraints : List SemanticConstraint)
    (_promptText _taskText replyText : String) : List (SemanticConstraint × String) :=
  Id.run do
  let mut violations : List (SemanticConstraint × String) := []
  for c in constraints do
    match c with
    | .stayOnTopic keywords =>
      let replyKeys := extractKeywords replyText
      let overlap := keywordOverlap keywords replyKeys
      if overlap < 0.03 then
        violations := violations ++ [(c, s!"topic overlap too low ({overlap})")]
    | .forbidIntent intent =>
      let classified := classifyIntent replyText
      if classified == intent then
        violations := violations ++ [(c, s!"reply has forbidden intent: {intent}")]
    | .maintainTone baseline =>
      let current := fingerprint replyText
      let dist := fingerprintDistance baseline current
      if dist > 10.0 then
        violations := violations ++ [(c, s!"tone drift distance: {dist}")]
    | .requireTechnical =>
      let fp := fingerprint replyText
      if fp.technicalDensity < 0.5 then
        violations := violations ++ [(c, "reply lacks technical language")]
    | .requireFormal =>
      let fp := fingerprint replyText
      if fp.formalityScore < 0.2 then
        violations := violations ++ [(c, "reply is too informal")]
    | .requireConcise maxSentences =>
      let sents := sentenceCount replyText
      if sents > maxSentences then
        violations := violations ++ [(c, s!"reply has {sents} sentences, max is {maxSentences}")]
  return violations

end LeanPrime
