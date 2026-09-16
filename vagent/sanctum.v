module vagent

import os
import x.json2

// sanctum.v — the boundary cannot be edited by what it binds.
//
// Every rule in this package is authored in the specification. That is the
// right design for rules about the project, and a circular one for the rule
// that protects the rules:
//
//     §99 The agent never edits the enforcement code.
//     @enforce forbid_path: vagent/covenant.v
//
// A clause lives in the specification. Editing the specification removes the
// clause. So a clause that forbids editing the specification is removed by
// the very act it forbids, and protects nothing. The same holds one level
// down: a guard that protects covenant.v is code inside covenant.v. Rewrite
// the file and the guard goes with it. Any protection expressed in the thing
// being protected is not protection; it is a comment.
//
// So this invariant is NOT a clause:
//
//   * It is not written in the specification, so editing the specification
//     cannot remove it.
//   * It takes no @enforce syntax, so a malformed rule cannot disable it.
//   * It is not narrowable. An exception here is indistinguishable from the
//     attack.
//   * It runs FIRST, before any clause, so it holds even when the
//     specification is empty, absent or entirely malformed.
//
// It protects two things — the enforcement modules and the specification
// file in force — both by content address, so a change made by a route this
// module never anticipated is still detected on the next verify() even
// though it could not be refused.
//
// SCOPE, stated precisely. This governs the AGENT's tool calls. It is not a
// filesystem permission and does not try to be: a human developing this
// project edits these files directly, with an editor, and should. The claim
// is narrow and exact — the agent cannot rewrite the rules that bind it
// while being bound by them.
//
// WHAT IT CANNOT DO. A process with a shell can eventually reach any file;
// what it cannot do is get that write through this gate, and every route the
// effect vocabulary can name goes through this gate. Routes it cannot name
// are not refused, but the content addresses make the result visible rather
// than silent, which is the difference between a boundary that failed and
// one that was never there.

// The modules that make up the boundary. Named explicitly rather than
// globbed: a glob over the package would also protect ordinary code, and a
// protection that covers everything is one an operator will switch off.
pub const protected_modules = [
	'sanctum.v', // first, and itself
	'charter.v',
	'covenant.v',
	'effects.v',
	'exemption.v',
	'consent.v',
	'egress.v',
	'horizon.v',
	'ration.v',
	'obligation.v',
	'sequence.v',
	'provenance.v',
	'sentinel.v',
	'escrow.v',
	'integrity.v',
	'witness.v',
	'audit.v',
	'attest.v',
	'remedy.v',
	'replay.v',
	'systemprompt.v', // the prompt's single source
]

fn file_digest(path string) string {
	data := os.read_bytes(path) or { return '' }
	return hash(data.bytestr())
}

// sanctum_norm collapses . and .. and keeps a leading slash, so a call
// naming the same file by a different spelling is still matched.
fn sanctum_norm(path string) string {
	anchor := if path.starts_with('/') { '/' } else { '' }
	mut parts := []string{}
	for part in path.replace('\\', '/').split('/') {
		if part == '' {
			continue
		}
		if part == '..' {
			if parts.len > 0 {
				parts.delete_last()
			}
			continue
		}
		if part == '.' {
			continue
		}
		parts << part
	}
	return anchor + parts.join('/')
}

// SanctumBreach is an act that would change the boundary itself.
pub struct SanctumBreach {
pub:
	// module | specification
	what   string
	path   string
	effect string
}

pub fn (b &SanctumBreach) to_json() map[string]json2.Any {
	return {
		'what':   json2.Any(b.what)
		'path':   json2.Any(b.path)
		'effect': json2.Any(b.effect)
	}
}

pub fn (b &SanctumBreach) describe() string {
	return "${b.effect} to '${b.path}' would change the ${b.what} that is enforcing this very call"
}

// SanctumChange is a protected file whose content no longer matches what was
// sealed.
pub struct SanctumChange {
pub:
	what string
	path string
	was  string
	now  string
}

pub fn (c &SanctumChange) describe() string {
	if c.now == '' {
		return "${c.what} '${c.path}' has been removed or is unreadable"
	}
	return "${c.what} '${c.path}' changed since startup (${c.was[..12]} -> ${c.now[..12]})"
}

@[heap]
pub struct Sanctum {
pub mut:
	log &EventLog
	// the directory the boundary's own sources live in. It may be empty —
	// a built binary has no source tree beside it — and the tail matching
	// in what_is still catches the spelling a patch uses.
	dir         string
	spec_source string
	blocked     int
mut:
	sealed map[string]string
}

pub fn new_sanctum(log &EventLog, spec_source string, package_dir string) &Sanctum {
	mut s := &Sanctum{
		log:         unsafe { log }
		dir:         package_dir
		spec_source: spec_source
	}
	s.seal()
	return s
}

// -- content addresses -------------------------------------------------------

// protected_paths maps an absolute normalised path to what it is.
pub fn (s &Sanctum) protected_paths() map[string]string {
	mut out := map[string]string{}
	if s.dir != '' {
		for name in protected_modules {
			out[sanctum_norm(os.join_path(s.dir, name))] = 'module'
		}
	}
	if s.spec_source != '' {
		out[sanctum_norm(s.spec_source)] = 'specification'
	}
	return out
}

// seal records the content address of everything protected.
pub fn (mut s Sanctum) seal() map[string]string {
	s.sealed = map[string]string{}
	for path, _ in s.protected_paths() {
		d := file_digest(path)
		if d != '' {
			s.sealed[path] = d
		}
	}
	s.log.append('sanctum.sealed', {
		'files': json2.Any(s.sealed.len)
		'dir':   json2.Any(s.dir)
		'spec':  json2.Any(s.spec_source)
	}, AppendOpts{ actor: 'kernel' })
	return s.sealed.clone()
}

// verify lists the protected files that have changed since they were sealed.
pub fn (mut s Sanctum) verify() []SanctumChange {
	protected := s.protected_paths()
	mut out := []SanctumChange{}
	for path, was in s.sealed {
		now := file_digest(path)
		if now != was {
			out << SanctumChange{
				what: protected[path] or { 'module' }
				path: path
				was:  was
				now:  now
			}
		}
	}
	if out.len > 0 {
		s.log.append('sanctum.changed', {
			'changes': json2.Any(out.map(json2.Any(it.describe())))
		}, AppendOpts{ actor: 'kernel' })
	}
	return out
}

// -- the gate ----------------------------------------------------------------

// what_is names which protected thing `raw` refers to, or ''.
//
// A protected file has many true spellings: absolute, relative to the
// working directory, relative to the package, and — the one a patch actually
// uses — `vagent/covenant.v` from the repository root. Matching only the
// absolute form would leave every other spelling a way in.
fn (s &Sanctum) what_is(raw string) string {
	protected := s.protected_paths()
	mut candidates := [sanctum_norm(resolve_path(raw))]
	if !os.is_abs_path(raw) {
		candidates << sanctum_norm(os.join_path(os.getwd(), raw))
		if s.dir != '' {
			candidates << sanctum_norm(os.join_path(s.dir, raw))
			candidates << sanctum_norm(os.join_path(os.dir(s.dir), raw))
		}
	}
	for key in candidates {
		if what := protected[key] {
			return what
		}
	}
	// `<package>/<module>` named from anywhere above it
	tail := sanctum_norm(raw)
	pkg := if s.dir != '' { os.base(s.dir) } else { 'vagent' }
	for name in protected_modules {
		if tail == '${pkg}/${name}' || tail.ends_with('/${pkg}/${name}') {
			return 'module'
		}
	}
	if s.spec_source != '' {
		spec_tail := os.base(s.spec_source)
		if tail == spec_tail || tail.ends_with('/' + spec_tail) {
			// only when it really is that file, not any same-named one
			for key in candidates {
				if what := protected[key] {
					return what
				}
			}
		}
	}
	return ''
}

// check lists the acts that would change the boundary. It judges EFFECTS, so
// the shell, a patch and a direct write are the same act here too.
pub fn (s &Sanctum) check(tool string, args map[string]json2.Any) []SanctumBreach {
	mut out := []SanctumBreach{}
	for e in derive(tool, args) {
		if (e.kind != effect_write && e.kind != effect_delete) || e.path == '' {
			continue
		}
		what := s.what_is(e.path)
		if what != '' {
			out << SanctumBreach{
				what:   what
				path:   e.path
				effect: e.kind
			}
		}
	}
	return out
}

// gate is the block reason, or '' to allow. It is consulted before any
// clause and is never narrowed.
pub fn (mut s Sanctum) gate(tool string, args map[string]json2.Any) string {
	breaches := s.check(tool, args)
	if breaches.len == 0 {
		return ''
	}
	s.blocked++
	s.log.append('sanctum.blocked', {
		'tool':     json2.Any(tool)
		'breaches': json2.Any(breaches.map(json2.Any(it.to_json())))
	}, AppendOpts{ actor: 'kernel' })
	mut lines := ['SanctumViolation: this call would change the boundary that is enforcing it.']
	for b in breaches {
		lines << '  ${b.describe()}'
	}
	lines << '  This is not a clause and cannot be excepted or granted. Edit these files directly if you intend to change the rules.'
	return lines.join('\n')
}

pub fn (mut s Sanctum) report() string {
	changes := s.verify()
	head := 'sanctum: ${s.sealed.len} protected file(s) · ${s.blocked} call(s) refused'
	if changes.len == 0 {
		return head + '\n  every protected file matches what was sealed'
	}
	return head + '\n' + changes.map('  !! ${it.describe()}').join('\n')
}
