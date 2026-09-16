module vagent

import x.json2

// council.v — multi-agent adversarial debate.
//
// For high-stakes decisions, one opinion is not enough. The council convenes
// a structured debate over a question:
//
//   * THESIS      — argues FOR the proposition.
//   * ANTITHESIS  — argues AGAINST it, and must attack the thesis's weakest
//                   point rather than just restate a contrary view.
//   * SYNTHESIS   — a blind judge: it sees ONLY the two arguments, never the
//                   question's framing, never the speakers' identities, and
//                   decides on argument strength alone. Blind review is the
//                   point — a judge that sees the defence is not a judge.
//
// The verdict is sealed as council.verdict with the winning side, the
// deciding reason and a confidence score. Positions are sealed as
// council.position, so every debate is replayable and auditable.
//
// The speaker is injectable: in the agent it is bound to a model call through
// the mastermind gate, and in the tests it is a script. The council itself is
// deterministic orchestration — the two positions run one at a time, and the
// synthesis brief is built mechanically from them and carries no other
// context, so the blindness is structural rather than a matter of trust.

pub const council_roles = ['thesis', 'antithesis']
pub const max_position_chars = 1200

const thesis_brief = 'You are the THESIS in a structured debate. Argue FOR the proposition ' + 'below. Make the strongest honest case: concrete evidence, mechanisms, ' + 'trade-offs in your favour. <= 150 words. End with a line exactly:\n' + 'STRONGEST POINT: <one sentence>'

const antithesis_brief = 'You are the ANTITHESIS in a structured debate. Argue AGAINST the ' + 'proposition below AND attack the strongest argument FOR it. Concrete ' + 'risks, failure modes, costs. <= 150 words. End with a line exactly:\n' + 'STRONGEST POINT: <one sentence>'

const synthesis_brief_head = 'You are a BLIND JUDGE in a debate. You see only two anonymised ' + 'arguments — you do not know the question\x27s framing or who wrote ' + 'what. Decide purely on argument strength: evidence, specificity, ' + 'and how well each side rebuts the other.\n\n'

const synthesis_brief_tail = 'Reply in EXACTLY this form:\n' + 'WINNER: A | B | DRAW\n' + 'CONFIDENCE: <0-100>%\n' + 'REASON: <one or two sentences>'

fn synthesis_brief(thesis string, antithesis string) string {
	return synthesis_brief_head + 'ARGUMENT A:\n${thesis}\n\nARGUMENT B:\n${antithesis}\n\n' + synthesis_brief_tail
}

// -- records ------------------------------------------------------------------

pub struct Position {
pub mut:
	role            string
	text            string
	strongest_point string
	ok              bool = true
	error           string
}

pub struct CouncilVerdict {
pub mut:
	question string
	// thesis | antithesis | draw, or empty when the debate never happened
	winner     string
	confidence f64
	reason     string
	positions  map[string]string
	ok         bool = true
	error      string
}

pub fn (v &CouncilVerdict) to_json() map[string]json2.Any {
	mut pos := map[string]json2.Any{}
	for role, text in v.positions {
		pos[role] = json2.Any(clip_plain(text, max_position_chars))
	}
	return {
		'question':   json2.Any(clip_plain(v.question, 300))
		'winner':     json2.Any(v.winner)
		'confidence': json2.Any(round_to(v.confidence, 1))
		'reason':     json2.Any(clip_plain(v.reason, 300))
		'positions':  json2.Any(pos)
		'ok':         json2.Any(v.ok)
		'error':      json2.Any(clip_plain(v.error, 200))
	}
}

fn strongest_point(text string) string {
	re := compile_regex(r'(?i)strongest point:\s*(.+)') or { return '' }
	m := re.search(text) or { return '' }
	return group_text(text, &m, 1).trim_space()
}

// parse_synthesis reads the judge's reply as (winner A|B|DRAW, confidence,
// reason).
//
// A missing or unparseable confidence is 0, not 50. The earlier default of a
// coin-flip meant a judge that ignored the reply format had its verdict
// trusted at exactly the bar of "no information at all" — which is the one
// number that reads as an honest tie. Unknown is not 50/50: the verdict is
// still recorded, and the caller can see there is no signal behind it.
pub fn parse_synthesis(text string) (string, f64, string) {
	winner_re := compile_regex(r'(?i)winner:\s*(A|B|DRAW)') or { return 'DRAW', 0.0, '' }
	conf_re := compile_regex(r'(?i)confidence:\s*(\d+(?:\.\d+)?)\s*%') or {
		return 'DRAW', 0.0, ''
	}
	reason_re := compile_regex(r'(?is)reason:\s*(.+)') or { return 'DRAW', 0.0, '' }

	mut winner := 'DRAW'
	if m := winner_re.search(text) {
		winner = group_text(text, &m, 1).to_upper()
	}
	mut conf := 0.0
	if m := conf_re.search(text) {
		conf = group_text(text, &m, 1).f64()
	}
	mut reason := ''
	if m := reason_re.search(text) {
		reason = group_text(text, &m, 1).trim_space()
	}
	return winner, min_f64(100.0, max_f64(0.0, conf)), clip_plain(reason, 300)
}

// -- the council --------------------------------------------------------------

// CouncilSpeaker produces one position. An error is a silent speaker, which
// the council handles rather than propagates.
pub type CouncilSpeaker = fn (role string, brief string) !string

@[heap]
pub struct Council {
pub mut:
	log     &EventLog
	speaker CouncilSpeaker = unsafe { nil }
	timeout f64            = 120.0
}

pub fn new_council(log &EventLog, speaker CouncilSpeaker) &Council {
	return &Council{
		log:     unsafe { log }
		speaker: speaker
	}
}

// new_silent_council is a council with no speaker attached — it can be
// convened, and says so honestly instead of inventing a verdict.
pub fn new_silent_council(log &EventLog) &Council {
	return &Council{
		log: unsafe { log }
	}
}

// convene runs one full debate: thesis, then antithesis, then the blind
// synthesis. It never fails outward — a failure lands in the verdict.
pub fn (mut c Council) convene(question string) CouncilVerdict {
	council_id := 'council-${c.log.head(c.log.branch) + 1}'
	c.log.append('council.convened', {
		'council_id': json2.Any(council_id)
		'question':   json2.Any(clip_plain(question, 300))
	}, AppendOpts{ actor: 'council' })

	mut verdict := CouncilVerdict{
		question: question
	}
	if c.speaker == unsafe { nil } {
		verdict.ok = false
		verdict.error = 'no speaker attached'
		c.seal_verdict(council_id, verdict)
		return verdict
	}

	briefs := {
		'thesis':     '${thesis_brief}\n\nPROPOSITION: ${question}'
		'antithesis': '${antithesis_brief}\n\nPROPOSITION: ${question}'
	}
	mut positions := []Position{}
	for role in council_roles {
		positions << c.speak(role, briefs[role] or { '' })
	}

	for p in positions {
		c.log.append('council.position', {
			'council_id':      json2.Any(council_id)
			'role':            json2.Any(p.role)
			'text':            json2.Any(clip_plain(p.text, max_position_chars))
			'strongest_point': json2.Any(p.strongest_point)
			'ok':              json2.Any(p.ok)
			'error':           json2.Any(p.error)
		}, AppendOpts{ actor: 'council:${p.role}' })
		if p.ok {
			verdict.positions[p.role] = p.text
		}
	}

	failed := positions.filter(!it.ok)
	if failed.len == council_roles.len {
		verdict.ok = false
		verdict.error = failed.map('${it.role}: ${it.error}').join('; ')
		c.seal_verdict(council_id, verdict)
		return verdict
	}
	if failed.len == 1 {
		// one side silent — the other wins by default, at low confidence
		for p in positions {
			if p.ok {
				verdict.winner = p.role
				break
			}
		}
		verdict.confidence = 30.0
		verdict.reason = '${failed[0].role} failed (${failed[0].error}); ' + 'default to the side that argued'
		c.seal_verdict(council_id, verdict)
		return verdict
	}

	// blind synthesis: only the two arguments, anonymised as A and B
	brief := synthesis_brief(verdict.positions['thesis'] or { '' }, verdict.positions['antithesis'] or {
		''
	})
	raw := c.speaker('synthesis', brief) or {
		verdict.ok = false
		verdict.error = 'synthesis failed: ${err.msg()}'
		c.seal_verdict(council_id, verdict)
		return verdict
	}

	side, conf, reason := parse_synthesis(raw)
	verdict.winner = match side {
		'A' { 'thesis' }
		'B' { 'antithesis' }
		else { 'draw' }
	}
	verdict.confidence = conf
	verdict.reason = reason
	c.seal_verdict(council_id, verdict)
	return verdict
}

fn (mut c Council) speak(role string, brief string) Position {
	text := c.speaker(role, brief) or {
		return Position{
			role:  role
			ok:    false
			error: err.msg()
		}
	}
	body := text.trim_space()
	if body == '' {
		return Position{
			role:  role
			ok:    false
			error: 'empty position'
		}
	}
	return Position{
		role:            role
		text:            clip_plain(body, max_position_chars)
		strongest_point: strongest_point(body)
	}
}

fn (mut c Council) seal_verdict(council_id string, verdict CouncilVerdict) {
	mut d := verdict.to_json()
	d['council_id'] = json2.Any(council_id)
	c.log.append('council.verdict', d, AppendOpts{ actor: 'council' })
}

// -- projections --------------------------------------------------------------

pub fn (mut c Council) verdicts() []Rec {
	st := fold(mut c.log, c.log.branch)
	return st.council_events.filter(jstr(it, 'type') == 'council.verdict')
}

pub fn (mut c Council) format_status() string {
	vs := c.verdicts()
	mut lines := [
		'COUNCIL — adversarial debate',
		'  debates decided: ${vs.len}',
	]
	mut tail := vs.clone()
	if tail.len > 6 {
		tail = tail[tail.len - 6..].clone()
	}
	for v in tail {
		lines << '    ' + pad_width(jstr(v, 'winner'), 11) + ' conf ${jf64(v, 'confidence'):.0f}%  ' + clip_plain(jstr(v, 'question'), 48)
	}
	return lines.join('\n')
}
