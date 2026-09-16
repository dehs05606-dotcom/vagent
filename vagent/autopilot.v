module vagent

import os
import x.json2

// autopilot.v — the self-enabling routing brain.
//
// The agent decides FOR ITSELF, before every turn, which powers the task
// needs — and enables them on its own:
//
//   * GOAL MODE      — the request is a verifiable mission ("fix", "add",
//                      "make X pass") -> auto-draft a machine-checkable
//                      goal contract.
//   * REAL-TIME WEB  — the request needs live data ("latest", "today",
//                      "current", prices, news) -> steer the turn to use
//                      web_search for real-time facts.
//
// Routing is deterministic (rung 1-2 of the Determinism Ladder): fast, free
// and explainable. Every decision is logged as an 'autopilot.route' event
// and surfaced in the TUI, so nothing the agent enables is ever hidden
// (axiom A7).

const web_triggers = ['latest', 'today', 'current', 'right now', 'real time',
	'real-time', 'news', 'headline', 'price', 'stock', 'weather', 'score',
	'release', 'version', 'who won', 'update on', 'breaking', 'live', 'now',
	'aaj', 'abhi', 'taaza', 'naya', 'sabse naya', 'rate', 'exchange']

const goal_verbs = ['fix', 'implement', 'add', 'create', 'build', 'make',
	'ensure', 'refactor', 'write', 'develop', 'set up', 'setup', 'migrate',
	'convert', 'optimize', 'optimise', 'banao', 'thik karo', 'likho']

const question_starters = ['what', 'why', 'how', 'when', 'where', 'who',
	'which', 'is ', 'are ', 'do ', 'does ', 'can ', 'kya', 'kaun', 'kab',
	'kahan', 'kyu', 'kaise']

// word_boundary_hits finds which of `terms` appear in `low` as whole words,
// so "fix" never fires inside "suffix", "add" inside "address", or "rate"
// inside "generate".
fn word_boundary_hits(low string, terms []string) []string {
	mut hits := []string{}
	for term in terms {
		if has_word(low, term) {
			hits << term
		}
	}
	return hits
}

fn is_word_byte(c u8) bool {
	return (c >= `a` && c <= `z`) || (c >= `A` && c <= `Z`) || (c >= `0` && c <= `9`)
		|| c == `_`
}

// has_word reports whether `term` occurs in `text` bounded by non-word
// characters on both sides. A multi-word term ("set up") is bounded the
// same way at its outer edges.
fn has_word(text string, term string) bool {
	if term == '' {
		return false
	}
	mut from := 0
	for {
		idx := text.index_after(term, from) or { return false }
		before_ok := idx == 0 || !is_word_byte(text[idx - 1])
		after := idx + term.len
		after_ok := after >= text.len || !is_word_byte(text[after])
		if before_ok && after_ok {
			return true
		}
		from = idx + 1
	}
	return false
}

// RouteDecision is what the AutoPilot enabled for this turn, and why.
pub struct RouteDecision {
pub mut:
	suggest_goal   bool
	goal_statement string
	goal_clauses   []Rec
	use_web        bool
	reasons        []string
}

pub fn (d &RouteDecision) active() bool {
	return d.suggest_goal || d.use_web
}

pub fn (d &RouteDecision) summary() string {
	mut bits := []string{}
	if d.suggest_goal {
		bits << '⚡ goal mode: ${d.goal_clauses.len} clause(s) auto-drafted'
	}
	if d.use_web {
		bits << '⚡ real-time web mode'
	}
	return bits.join('  ·  ')
}

// AutoPilot is a deterministic pre-turn router. It never calls a model.
pub struct AutoPilot {
pub mut:
	log     &EventLog
	enabled bool = true
}

pub fn new_autopilot(log &EventLog, enabled bool) AutoPilot {
	return AutoPilot{
		log:     unsafe { log }
		enabled: enabled
	}
}

// route inspects the user message and decides what to enable.
pub fn (mut a AutoPilot) route(text string, goal_active bool, autonomy int) RouteDecision {
	mut d := RouteDecision{}
	if !a.enabled || text.trim_space() == '' {
		return d
	}
	low := text.to_lower()
	trimmed := text.trim_space()
	mut is_question := trimmed.ends_with('?')
	if !is_question {
		for starter in question_starters {
			if low.starts_with(starter) {
				is_question = true
				break
			}
		}
	}

	// 1. real-time web — questions about live data
	hits := word_boundary_hits(low, web_triggers)
	if hits.len > 0 {
		d.use_web = true
		shown := if hits.len > 3 { hits[..3] } else { hits }
		d.reasons << "real-time web: live-data trigger(s) '" + shown.join("', '") + "'"
	}

	// 2. goal mode — a verifiable mission, not a question
	if !goal_active && !is_question {
		if word_boundary_hits(low, goal_verbs).len > 0 {
			d.suggest_goal = true
			d.goal_statement = clip_plain(trimmed, 100)
			d.goal_clauses = draft_clauses(text)
			d.reasons << 'goal mode: mission verb detected, ' +
				'${d.goal_clauses.len} clause(s) drafted'
		}
	}

	if d.active() {
		a.log.append('autopilot.route', {
			'suggest_goal': json2.Any(d.suggest_goal)
			'use_web':      json2.Any(d.use_web)
			'reasons':      json2.Any(strs_to_any(d.reasons))
		}, AppendOpts{ actor: 'system' })
	}
	return d
}

// draft_clauses derives machine-checkable clauses from the request itself.
//
// Only predicates that can actually be constructed are added; anything else
// becomes an advisory clause a human can prove. A goal that cannot be failed
// is not a goal — so this always tries for a real predicate first.
fn draft_clauses(text string) []Rec {
	low := text.to_lower()
	mut clauses := []Rec{}

	// tests mentioned -> find the real test command on disk (rung 3)
	if low.contains('test') || low.contains('pytest') || low.contains('suite') {
		cmd := detect_test_command()
		if cmd != '' {
			clauses << Rec({
				'text':   json2.Any('test suite passes')
				'weight': json2.Any(1.0)
				'proof':  json2.Any({
					'type':    json2.Any('exit_code')
					'command': json2.Any(cmd)
					'expect':  json2.Any(0)
				})
			})
		}
	}

	// explicit paths mentioned -> they must exist when done
	if re := compile_regex(r'(?:^|\s)([./~][\w./~-]+\.\w{1,6})') {
		mut n := 0
		for m in re.find_all(text) {
			if n >= 2 {
				break
			}
			p := group_text(text, &m, 1)
			clauses << Rec({
				'text':   json2.Any('artifact exists: ${p}')
				'weight': json2.Any(1.0)
				'proof':  json2.Any({
					'type': json2.Any('file_exists')
					'path': json2.Any(p)
				})
			})
			n++
		}
	}

	if clauses.len == 0 {
		// nothing machine-checkable could be derived — an advisory clause,
		// provable by the human or by a later /goal prove
		clauses << Rec({
			'text':     json2.Any(clip_plain(text.trim_space(), 80))
			'weight':   json2.Any(1.0)
			'advisory': json2.Any(true)
		})
	}
	// normalise ids
	for i, mut c in clauses {
		c['id'] = 'C${i + 1}'
	}
	return clauses
}

// detect_test_command probes the cwd for a real test runner (deterministic,
// rung 3).
fn detect_test_command() string {
	cwd := os.getwd()
	if os.exists(os.join_path(cwd, 'v.mod')) {
		return 'v test .'
	}
	if os.exists(os.join_path(cwd, 'pytest.ini')) || os.exists(os.join_path(cwd, 'pyproject.toml'))
		|| os.is_dir(os.join_path(cwd, 'tests')) || os.is_dir(os.join_path(cwd, 'test')) {
		return 'python -m pytest -q'
	}
	for name in os.ls(cwd) or { [] } {
		if name.starts_with('test_') && name.ends_with('.py') {
			return 'python -m pytest -q'
		}
		if name.ends_with('_test.py') {
			return 'python -m pytest -q'
		}
	}
	if os.exists(os.join_path(cwd, 'package.json')) {
		return 'npm test'
	}
	return ''
}
