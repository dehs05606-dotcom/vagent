module vagent

import os
import x.json2

// remedy.v — a refusal that says what WOULD be allowed.
//
// A boundary that only ever says no produces a predictable failure, and it
// is not disobedience. The agent tries a write, is refused, tries a
// near-variant, is refused, tries another. Each attempt is individually
// reasonable — it has been told that this act is forbidden, never what a
// permitted act looks like — and the loop burns the turn without a single
// line of useful work. Every refusal was correct and the outcome is still a
// failure.
//
// Compilers solved this decades ago. `undefined name 'lenght'` is a bad
// error; `undefined name 'lenght' — did you mean 'length'?` is a good one,
// and the difference is not politeness. The second carries the information
// needed to act, so the next attempt is informed rather than a guess.
//
// So every refusal is paired with the nearest compliant act, computed from
// the clause that refused rather than suggested by a model. Two properties
// keep this from becoming a hole:
//
//   1. A REMEDY IS NOT PERMISSION. It is a sentence. The suggested act goes
//      through the same gate as any other and is refused in turn if some
//      other clause objects. Nothing here can approve anything.
//   2. IT IS DERIVED, NEVER GUESSED. Each remedy is computed from the
//      guard's own parameters — its roots, its globs, its regex. When a
//      clause gives nothing to compute from, this says so instead of
//      inventing a plausible-sounding suggestion, which would be worse than
//      silence because the agent would act on it.

pub struct Suggestion {
pub:
	clause string
	// a concrete, checkable next step
	action    string
	rationale string
}

pub fn (s &Suggestion) to_json() map[string]json2.Any {
	return {
		'clause':    json2.Any(s.clause)
		'action':    json2.Any(s.action)
		'rationale': json2.Any(s.rationale)
	}
}

fn remedy_basename(path string) string {
	name := os.base(seq_norm(path))
	return if name != '' && name != '.' { name } else { 'file' }
}

// nearest_root is the permitted root sharing most with the refused path, so
// the suggestion lands where the author most plausibly meant.
fn nearest_root(path string, roots []string) string {
	if roots.len == 0 {
		return ''
	}
	norm := seq_norm(path)
	segments := norm.split('/')
	mut best := roots[0]
	mut score := -1
	for r in roots {
		rn := seq_norm(r)
		mut common := 0
		rn_parts := rn.split('/')
		for i in 0 .. min_int(segments.len, rn_parts.len) {
			if segments[i] != rn_parts[i] {
				break
			}
			common++
		}
		// a root whose name appears anywhere in the path is a better guess
		if rn != '' && rn in segments {
			common += 2
		}
		if common > score {
			best = r
			score = common
		}
	}
	return best
}

// remedy_for_violation is the compliant alternative to one covenant
// violation, or none when the clause gives nothing to compute from.
pub fn remedy_for_violation(v &Violation, guards []Guard) ?Suggestion {
	kind := v.kind
	clause := if v.clause != '' { v.clause } else { '?' }
	path := v.path
	mut guard := Guard{}
	mut have_guard := false
	for g in guards {
		if g.clause == clause && g.kind == kind {
			guard = g
			have_guard = true
			break
		}
	}

	match kind {
		'confine_paths' {
			if !have_guard || guard.roots.len == 0 {
				return none
			}
			root := nearest_root(path, guard.roots)
			return Suggestion{
				clause:    clause
				action:    'write to ${root.trim_right("/")}/${remedy_basename(path)} instead'
				rationale: 'this clause permits only ${guard.roots.join(", ")}'
			}
		}
		'forbid_path' {
			globs := if have_guard { guard.globs.clone() } else { []string{} }
			where := if globs.len > 0 { globs.join(', ') } else { 'the forbidden pattern' }
			return Suggestion{
				clause:    clause
				action:    "choose a path for '${remedy_basename(path)}' outside ${where}"
				rationale: 'the filename is fine; the location is not'
			}
		}
		'require_content' {
			value := if have_guard { guard.value } else { '' }
			where := if have_guard { guard.where } else { '' }
			subject := if path != '' { path } else { where }
			return Suggestion{
				clause:    clause
				action:    "add the required content to '${subject}' before writing it — the clause requires a match for '${value}'"
				rationale: if where != '' { "applies to files matching '${where}'" } else { '' }
			}
		}
		'forbid_content' {
			mut span := ''
			if re := compile_regex(r"pattern: \x27([^\x27]*)\x27") {
				if m := re.search(v.detail) {
					span = group_text(v.detail, &m, 1)
				}
			}
			action := if span != '' {
				"remove '${span}' from the content and write the rest"
			} else {
				'remove the offending span and write the rest'
			}
			return Suggestion{
				clause:    clause
				action:    action
				rationale: 'only that span is refused, not the whole write'
			}
		}
		'forbid_tool' {
			value := if have_guard { guard.value } else { '' }
			action := match value {
				'delete_path' {
					'leave the file in place, or move it with move_path if it must go'
				}
				'run_command' {
					'use write_file / edit_file for file changes'
				}
				'apply_patch' {
					'make the same edits with edit_file'
				}
				else {
					"use a tool other than '${value}'"
				}
			}
			return Suggestion{
				clause:    clause
				action:    action
				rationale: "'${value}' is forbidden by this clause"
			}
		}
		'forbid_effect' {
			effect := v.detail.all_before(' ')
			action := match effect {
				'delete' {
					'leave the file in place; if it must stop being used, empty it or move it aside'
				}
				'write' {
					'read-only work only under this clause'
				}
				'opaque' {
					'use a command whose effects can be read ahead of time — a literal redirect rather than eval or a shell -c'
				}
				else {
					'avoid the ${if effect != "" { effect } else { "forbidden" }} effect'
				}
			}
			return Suggestion{
				clause:    clause
				action:    action
				rationale: 'the act is refused by any route, not just this one'
			}
		}
		'forbid_command' {
			return Suggestion{
				clause:    clause
				action:    'rewrite the command without the forbidden form'
				rationale: 'the pattern is matched against the command text'
			}
		}
		else {
			return none
		}
	}
}

// remedy_for_breach is the compliant alternative to a horizon breach.
pub fn remedy_for_breach(b &Breach) Suggestion {
	room := f64(b.limit - b.current)
	if room <= 0 {
		tail := if b.window == 'turn' {
			'start a new turn'
		} else {
			'the limit is for the whole session'
		}
		return Suggestion{
			clause:    b.clause
			action:    'this ${b.window} has no ${b.measure} left — ${tail}'
			rationale: '${b.measure} is capped at ${b.limit} per ${b.window}'
		}
	}
	return Suggestion{
		clause:    b.clause
		action:    'reduce this call to at most ${room:.0f} more ${b.measure}, or split it across turns'
		rationale: '${b.current} of ${b.limit} ${b.measure} already used this ${b.window}'
	}
}

// remedy_for_overspend is the same, for a ration budget.
pub fn remedy_for_overspend(o &Overspend) Suggestion {
	room := o.limit - o.spent
	if room <= 0 {
		tail := if o.window == 'turn' {
			'start a new turn'
		} else {
			'the limit is for the whole session'
		}
		return Suggestion{
			clause:    o.clause
			action:    'this ${o.window} has no ${o.measure} left — ${tail}'
			rationale: '${o.measure} is capped at ${ration_fmt(o.measure, o.limit)} per ${o.window}'
		}
	}
	return Suggestion{
		clause:    o.clause
		action:    'reduce this call to at most ${ration_fmt(o.measure, room)} more ${o.measure}, or split it across turns'
		rationale: '${ration_fmt(o.measure, o.spent)} of ${ration_fmt(o.measure, o.limit)} ${o.measure} already used this ${o.window}'
	}
}

// annotate appends the compliant alternatives to a refusal message.
//
// A refusal with no derivable remedy is returned UNCHANGED rather than
// padded with a generic line: "try something else" is noise, and noise in an
// error message is how error messages stop being read.
pub fn annotate(refusal string, violations []Violation, guards []Guard, breaches []Breach, overspend []Overspend) string {
	mut out := []Suggestion{}
	for v in violations {
		if s := remedy_for_violation(&v, guards) {
			out << s
		}
	}
	for b in breaches {
		out << remedy_for_breach(&b)
	}
	for o in overspend {
		out << remedy_for_overspend(&o)
	}
	if out.len == 0 {
		return refusal
	}

	mut seen := map[string]bool{}
	mut lines := [refusal, '', 'What would be allowed:']
	for s in out {
		if seen[s.action] {
			continue
		}
		seen[s.action] = true
		tail := if s.rationale != '' { '  (${s.rationale})' } else { '' }
		lines << '  ${s.clause}: ${s.action}${tail}'
	}
	lines << '  — a suggestion, not permission: it is gated like any other call'
	return lines.join('\n')
}
