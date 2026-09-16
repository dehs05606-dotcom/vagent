module vagent

import math

// salience.v — putting the rules that matter where the model actually reads.
//
// Every module before this one governs what the agent DOES. None of them
// makes it more likely the model follows the specification in the first
// place, and that is the thing the author actually asked for. A boundary
// that refuses non-compliant actions and a model that complies are
// different goods: the first produces a refused call and a wasted turn, the
// second produces the right work.
//
// The mechanism this addresses is not a defect in the model and cannot be
// fixed by asking harder. Attention over a long context is not uniform. A
// specification delivered as one 150k-char block puts most of its rules in
// the middle, which is measurably the weakest position — with 400 clauses
// the three that govern the current request sit around the 50% mark,
// exactly where recall is worst. The prompt is complete, correct, delivered
// verbatim, and the rules the turn needs are the least visible part of it.
//
// So: deliver the specification whole, as before — and ALSO restate, at the
// end of the context where attention is strongest, the small number of
// clauses this particular request implicates.
//
//     150k specification, verbatim, once     (systemprompt.spec)
//     + the 3-8 clauses this turn touches    (here, at the end)
//
// This is not a reminder to obey and not a re-injected instruction. No
// sentence is invented: the text is the author's own clauses, selected by
// term overlap with the request and by which clauses carry enforceable
// rules, and reproduced unchanged. If nothing is relevant, nothing is
// added.
//
// WHY SELECTION IS CONSERVATIVE. A clause wrongly left out is a rule the
// model is less likely to follow; a clause wrongly included costs tokens
// and dilutes the rest. Recall matters more than precision here, so scoring
// favours inclusion: an enforceable clause with any real term overlap gets
// in, and the budget — not the threshold — is what bounds the block.
//
// WHAT THIS IS NOT. It does not summarise, paraphrase, or rank the
// specification for the model, and it never replaces delivering it in full.
// A selection that stood in for the whole specification would be this
// module deciding which of the author's rules matter, which is not a
// judgement it is entitled to make.

// stop_terms appear in almost every clause and so separate nothing.
const stop_terms = ['the', 'and', 'for', 'with', 'that', 'this', 'from', 'must',
	'never', 'always', 'should', 'every', 'each', 'any', 'all', 'not', 'are',
	'was', 'has', 'have', 'will', 'can', 'may', 'use', 'used', 'using', 'when',
	'then', 'than', 'its', 'their', 'there', 'here', 'into', 'out', 'via',
	'you', 'your', 'our', 'one', 'two', 'only', 'also', 'but', 'own', 'clause',
	'rule', 'rules', 'section', 'agent', 'code', 'file', 'files']

pub const salience_default_budget = 6_000 // chars of restated clauses
pub const salience_default_max = 8 // clauses, however much budget is left

const salience_header = 'CLAUSES THIS REQUEST TOUCHES — reproduced verbatim from the ' +
	'specification above, restated here because the specification is long ' +
	'and these are the ones in play. The specification as a whole remains ' +
	'binding; nothing here narrows it.'

// terms extracts content words, lowercased, with stopwords dropped. A word
// is a letter or underscore followed by at least two more word characters,
// matching the Python `[A-Za-z_][A-Za-z0-9_]{2,}`.
pub fn terms(text string) map[string]bool {
	mut out := map[string]bool{}
	mut cur := ''
	for i := 0; i <= text.len; i++ {
		c := if i < text.len { text[i] } else { u8(` `) }
		if is_word_byte(c) {
			if cur == '' && (c >= `0` && c <= `9`) {
				// a word cannot start with a digit
				continue
			}
			cur += c.ascii_str()
			continue
		}
		if cur.len >= 3 {
			low := cur.to_lower()
			if low !in stop_terms {
				out[low] = true
			}
		}
		cur = ''
	}
	return out
}

pub struct Scored {
pub:
	clause_id string
	title     string
	text      string
	score     f64
	// `shared` is a V keyword, so the overlapping terms are named plainly
	overlap []string
}

fn intersect_terms(a map[string]bool, b map[string]bool) []string {
	mut out := []string{}
	for k, _ in a {
		if k in b {
			out << k
		}
	}
	out.sort()
	return out
}

// score_clauses ranks clauses by how much this request implicates them.
//
// Scoring is deliberately simple and deterministic: term overlap, plus a
// weight for clauses that carry an enforceable rule, plus a small weight for
// a title match. A learned or model-based ranker would put a second model's
// judgement between the author's rules and the agent, which is the thing
// this package exists to avoid.
pub fn score_clauses(clauses []Clause, request string, tools []string, weights map[string]f64) []Scored {
	mut want := terms(request)
	for t in tools {
		for k, _ in terms(t) {
			want[k] = true
		}
	}
	if want.len == 0 {
		return []
	}

	mut out := []Scored{}
	for c in clauses {
		body := c.title + '\n' + c.body
		have := terms(body)
		if have.len == 0 {
			continue
		}
		overlap := intersect_terms(want, have)
		if overlap.len == 0 {
			continue
		}
		// overlap normalised by the clause's own vocabulary, so a long
		// clause does not win simply by containing more words
		mut score := f64(overlap.len) / math.sqrt(f64(have.len))
		if c.enforced() {
			// a clause with a machine-checkable rule is one the agent will
			// be refused on; surfacing it early turns a refusal into work
			score *= 1.6
		}
		if intersect_terms(want, terms(c.title)).len > 0 {
			score *= 1.3
		}
		// measured adherence, when there is any: a clause the model is
		// observed to miss earns the scarce end-of-context position over
		// one it already follows (feedback.v). Absent a measurement the
		// multiplier is 1.0, so this changes nothing until something is
		// actually known.
		if weights.len > 0 {
			score *= weights[c.id] or { 1.0 }
		}
		out << Scored{
			clause_id: c.id
			title:     c.title
			text:      body.trim_space()
			score:     score
			overlap:   overlap
		}
	}
	// highest score first; ties break on the clause id so the selection is
	// reproducible
	out.sort_with_compare(fn (a &Scored, b &Scored) int {
		if a.score > b.score {
			return -1
		}
		if a.score < b.score {
			return 1
		}
		return compare_strings(a.clause_id, b.clause_id)
	})
	return out
}

@[params]
pub struct SalienceOpts {
pub:
	tools   []string
	budget  int = salience_default_budget
	limit   int = salience_default_max
	weights map[string]f64
}

// select_clauses returns the clauses to restate, within a character budget.
pub fn select_clauses(clauses []Clause, request string, opts SalienceOpts) []Scored {
	mut chosen := []Scored{}
	mut spent := 0
	for s in score_clauses(clauses, request, opts.tools, opts.weights) {
		if chosen.len >= opts.limit {
			break
		}
		cost := s.text.len + 8
		if spent + cost > opts.budget {
			continue // a long clause must not starve shorter ones
		}
		chosen << s
		spent += cost
	}
	return chosen
}

// salience_block is the text to place at the end of the context, or '' for
// nothing.
//
// It returns '' rather than an empty header when no clause is implicated: a
// block that says "no rules apply here" is a sentence this module invented,
// and it would be read as permission.
pub fn salience_block(clauses []Clause, request string, opts SalienceOpts) string {
	picked := select_clauses(clauses, request, opts)
	if picked.len == 0 {
		return ''
	}
	mut parts := [salience_header, '']
	for s in picked {
		parts << s.text
		parts << ''
	}
	return parts.join('\n').trim_right(' \t\n') + '\n'
}

pub fn salience_report(clauses []Clause, request string, opts SalienceOpts) string {
	picked := select_clauses(clauses, request, opts)
	if picked.len == 0 {
		return 'salience: no clause is implicated by this request'
	}
	mut lines := ['salience: ${picked.len} of ${clauses.len} clauses ' +
		'restated at the end of context']
	for s in picked {
		shown := if s.overlap.len > 6 { s.overlap[..6] } else { s.overlap }
		lines << '  ${pad_right(s.clause_id, 12)} ${pad_left("${s.score:.2f}", 6)}  ' +
			shown.join(', ')
	}
	return lines.join('\n')
}
