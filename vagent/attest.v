module vagent

import x.json2

// attest.v — the reply is a claim about the world, and claims are checkable.
//
// Everything upstream governs what the agent DOES. Nothing governs what it
// SAYS it did, and the reply is where a specification is most casually
// broken: "I ran the tests and they pass", "the file is updated", "I fixed
// the import" — sentences whose truth nobody checked, in the one artefact
// the user actually reads.
//
// This is not hypothetical. A model under length pressure, or one whose tool
// call failed three turns ago, reliably summarises the plan it intended
// rather than the events that occurred. The summary is fluent, confident and
// wrong, and it is wrong in exactly the direction that looks like success.
//
// The event log already knows. So a claim is not an opinion — it is a
// proposition about a record that exists, and each one gets a verdict:
//
//     SUPPORTED     the record backs it
//     CONTRADICTED  the record refutes it
//     UNSUPPORTED   nothing in the record speaks to it either way
//
// The distinction matters. CONTRADICTED is a false statement about a
// knowable fact. UNSUPPORTED is a statement the agent was not entitled to
// make, which is a different failure and deserves different handling.
//
// This module REPORTS. It does not rewrite the model's words, and nothing
// here is fed back into the prompt: a summary that silently edits what the
// agent said would make the transcript a worse record than the log it came
// from.

pub const claim_supported = 'supported'
pub const claim_contradicted = 'contradicted'
pub const claim_unsupported = 'unsupported'

// commands that constitute "running the tests"
const test_cmd_pattern = r'(?i)\b(pytest|py\.test|unittest|nose2|tox|jest|vitest|mocha|go\s+test|cargo\s+test|npm\s+(?:run\s+)?test|yarn\s+test|make\s+test|gradle\s+test|mvn\s+test|rspec|phpunit)\b'

const pass_pattern = r'(?i)\b(?:all\s+)?(?:the\s+)?(?:(\d+)\s+)?tests?\b[^.!\n]{0,40}?\b(pass(?:es|ed|ing)?|green|succeed(?:ed|s)?)\b'
const fail_pattern = r'(?i)\btests?\b[^.!\n]{0,30}?\b(fail(?:ed|s|ing)?)\b'

// "I ran `pytest -q`" is a claim about a command. "I ran the tests and they
// pass" is prose, and the tests_pass check already covers it — reading it as
// a command named "the tests and they pass" would manufacture a violation
// out of ordinary English. Backticks make it a command claim; bare text does
// so only when the first word could plausibly be a program.
const ran_backtick_pattern = r'(?i)\bI\s+(?:just\s+)?(?:ran|executed|invoked)\s+\x60([^\x60\n]{2,80})\x60'
const ran_bare_pattern = r'(?i)\bI\s+(?:just\s+)?(?:ran|executed|invoked)\s+([\w./\-]+)'

const not_a_command = ['the', 'a', 'an', 'all', 'it', 'them', 'this', 'that', 'these',
	'those', 'tests', 'test', 'suite', 'again', 'both', 'each', 'everything', 'some',
	'my', 'our', 'your', 'into', 'through', 'over']

const file_claim_pattern = r'(?i)\bI\s+(?:have\s+)?(created|wrote|written|added|updated|modified|edited|deleted|removed)\s+(?:the\s+)?(?:file\s+)?\x60?([\w./\-]+\.[A-Za-z0-9]{1,8})\x60?'

pub struct Claim {
pub:
	// tests_pass | ran_command | file_written | file_deleted
	kind string
	// the command, path or count the claim is about
	subject  string
	verdict  string
	evidence string
	quote    string
}

pub fn (c &Claim) to_json() map[string]json2.Any {
	return {
		'kind':     json2.Any(c.kind)
		'subject':  json2.Any(c.subject)
		'verdict':  json2.Any(c.verdict)
		'evidence': json2.Any(c.evidence)
		'quote':    json2.Any(clip_plain(c.quote, 200))
	}
}

pub struct Attestation {
pub:
	claims []Claim
}

pub fn (a &Attestation) contradicted() []Claim {
	return a.claims.filter(it.verdict == claim_contradicted)
}

pub fn (a &Attestation) unsupported() []Claim {
	return a.claims.filter(it.verdict == claim_unsupported)
}

pub fn (a &Attestation) clean() bool {
	return a.contradicted().len == 0 && a.unsupported().len == 0
}

pub fn (a &Attestation) report() string {
	if a.claims.len == 0 {
		return 'attest: the reply made no checkable claim'
	}
	mut lines := [
		'attest: ${a.claims.len} claim(s) · ${a.contradicted().len} contradicted · ${a.unsupported().len} unsupported',
	]
	for c in a.claims {
		mark := match c.verdict {
			claim_supported { '✓' }
			claim_contradicted { '✗' }
			else { '?' }
		}
		lines << '  ${mark} ' + pad_width(c.kind, 14) + ' ' +
			pad_width(clip_plain(c.subject, 40), 42) + ' ${c.evidence}'
	}
	return lines.join('\n')
}

struct RanCommand {
	command string
mut:
	result string
}

// Record is what the log actually says, folded once per attestation.
struct Record {
mut:
	commands   []RanCommand
	written    map[string]bool
	deleted    map[string]bool
	tool_calls []string
}

fn build_record(mut log EventLog) Record {
	mut rec := Record{}
	mut pending_command := ''
	mut has_pending := false
	for ev in log.events(log.branch) {
		if ev.typ == 'tool.call' {
			name := jstr(ev.data, 'name')
			args := jmap(ev.data, 'args')
			rec.tool_calls << name
			cmd := jstr(args, 'command')
			pending_command = cmd
			has_pending = true
			if cmd != '' {
				rec.commands << RanCommand{
					command: cmd
				}
			}
			for e in derive(name, args) {
				if e.kind == effect_write && e.path != '' {
					rec.written[path_tail(e.path)] = true
				} else if e.kind == effect_delete && e.path != '' {
					rec.deleted[path_tail(e.path)] = true
				}
			}
		} else if ev.typ == 'tool.result' && has_pending {
			result := jstr(ev.data, 'result')
			if pending_command != '' && rec.commands.len > 0
				&& rec.commands.last().command == pending_command {
				rec.commands[rec.commands.len - 1].result = result
			}
			has_pending = false
			pending_command = ''
		}
	}
	return rec
}

fn (r &Record) test_runs() []RanCommand {
	re := compile_regex(test_cmd_pattern) or { return [] }
	mut out := []RanCommand{}
	for c in r.commands {
		if _ := re.search(c.command) {
			out << c
		}
	}
	return out
}

// path_tail compares paths by their meaningful tail, so 'src/a.py' matches
// an absolute '/home/u/proj/src/a.py' without pretending to resolve either.
fn path_tail(path string) string {
	mut s := path.replace('\\', '/')
	for s.starts_with('.') || s.starts_with('/') {
		s = s[1..]
	}
	return s
}

fn mentions(haystack string, needle string) bool {
	a := path_tail(haystack)
	b := path_tail(needle)
	return a.ends_with(b) || b.ends_with(a)
}

// exit_ok reports whether a recorded result shows success. It returns none
// when the record does not say, which is not the same as failure.
fn exit_ok(result string) ?bool {
	if re := compile_regex(r'(?i)exit[_ ]?code[:= ]+(-?\d+)') {
		if m := re.search(result) {
			return group_text(result, &m, 1).int() == 0
		}
	}
	if re := compile_regex(r'\b\d+\s+failed\b|\bFAILED\b|\bERROR\b') {
		if _ := re.search(result) {
			return false
		}
	}
	if re := compile_regex(r'(?i)\b\d+\s+passed\b|\bOK\b|\ball tests? pass') {
		if _ := re.search(result) {
			return true
		}
	}
	return none
}

fn count_reported(result string) ?int {
	re := compile_regex(r'(?i)\b(\d+)\s+passed\b') or { return none }
	m := re.search(result) or { return none }
	return group_text(result, &m, 1).int()
}

// attest checks a reply's checkable claims against the sealed record.
pub fn attest(reply string, mut log EventLog) Attestation {
	mut rec := build_record(mut log)
	mut claims := []Claim{}
	text := reply

	// -- "the tests pass" ----------------------------------------------------
	if pass_re := compile_regex(pass_pattern) {
		for m in pass_re.find_all(text) {
			count := group_text(text, &m, 1)
			quote := group_text(text, &m, 0)
			runs := rec.test_runs()
			if runs.len == 0 {
				claims << Claim{
					kind:     'tests_pass'
					subject:  if count != '' { count } else { 'tests' }
					verdict:  claim_unsupported
					evidence: "no test command appears in this session's log"
					quote:    quote
				}
				continue
			}
			last := runs.last()
			ok := exit_ok(last.result) or {
				claims << Claim{
					kind:     'tests_pass'
					subject:  last.command
					verdict:  claim_unsupported
					evidence: '${last.command} ran but its result records no outcome'
					quote:    quote
				}
				continue
			}
			if !ok {
				claims << Claim{
					kind:     'tests_pass'
					subject:  last.command
					verdict:  claim_contradicted
					evidence: 'the run recorded a failure: ${last.command}'
					quote:    quote
				}
				continue
			}
			if count != '' {
				if reported := count_reported(last.result) {
					if reported != count.int() {
						claims << Claim{
							kind:     'tests_pass'
							subject:  count
							verdict:  claim_contradicted
							evidence: 'the run reported ${reported} passing, not ${count}'
							quote:    quote
						}
						continue
					}
				}
			}
			claims << Claim{
				kind:     'tests_pass'
				subject:  last.command
				verdict:  claim_supported
				evidence: '${last.command} passed'
				quote:    quote
			}
		}
	}

	if fail_re := compile_regex(fail_pattern) {
		for m in fail_re.find_all(text) {
			runs := rec.test_runs()
			if runs.len == 0 {
				continue
			}
			if ok := exit_ok(runs.last().result) {
				if ok {
					claims << Claim{
						kind:     'tests_pass'
						subject:  runs.last().command
						verdict:  claim_contradicted
						evidence: 'the recorded run passed'
						quote:    group_text(text, &m, 0)
					}
				}
			}
		}
	}

	// -- "I ran X" -----------------------------------------------------------
	mut said := []RanCommand{}
	mut quotes := []string{}
	mut spans := [][]int{}
	if bt := compile_regex(ran_backtick_pattern) {
		for m in bt.find_all(text) {
			said << RanCommand{
				command: group_text(text, &m, 1).trim_space()
			}
			quotes << group_text(text, &m, 0)
			spans << [m.start, m.end]
		}
	}
	if bare := compile_regex(ran_bare_pattern) {
		for m in bare.find_all(text) {
			mut inside := false
			for sp in spans {
				if sp[0] <= m.start && m.start < sp[1] {
					inside = true
					break
				}
			}
			if inside {
				// already read as a backticked claim
				continue
			}
			token := group_text(text, &m, 1).trim_space()
			if token.to_lower() in not_a_command {
				// prose, not a command claim
				continue
			}
			said << RanCommand{
				command: token
			}
			quotes << group_text(text, &m, 0)
		}
	}
	for i, s in said {
		head := if s.command.contains(' ') { s.command.all_before(' ') } else { s.command }
		mut found := false
		for c in rec.commands {
			if mentions(c.command, head) || c.command.contains(head) {
				found = true
				break
			}
		}
		if found {
			claims << Claim{
				kind:     'ran_command'
				subject:  s.command
				verdict:  claim_supported
				evidence: 'a matching command is in the log'
				quote:    quotes[i]
			}
			continue
		}
		if head in rec.tool_calls {
			claims << Claim{
				kind:     'ran_command'
				subject:  s.command
				verdict:  claim_supported
				evidence: 'a matching tool call is in the log'
				quote:    quotes[i]
			}
			continue
		}
		claims << Claim{
			kind:     'ran_command'
			subject:  s.command
			verdict:  claim_contradicted
			evidence: 'no such command or tool call was recorded'
			quote:    quotes[i]
		}
	}

	// -- "I created / updated / deleted <file>" -------------------------------
	if file_re := compile_regex(file_claim_pattern) {
		for m in file_re.find_all(text) {
			verb := group_text(text, &m, 1).to_lower()
			path := group_text(text, &m, 2)
			quote := group_text(text, &m, 0)
			deleting := verb == 'deleted' || verb == 'removed'
			kind := if deleting { 'file_deleted' } else { 'file_written' }
			pool := if deleting { rec.deleted.clone() } else { rec.written.clone() }
			other := if deleting { rec.written.clone() } else { rec.deleted.clone() }

			mut hit := false
			for p, _ in pool {
				if mentions(p, path) {
					hit = true
					break
				}
			}
			if hit {
				claims << Claim{
					kind:     kind
					subject:  path
					verdict:  claim_supported
					evidence: 'a matching effect is in the log'
					quote:    quote
				}
				continue
			}
			mut opposite := false
			for p, _ in other {
				if mentions(p, path) {
					opposite = true
					break
				}
			}
			claims << Claim{
				kind:     kind
				subject:  path
				verdict:  claim_contradicted
				evidence: if opposite {
					'the log records the opposite effect on this path'
				} else {
					'no write or delete on this path was recorded'
				}
				quote:    quote
			}
		}
	}

	return Attestation{
		claims: claims
	}
}

// seal_attestation records the verdict. It is ALWAYS sealed, including a
// clean one: an attestation that only appears when something is wrong is
// evidence of absence nobody can audit.
pub fn seal_attestation(mut log EventLog, att &Attestation) {
	log.append('attest.verdict', {
		'claims':       json2.Any(att.claims.map(json2.Any(it.to_json())))
		'contradicted': json2.Any(att.contradicted().len)
		'unsupported':  json2.Any(att.unsupported().len)
	}, AppendOpts{ actor: 'kernel' })
}
