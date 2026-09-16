module vagent

import rand
import x.json2

// consent.v — the exception a human grants once, not the switch they leave on.
//
// A boundary with no override is a boundary that gets turned off. Sooner or
// later a clause refuses something the operator genuinely wants: a one-time
// write outside the project root, a single destructive command during a
// migration, a push during a release. The refusal is correct and the work is
// also correct, and the system offers exactly one way through — disable the
// rule, raise autonomy, edit the spec.
//
// Each of those is unbounded in three directions at once. It applies to
// every path, not the one in question. It lasts for the rest of the session,
// not the moment. And it leaves no record tying the exception to the person
// who wanted it. The rule survives on paper and stops holding in practice,
// which is the failure mode of every security system that made the safe path
// inconvenient.
//
// So consent here is a GRANT: narrow, expiring, single-use by default, and
// sealed.
//
//   * scoped     to one clause and, where given, one path or command
//   * expiring   by wall-clock TTL and by number of uses
//   * consumed   spending a grant is recorded; a used grant is gone
//   * sealed     granted, spent, revoked and exhausted are all events
//
// So "allow this once" is expressible, and nobody has to reach for "allow
// everything from now on".
//
// WHAT A GRANT CANNOT DO. It cannot be created by the agent — grant() is
// called from the approval path a human drives, never from a tool. It cannot
// widen beyond the clause it names. It cannot be open-ended: a grant with no
// TTL and no use limit is rejected at creation, because that is the switch
// this module exists to avoid. And it is never implicit: an un-granted
// refusal stays a refusal.

// a grant may not outlive the hour it was given in
pub const max_grant_ttl = 3600.0
pub const max_grant_uses = 50

pub struct Grant {
pub:
	id     string
	clause string
	// the exact path this applies to; '' means anywhere within the clause
	path string
	// the exact command this applies to
	command    string
	uses       int = 1
	reason     string
	granted_by string = 'human'
pub mut:
	used       int
	expires_at f64
	revoked    bool
}

pub fn (g &Grant) to_json() map[string]json2.Any {
	return {
		'id':         json2.Any(g.id)
		'clause':     json2.Any(g.clause)
		'path':       json2.Any(g.path)
		'command':    json2.Any(g.command)
		'uses':       json2.Any(g.uses)
		'used':       json2.Any(g.used)
		'expires_at': json2.Any(g.expires_at)
		'reason':     json2.Any(g.reason)
		'granted_by': json2.Any(g.granted_by)
		'revoked':    json2.Any(g.revoked)
	}
}

pub fn (g &Grant) live(now f64) bool {
	return !g.revoked && g.used < g.uses && now < g.expires_at
}

pub fn (g &Grant) live_now() bool {
	return g.live(now_ts())
}

// covers reports whether this grant speaks to that refusal.
//
// Scoping is by EXACT value, not by pattern: a grant is an exception to one
// act, and a glob would make it a rule change wearing an exception's clothes.
pub fn (g &Grant) covers(clause string, path string, command string) bool {
	if clause != g.clause {
		return false
	}
	if g.path != '' && same_path(g.path, path) {
		return true
	}
	if g.command != '' && g.command.trim_space() == command.trim_space() {
		return true
	}
	return g.path == '' && g.command == ''
}

pub fn (g &Grant) remaining(now f64) string {
	left := max_int(0, int(g.expires_at - now))
	return '${g.uses - g.used} use(s), ${left}s'
}

// same_path is an exact comparison with . and .. resolved.
//
// A relative path is NOT equal to an absolute one: resolving it needs a
// working directory this module does not know, and guessing wrong would let
// a grant for one file cover a different file. Two paths match only when
// both are anchored the same way.
pub fn same_path(a string, b string) bool {
	return a != '' && sanctum_norm(a) == sanctum_norm(b)
}

@[heap]
pub struct Consent {
pub mut:
	log    &EventLog
	grants []Grant
	spent  int
}

pub fn new_consent(log &EventLog) &Consent {
	return &Consent{
		log: unsafe { log }
	}
}

pub struct GrantOpts {
pub:
	path       string
	command    string
	uses       int = 1
	ttl        f64 = 300.0
	reason     string
	granted_by string = 'human'
}

// grant records a bounded exception. It is called from the human approval
// path.
//
// An unbounded grant is refused at creation rather than accepted and quietly
// capped: an operator who asked for "forever" and received "an hour" would
// believe the wrong thing about their own system.
pub fn (mut c Consent) grant(clause string, opts GrantOpts) !Grant {
	if clause == '' {
		return error('a grant must name the clause it excepts')
	}
	if opts.uses < 1 || opts.uses > max_grant_uses {
		return error('uses must be between 1 and ${max_grant_uses}')
	}
	if opts.ttl <= 0 || opts.ttl > max_grant_ttl {
		return error('ttl must be between 0 and ${max_grant_ttl:.0f}s — a grant that does not expire is the standing override this exists to replace')
	}
	g := Grant{
		id:         rand.uuid_v4().replace('-', '')[..12]
		clause:     clause
		path:       opts.path
		command:    opts.command
		uses:       opts.uses
		used:       0
		expires_at: now_ts() + opts.ttl
		reason:     opts.reason
		granted_by: opts.granted_by
	}
	c.grants << g
	c.log.append('consent.granted', g.to_json(), AppendOpts{ actor: 'human' })
	return g
}

pub fn (mut c Consent) revoke(grant_id string) bool {
	for i, g in c.grants {
		if g.id == grant_id && !g.revoked {
			c.grants[i].revoked = true
			c.log.append('consent.revoked', {
				'id': json2.Any(g.id)
			}, AppendOpts{ actor: 'human' })
			return true
		}
	}
	return false
}

// revoke_all revokes every LIVE grant.
//
// A grant that already expired or was spent is left as it is: restamping it
// as revoked would rewrite why it ended, and the ledger's value is that it
// says what happened.
pub fn (mut c Consent) revoke_all() int {
	now := now_ts()
	mut n := 0
	for i, g in c.grants {
		if g.live(now) {
			c.grants[i].revoked = true
			n++
		}
	}
	if n > 0 {
		c.log.append('consent.revoked_all', {
			'count': json2.Any(n)
		}, AppendOpts{ actor: 'human' })
	}
	return n
}

// -- spending ----------------------------------------------------------------

// find is a live grant covering this refusal, or none. It is read-only.
pub fn (c &Consent) find(clause string, path string, command string) ?int {
	now := now_ts()
	for i, g in c.grants {
		if g.live(now) && g.covers(clause, path, command) {
			return i
		}
	}
	return none
}

// spend consumes one use of a covering grant, if there is one.
pub fn (mut c Consent) spend(clause string, path string, command string) ?Grant {
	idx := c.find(clause, path, command) or { return none }
	c.grants[idx].used++
	c.spent++
	g := c.grants[idx]
	c.log.append('consent.spent', {
		'id':      json2.Any(g.id)
		'clause':  json2.Any(clause)
		'path':    json2.Any(path)
		'command': json2.Any(command)
		'used':    json2.Any(g.used)
		'uses':    json2.Any(g.uses)
	}, AppendOpts{ actor: 'kernel' })
	if g.used >= g.uses {
		c.log.append('consent.exhausted', {
			'id': json2.Any(g.id)
		}, AppendOpts{ actor: 'kernel' })
	}
	return g
}

// narrow returns the violations no live grant covers.
//
// Narrowing only, like an exemption: with nothing refused there is nothing
// to forgive, so a grant can never create permission.
pub fn (mut c Consent) narrow(violations []Violation, tool string, command string) []Violation {
	if violations.len == 0 || c.grants.len == 0 {
		return violations
	}
	mut kept := []Violation{}
	for v in violations {
		if _ := c.spend(v.clause, v.path, command) {
			continue
		}
		kept << v
	}
	return kept
}

// -- observation -------------------------------------------------------------

pub fn (c &Consent) live() []Grant {
	now := now_ts()
	return c.grants.filter(it.live(now))
}

pub fn (c &Consent) report() string {
	if c.grants.len == 0 {
		return 'consent: no grants have been given'
	}
	now := now_ts()
	live := c.live()
	mut lines := ['consent: ${live.len} live · ${c.grants.len} total · ${c.spent} spent']
	for g in c.grants {
		state := if g.live(now) {
			'live'
		} else if g.revoked {
			'revoked'
		} else if g.used >= g.uses {
			'exhausted'
		} else {
			'expired'
		}
		mut scope := g.path
		if scope == '' {
			scope = g.command
		}
		if scope == '' {
			scope = '(whole clause)'
		}
		why := if g.reason != '' { '  — ${g.reason}' } else { '' }
		lines << '  ${g.id}  §' + pad_width(g.clause, 6) + ' ' + pad_width(state, 9) + ' ' +
			pad_width(clip_plain(scope, 34), 36) + ' ${g.remaining(now)}${why}'
	}
	return lines.join('\n')
}
