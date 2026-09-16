module vagent

import x.json2

// egress.v — the effects that leave the machine.
//
// Every effect the boundary can name so far is a filesystem effect: writes,
// deletes, execs. That is a complete vocabulary for what the agent does to
// the project, and it says nothing at all about what the agent sends OUT of
// it — the one category of effect that cannot be reverted, cannot be
// contained afterwards, and cannot be undone by a snapshot.
//
//     a write to /etc/passwd is bad and recoverable.
//     a POST of /etc/passwd is recoverable by nobody.
//
// curl, wget, scp, rsync, nc, ssh and git push all exist, and each can carry
// the contents of the project to a host the specification never approved.
// Until this module, every one of them derived either no effect at all or a
// bare exec that no clause could read.
//
// So egress is a first-class effect with its own vocabulary — host, method,
// and what it carries when that can be determined — and its own guards,
// because the questions are different from the filesystem ones:
//
//     §8 The agent reaches only the package index and our own origin.
//     @egress allow_hosts pypi.org, files.pythonhosted.org, github.com
//
//     §9 Nothing leaves this machine carrying project data.
//     @egress forbid_upload
//
// ALLOWLIST, NOT DENYLIST. allow_hosts refuses every host it does not name,
// including one it has never heard of. A denylist of bad hosts is unbounded
// and always one entry behind; an allowlist is finite and its gaps fail
// closed. A host that cannot be determined before the command runs — a URL
// in a variable, a piped installer — is refused under an allowlist for the
// same reason an opaque write is refused under containment: it cannot be
// shown to be permitted.

// GET-shaped: pulling bytes in
pub const egress_fetch = 'fetch'
// sending a payload
pub const egress_post = 'post'
// a file transfer out
pub const egress_upload = 'upload'
// a version-control publish
pub const egress_push = 'push'
// a raw socket, reverse shell or port forward
pub const egress_tunnel = 'tunnel'
pub const egress_methods = [egress_fetch, egress_post, egress_upload, egress_push,
	egress_tunnel]

// a host that cannot be determined before the command runs
pub const unknown_host = '?'

const post_flags = ['-d', '--data', '--data-binary', '--data-raw', '-F', '--form',
	'-T', '--upload-file', '-X']

fn net_tool_method(name string) ?string {
	return match name {
		'curl', 'wget', 'http', 'httpie' { egress_fetch }
		'scp', 'sftp', 'rsync' { egress_upload }
		'nc', 'ncat', 'netcat', 'socat', 'telnet', 'ssh' { egress_tunnel }
		else { none }
	}
}

pub struct Egress {
pub:
	method string
	host   string
	// a path or an inline payload, when determinable
	carries string
	reason  string
}

pub fn (e &Egress) to_json() map[string]json2.Any {
	mut d := {
		'method': json2.Any(e.method)
		'host':   json2.Any(e.host)
	}
	if e.carries != '' {
		d['carries'] = json2.Any(clip_plain(e.carries, 200))
	}
	if e.reason != '' {
		d['reason'] = json2.Any(e.reason)
	}
	return d
}

pub struct EgressRule {
pub:
	clause string
	kind   string
	hosts  []string
	method string
}

pub fn (r &EgressRule) to_json() map[string]json2.Any {
	mut d := {
		'clause': json2.Any(r.clause)
		'kind':   json2.Any(r.kind)
	}
	if r.hosts.len > 0 {
		d['hosts'] = json2.Any(r.hosts.map(json2.Any(it)))
	}
	if r.method != '' {
		d['method'] = json2.Any(r.method)
	}
	return d
}

pub struct EgressBreach {
pub:
	clause string
	kind   string
	detail string
}

pub fn (b &EgressBreach) to_json() map[string]json2.Any {
	return {
		'clause': json2.Any(b.clause)
		'kind':   json2.Any(b.kind)
		'detail': json2.Any(b.detail)
	}
}

// ---------------------------------------------------------------------------
// derivation
// ---------------------------------------------------------------------------

// host_of reads a host out of a token: a URL, or the host half of an scp
// target.
pub fn host_of(token string) string {
	if re := compile_regex(r'(?i)\b(?:https?|ftp|ssh|git)://([^/\s\x27"]+)') {
		if m := re.search(token) {
			raw := group_text(token, &m, 1)
			return raw.all_after_last('@').all_before(':').to_lower()
		}
	}
	if re := compile_regex(r'(?i)\b(?:[\w.\-]+@)?([\w.\-]+):[^\s]') {
		if m := re.search(token) {
			return group_text(token, &m, 1).to_lower()
		}
	}
	return ''
}

fn has_dynamic_egress(seg string) bool {
	return seg.contains('\$') || seg.contains('`')
}

// derive_egress_command is the egress effects of a shell command line.
pub fn derive_egress_command(command string) []Egress {
	mut out := []Egress{}
	assign_re := compile_regex(r'^[A-Za-z_][A-Za-z0-9_]*=') or { return out }
	bare_host_re := compile_regex(r'^(?:[\w.\-]+@)?[\w.\-]+\.[A-Za-z]{2,}$') or { return out }

	for segment in split_segments(command) {
		seg := segment.trim_space()
		if seg == '' {
			continue
		}
		mut tokens, ok := shell_split(seg)
		if !ok {
			tokens = seg.split(' ').filter(it != '')
		}
		// leading VAR=value assignments are not the command
		for tokens.len > 0 {
			if _ := assign_re.search(tokens[0]) {
				tokens.delete(0)
			} else {
				break
			}
		}
		if tokens.len == 0 {
			continue
		}
		name := tokens[0].all_after_last('/')
		rest := tokens[1..].clone()

		if name == 'git' && rest.len > 0 && rest[0] == 'push' {
			mut host := ''
			for t in rest {
				h := host_of(t)
				if h != '' {
					host = h
					break
				}
			}
			out << Egress{
				method: egress_push
				host:   if host != '' { host } else { unknown_host }
				reason: 'git push'
			}
			continue
		}

		mut method := net_tool_method(name) or { continue }

		mut host := ''
		for t in tokens {
			h := host_of(t)
			if h != '' {
				host = h
				break
			}
		}
		if host == '' {
			// a bare host argument: nc example.com 4444, ssh user@host
			for t in rest {
				if t.starts_with('-') {
					continue
				}
				if _ := bare_host_re.search(t) {
					host = t.all_after_last('@').to_lower()
					break
				}
			}
		}
		if host == '' || has_dynamic_egress(seg) {
			host = unknown_host
		}

		mut carries := ''
		if method == egress_fetch {
			mut is_post := false
			for f in post_flags {
				if f in rest {
					is_post = true
					break
				}
			}
			if is_post {
				method = egress_post
				for i, t in rest {
					if t in post_flags && i + 1 < rest.len {
						carries = rest[i + 1]
						break
					}
				}
			}
		} else if method == egress_upload {
			for t in rest {
				if !t.starts_with('-') && host_of(t) == '' {
					carries = t
					break
				}
			}
		}
		out << Egress{
			method:  method
			host:    host
			carries: carries
			reason:  '${name} command'
		}
	}
	return out
}

// derive_egress is the egress effects of any tool call.
pub fn derive_egress(tool string, args map[string]json2.Any) []Egress {
	if tool in shell_tools {
		return derive_egress_command(jstr(args, 'command'))
	}
	if tool == 'web_fetch' {
		url := jstr(args, 'url')
		h := host_of(url)
		return [
			Egress{
				method: egress_fetch
				host:   if h != '' { h } else { unknown_host }
				reason: 'web_fetch'
			},
		]
	}
	if tool == 'web_search' {
		return [
			Egress{
				method: egress_fetch
				host:   'search'
				reason: 'web_search'
			},
		]
	}
	return []
}

// ---------------------------------------------------------------------------
// rules
// ---------------------------------------------------------------------------

pub fn parse_egress_rules(spec string) ([]EgressRule, []string) {
	mut rules := []EgressRule{}
	mut errors := []string{}
	mut clause := 'preamble'

	section_re := compile_regex(r'^\s{0,3}§\s*([\d.]+[a-z]?)') or { return rules, errors }
	tag_re := compile_regex(r'^\s{0,3}\[([A-Za-z0-9_.\-]+)\]') or { return rules, errors }
	head_re := compile_regex(r'(?i)^\s*@egress\b') or { return rules, errors }
	guard_re := compile_regex(r'(?i)^\s*@egress\s+(allow_hosts|forbid_hosts|forbid_method|forbid_upload|forbid_all)(?:\s+(.+?))?\s*$') or {
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
		m := guard_re.search(line) or {
			errors << "${clause}: malformed @egress — expected 'allow_hosts <a, b>', " +
				"'forbid_hosts <a>', 'forbid_method <m>', 'forbid_upload' or 'forbid_all'"
			continue
		}
		kind := group_text(line, &m, 1).to_lower()
		rest := group_text(line, &m, 2).trim_space()
		if kind == 'allow_hosts' || kind == 'forbid_hosts' {
			mut hosts := []string{}
			for h in rest.split(',') {
				t := h.trim_space().to_lower()
				if t != '' {
					hosts << t
				}
			}
			if hosts.len == 0 {
				errors << '${clause}: ${kind} needs at least one host'
				continue
			}
			rules << EgressRule{
				clause: clause
				kind:   kind
				hosts:  hosts
			}
		} else if kind == 'forbid_method' {
			if rest.to_lower() !in egress_methods {
				errors << "${clause}: unknown method '${rest}' — known: ${egress_methods.join(", ")}"
				continue
			}
			rules << EgressRule{
				clause: clause
				kind:   kind
				method: rest.to_lower()
			}
		} else {
			rules << EgressRule{
				clause: clause
				kind:   kind
			}
		}
	}
	return rules, errors
}

fn host_allowed(host string, allowed []string) bool {
	if host == unknown_host {
		// it cannot be shown to be permitted
		return false
	}
	for a in allowed {
		if host == a || host.ends_with('.' + a) {
			return true
		}
	}
	return false
}

fn host_matches_any(host string, hosts []string) bool {
	for h in hosts {
		if host == h || host.ends_with('.' + h) {
			return true
		}
	}
	return false
}

@[heap]
pub struct Perimeter {
pub mut:
	log     &EventLog
	rules   []EgressRule
	errors  []string
	blocked int
	cleared int
}

pub fn new_perimeter(log &EventLog, spec string) &Perimeter {
	mut p := &Perimeter{
		log: unsafe { log }
	}
	p.bind(spec)
	return p
}

pub fn (mut p Perimeter) bind(spec string) {
	p.rules, p.errors = parse_egress_rules(spec)
}

pub fn (p &Perimeter) check(tool string, args map[string]json2.Any) []EgressBreach {
	if p.rules.len == 0 {
		return []
	}
	mut out := []EgressBreach{}
	for e in derive_egress(tool, args) {
		for r in p.rules {
			match r.kind {
				'forbid_all' {
					out << EgressBreach{
						clause: r.clause
						kind:   r.kind
						detail: "${e.method} to '${e.host}' — this agent makes no network calls"
					}
				}
				'allow_hosts' {
					if !host_allowed(e.host, r.hosts) {
						why := if e.host == unknown_host {
							'the host cannot be determined before the command runs'
						} else {
							"'${e.host}' is not on the allowlist"
						}
						out << EgressBreach{
							clause: r.clause
							kind:   r.kind
							detail: '${e.method}: ${why} [${r.hosts.join(", ")}]'
						}
					}
				}
				'forbid_hosts' {
					if host_matches_any(e.host, r.hosts) {
						out << EgressBreach{
							clause: r.clause
							kind:   r.kind
							detail: "${e.method} to '${e.host}' is forbidden"
						}
					}
				}
				'forbid_method' {
					if e.method == r.method {
						out << EgressBreach{
							clause: r.clause
							kind:   r.kind
							detail: "${e.method} to '${e.host}' is forbidden"
						}
					}
				}
				'forbid_upload' {
					if e.method == egress_post || e.method == egress_upload
						|| e.method == egress_push {
						carries := if e.carries != '' { " carrying '${e.carries}'" } else { '' }
						out << EgressBreach{
							clause: r.clause
							kind:   r.kind
							detail: "${e.method} to '${e.host}'${carries} — nothing leaves this machine"
						}
					}
				}
				else {}
			}
		}
	}
	return out
}

pub fn (mut p Perimeter) gate(tool string, args map[string]json2.Any) string {
	breaches := p.check(tool, args)
	if breaches.len == 0 {
		if p.rules.len > 0 && derive_egress(tool, args).len > 0 {
			p.cleared++
		}
		return ''
	}
	p.blocked++
	p.log.append('egress.blocked', {
		'tool':     json2.Any(tool)
		'breaches': json2.Any(breaches.map(json2.Any(it.to_json())))
	}, AppendOpts{ actor: 'kernel' })
	plural := if breaches.len > 1 { 's' } else { '' }
	mut lines := [
		'EgressRefused: this call would leave the machine in a way ${breaches.len} clause${plural} forbid.',
	]
	for b in breaches {
		lines << '  ${b.clause}: ${b.detail}'
	}
	return lines.join('\n')
}

pub fn (p &Perimeter) report() string {
	if p.rules.len == 0 {
		return 'egress: no @egress rules — network effects are ungoverned'
	}
	mut lines := ['egress: ${p.rules.len} rule(s) · ${p.blocked} refused / ${p.cleared} cleared']
	for r in p.rules {
		detail := if r.hosts.len > 0 { r.hosts.join(', ') } else { r.method }
		lines << '  ' + pad_width(r.clause, 10) + ' ' + pad_width(r.kind, 14) + ' ${detail}'
	}
	for e in p.errors {
		lines << '  !! ${e}'
	}
	return lines.join('\n')
}
