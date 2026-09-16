module vagent

import x.json2

// distill.v — proposing rules for the clauses that enforce nothing.
//
// audit.v reports the number and it is always the same shape: a specification
// of several hundred clauses, of which a handful carry an @enforce or @output
// rule and the rest are prose. The prose clauses are not idle — they are what
// the author actually wrote, and they are why the specification is 150k
// characters — but to every mechanism in this package they are invisible.
// They cannot refuse an action, cannot check a reply, and cannot be measured
// by adherence.v, which reports them as UNSCORABLE rather than counting them
// as followed.
//
// Writing a rule for each one by hand is the correct fix and nobody does it,
// because there are four hundred of them. So this reads the prose and
// proposes the rule it implies:
//
//     "Secrets never appear in source."
//         -> @enforce forbid_content: (?i)(api[_-]?key|token|password)\s*=
//
//     "Writes stay under src/ and tests/."
//         -> @enforce confine_paths: src, tests
//
//     "Every module ships with a test."
//         -> @oblige on write **/*.py require exists tests/test_{stem}.py
//
// It PROPOSES. Nothing here edits the specification, and nothing it produces
// is enforced until the author pastes it in. That restraint is the whole
// design, not caution for its own sake:
//
//   * An inferred rule that is too broad refuses legitimate work, and an
//     operator's fix for a boundary that blocks real work is to switch the
//     boundary off — so a wrong guess does not cost one clause, it costs the
//     whole mechanism's credibility.
//   * An inferred rule that is too narrow is worse, because it REPORTS as
//     enforced. The author reads "247 clauses enforced" and believes a
//     guarantee that does not exist, which is the precise failure this
//     package was built to remove.
//
// So every proposal carries the clause it came from, the sentence that
// triggered it, and a confidence, and the output is a patch to read rather
// than a change to apply.
//
// Confidence is what the PATTERN earned, not what the rule is worth:
//     high    an unambiguous prohibition with a concrete object
//     medium  a clear directive whose object had to be generalised
//     low     a plausible reading that needs the author's eye
//
// Nothing above "low" is guessed at from a verb alone.

pub const confidence_high = 'high'
pub const confidence_medium = 'medium'
pub const confidence_low = 'low'

fn confidence_order(c string) int {
	return match c {
		confidence_high { 0 }
		confidence_medium { 1 }
		else { 2 }
	}
}

pub struct Proposal {
pub:
	clause string
	// the @enforce / @output / @oblige line to paste
	line       string
	confidence string
	// the sentence it was read from
	because string
	note    string
}

pub fn (p &Proposal) to_json() map[string]json2.Any {
	return {
		'clause':     json2.Any(p.clause)
		'line':       json2.Any(p.line)
		'confidence': json2.Any(p.confidence)
		'because':    json2.Any(p.because)
		'note':       json2.Any(p.note)
	}
}

// -- the readings -------------------------------------------------------------
//
// Each pattern reads one shape of sentence. They are deliberately narrow:
// a verb alone is never enough, because "the agent should be careful about
// deletion" is not a prohibition and a rule that treats it as one refuses
// work the author never meant to forbid.

const neg_verb = r"(?:never|must not|must never|do not|don't|no\b|cannot|shall not)"
const pos_verb = r'(?:always|must|shall|should|has to|have to)'
const secret_word = r'(?:secret|credential|api[_ -]?key|token|password|passphrase)'

// "secrets never appear in source" / "never commit credentials"
const r_secret = r'(?i)\b' + secret_word + r's?\b[^.]*\b' + neg_verb + r'\b|\b' + neg_verb + r'\b[^.]*\b' + secret_word + r's?\b'

// "writes stay under src/ and tests/" / "work only in src"
const r_confine = r'(?i)\b(?:writes?|work|changes?|edits?|files?)\b[^.]*?\b(?:stay|remain|live|confined|only)\b[^.]*?\b(?:under|in|within|inside)\s+([\w./*-]+(?:\s*(?:,|and|or)\s*[\w./*-]+)*)'

// "never delete" / "nothing is ever deleted"
const r_delete = r'(?i)\b' + neg_verb + r'\b[^.]*\b(?:delete|remove|rm|erase)\b|\b(?:nothing|no file)\b[^.]*\bever\s+(?:deleted|removed)\b'

// "never run destructive shell commands" / "no rm -rf"
const r_destructive = r'(?i)\b' + neg_verb + r'\b[^.]*\b(?:rm\s+-rf|force[- ]push|drop\s+table|destructive)\b'

// "every module ships with a test" / "each .py file has a test"
const r_oblige_test = r'(?i)\b(?:every|each|all)\b[^.]*\b(?:module|file|source file)\b[^.]*\b(?:ships? with|has|have|needs?|requires?|comes? with)\b[^.]*\btests?\b'

// "every public function carries a docstring"
const r_docstring = r'(?i)\b(?:every|each|all)\b[^.]*\b(?:function|module|class)\b[^.]*\b(?:carr(?:y|ies)|has|have|needs?|requires?)\b[^.]*\bdocstring\b'

// "never claim a test passed without the exit code"
const r_exitcode = r'(?i)\b' + neg_verb + r'\b[^.]*\b(?:claim|say|state|report)\b[^.]*\b(?:test|pass)\w*|\btests?\b[^.]*\breported?\b[^.]*\bexit code\b'

// "cite file:line" / "always reference the file and line"
const r_cite = r'(?i)\b(?:cite|reference|quote)\b[^.]*\b(?:file:?line|file and line|path and line)\b|\b' + pos_verb + r'\b[^.]*\bcite\b'

// "the agent reaches only <hosts>" / "network access only to X".
// The verbs take their inflections: reaches, contacts, connects to.
const r_hosts = r'(?i)\b(?:reach\w*|contact\w*|connect\w*|network access|fetch\w*)\b[^.]*?\bonly\b[^.]*?([\w-]+\.[\w.]{2,}(?:\s*(?:,|and)\s*[\w-]+\.[\w.]{2,})*)'

// split_roots reads "src/, tests and docs" as three roots.
fn split_roots(raw string) []string {
	mut parts := []string{}
	mut cur := []u8{}
	mut i := 0
	for i < raw.len {
		c := raw[i]
		if c == `,` {
			parts << cur.bytestr()
			cur = []u8{}
			i++
			continue
		}
		// `and` / `or` only count as separators when they stand alone
		if is_word_at(raw, i, 'and') || is_word_at(raw, i, 'or') {
			word_len := if is_word_at(raw, i, 'and') { 3 } else { 2 }
			parts << cur.bytestr()
			cur = []u8{}
			i += word_len
			continue
		}
		cur << c
		i++
	}
	parts << cur.bytestr()

	mut out := []string{}
	for p in parts {
		text := p.trim_space().trim_right('/')
		if text == '' || text in ['the', 'a', 'an'] {
			continue
		}
		out << text
	}
	return out
}

fn is_word_at(s string, i int, word string) bool {
	if i + word.len > s.len || s[i..i + word.len] != word {
		return false
	}
	if i > 0 && is_word_byte(s[i - 1]) {
		return false
	}
	if i + word.len < s.len && is_word_byte(s[i + word.len]) {
		return false
	}
	return true
}

fn matches(pattern string, s string) bool {
	re := compile_regex(pattern) or { return false }
	if _ := re.search(s) {
		return true
	}
	return false
}

fn first_group(pattern string, s string) string {
	re := compile_regex(pattern) or { return '' }
	m := re.search(s) or { return '' }
	return group_text(s, &m, 1)
}

// read_sentence is every rule this one sentence plausibly implies.
pub fn read_sentence(clause_id string, sentence string) []Proposal {
	s := sentence.trim_space()
	if s.len < 12 {
		return []
	}
	mut out := []Proposal{}

	if matches(r_secret, s) {
		out << Proposal{
			clause:     clause_id
			line:       '@enforce forbid_content: (?i)(api[_-]?key|token|password|secret)' + '\\s*=\\s*["\x27][A-Za-z0-9]'
			confidence: confidence_high
			because:    s
			note:       'matches a literal assignment; widen it if your secrets appear in other shapes'
		}
	}

	roots := split_roots(first_group(r_confine, s))
	if roots.len > 0 {
		out << Proposal{
			clause:     clause_id
			line:       '@enforce confine_paths: ' + roots.join(', ')
			confidence: if roots.len <= 3 { confidence_high } else { confidence_medium }
			because:    s
			note:       'confine_paths refuses every write and delete outside these roots, by any route'
		}
	}

	if matches(r_delete, s) {
		out << Proposal{
			clause:     clause_id
			line:       '@enforce forbid_effect: delete'
			confidence: confidence_high
			because:    s
			note:       'refuses deletion by any route, including rm and mv'
		}
	}

	if matches(r_destructive, s) {
		out << Proposal{
			clause:     clause_id
			line:       '@enforce forbid_command: (?i)(rm\\s+-rf\\s+/|push\\s+--force|drop\\s+table)'
			confidence: confidence_medium
			because:    s
			note:       'matches the command text; list the exact forms you mean'
		}
	}

	if matches(r_oblige_test, s) {
		out << Proposal{
			clause:     clause_id
			line:       '@oblige on write src/**/*.py require exists tests/test_{stem}.py'
			confidence: confidence_medium
			because:    s
			note:       "adjust the paths to your layout; this blocks 'done', not work"
		}
	}

	if matches(r_docstring, s) {
		out << Proposal{
			clause:     clause_id
			line:       '@enforce {"kind": "require_content", "value": "^\\\\s*[\\"\x27]{3}", "where": "*.py"}'
			confidence: confidence_medium
			because:    s
			note:       'checks the written content of .py files only'
		}
	}

	if matches(r_exitcode, s) {
		out << Proposal{
			clause:     clause_id
			line:       '@output forbid (?i)tests? (pass|fail)\\w*(?![^.]*exit)'
			confidence: confidence_high
			because:    s
			note:       'checks the reply, and a failing draft is regenerated'
		}
	}

	if matches(r_cite, s) {
		out << Proposal{
			clause:     clause_id
			line:       '@output require \\S+:\\d+   when   (?i)\\b(edited|changed|wrote|updated)\\b'
			confidence: confidence_medium
			because:    s
			note:       'armed only for replies that describe a change'
		}
	}

	hosts := split_roots(first_group(r_hosts, s))
	if hosts.len > 0 {
		out << Proposal{
			clause:     clause_id
			line:       '@egress allow_hosts ' + hosts.join(', ')
			confidence: confidence_high
			because:    s
			note:       'an allowlist: every host not named is refused, including ones ' + 'that cannot be read before the command runs'
		}
	}
	return out
}

// sentences splits a clause body into sentences, skipping its own rule lines.
pub fn sentences(text string) []string {
	rule_re := compile_regex(r'(?i)^\s*@(enforce|output|oblige|horizon|ration|egress|sequence|origin|except|authority)\b') or {
		return []
	}
	mut out := []string{}
	for line in split_lines(text) {
		if _ := rule_re.search(line) {
			continue
		}
		for part in split_sentences(line) {
			trimmed := part.trim_space()
			if trimmed != '' {
				out << trimmed
			}
		}
	}
	return out
}

// split_sentences breaks after a `.`, `!` or `?` that is followed by
// whitespace — the lookbehind the original used, written out.
fn split_sentences(line string) []string {
	mut out := []string{}
	mut start := 0
	mut i := 0
	for i < line.len {
		c := line[i]
		if c == `.` || c == `!` || c == `?` {
			mut j := i + 1
			for j < line.len && is_space_byte(line[j]) {
				j++
			}
			if j > i + 1 {
				out << line[start..i + 1]
				start = j
				i = j
				continue
			}
		}
		i++
	}
	if start < line.len {
		out << line[start..]
	}
	return out
}

fn is_space_byte(c u8) bool {
	return c == ` ` || c == `\t` || c == `\n` || c == `\r`
}

// distill is the proposals for a specification's clauses.
//
// It defaults to the clauses that carry no rule. Proposing a rule for a
// clause that already has one invites the author to add a second, subtly
// different one, and two rules for a clause is how a specification starts
// contradicting itself.
pub fn distill(clauses []Clause, only_unenforced bool) []Proposal {
	mut out := []Proposal{}
	mut seen := map[string]bool{}
	for c in clauses {
		if only_unenforced && c.enforced() {
			continue
		}
		body := c.title + '\n' + c.body
		for s in sentences(body) {
			for p in read_sentence(c.id, s) {
				key := '${p.clause}\x00${p.line}'
				if seen[key] {
					continue
				}
				seen[key] = true
				out << p
			}
		}
	}
	// strongest readings first, then by clause; the discovery index breaks
	// a full tie so two runs over one specification agree exactly
	mut indexed := []IndexedProposal{}
	for i, p in out {
		indexed << IndexedProposal{
			proposal: p
			index:    i
		}
	}
	indexed.sort_with_compare(fn (a &IndexedProposal, b &IndexedProposal) int {
		oa := confidence_order(a.proposal.confidence)
		ob := confidence_order(b.proposal.confidence)
		if oa != ob {
			return oa - ob
		}
		if a.proposal.clause != b.proposal.clause {
			return if a.proposal.clause < b.proposal.clause { -1 } else { 1 }
		}
		return a.index - b.index
	})
	return indexed.map(it.proposal)
}

struct IndexedProposal {
	proposal Proposal
	index    int
}

// patch is the proposals as text to paste into the specification.
pub fn patch(proposals []Proposal, minimum string) string {
	keep := proposals.filter(confidence_order(it.confidence) <= confidence_order(minimum))
	if keep.len == 0 {
		return ''
	}
	mut lines := [
		'# Proposed rules — read each one, then paste the ones you want',
		'# into the matching clause in systemprompt.py. Nothing here is',
		'# in force until you do.',
		'',
	]
	mut current := ''
	for p in keep {
		if p.clause != current {
			lines << '# --- clause ${p.clause} ' + '-'.repeat(44)
			current = p.clause
		}
		lines << '#   because: ' + clip_plain(p.because, 100)
		if p.note != '' {
			lines << '#   note   : ${p.note}'
		}
		lines << '#   [${p.confidence}]'
		lines << p.line
		lines << ''
	}
	return lines.join('\n')
}

// report counts what was NOT covered as well as what was — a module that
// only reported its hits would read as complete coverage of the prose.
pub fn distill_report(clauses []Clause, proposals []Proposal) string {
	if clauses.len == 0 {
		return 'distill: no specification is bound'
	}
	props := proposals
	unenforced := clauses.filter(!it.enforced())
	mut by_conf := map[string]int{}
	mut covered := map[string]bool{}
	for p in props {
		by_conf[p.confidence] = by_conf[p.confidence] + 1
		covered[p.clause] = true
	}
	mut keys := by_conf.keys()
	keys.sort()
	breakdown := keys.map('${it}:${by_conf[it]}').join(', ')
	summary := if breakdown != '' { breakdown } else { 'none' }
	return [
		'distill: ${unenforced.len} of ${clauses.len} clauses carry no rule',
		'  ${props.len} proposal(s) for ${covered.len} of them (${summary})',
		'  ${unenforced.len - covered.len} clause(s) yielded nothing — prose ' + 'this module cannot read into a rule',
		'  nothing is applied: run /distill patch to see the text',
	].join('\n')
}
