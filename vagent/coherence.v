module vagent

import x.json2

// coherence.v — a specification that contradicts itself cannot be followed.
//
// Every mechanism here assumes the specification is satisfiable: that some
// behaviour exists which obeys all of it at once. Nothing checks that
// assumption, and for a document of several hundred clauses written over
// months it is the assumption most likely to be false.
//
// When two clauses conflict the model is not disobeying. It is CHOOSING,
// because obeying both is impossible, and whichever it picks looks like
// non-compliance against the other. The author sees "it ignores my rules",
// adds a stricter rule, and the new rule conflicts with a third — the
// specification grows, adherence falls, and every measurement is of a
// document no behaviour could satisfy.
//
// audit.v finds conflicts between GUARDS — a root both confined to and
// forbidden — which catches the machine-checkable few. The prose is where
// specifications actually contradict themselves, and the prose is most of
// the document. So this compares clauses to each other:
//
//     CONTRADICTION  two clauses about the same subject with opposite
//                    polarity — one requires what the other forbids
//     DUPLICATE      the same rule stated twice, harmless until one is
//                    edited and the author believes both moved
//     SUBSUMED       one clause wholly contained in another, so the
//                    narrower one adds nothing but length
//     OVERRIDE       a later clause naming an earlier one as an exception
//                    — reported so the pair is read together, not as a fault
//
// WHAT IT CAN AND CANNOT DO. This is LEXICAL: shared subject terms plus
// opposing polarity markers. It finds the contradictions visible in the
// words, which is most of the ones that accumulate by accident. It will not
// find a contradiction that requires understanding the domain, and it says
// so rather than reporting a clean bill of health it cannot give.

pub const coherence_contradiction = 'contradiction'
pub const coherence_duplicate = 'duplicate'
pub const coherence_subsumed = 'subsumed'
pub const coherence_override = 'override'

const coherence_stop = ['the', 'and', 'for', 'with', 'that', 'this', 'from', 'any',
	'all', 'are', 'was', 'has', 'have', 'will', 'can', 'may', 'when', 'then', 'than',
	'its', 'their', 'there', 'here', 'into', 'out', 'via', 'you', 'your', 'our', 'one',
	'two', 'also', 'but', 'own', 'clause', 'rule', 'section', 'agent', 'which', 'what',
	'who', 'how', 'why', 'been', 'they', 'them', 'such', 'some', 'other', 'each',
	'every', 'only', 'not', 'must', 'never', 'always', 'should', 'shall']

// polarity markers. "must" and "never" are stopwords for SUBJECT terms but
// are exactly what decides polarity, so they are read separately.
const negative_pattern = r"(?i)\b(?:never|must not|must never|do not|don\x27t|cannot|can\x27t|shall not|no longer|avoid|forbid\w*|prohibit\w*|ban\w*|refuse\w*|is not|are not|without)\b"

// "must" is prescriptive; "must never" is not. Without the lookaheads a
// prohibition scores as both polarities and cancels to neutral, which is
// exactly the clause a contradiction check most needs to read.
const positive_pattern = r'(?i)\b(?:always|must(?!\s+(?:not|never))|shall(?!\s+not)|should(?!\s+(?:not|never))|required?|require\w*|ensure\w*|has to|have to|need to|needs to|prefer\w*|use\b)\b'

// "except", "unless", "overrides §4" — a declared relationship, not a fault
const override_pattern = r'(?i)\b(?:except|unless|overrides?|supersedes?|notwithstanding|takes? precedence)\b'

// subject terms two clauses must share to be compared at all
pub const min_shared_terms = 3
// Jaccard above which two clauses are the same rule
pub const dup_ratio = 0.85
// the share of the narrower clause inside the wider one
pub const sub_ratio = 0.90

// coherence_terms are the subject words of a clause: three letters or more,
// lowercased, stopwords removed.
pub fn coherence_terms(text string) map[string]bool {
	mut out := map[string]bool{}
	re := compile_regex(r'[A-Za-z_][A-Za-z0-9_]{2,}') or { return out }
	for m in re.find_all(text) {
		w := group_text(text, &m, 0).to_lower()
		if w in coherence_stop {
			continue
		}
		out[w] = true
	}
	return out
}

// polarity is -1 prohibitive, +1 prescriptive, 0 for neither or both.
pub fn polarity(text string) int {
	neg := count_matches(negative_pattern, text)
	pos := count_matches(positive_pattern, text)
	if neg > 0 && pos == 0 {
		return -1
	}
	if pos > 0 && neg == 0 {
		return 1
	}
	if neg > pos * 2 {
		return -1
	}
	if pos > neg * 2 {
		return 1
	}
	return 0
}

pub struct CoherenceFinding {
pub:
	kind   string
	a      string
	b      string
	shared []string
	detail string
}

pub fn (f &CoherenceFinding) to_json() map[string]json2.Any {
	return {
		'kind':   json2.Any(f.kind)
		'a':      json2.Any(f.a)
		'b':      json2.Any(f.b)
		'shared': json2.Any(f.shared[..min_int(10, f.shared.len)].map(json2.Any(it)))
		'detail': json2.Any(f.detail)
	}
}

pub fn (f &CoherenceFinding) describe() string {
	head := f.shared[..min_int(6, f.shared.len)]
	return '[${f.kind}] ${f.a} ↔ ${f.b}: ${f.detail} (shared: ${head.join(", ")})'
}

pub struct CoherenceReport {
pub mut:
	findings []CoherenceFinding
	compared int
	clauses  int
}

pub fn (r &CoherenceReport) of(kind string) []CoherenceFinding {
	return r.findings.filter(it.kind == kind)
}

// satisfiable means no contradiction was FOUND. That is not the same as
// "none exists", and the report says so.
pub fn (r &CoherenceReport) satisfiable() bool {
	return r.of(coherence_contradiction).len == 0
}

pub fn (r &CoherenceReport) describe() string {
	if r.clauses == 0 {
		return 'coherence: no specification is bound'
	}
	kinds := [coherence_contradiction, coherence_duplicate, coherence_subsumed,
		coherence_override]
	counts := kinds.map('${it}:${r.of(it).len}')
	mut lines := ['coherence: ${r.clauses} clauses · ${r.compared} pairs compared · ' +
		counts.join(' · ')]
	if r.of(coherence_contradiction).len > 0 {
		lines << ''
		lines << '  a contradiction means no behaviour satisfies both clauses — the model is choosing, not disobeying:'
	}
	for f in r.of(coherence_contradiction) {
		lines << '  !! ${f.describe()}'
	}
	for kind in [coherence_duplicate, coherence_subsumed, coherence_override] {
		found := r.of(kind)
		for f in found[..min_int(6, found.len)] {
			lines << '  -  ${f.describe()}'
		}
	}
	lines << ''
	lines << '  lexical only: it finds contradictions visible in the words, not ones that need the domain. A clean report is not proof the specification is satisfiable.'
	return lines.join('\n')
}

fn clause_text(c &Clause) string {
	return (c.title + '\n' + c.body).trim_space()
}

// strip_rules removes the machine syntax. Comparing rule lines would match
// every clause that happens to use the same guard kind.
fn strip_rules(text string) string {
	mut out := []string{}
	re := compile_regex(r'^\s*@\w+') or { return text }
	for line in split_lines(text) {
		if _ := re.search(line) {
			continue
		}
		out << line
	}
	return out.join('\n')
}

struct CoherenceItem {
	id       string
	body     string
	terms    map[string]bool
	polarity int
}

// analyse_coherence compares every pair of clauses that share enough subject
// to conflict.
pub fn analyse_coherence(clauses []Clause) CoherenceReport {
	mut items := []CoherenceItem{}
	for c in clauses {
		if c.id == 'preamble' {
			continue
		}
		body := strip_rules(clause_text(&c))
		t := coherence_terms(body)
		if t.len == 0 {
			continue
		}
		items << CoherenceItem{
			id:       c.id
			body:     body
			terms:    t.clone()
			polarity: polarity(body)
		}
	}

	mut rep := CoherenceReport{
		clauses: items.len
	}
	for i in 0 .. items.len {
		a := items[i]
		for j in i + 1 .. items.len {
			b := items[j]
			mut common := []string{}
			for term, _ in a.terms {
				if term in b.terms {
					common << term
				}
			}
			if common.len < min_shared_terms {
				continue
			}
			rep.compared++
			common.sort()
			union_size := a.terms.len + b.terms.len - common.len
			jaccard := if union_size > 0 { f64(common.len) / f64(union_size) } else { 0.0 }
			smaller := min_int(a.terms.len, b.terms.len)
			containment := if smaller > 0 { f64(common.len) / f64(smaller) } else { 0.0 }

			// a declared relationship is not a fault
			if count_matches(override_pattern, a.body) > 0
				|| count_matches(override_pattern, b.body) > 0 {
				rep.findings << CoherenceFinding{
					kind:   coherence_override
					a:      a.id
					b:      b.id
					shared: common
					detail: 'one names an exception to the other — read them together'
				}
				continue
			}

			if jaccard >= dup_ratio {
				rep.findings << CoherenceFinding{
					kind:   coherence_duplicate
					a:      a.id
					b:      b.id
					shared: common
					detail: 'the same rule stated twice; editing one will not move the other'
				}
				continue
			}

			if containment >= sub_ratio && jaccard < dup_ratio {
				wide := if a.terms.len > b.terms.len { a.id } else { b.id }
				narrow := if a.terms.len > b.terms.len { b.id } else { a.id }
				rep.findings << CoherenceFinding{
					kind:   coherence_subsumed
					a:      narrow
					b:      wide
					shared: common
					detail: '${narrow} is wholly contained in ${wide} and adds only length'
				}
				continue
			}

			if a.polarity != 0 && b.polarity != 0 && a.polarity != b.polarity {
				req := if a.polarity > 0 { a.id } else { b.id }
				forb := if a.polarity > 0 { b.id } else { a.id }
				rep.findings << CoherenceFinding{
					kind:   coherence_contradiction
					a:      a.id
					b:      b.id
					shared: common
					detail: '${req} requires what ${forb} forbids, about the same subject'
				}
			}
		}
	}
	return rep
}
