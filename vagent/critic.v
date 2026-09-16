module vagent

import x.json2

// critic.v — checking the clauses a regex cannot express.
//
// conform.v checks the reply against @output rules, which are regexes. That
// covers the rules with a lexical shape — a forbidden phrase, a required
// citation format, a length — and nothing else. Most of a specification is
// not lexical:
//
//     "prefer composition over inheritance"
//     "explain the trade-off before recommending one option"
//     "do not restate the user's question back to them"
//
// No regex decides whether a reply follows these. adherence.v reports them
// as UNSCORABLE, and they remain what they were: the majority of the
// specification, checked by nothing.
//
// The only thing that can read prose is a model. So a second pass reads the
// draft against the clauses it implicates and reports which ones it breaks.
// That is a real departure from the rest of this package, which is
// deterministic everywhere, and it is confined deliberately:
//
//   1. IT ONLY REPORTS. A verdict is never a refusal and never rewrites the
//      draft. It produces findings conform.v can ask the model to address.
//   2. IT CITES OR IT IS DISCARDED. A finding must name a clause that was
//      actually sent to it AND quote the draft. A finding that cites
//      nothing, or cites a clause that does not exist, is dropped — a
//      critic that can invent a violation is a critic that can block
//      correct work forever.
//   3. IT IS NEVER THE ONLY CHECK. Everything a regex can decide is decided
//      by conform.v first. This runs on what is left, where a model's
//      judgement is the only instrument available and its errors are
//      cheapest: a false finding costs one regeneration.
//
// WHAT THIS COSTS, plainly: a second model call per reply, and a judgement
// that is not reproducible the way the rest of this package is. Two runs can
// disagree. That is the price of checking prose at all, and the alternative
// is not checking it.

// clauses sent to one critique
pub const max_critic_clauses = 12
// chars of draft sent
pub const max_critic_draft = 12_000

const critic_prompt = 'You are checking one draft reply against specific clauses from a specification. You are not rewriting it and not answering the user.

For each clause, decide whether the draft BREAKS it. A clause is broken only if the draft actually conflicts with it — not if the draft is merely silent about it, and not if you would have written it differently.

Reply with JSON only, in this exact shape:
{"findings": [{"clause": "<id>", "quote": "<exact text from the draft>", "why": "<one sentence>"}]}

An empty list means the draft breaks none of them. Quote the draft exactly; a finding whose quote is not in the draft is discarded.

CLAUSES:
{clauses}

DRAFT:
{draft}
'

pub struct Finding {
pub:
	clause string
	quote  string
	why    string
}

pub fn (f &Finding) to_json() map[string]json2.Any {
	return {
		'clause': json2.Any(f.clause)
		'quote':  json2.Any(clip_plain(f.quote, 200))
		'why':    json2.Any(f.why)
	}
}

pub fn (f &Finding) describe() string {
	return "${f.clause}: ${f.why} — '${clip_plain(f.quote, 80)}'"
}

pub struct Critique {
pub mut:
	findings   []Finding
	considered []string
	discarded  int
	error      string
}

pub fn (c &Critique) clean() bool {
	return c.findings.len == 0 && c.error == ''
}

pub fn (c &Critique) describe() string {
	if c.error != '' {
		return 'critic: not run (${c.error})'
	}
	if c.considered.len == 0 {
		return 'critic: no prose clause was implicated by this reply'
	}
	mut head := 'critic: ${c.considered.len} clause(s) read · ${c.findings.len} finding(s)'
	if c.discarded > 0 {
		head += ' · ${c.discarded} discarded'
	}
	if c.findings.len == 0 {
		return head + '\n  the draft breaks none of them'
	}
	return head + '\n' + c.findings.map('  ${it.describe()}').join('\n')
}

// prose_clauses are the clauses with no machine-checkable rule — the ones
// left over.
//
// A clause conform.v already decides is not sent: paying for a model's
// opinion about a question a regex has answered is waste, and a disagreement
// between them would have no principled resolution.
pub fn prose_clauses(clauses []Clause, output_rule_clauses []string) []Clause {
	return clauses.filter(!it.enforced() && it.id !in output_rule_clauses
		&& (it.body != '' || it.title != ''))
}

pub fn build_critic_prompt(clauses []Clause, draft string) string {
	mut blocks := []string{}
	for c in clauses {
		body := (c.title + '\n' + c.body).trim_space()
		blocks << '[${c.id}] ${body}'
	}
	return critic_prompt.replace('{clauses}', blocks.join('\n\n')).replace('{draft}',
		clip_plain(draft, max_critic_draft))
}

// parse_critique reads the critic's reply and returns the findings plus how
// many were discarded.
//
// Every guard here exists because the failure it prevents is worse than a
// missed finding: an invented clause id, a quote that is not in the draft, or
// a wall of prose instead of JSON would each let the critic manufacture work
// the model can never satisfy.
pub fn parse_critique(raw string, draft string, allowed []string) ([]Finding, int) {
	text := raw.trim_space()
	start := text.index('{') or { return []Finding{}, 0 }
	end := text.last_index('}') or { return []Finding{}, 0 }
	if end <= start {
		return []Finding{}, 0
	}
	parsed := json2.decode[json2.Any](text[start..end + 1]) or { return []Finding{}, 0 }
	if parsed !is map[string]json2.Any {
		return []Finding{}, 0
	}
	items := jarr(parsed.as_map(), 'findings')

	mut out := []Finding{}
	mut discarded := 0
	for item in items {
		if item !is map[string]json2.Any {
			discarded++
			continue
		}
		row := item.as_map()
		clause := jstr(row, 'clause').trim_space().trim('[]')
		quote := jstr(row, 'quote').trim_space()
		why := jstr(row, 'why').trim_space()
		if clause !in allowed {
			// a clause it was never shown
			discarded++
			continue
		}
		if quote == '' || !draft.contains(quote) {
			// a quote that is not in the draft
			discarded++
			continue
		}
		if why == '' {
			discarded++
			continue
		}
		out << Finding{
			clause: clause
			quote:  quote
			why:    why
		}
	}
	return out, discarded
}

@[heap]
pub struct Critic {
pub mut:
	log       &EventLog
	spec      string
	runs      int
	findings  int
	discarded int
}

pub fn new_critic(log &EventLog, spec string) &Critic {
	return &Critic{
		log:  unsafe { log }
		spec: spec
	}
}

pub fn (mut c Critic) bind(spec string) {
	c.spec = spec
}

// review critiques `draft` against the prose clauses.
//
// `ask` is injected, so this module holds no model client: it can be tested
// without one, pointed at a cheaper model than the agent's, and cannot call a
// model on its own.
pub fn (mut c Critic) review(draft string, clauses []Clause, ask AskFn, output_rule_clauses []string, limit int) Critique {
	prose := prose_clauses(clauses, output_rule_clauses)
	if prose.len == 0 || draft.trim_space() == '' {
		return Critique{}
	}

	// the clauses this draft plausibly touches, so the critique is about a
	// handful rather than the whole specification
	picked := select_clauses(prose, draft, SalienceOpts{ limit: limit })
	picked_ids := picked.map(it.clause_id)
	mut chosen := prose.filter(it.id in picked_ids)
	if chosen.len == 0 {
		chosen = prose[..min_int(limit, prose.len)].clone()
	}

	mut crit := Critique{
		considered: chosen.map(it.id)
	}
	c.runs++
	raw := ask(build_critic_prompt(chosen, draft)) or {
		// a critique is not the turn: a failed one is reported, not raised
		crit.error = err.msg()
		c.log.append('critic.error', {
			'error': json2.Any(crit.error)
		}, AppendOpts{ actor: 'kernel' })
		return crit
	}

	findings, discarded := parse_critique(raw, draft, chosen.map(it.id))
	crit.findings = findings
	crit.discarded = discarded
	c.findings += findings.len
	c.discarded += discarded
	c.log.append('critic.review', {
		'considered': json2.Any(crit.considered.map(json2.Any(it)))
		'findings':   json2.Any(findings.map(json2.Any(it.to_json())))
		'discarded':  json2.Any(discarded)
	}, AppendOpts{ actor: 'kernel' })
	return crit
}

// critic_instruction is what conform.v's retry is handed. It names the
// clause and quotes the draft; it never writes the replacement.
pub fn (c &Critic) instruction(crit &Critique) string {
	plural := if crit.findings.len > 1 { 's' } else { '' }
	mut lines := [
		'Your draft conflicts with ${crit.findings.len} clause${plural} of the specification. ' +
		'Rewrite it so that it does not. Change nothing else.',
	]
	for f in crit.findings {
		lines << '  ${f.clause}: ${f.why}'
		lines << "    in your draft: '${clip_plain(f.quote, 120)}'"
	}
	return lines.join('\n')
}

pub fn (c &Critic) report() string {
	if c.runs == 0 {
		return 'critic: not run yet'
	}
	return 'critic: ${c.runs} review(s) · ${c.findings} finding(s) · ${c.discarded} discarded as uncited or invented'
}
