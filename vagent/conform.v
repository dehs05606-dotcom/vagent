module vagent

import x.json2

// conform.v — the reply is checked before it is accepted, not after.
//
// attest.v checks a reply's factual claims against the log and REPORTS.
// Reporting is right for a claim about the past: the transcript should
// record what the agent said, not a corrected version.
//
// It is wrong for a rule about form. If the specification says "every code
// change is reported as file:line", a reply that breaks it is not a
// historical record to preserve — it is a draft that has not met the
// contract yet, and nothing else here stops it reaching the user.
//
// So @output rules are checked against the DRAFT, and a failing draft goes
// back to the model with the clause it broke. Three properties keep this
// from becoming a way to launder bad output:
//
//   1. BOUNDED. A fixed number of attempts, then the draft goes through as
//      it is with the unmet clauses attached. An unbounded loop would burn
//      a turn and could never terminate on a rule the model cannot meet.
//   2. HONEST ON FAILURE. What the user sees is the real draft plus the
//      rules it broke — never a dropped reply, never a fabricated one.
//   3. THE RULES ARE THE AUTHOR'S. Every check is an @output line in the
//      specification. This module invents no requirement and rewrites no
//      text; it decides only whether to accept a draft or ask again.
//
// @output kinds:
//
//   @output forbid  <regex>                 the reply must not match
//   @output require <regex>                 the reply must match
//   @output require <regex> when <regex>    required only if the reply
//                                           matches the `when` pattern
//   @output max_chars <n>                   a length ceiling

// regenerations, not total drafts
pub const default_attempts = 2

pub struct Rule {
pub:
	clause string
	// forbid | require | max_chars
	kind    string
	pattern string
	// require only: the condition that arms it
	when string
	// max_chars only
	limit int
}

pub fn (r &Rule) to_json() map[string]json2.Any {
	mut d := {
		'clause': json2.Any(r.clause)
		'kind':   json2.Any(r.kind)
	}
	if r.pattern != '' {
		d['pattern'] = json2.Any(r.pattern)
	}
	if r.when != '' {
		d['when'] = json2.Any(r.when)
	}
	if r.limit != 0 {
		d['limit'] = json2.Any(r.limit)
	}
	return d
}

pub fn (r &Rule) describe() string {
	if r.kind == 'max_chars' {
		return '${r.clause}: the reply must be at most ${r.limit} chars'
	}
	if r.kind == 'forbid' {
		return "${r.clause}: the reply must not match '${r.pattern}'"
	}
	scope := if r.when != '' { " (because it matches '${r.when}')" } else { '' }
	return "${r.clause}: the reply must match '${r.pattern}'${scope}"
}

pub struct Unmet {
pub:
	rule   Rule
	detail string
}

pub fn (u &Unmet) to_json() map[string]json2.Any {
	mut d := u.rule.to_json()
	d['detail'] = json2.Any(u.detail)
	return d
}

pub struct Outcome {
pub:
	text     string
	attempts int = 1
	unmet    []Unmet
}

pub fn (o &Outcome) conformed() bool {
	return o.unmet.len == 0
}

// annotated is the text as the user should see it. A draft that never
// conformed carries the rules it broke rather than being dropped or quietly
// presented as though it had.
pub fn (o &Outcome) annotated() string {
	if o.conformed() {
		return o.text
	}
	rules_s := if o.unmet.len > 1 { 's' } else { '' }
	tries_s := if o.attempts > 1 { 's' } else { '' }
	mut lines := [
		o.text,
		'',
		'[conform] this reply does not meet ${o.unmet.len} output rule${rules_s} after ${o.attempts} attempt${tries_s}:',
	]
	for u in o.unmet {
		lines << '  ${u.detail}'
	}
	return lines.join('\n')
}

// parse_rules reads the @output lines out of a specification, and reports
// what it could not read rather than dropping it silently.
pub fn parse_rules(spec string) ([]Rule, []string) {
	mut rules := []Rule{}
	mut errors := []string{}
	mut clause := 'preamble'

	section_re := compile_regex(r'^\s{0,3}§\s*([\d.]+[a-z]?)') or { return rules, errors }
	tag_re := compile_regex(r'^\s{0,3}\[([A-Za-z0-9_.\-]+)\]') or { return rules, errors }
	head_re := compile_regex(r'^\s*@output\b') or { return rules, errors }
	out_re := compile_regex(r'(?i)^\s*@output\s+(forbid|require|max_chars)\s+(.+?)\s*$') or {
		return rules, errors
	}
	when_re := compile_regex(r'(?i)\s+when\s+') or { return rules, errors }

	for line in split_lines(spec) {
		if m := section_re.search(line) {
			clause = group_text(line, &m, 1)
			continue
		}
		if m := tag_re.search(line) {
			clause = group_text(line, &m, 1)
			continue
		}
		if _ := head_re.search(line) {
		} else {
			continue
		}
		m := out_re.search(line) or {
			errors << "${clause}: malformed @output — expected 'forbid <regex>', " +
				"'require <regex> [when <regex>]' or 'max_chars <n>'"
			continue
		}
		kind := group_text(line, &m, 1).to_lower()
		mut rest := group_text(line, &m, 2).trim_space()

		if kind == 'max_chars' {
			if !is_all_digits(rest) {
				errors << '${clause}: max_chars needs a number'
				continue
			}
			limit := rest.int()
			if limit <= 0 {
				errors << '${clause}: max_chars must be positive'
				continue
			}
			rules << Rule{
				clause: clause
				kind:   kind
				limit:  limit
			}
			continue
		}

		mut when := ''
		if kind == 'require' {
			if wm := when_re.search(rest) {
				when = rest[wm.end..].trim_space()
				rest = rest[..wm.start].trim_space()
			}
		}
		mut bad := false
		for rx in [rest, when] {
			if rx == '' {
				continue
			}
			compile_regex(rx) or {
				errors << '${clause}: invalid @output regex (${err.msg()})'
				bad = true
			}
		}
		if rest == '' {
			errors << '${clause}: @output ${kind} needs a pattern'
			continue
		}
		if bad {
			continue
		}
		rules << Rule{
			clause:  clause
			kind:    kind
			pattern: rest
			when:    when
		}
	}
	return rules, errors
}

fn is_all_digits(s string) bool {
	if s == '' {
		return false
	}
	for c in s {
		if c < `0` || c > `9` {
			return false
		}
	}
	return true
}

// check_rules is the output rules this draft does not meet. Pure and
// deterministic.
pub fn check_rules(rules []Rule, text string) []Unmet {
	mut out := []Unmet{}
	body := text
	for r in rules {
		match r.kind {
			'max_chars' {
				if body.len > r.limit {
					out << Unmet{
						rule:   r
						detail: '${r.clause}: the reply is ${thousands(body.len)} chars, over the ${thousands(r.limit)} allowed'
					}
				}
			}
			'forbid' {
				re := compile_regex(r.pattern) or { continue }
				if m := re.search(body) {
					hit := clip_plain(group_text(body, &m, 0), 60)
					out << Unmet{
						rule:   r
						detail: "${r.clause}: the reply contains '${hit}', which this clause forbids"
					}
				}
			}
			'require' {
				if r.when != '' {
					wre := compile_regex(r.when) or { continue }
					if _ := wre.search(body) {
					} else {
						// the rule is not armed for this reply
						continue
					}
				}
				re := compile_regex(r.pattern) or { continue }
				if _ := re.search(body) {
					continue
				}
				why := if r.when != '' {
					" (it matches '${r.when}', which requires this)"
				} else {
					''
				}
				out << Unmet{
					rule:   r
					detail: "${r.clause}: the reply must match '${r.pattern}' and does not${why}"
				}
			}
			else {}
		}
	}
	return out
}

// conform_instruction is what goes back with the draft.
//
// It states the rule and what the draft did, and nothing else. A module that
// drafted the conforming answer would be answering for the model, and the
// reply would stop being the model's.
pub fn conform_instruction(unmet []Unmet) string {
	plural := if unmet.len > 1 { 's' } else { '' }
	mut lines := [
		'Your draft does not meet ${unmet.len} output rule${plural} from the specification. ' +
		'Rewrite it so that it does. Change nothing else.',
	]
	for u in unmet {
		// both halves are needed: what the draft did, and what the rule
		// requires. The first alone leaves the model guessing at the target;
		// the second alone leaves it guessing at the miss.
		lines << '  ${u.detail}'
		lines << '    rule: ${u.rule.describe()}'
	}
	return lines.join('\n')
}

// Regenerator asks the model for another draft. It is injected, so this
// module holds no model client and cannot itself call one.
pub type Regenerator = fn (instruction string) !string

@[heap]
pub struct Conform {
pub mut:
	log      &EventLog
	attempts int
	rules    []Rule
	errors   []string
	checked  int
	// regenerations asked for
	regenerated int
	failed      int
}

pub fn new_conform(log &EventLog, spec string, attempts int) &Conform {
	mut c := &Conform{
		log:      unsafe { log }
		attempts: max_int(0, attempts)
	}
	c.bind(spec)
	return c
}

pub fn (mut c Conform) bind(spec string) {
	c.rules, c.errors = parse_rules(spec)
}

pub fn (c &Conform) check(text string) []Unmet {
	return check_rules(c.rules, text)
}

// run accepts `draft`, or asks `regenerate` for another — bounded.
pub fn (mut c Conform) run(draft string, regenerate Regenerator) Outcome {
	if c.rules.len == 0 {
		return Outcome{
			text: draft
		}
	}
	c.checked++
	mut text := draft
	mut unmet := c.check(text)
	mut tries := 1
	for unmet.len > 0 && tries <= c.attempts {
		c.log.append('conform.rejected', {
			'attempt': json2.Any(tries)
			'unmet':   json2.Any(unmet.map(json2.Any(it.to_json())))
		}, AppendOpts{ actor: 'kernel' })
		c.regenerated++
		nxt := regenerate(conform_instruction(unmet)) or {
			// never lose a draft to a failed retry
			c.log.append('conform.error', {
				'error': json2.Any(err.msg())
			}, AppendOpts{ actor: 'kernel' })
			break
		}
		tries++
		if nxt.trim_space() == '' {
			// an empty retry is not progress
			break
		}
		text = nxt
		unmet = c.check(text)
	}

	if unmet.len > 0 {
		c.failed++
		c.log.append('conform.unmet', {
			'attempts': json2.Any(tries)
			'unmet':    json2.Any(unmet.map(json2.Any(it.to_json())))
		}, AppendOpts{ actor: 'kernel' })
	} else {
		c.log.append('conform.accepted', {
			'attempts': json2.Any(tries)
		}, AppendOpts{ actor: 'kernel' })
	}
	return Outcome{
		text:     text
		attempts: tries
		unmet:    unmet
	}
}

pub fn (c &Conform) report() string {
	if c.rules.len == 0 {
		return 'conform: no @output rules in the specification'
	}
	mut lines := [
		'conform: ${c.rules.len} output rule(s) · ${c.checked} reply(ies) checked · ' +
		'${c.regenerated} regenerated · ${c.failed} still unmet',
	]
	for r in c.rules {
		lines << '  ${r.describe()}'
	}
	for e in c.errors {
		lines << '  !! ${e}'
	}
	return lines.join('\n')
}
