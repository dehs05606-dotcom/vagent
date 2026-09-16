module vagent

import os
import x.json2

// integrity.v — the specification the model reads and the one it is held to
// must be the same bytes.
//
// Every mechanism in this package rests on one unstated assumption: that the
// text delivered as the system prompt and the text parsed into clauses came
// from the same place and still agree. Nothing else checks it, and there are
// ordinary ways for them to diverge with no error anywhere:
//
//   * The Covenant is bound to one text and the prompt carries another.
//     Rebinding one without the other leaves the agent reading rules it is
//     not held to, or held to rules it was never shown.
//   * A clause is added to the spec but carries no @enforce. It reads as
//     binding and enforces nothing.
//   * A caller passes a spec that is not the one in systemprompt.v, so the
//     boundary silently governs something other than what shipped.
//
// The specification is a constant in systemprompt.v rather than a file,
// which removes the worst of these on its own: there is no path to resolve,
// no environment variable, and nothing to swap between reads. What remains
// here is whether the text the model received and the clauses it is held to
// are the same text — which no amount of file protection can answer.
//
// Each of these is quiet. The system keeps working; only its guarantee is
// gone. A guarantee that fails silently is the most expensive kind, because
// the belief it created outlives it.
//
// So the specification is content-addressed and its identity checked, not
// assumed:
//
//     source      where the bytes came from
//     digest      sha256 of the exact bytes
//     clauses     how many were parsed, and how many bind
//     agreement   prompt bytes == boundary bytes == file on disk
//
// verify() answers all four and names precisely which one broke. It never
// repairs anything on its own: a specification that silently reloaded
// itself mid-session would be a worse failure than a stale one, because the
// rules would change under an agent already part-way through acting on
// them. Drift is REPORTED and the reconciliation is an explicit act
// (/prompt reload), which is itself sealed.

pub const integrity_ok = 'ok'
pub const integrity_drifted = 'drifted' // disk no longer matches what is loaded
pub const integrity_split = 'split' // prompt and boundary disagree
pub const integrity_absent = 'absent' // no specification at all

pub fn spec_digest(text string) string {
	return hash(text)
}

pub fn spec_short(text string) string {
	return spec_digest(text)[..16]
}

// Seal is the identity of a specification at a moment in time.
pub struct Seal {
pub mut:
	source   string
	digest   string
	chars    int
	clauses  int
	enforced int
}

pub fn (s &Seal) to_json() map[string]json2.Any {
	return {
		'source':   json2.Any(s.source)
		'digest':   json2.Any(s.digest)
		'chars':    json2.Any(s.chars)
		'clauses':  json2.Any(s.clauses)
		'enforced': json2.Any(s.enforced)
	}
}

pub struct IntegrityReport {
pub:
	state    string
	seal     Seal
	problems []string
}

// ok is true only when nothing at all was worth reporting. A report that
// read "ok" while carrying problems would be the exact silent failure this
// module exists to remove.
pub fn (r &IntegrityReport) ok() bool {
	return r.state == integrity_ok && r.problems.len == 0
}

pub fn (r &IntegrityReport) describe() string {
	if r.state == integrity_absent {
		return 'integrity: no specification is loaded — the boundary ' +
			"governs nothing and 'master' is the compact prompt"
	}
	head := 'integrity: ${thousands(r.seal.chars)} chars · ${r.seal.clauses} ' +
		'clauses (${r.seal.enforced} enforced) · ${r.seal.digest[..16]} · ${r.seal.source}'
	if r.ok() {
		return head + '\n  prompt, boundary and file on disk agree'
	}
	return head + '\n  ' + r.problems.join('\n  ')
}

// Integrity is content-addressed identity for the live specification.
@[heap]
pub struct Integrity {
pub mut:
	log        &EventLog
	sealed     Seal
	has_sealed bool
}

pub fn new_integrity(log &EventLog) &Integrity {
	return &Integrity{
		log: unsafe { log }
	}
}

// -- sealing -----------------------------------------------------------------

// seal records the identity of the specification now in force.
pub fn (mut i Integrity) seal(spec_text string, source string, covenant &Covenant) Seal {
	mut s := Seal{
		source: source
		digest: spec_digest(spec_text)
		chars:  spec_text.len
	}
	if covenant != unsafe { nil } {
		s.clauses = covenant.clauses.len
		s.enforced = covenant.enforced_clauses().len
	}
	i.sealed = s
	i.has_sealed = true
	i.log.append('integrity.sealed', s.to_json(), AppendOpts{ actor: 'kernel' })
	return s
}

// -- verification ------------------------------------------------------------

// verify checks that the prompt's bytes, the boundary's clauses and the
// file on disk are still one specification.
pub fn (mut i Integrity) verify(prompt_spec string, covenant &Covenant, source string) IntegrityReport {
	src := if source != '' {
		source
	} else if i.has_sealed {
		i.sealed.source
	} else {
		''
	}
	mut s := Seal{
		source: src
		digest: spec_digest(prompt_spec)
		chars:  prompt_spec.len
	}
	if covenant != unsafe { nil } {
		s.clauses = covenant.clauses.len
		s.enforced = covenant.enforced_clauses().len
	}
	if prompt_spec.trim_space() == '' {
		return IntegrityReport{
			state: integrity_absent
			seal:  s
		}
	}

	mut problems := []string{}
	mut state := integrity_ok

	// 1. does the boundary hold the same text the prompt carries?
	if covenant != unsafe { nil } {
		rebuilt := covenant_clause_digest(covenant.clauses)
		from_prompt_clauses, _ := parse_clauses(prompt_spec)
		if rebuilt != '' && rebuilt != covenant_clause_digest(from_prompt_clauses) {
			problems << "the boundary's clauses were not parsed from the " +
				"prompt's bytes — reload both with /prompt reload"
			state = integrity_split
		}
	}

	// 2. does the file on disk still match what is loaded?
	if src != '' {
		if !os.exists(src) {
			problems << 'the specification file is unreadable (missing) — ' +
				'the loaded copy is still in force'
			if state == integrity_ok {
				state = integrity_drifted
			}
		} else {
			on_disk := os.read_file(src) or { '' }
			if spec_digest(on_disk) != s.digest {
				problems << '${src} has changed since it was loaded ' +
					'(${thousands(on_disk.len)} chars on disk vs ' +
					'${thousands(s.chars)} in force) — the agent is being held ' +
					'to the loaded copy, not the edited one'
				if state == integrity_ok {
					state = integrity_drifted
				}
			}
		}
	}

	// 3. did it change identity since it was sealed?
	if i.has_sealed && i.sealed.digest != s.digest {
		problems << 'the specification changed within this session ' +
			'(${i.sealed.digest[..16]} -> ${s.digest[..16]})'
		if state == integrity_ok {
			state = integrity_drifted
		}
	}

	// 4. a specification that binds nothing is worth saying out loud
	if covenant != unsafe { nil } && s.clauses > 0 && s.enforced == 0 {
		problems << '${s.clauses} clauses are loaded and none carries an ' +
			'@enforce rule — the specification is prose to the boundary'
	}

	report := IntegrityReport{
		state:    state
		seal:     s
		problems: problems
	}
	if !report.ok() {
		mut payload := s.to_json()
		payload['state'] = state
		payload['problems'] = strs_to_any(problems)
		i.log.append('integrity.drift', payload, AppendOpts{ actor: 'kernel' })
	}
	return report
}

// covenant_clause_digest hashes a clause list by fingerprint and guards, so
// two boundaries parsed from the same bytes hash identically and two parsed
// from different bytes do not.
fn covenant_clause_digest(clauses []Clause) string {
	mut parts := []string{}
	for c in clauses {
		parts << c.fingerprint()
		for g in c.guards {
			parts << canonical(json2.Any(g.to_json()))
		}
	}
	return hash(parts.join('\x00'))
}
