module vagent

import os
import x.json2

// obligation.v — the clauses that are broken by doing nothing.
//
// Every guard so far refuses an act. That shape can only catch COMMISSION:
// the agent tried to write the wrong thing, delete the wrong thing, reach
// the wrong place. Refuse hard enough and the agent complies perfectly by
// doing nothing at all.
//
// Most of a real specification is not like that. "Every module ships with a
// test." "A public function carries a docstring." "A schema change comes
// with a migration." None of these can be enforced by refusing a call,
// because the violation is not a call — it is a call that never came. An
// omission has no action to gate.
//
// So an obligation is not a guard. It is a DEBT:
//
//     §6 Every module ships with a test.
//     @oblige on write src/**/*.py require exists tests/test_{stem}.py
//
//     writing src/parser.py          ->  incurs  tests/test_parser.py
//     writing tests/test_parser.py   ->  discharges it
//     still outstanding              ->  the debt is the blocker
//
// The ledger is folded from the event log, so it survives a restart: every
// debt names the clause that created it, the act that incurred it, and the
// condition that will settle it. Nothing is remembered in a variable a crash
// can lose.
//
// Enforcement is by BLOCKING PROGRESS rather than by refusing work. An
// outstanding debt does not stop the agent editing files — that would make
// the specification impossible to satisfy, since the discharging write is
// itself an act. It stops the things that mean "done". The debt cannot be
// out-waited and cannot be talked away, because settling it is a fact on
// disk rather than an assertion in a reply.
//
// Templates available in a require path: {stem} {name} {parent} {path}.

pub struct ObligeRule {
pub:
	clause string
	// write | delete
	act string
	// which paths trigger it
	glob string
	// exists | absent | contains
	kind string
	// the templated path
	target string
	// for `contains`
	pattern string
}

pub fn (r &ObligeRule) to_json() map[string]json2.Any {
	mut d := {
		'clause': json2.Any(r.clause)
		'act':    json2.Any(r.act)
		'glob':   json2.Any(r.glob)
		'kind':   json2.Any(r.kind)
		'target': json2.Any(r.target)
	}
	if r.pattern != '' {
		d['pattern'] = json2.Any(r.pattern)
	}
	return d
}

// Debt is one outstanding requirement, traceable to what incurred it.
pub struct Debt {
pub:
	clause  string
	kind    string
	target  string
	pattern string
	// the path whose change created the debt
	incurred_by string
	// the act on that path which created it
	act string = 'write'
}

pub fn (d &Debt) id() string {
	return '${d.clause}:${d.kind}:${d.target}'
}

pub fn (d &Debt) to_json() map[string]json2.Any {
	return {
		'clause':      json2.Any(d.clause)
		'kind':        json2.Any(d.kind)
		'target':      json2.Any(d.target)
		'pattern':     json2.Any(d.pattern)
		'incurred_by': json2.Any(d.incurred_by)
		'act':         json2.Any(d.act)
	}
}

// settled reports whether the world now satisfies this debt. It is a fact on
// disk — never a claim, never a flag someone can set.
pub fn (d &Debt) settled(root string) bool {
	mut p := d.target
	if root != '' && !os.is_abs_path(p) {
		p = os.join_path(root, p)
	}
	match d.kind {
		'exists' {
			return os.is_file(p)
		}
		'absent' {
			return !os.exists(p)
		}
		'contains' {
			if !os.exists(p) {
				return false
			}
			text := os.read_file(p) or { return false }
			if d.pattern == '' {
				return true
			}
			re := compile_regex(d.pattern) or { return false }
			return re.search(text) != none
		}
		else {
			return true
		}
	}
}

pub fn (d &Debt) describe() string {
	what := match d.kind {
		'exists' { 'must exist' }
		'absent' { 'must not exist' }
		'contains' { "must match '${d.pattern}'" }
		else { 'must hold' }
	}
	return '${d.clause}: ${d.target} ${what} (incurred by ${d.incurred_by})'
}

pub fn parse_oblige_rules(spec string) ([]ObligeRule, []string) {
	mut rules := []ObligeRule{}
	mut errors := []string{}
	mut clause := 'preamble'

	section_re := compile_regex(r'^\s{0,3}§\s*([\d.]+[a-z]?)') or { return rules, errors }
	tag_re := compile_regex(r'^\s{0,3}\[([A-Za-z0-9_.\-]+)\]') or { return rules, errors }
	head_re := compile_regex(r'(?i)^\s*@oblige\b') or { return rules, errors }
	oblige_re := compile_regex(r'(?i)^\s*@oblige\s+on\s+(write|delete)\s+(\S+)\s+require\s+(exists|absent|contains)\s+(\S+)(?:\s+matching\s+(.+))?\s*$') or {
		return rules, errors
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
		m := oblige_re.search(line) or {
			errors << "${clause}: malformed @oblige — expected '@oblige on write <glob> require exists <path>'"
			continue
		}
		kind := group_text(line, &m, 3).to_lower()
		pattern := group_text(line, &m, 5).trim_space()
		if kind == 'contains' && pattern == '' {
			errors << '${clause}: `contains` needs `matching <regex>`'
			continue
		}
		if pattern != '' {
			compile_regex(pattern) or {
				errors << '${clause}: invalid `matching` regex (${err.msg()})'
				continue
			}
		}
		rules << ObligeRule{
			clause:  clause
			act:     group_text(line, &m, 1).to_lower()
			glob:    group_text(line, &m, 2)
			kind:    kind
			target:  group_text(line, &m, 4)
			pattern: pattern
		}
	}
	return rules, errors
}

// expand_target fills the templates a require path may carry.
fn expand_target(target string, path string) string {
	norm := seq_norm(path)
	name := norm.all_after_last('/')
	stem := if name.contains('.') { name.all_before_last('.') } else { name }
	parent := if norm.contains('/') { norm.all_before_last('/') } else { '.' }
	return target.replace('{stem}', stem).replace('{name}', name).replace('{parent}',
		parent).replace('{path}', norm)
}

// glob_deep is the `src/**/*.py` case: it matches at any depth, including
// directly under src/.
fn glob_deep(path string, pattern string) bool {
	if !pattern.contains('**/') {
		return false
	}
	flat := pattern.replace('**/', '')
	return fnmatch_name(path, flat) || fnmatch_name(path, pattern)
}

@[heap]
pub struct Ledger {
pub mut:
	log    &EventLog
	root   string
	rules  []ObligeRule
	errors []string
}

pub fn new_ledger(log &EventLog, spec string, root string) &Ledger {
	mut l := &Ledger{
		log:  unsafe { log }
		root: root
	}
	l.bind(spec)
	return l
}

pub fn (mut l Ledger) bind(spec string) {
	l.rules, l.errors = parse_oblige_rules(spec)
}

// -- incurring ---------------------------------------------------------------

// incurred_by lists the debts a call would create. It is derived from
// EFFECTS, so a write through the shell incurs exactly what write_file would.
pub fn (l &Ledger) incurred_by(tool string, args map[string]json2.Any) []Debt {
	mut out := []Debt{}
	mut seen := map[string]bool{}
	for e in derive(tool, args) {
		if (e.kind != effect_write && e.kind != effect_delete) || e.path == '' {
			continue
		}
		act := if e.kind == effect_write { 'write' } else { 'delete' }
		norm := seq_norm(e.path)
		for rule in l.rules {
			if rule.act != act {
				continue
			}
			if !(fnmatch_name(norm, rule.glob) || fnmatch_name(norm, rule.glob.trim_right('/') + '/*')
				|| glob_deep(norm, rule.glob)) {
				continue
			}
			debt := Debt{
				clause:      rule.clause
				kind:        rule.kind
				target:      expand_target(rule.target, norm)
				pattern:     rule.pattern
				incurred_by: norm
				act:         act
			}
			if !seen[debt.id()] {
				seen[debt.id()] = true
				out << debt
			}
		}
	}
	return out
}

// record seals the debts a completed call incurred.
pub fn (mut l Ledger) record(tool string, args map[string]json2.Any) []Debt {
	debts := l.incurred_by(tool, args)
	for d in debts {
		l.log.append('obligation.incurred', d.to_json(), AppendOpts{ actor: 'kernel' })
	}
	return debts
}

// -- the fold ----------------------------------------------------------------

// outstanding is every debt incurred and not yet satisfied by the world.
//
// Settlement is re-tested against disk on every fold rather than recorded as
// discharged, so a debt that was settled and then undone is outstanding
// again. A ledger that only ever counted down could be satisfied once and
// then quietly broken.
//
// A later act on a path SUPERSEDES the debts an earlier act on that same
// path created. "Writing src/x.py requires tests/test_x.py" and "deleting
// src/x.py requires tests/test_x.py to be gone" are both reasonable clauses,
// and after a write then a delete they contradict each other — a state no
// sequence of actions could ever satisfy. The path's CURRENT act decides, so
// the ledger describes the world as it now is rather than as it once was.
pub fn (mut l Ledger) outstanding() []Debt {
	mut live := map[string]Debt{}
	mut order := []string{}
	mut latest_act := map[string]string{}
	for ev in l.log.events(l.log.branch) {
		if ev.typ != 'obligation.incurred' {
			continue
		}
		d := Debt{
			clause:      jstr(ev.data, 'clause')
			kind:        if k := ev.data['kind'] { k.str() } else { 'exists' }
			target:      jstr(ev.data, 'target')
			pattern:     jstr(ev.data, 'pattern')
			incurred_by: jstr(ev.data, 'incurred_by')
			act:         if a := ev.data['act'] { a.str() } else { 'write' }
		}
		if d.id() !in live {
			order << d.id()
		}
		live[d.id()] = d
		latest_act[d.incurred_by] = d.act
	}
	mut out := []Debt{}
	for id in order {
		d := live[id] or { continue }
		if latest_act[d.incurred_by] or { d.act } != d.act {
			continue
		}
		if !d.settled(l.root) {
			out << d
		}
	}
	return out
}

// blocker is the reason progress cannot be declared complete, or ''.
//
// An obligation never refuses work — the discharging write is itself work —
// it refuses DONE.
pub fn (mut l Ledger) blocker() string {
	debts := l.outstanding()
	if debts.len == 0 {
		return ''
	}
	plural := if debts.len > 1 { 's' } else { '' }
	mut lines := [
		'ObligationOutstanding: ${debts.len} requirement${plural} from the specification are not met yet.',
	]
	for d in debts[..min_int(12, debts.len)] {
		lines << '  ${d.describe()}'
	}
	if debts.len > 12 {
		lines << '  … and ${debts.len - 12} more'
	}
	return lines.join('\n')
}

pub fn (mut l Ledger) report() string {
	if l.rules.len == 0 {
		return 'obligations: no @oblige rules in the specification'
	}
	debts := l.outstanding()
	plural := if l.rules.len > 1 { 's' } else { '' }
	mut lines := ['obligations: ${l.rules.len} rule${plural} · ${debts.len} outstanding']
	for d in debts {
		lines << '  ○ ${d.describe()}'
	}
	for e in l.errors {
		lines << '  !! ${e}'
	}
	return lines.join('\n')
}
