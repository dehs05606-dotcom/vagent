/-
  LeanPrime.Agent.Guardian

  Multi-layer guardian: the last line of defense between the model's output
  and the conversation.

  The guardian sits between the model reply and the loop's acceptance logic.
  Every reply passes through it before entering the conversation as an
  assistant turn.  It orchestrates:

    1. **Mechanical compliance** — exact textual rules (from Compliance.lean)
    2. **Semantic compliance** — topic adherence, intent, drift (from Semantic.lean)
    3. **Authority enforcement** — sovereignty markers, conflict detection (from Authority.lean)
    4. **Behavioral anchoring** — identity-reinforcing instructions at conversation boundaries
    5. **Instruction distance tracking** — how far (in tokens) the model is from the last directive
    6. **Conversation fingerprinting** — detecting when the conversation's character changes

  The guardian does not make decisions about *what* to do with a failing
  reply — that is the loop's job.  It produces a `GuardianVerdict`:
  accept, warn (with course-correction), or reject (with the compliance
  error).

  ## Behavioral anchoring

  At conversation boundaries — after tool output, before a completion
  attempt, and periodically — the guardian injects a short identity anchor:
  a message reminding the model of its core identity and constraints.  This
  is not a full re-assertion of the prompt; it is a compressed identity
  statement derived from the first few lines of the prompt.

  ## Instruction distance

  The guardian tracks how many tokens have been added to the conversation
  since the last directive message.  When this distance exceeds a threshold,
  it triggers a re-assertion even outside the cadence, because the model's
  effective attention has moved past the instruction.

  ## Conversation fingerprinting

  Each turn is fingerprinted by its behavioral characteristics.  The
  guardian maintains a running average of the conversation's fingerprint
  and detects when a new turn deviates from it.  This catches gradual
  drift that per-turn analysis might miss.
-/
import LeanPrime.Prompt.Compliance
import LeanPrime.Prompt.Semantic
import LeanPrime.Prompt.Authority
import LeanPrime.Agent.Directives

namespace LeanPrime

/-! ### Instruction distance -/

structure InstructionDistance where
  tokensSinceLastDirective : Nat := 0
  turnsSinceLastDirective  : Nat := 0
  threshold                : Nat := 4000
  deriving Repr, Inhabited

def InstructionDistance.addTokens (d : InstructionDistance) (n : Nat) : InstructionDistance :=
  { d with tokensSinceLastDirective := d.tokensSinceLastDirective + n
           turnsSinceLastDirective := d.turnsSinceLastDirective + 1 }

def InstructionDistance.reset (d : InstructionDistance) : InstructionDistance :=
  { d with tokensSinceLastDirective := 0, turnsSinceLastDirective := 0 }

def InstructionDistance.isDistant (d : InstructionDistance) : Bool :=
  d.tokensSinceLastDirective > d.threshold

/-! ### Conversation fingerprint tracker -/

structure ConversationProfile where
  turnCount       : Nat := 0
  avgFormality    : Float := 0.0
  avgHedging      : Float := 0.0
  avgAssertive    : Float := 0.0
  avgTechnical    : Float := 0.0
  avgSentenceLen  : Float := 0.0
  deriving Repr, Inhabited

def ConversationProfile.update (p : ConversationProfile) (fp : BehavioralFingerprint)
    : ConversationProfile :=
  let n := p.turnCount.toFloat
  let w := 1.0 / (n + 1.0)
  { turnCount := p.turnCount + 1
    avgFormality := p.avgFormality * (1.0 - w) + fp.formalityScore * w
    avgHedging := p.avgHedging * (1.0 - w) + fp.hedgingScore * w
    avgAssertive := p.avgAssertive * (1.0 - w) + fp.assertiveness * w
    avgTechnical := p.avgTechnical * (1.0 - w) + fp.technicalDensity * w
    avgSentenceLen := p.avgSentenceLen * (1.0 - w) + fp.avgSentenceLen * w }

def ConversationProfile.asFingerprint (p : ConversationProfile) : BehavioralFingerprint :=
  { formalityScore := p.avgFormality
    hedgingScore := p.avgHedging
    assertiveness := p.avgAssertive
    technicalDensity := p.avgTechnical
    avgSentenceLen := p.avgSentenceLen }

def ConversationProfile.deviationOf (p : ConversationProfile) (fp : BehavioralFingerprint)
    : Float :=
  if p.turnCount < 3 then 0.0
  else fingerprintDistance p.asFingerprint fp

/-! ### Behavioral anchor -/

/-- Extract the core identity from the first few lines of the system prompt. -/
def extractIdentityAnchor (prompt : String) (maxLines : Nat := 5) : String :=
  let lines := (prompt.splitOn "\n").filter (fun l => !(trim l).isEmpty)
  let core := lines.take maxLines
  if core.isEmpty then ""
  else
    String.intercalate "\n"
      [ "[IDENTITY ANCHOR — derived from the system prompt]"
      , String.intercalate "\n" (core.map fun l => s!"  {truncate (trim l) 200}")
      , "[End anchor. Stay in character. Follow the system prompt.]" ]

/-- Produce an anchoring message for injection at conversation boundaries. -/
def anchoringMessage (prompt : String) (directives : List Directive) : String :=
  let anchor := extractIdentityAnchor prompt
  let ruleCount := directives.length
  let enforced := directives.filter (fun d => d.force != .preference) |>.length
  if anchor.isEmpty then ""
  else
    String.intercalate "\n"
      [ anchor
      , ""
      , s!"You have {ruleCount} standing instructions ({enforced} mandatory)."
      , "Continue the task exactly as the system prompt requires."
      , "Do not deviate. Do not adopt a different persona." ]

/-! ### Guardian state -/

structure GuardianState where
  distance         : InstructionDistance := {}
  profile          : ConversationProfile := {}
  semanticConstraints : List SemanticConstraint := []
  anchorText       : String := ""
  anchorInterval   : Nat := 5
  turnsSinceAnchor : Nat := 0
  totalWarnings    : Nat := 0
  totalRejections  : Nat := 0
  driftCorrections : Nat := 0
  authorityConflicts : Nat := 0
  deriving Inhabited

/-! ### Guardian verdict -/

inductive GuardianAction where
  | accept
  | warn (message : String)
  | reject (message : String)
  deriving Repr, Inhabited

structure GuardianVerdict where
  action             : GuardianAction
  complianceViolations : List Violation
  semanticViolations : List (SemanticConstraint × String)
  driftReport        : Option DriftReport
  distanceTriggered  : Bool
  anchorNeeded       : Bool
  deriving Inhabited

def GuardianVerdict.isAccepted (v : GuardianVerdict) : Bool :=
  match v.action with
  | .accept => true
  | _ => false

def GuardianVerdict.isRejected (v : GuardianVerdict) : Bool :=
  match v.action with
  | .reject _ => true
  | _ => false

def GuardianVerdict.describe (v : GuardianVerdict) : String :=
  match v.action with
  | .accept => "accepted"
  | .warn msg => s!"warning: {truncate msg 100}"
  | .reject msg => s!"rejected: {truncate msg 100}"

/-! ### The guardian check -/

/-- Run all guardian checks on a model reply. -/
def guardianCheck
    (rules : List (Nat × ComplianceRule))
    (constraints : List SemanticConstraint)
    (promptText taskText replyText : String)
    (gState : GuardianState)
    (forbiddenIntents : List ReplyIntent := []) : GuardianVerdict :=
  let compViolations := checkCompliance rules replyText
  if !compViolations.isEmpty then
    { action := .reject (correctionMessage compViolations)
      complianceViolations := compViolations
      semanticViolations := []
      driftReport := none
      distanceTriggered := false
      anchorNeeded := false }
  else
    let semViolations := checkSemanticConstraints constraints promptText taskText replyText
    let driftReport := analyzeDrift promptText taskText replyText forbiddenIntents
    let distanceTriggered := gState.distance.isDistant
    let anchorNeeded := gState.turnsSinceAnchor >= gState.anchorInterval
    let hasDrift := driftReport.isDrifting
    let hasSemanticIssues := !semViolations.isEmpty
    if hasDrift && driftReport.severity == .severe then
      { action := .reject (driftCorrectionMessage driftReport)
        complianceViolations := []
        semanticViolations := semViolations
        driftReport := some driftReport
        distanceTriggered := distanceTriggered
        anchorNeeded := true }
    else if hasDrift || hasSemanticIssues then
      let parts := Id.run do
        let mut p : List String := []
        if hasDrift then
          p := p ++ [driftReport.describe]
        for (c, reason) in semViolations do
          p := p ++ [s!"{c.describe}: {reason}"]
        return p
      let message := String.intercalate "\n"
        ([ "[GUARDIAN WARNING — your reply shows signs of drift]"
         , "" ]
         ++ parts.map (fun p => s!"  • {p}")
         ++ [ ""
            , "Re-read the system prompt. Realign your next response." ])
      { action := .warn message
        complianceViolations := []
        semanticViolations := semViolations
        driftReport := some driftReport
        distanceTriggered := distanceTriggered
        anchorNeeded := true }
    else
      { action := .accept
        complianceViolations := []
        semanticViolations := []
        driftReport := some driftReport
        distanceTriggered := distanceTriggered
        anchorNeeded := anchorNeeded }

/-- Update guardian state after processing a reply. -/
def updateGuardianState (gState : GuardianState) (verdict : GuardianVerdict)
    (replyTokens : Nat) (replyText : String) : GuardianState :=
  let fp := fingerprint replyText
  let newProfile := gState.profile.update fp
  let newDistance := gState.distance.addTokens replyTokens
  let needsAnchorReset := verdict.anchorNeeded
  match verdict.action with
  | .accept =>
    { gState with
      distance := if needsAnchorReset then newDistance.reset else newDistance
      profile := newProfile
      turnsSinceAnchor := if needsAnchorReset then 0 else gState.turnsSinceAnchor + 1 }
  | .warn _ =>
    { gState with
      distance := newDistance.reset
      profile := newProfile
      turnsSinceAnchor := 0
      totalWarnings := gState.totalWarnings + 1
      driftCorrections := gState.driftCorrections + 1 }
  | .reject _ =>
    { gState with
      distance := newDistance
      profile := newProfile
      turnsSinceAnchor := 0
      totalRejections := gState.totalRejections + 1 }

/-! ### Guardian summary for the status bar -/

structure GuardianSummary where
  warnings    : Nat
  rejections  : Nat
  driftEvents : Nat
  conflicts   : Nat
  deriving Repr, Inhabited

def GuardianState.summary (g : GuardianState) : GuardianSummary :=
  { warnings := g.totalWarnings
    rejections := g.totalRejections
    driftEvents := g.driftCorrections
    conflicts := g.authorityConflicts }

def GuardianSummary.describe (s : GuardianSummary) : String :=
  let parts := Id.run do
    let mut p : List String := []
    if s.warnings > 0 then p := p ++ [s!"{s.warnings} warn"]
    if s.rejections > 0 then p := p ++ [s!"{s.rejections} reject"]
    if s.driftEvents > 0 then p := p ++ [s!"{s.driftEvents} drift"]
    if s.conflicts > 0 then p := p ++ [s!"{s.conflicts} conflict"]
    return p
  if parts.isEmpty then "clean"
  else String.intercalate " · " parts

/-! ### Guardian initialization -/

def initGuardian (promptText : String) (directives : List Directive)
    (anchorInterval : Nat := 5) (distanceThreshold : Nat := 4000) : GuardianState :=
  { distance := { threshold := distanceThreshold }
    profile := {}
    semanticConstraints := extractSemanticConstraints directives promptText
    anchorText := anchoringMessage promptText directives
    anchorInterval := anchorInterval }

end LeanPrime
