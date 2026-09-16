module vagent

import x.json2

// mastermind.v — the coherence architecture for systemprompt.v.
//
// How does the agent follow the prompts in systemprompt.v *inevitably*,
// with zero enforcement, zero coercion, zero policing? By making the prompt
// the coherent center of every request. Nothing forces the model — the
// structure simply leaves nothing else to follow.
//
// Three cooperating mechanisms, all deterministic (rung 1):
//
//   PromptVault        Every prompt is sealed at startup with a sha256
//                      fingerprint and recorded in the event log. The vault
//                      is the ONLY source a prompt is ever read from — a
//                      prompt that was never sealed cannot reach a model.
//
//   PromptGate         The single door to the model. Every request — main
//                      agent, worker — passes gate.dispatch(), which
//                      guarantees messages[0] carries the sealed prompt
//                      (byte-for-byte prefix) and seals a prompt.dispatch
//                      lineage event. If the prompt is missing or shadowed
//                      it is simply re-seated — an integrity restore, like
//                      a checksum, not a penalty.
//
//   CoherenceComposer  The advanced piece. Dynamic context (goal, memory,
//                      constitution, web mode) is never appended as raw
//                      text that could compete with the prompt. It is
//                      COMPOSED into one coherent document: the sealed
//                      prompt stands first as the constitution, and every
//                      context section is explicitly framed as *input to*
//                      that constitution — provenance-tagged, ordered,
//                      deduplicated. The model follows the prompt because
//                      everything else in the message points back at it.
//                      Coherence, not coercion.
//
// There is no enforcement layer, no injection policing, no output-contract
// auditing. The system observes and records — it never punishes. Every
// dispatch is sealed into the event log; the lineage IS the proof of what
// the model saw.

// fingerprint is the sha256 of a prompt, clipped to 16 hex chars for
// display.
pub fn fingerprint(text string) string {
	return hash(text)[..16]
}

// ---------------------------------------------------------------------------
// PromptVault — hash-sealed prompts, the only source of truth at runtime
// ---------------------------------------------------------------------------

// PromptVault seals every prompt from systemprompt.v and serves them back.
//
// Sealing is recorded in the event log, so the exact prompt the system ran
// with is forever auditable. get() only ever returns sealed text — a prompt
// that was never sealed cannot reach a model.
@[heap]
pub struct PromptVault {
pub mut:
	log    &EventLog
	sealed map[string]string
}

pub fn new_prompt_vault(log &EventLog) &PromptVault {
	mut v := &PromptVault{
		log: unsafe { log }
	}
	v.seal('main', prompt_main())
	v.seal('master', prompt_get('master'))
	for role in role_names {
		v.seal('worker:${role}', prompt_worker(role, max_workers))
	}
	return v
}

fn (mut v PromptVault) seal(name string, text string) {
	v.sealed[name] = text
	v.log.append('prompt.sealed', {
		'name':        json2.Any(name)
		'fingerprint': json2.Any(fingerprint(text))
		'chars':       json2.Any(text.len)
	}, AppendOpts{ actor: 'kernel' })
}

pub fn (v &PromptVault) get(name string) ?string {
	return v.sealed[name] or { return none }
}

// resolve returns the sealed text for `name`, sealing on demand from the
// systemprompt registry.
//
// Already-sealed prompts (main, master, worker:* — sealed at vault init)
// are served straight from the cache. Prompts registered at runtime are
// sealed the first time they are requested, so the vault stays the only
// source a model ever reads a prompt from without needing a restart. If a
// registered prompt's text changed since it was sealed, it is re-sealed so
// the vault never serves a stale copy. A name that is neither sealed nor in
// the registry cannot be sealed and errors.
pub fn (mut v PromptVault) resolve(name string) !string {
	if existing := v.sealed[name] {
		// re-sync with the registry in case the text changed upstream
		if name in prompt_names() {
			text := prompt_get(name)
			if text != existing {
				v.seal(name, text)
				return text
			}
		}
		return existing
	}
	if name !in prompt_names() {
		return error("prompt '${name}' is not registered in systemprompt.v — " +
			'it cannot be sealed')
	}
	text := prompt_get(name)
	v.seal(name, text)
	return text
}

pub fn (v &PromptVault) fp(name string) string {
	text := v.sealed[name] or { return '' }
	return fingerprint(text)
}

pub fn (v &PromptVault) names() []string {
	mut out := v.sealed.keys()
	out.sort()
	return out
}

// verify reports whether `content` still carries the sealed prompt for
// `name`.
//
// Composed context legally FOLLOWS the sealed prompt, so this verifies the
// sealed text is an intact PREFIX — the prompt itself must be byte-for-byte
// uncorrupted and first.
pub fn (v &PromptVault) verify(name string, content string) bool {
	sealed := v.sealed[name] or { return false }
	return content.starts_with(sealed)
}

// ---------------------------------------------------------------------------
// CoherenceComposer — one coherent document, one voice
// ---------------------------------------------------------------------------

// section_order lists the context sections in authority order. Each section
// is framed as input TO the sealed prompt — never as a peer instruction.
// That framing is the whole trick: the prompt stays the only voice giving
// direction, and the model follows it because everything else defers to it.
//
// Order is position in the context, and position is attention. "salient" is
// last on purpose: it carries the clauses this turn implicates, and the end
// of the context is where a long prompt is actually read.
const section_order = ['constitution', 'goal', 'web', 'memory', 'salient']

const section_frames = {
	'constitution': 'STANDING CONTEXT — standing rules that apply within the directives above:'
	'goal':         'LIVE CONTEXT — the active goal contract the directives above are currently serving:'
	'web':          'LIVE CONTEXT — this turn needs real-time data; per the directives above, use web_search / web_fetch for current facts and quote sources:'
	'salient':      'SPECIFICATION — the clauses this request touches, reproduced from the specification above because it is long and these are the ones in play:'
	'memory':       'RECALL CONTEXT — relevant memory from prior work, to inform the directives above:'
}

// CoherenceComposer composes dynamic context into one coherent system
// document.
//
// The sealed prompt is the constitution; context sections are composed
// beneath it, each framed as input to the constitution, deduplicated and
// ordered. The output is a single document with a single voice — the
// prompt's. Nothing here coerces; it simply arranges the message so the
// prompt is the only thing there is to follow.
pub struct CoherenceComposer {}

// compose returns the sealed prompt plus framed, ordered, deduplicated
// context sections.
pub fn (c &CoherenceComposer) compose(sealed_prompt string, sections map[string]string) string {
	mut parts := [sealed_prompt]
	mut seen := map[string]bool{}
	for key in section_order {
		body := (sections[key] or { '' }).trim_space()
		if body == '' {
			continue
		}
		digest := hash(body)[..12]
		if digest in seen {
			continue // an identical section is already composed
		}
		seen[digest] = true
		frame := section_frames[key] or { continue }
		parts << '\n\n${frame}\n${body}'
	}
	return parts.join('')
}

// manifest lists which sections carried content — recorded in the lineage.
pub fn (c &CoherenceComposer) manifest(sections map[string]string) []string {
	mut out := []string{}
	for key in section_order {
		if (sections[key] or { '' }).trim_space() != '' {
			out << key
		}
	}
	return out
}

// ---------------------------------------------------------------------------
// PromptGate — the single door to the model
// ---------------------------------------------------------------------------

pub struct GateReport {
pub mut:
	prompt string
	// the prompt had to be re-seated (an integrity restore)
	fingerprint      string
	restored         bool
	sections         []string
	messages_guarded int
}

// PromptGate is the door every model call passes through, or it does not
// happen.
//
// dispatch() guarantees, mechanically and without coercion:
//  1. messages[0] is a system message,
//  2. its content carries the sealed prompt for the requested name,
//     byte-for-byte, at the front,
//  3. dynamic context is composed beneath it by the CoherenceComposer,
//  4. if the prompt is missing or shadowed it is re-seated (an integrity
//     restore — recorded, never punished),
//  5. a prompt.dispatch lineage event is sealed — the audit trail of
//     exactly which prompt and which context the model saw.
@[heap]
pub struct PromptGate {
pub mut:
	log          &EventLog
	vault        &PromptVault
	composer     CoherenceComposer
	dispatches   int
	restorations int
}

pub fn new_prompt_gate(log &EventLog, vault &PromptVault) &PromptGate {
	return &PromptGate{
		log:   unsafe { log }
		vault: unsafe { vault }
	}
}

// dispatch guards a message list for the model.
//
// `sections` is live context ({'goal': …, 'memory': …}); it is composed
// beneath the sealed prompt, framed as input to it. `compose_sections` set
// to false leaves an intact system message untouched, which is how a caller
// says "I have no context to add this turn".
pub fn (mut g PromptGate) dispatch(prompt_name string, mut messages []Message, sections map[string]string, compose_sections bool) !GateReport {
	sealed := g.vault.resolve(prompt_name)!
	mut report := GateReport{
		prompt:      prompt_name
		fingerprint: g.vault.fp(prompt_name)
	}

	has_system := messages.len > 0 && messages[0].role == 'system'
	current_text := if has_system { messages[0].text() } else { '' }
	prefix_intact := has_system && g.vault.verify(prompt_name, current_text)

	mut desired := sealed
	if compose_sections {
		desired = g.composer.compose(sealed, sections)
		report.sections = g.composer.manifest(sections)
	}
	if current_text != desired || !has_system {
		messages = with_system(mut messages, desired)
		if !prefix_intact {
			report.restored = true
			g.restorations++
		}
	}

	g.dispatches++
	report.messages_guarded = messages.len
	g.log.append('prompt.dispatch', {
		'prompt':      json2.Any(prompt_name)
		'fingerprint': json2.Any(report.fingerprint)
		'restored':    json2.Any(report.restored)
		'sections':    json2.Any(strs_to_any(report.sections))
		'messages':    json2.Any(messages.len)
	}, AppendOpts{ actor: 'kernel' })
	return report
}

// ---------------------------------------------------------------------------
// Mastermind — vault + gate + composer, assembled over one EventLog
// ---------------------------------------------------------------------------

pub struct MastermindState {
pub mut:
	sealed         []Rec
	dispatches     int
	restorations   int
	section_counts map[string]int
}

@[heap]
pub struct Mastermind {
pub mut:
	log      &EventLog
	vault    &PromptVault
	composer CoherenceComposer
	gate     &PromptGate
}

pub fn new_mastermind(log &EventLog) &Mastermind {
	vault := new_prompt_vault(log)
	return &Mastermind{
		log:   unsafe { log }
		vault: vault
		gate:  new_prompt_gate(log, vault)
	}
}

// status returns live counts from the fold — the observation ledger.
pub fn (mut m Mastermind) status() MastermindState {
	st := fold(mut m.log, '')
	mut counts := map[string]int{}
	mut restorations := 0
	for d in st.prompt_dispatches {
		for s in jstrs(d, 'sections') {
			counts[s] = (counts[s] or { 0 }) + 1
		}
		if jbool(d, 'restored') {
			restorations++
		}
	}
	return MastermindState{
		sealed:         st.prompt_sealed
		dispatches:     st.prompt_dispatches.len
		restorations:   restorations
		section_counts: counts
	}
}

pub fn (mut m Mastermind) format_status() string {
	s := m.status()
	mut lines := ['MASTERMIND — the coherence ledger',
		'  dispatches ${s.dispatches}   integrity restorations ${s.restorations}',
		'  sealed prompts:']
	for p in s.sealed {
		name := if jstr(p, 'name') != '' { jstr(p, 'name') } else { '?' }
		fpx := if jstr(p, 'fingerprint') != '' { jstr(p, 'fingerprint') } else { '?' }
		chars := thousands(jint(p, 'chars'))
		lines << '    ${pad_right(name, 16)} ${fpx}  ${pad_left(chars, 8)} chars'
	}
	if s.section_counts.len > 0 {
		mut keys := s.section_counts.keys()
		keys.sort()
		mut bits := []string{}
		for k in keys {
			bits << '${k}×${s.section_counts[k]}'
		}
		lines << '  context composed: ' + bits.join('  ')
	}
	lines << '  the model only ever sees a sealed prompt with coherent ' +
		'context composed beneath it — the gate is the single door; ' +
		'nothing forces, everything coheres.'
	return lines.join('\n')
}

// pad_left right-aligns `s` in a field of `width`, matching Python's `{:>n}`.
fn pad_left(s string, width int) string {
	n := s.runes().len
	return if n >= width { s } else { ' '.repeat(width - n) + s }
}
