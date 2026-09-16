module vagent

import x.json2

// exemption.v — the "except" that every real specification contains.
//
// Every guard built so far is absolute. `confine_paths: src, tests` means
// every write, without exception, forever. No real specification is shaped
// like that. They all read:
//
//     writes stay under src/ and tests/ — except the changelog
//     never delete — except build artefacts
//     no secrets in source — except the fixtures that test secret detection
//
// A boundary with no way to say "except" forces the author into one of two
// failures, and both end with the specification not being followed:
//
//   * DROP THE CLAUSE. The exception is real and the rule cannot express it,
//     so the whole rule comes out, and with it all the enforcement it was
//     carrying.
//   * WORK AROUND IT. The clause stays, legitimate work is refused, and the
//     operator raises autonomy or edits the spec under pressure. The rule
//     survives on paper while being routinely bypassed in practice.
//
// The second is worse, because the report still shows the clause as bound.
// An unusable rule is abandoned in fact and enforced on paper.
//
// So exceptions are first-class, written next to the rule they narrow:
//
//     §1 Writes stay under src/ and tests/.
//     @enforce confine_paths: src, tests
//     @except path CHANGELOG.md
//
// Three properties make this safe rather than a hole:
//
//   1. SCOPED TO ONE CLAUSE. An @except narrows the clause it appears under
//      and nothing else — the scoping is structural, not a check that could
//      be forgotten.
//   2. NARROWING ONLY. It can forgive a violation; it can never create
//      permission. Remove every guard and the exemptions do nothing at all.
//   3. RECORDED. Every forgiveness is sealed with the clause and the path,
//      so an exception that is load-bearing in practice shows up as a
//      number rather than as a line nobody re-reads.

// ex_glob is fnmatch with the conveniences a path exception needs: a
// directory name also covers what is under it, and a bare segment matches
// anywhere in the path.
fn ex_glob(path string, pattern string) bool {
	norm := seq_norm(path)
	pat := pattern.trim_right('/')
	if fnmatch_name(norm, pat) || fnmatch_name(norm, pat + '/*') {
		return true
	}
	if pat.contains('**') {
		flat := pat.replace('**/', '').replace('/**', '')
		if fnmatch_name(norm, flat) || norm.starts_with(flat.trim_right('*')) {
			return true
		}
	}
	for seg in norm.split('/') {
		if fnmatch_name(seg, pat) {
			return true
		}
	}
	return false
}

pub struct Exemption {
pub:
	clause string
	// path | tool | content | when
	kind  string
	value string
	// `when` only: the path glob the regex is scoped to
	where string
}

pub fn (e &Exemption) to_json() map[string]json2.Any {
	mut d := {
		'clause': json2.Any(e.clause)
		'kind':   json2.Any(e.kind)
		'value':  json2.Any(e.value)
	}
	if e.where != '' {
		d['where'] = json2.Any(e.where)
	}
	return d
}

// forgives reports whether this exemption forgives `violation`.
//
// It is never consulted for a violation of a different clause: the clause
// check is the first line, so scoping cannot be forgotten at a call site.
pub fn (x &Exemption) forgives(violation &Violation, tool string, effects []Effect) bool {
	if violation.clause != x.clause {
		return false
	}
	match x.kind {
		'path' {
			return violation.path != '' && ex_glob(violation.path, x.value)
		}
		'tool' {
			return tool == x.value
		}
		'content' {
			for e in effects {
				if e.path != '' && violation.path != '' && seq_norm(e.path) == seq_norm(violation.path)
					&& e.content != '' {
					re := compile_regex(x.value) or { return false }
					return re.search(e.content) != none
				}
			}
			return false
		}
		'when' {
			if violation.path == '' || !ex_glob(violation.path, x.where) {
				return false
			}
			for e in effects {
				if e.path != '' && seq_norm(e.path) == seq_norm(violation.path) {
					re := compile_regex(x.value) or { return false }
					return re.search(e.content) != none
				}
			}
			return false
		}
		else {
			return false
		}
	}
}

// parse_exemptions reads the @except lines, each bound to the clause it sits
// under.
pub fn parse_exemptions(spec string) ([]Exemption, []string) {
	mut out := []Exemption{}
	mut errors := []string{}
	mut clause := 'preamble'

	section_re := compile_regex(r'^\s{0,3}§\s*([\d.]+[a-z]?)') or { return out, errors }
	tag_re := compile_regex(r'^\s{0,3}\[([A-Za-z0-9_.\-]+)\]') or { return out, errors }
	head_re := compile_regex(r'(?i)^\s*@except\b') or { return out, errors }
	except_re := compile_regex(r'(?i)^\s*@except\s+(path|tool|content|when)\s+(.+?)\s*$') or {
		return out, errors
	}

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
		m := except_re.search(line) or {
			errors << "${clause}: malformed @except — expected '@except path <glob>', " +
				"'tool <name>', 'content <regex>' or 'when <glob> <regex>'"
			continue
		}
		kind := group_text(line, &m, 1).to_lower()
		mut rest := group_text(line, &m, 2).trim_space()
		mut where := ''
		if kind == 'when' {
			bits := rest.split_any(' \t').filter(it != '')
			if bits.len < 2 {
				errors << "${clause}: '@except when' needs a path glob and a regex"
				continue
			}
			where = bits[0]
			rest = rest[where.len..].trim_space()
		}
		if kind == 'content' || kind == 'when' {
			compile_regex(rest) or {
				errors << '${clause}: invalid @except regex (${err.msg()})'
				continue
			}
		}
		if rest == '' {
			errors << '${clause}: @except ${kind} needs a value'
			continue
		}
		out << Exemption{
			clause: clause
			kind:   kind
			value:  rest
			where:  where
		}
	}
	return out, errors
}

@[heap]
pub struct Exemptions {
pub mut:
	log     &EventLog
	items   []Exemption
	errors  []string
	applied int
mut:
	hits map[string]int
}

pub fn new_exemptions(log &EventLog, spec string) &Exemptions {
	mut e := &Exemptions{
		log: unsafe { log }
	}
	e.bind(spec)
	return e
}

pub fn (mut e Exemptions) bind(spec string) {
	e.items, e.errors = parse_exemptions(spec)
}

// narrow returns the violations that survive.
//
// Narrowing only: a call with no violations cannot gain permission here,
// because there is nothing to forgive.
pub fn (mut e Exemptions) narrow(violations []Violation, tool string, effects []Effect) []Violation {
	if e.items.len == 0 || violations.len == 0 {
		return violations
	}
	mut kept := []Violation{}
	for v in violations {
		mut forgiven := false
		for x in e.items {
			if x.forgives(&v, tool, effects) {
				e.applied++
				key := '${x.clause}:${x.kind}'
				e.hits[key] = e.hits[key] + 1
				mut payload := x.to_json()
				payload['forgave'] = json2.Any(v.to_json())
				payload['tool'] = json2.Any(tool)
				e.log.append('exemption.applied', payload, AppendOpts{ actor: 'kernel' })
				forgiven = true
				break
			}
		}
		if !forgiven {
			kept << v
		}
	}
	return kept
}

pub fn (e &Exemptions) report() string {
	if e.items.len == 0 {
		return 'exemptions: none declared'
	}
	mut lines := ['exemptions: ${e.items.len} declared · ${e.applied} applied']
	for x in e.items {
		key := '${x.clause}:${x.kind}'
		n := e.hits[key] or { 0 }
		mark := if n > 0 { '●' } else { '○' }
		scope := if x.where != '' { ' in ${x.where}' } else { '' }
		lines << '  ${mark} ' + pad_width(x.clause, 10) + ' except ${x.kind} ' +
			clip_plain(x.value, 34) + '${scope} — forgave ${n}'
	}
	for err in e.errors {
		lines << '  !! ${err}'
	}
	return lines.join('\n')
}
