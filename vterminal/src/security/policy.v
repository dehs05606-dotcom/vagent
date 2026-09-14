module security

import src.utils
import src.config

// dangerous_patterns are substrings that, appearing anywhere in a command,
// make it destructive enough that V-AGENT always asks even in `allow` mode.
// The list is intentionally short: it catches the classic foot-guns rather
// than trying to be a sandbox, which is what `sandbox.v` is for.
const dangerous_patterns = [
	'rm -rf /',
	'rm -fr /',
	'rm -rf ~',
	'rm -rf *',
	':(){:|:&};:',
	'mkfs',
	'> /dev/sd',
	'of=/dev/sd',
	'dd if=/dev/zero',
	'chmod -r 777 /',
	'chown -r',
	'shutdown',
	'reboot',
	'halt ',
	'killall -9',
	'git push --force',
	'git reset --hard',
	'git clean -fdx',
	'npm publish',
	'curl | sh',
	'curl | bash',
	'wget | sh',
	'sudo ',
	'doas ',
	'su -',
]

// classify_command returns a non-empty reason when a shell command matches a
// destructive pattern.
pub fn classify_command(cmd string) string {
	lower := cmd.to_lower()
	for pat in dangerous_patterns {
		if lower.contains(pat) {
			return 'matches destructive pattern "${pat}"'
		}
	}
	return ''
}

// AskFn is how the engine reaches the user when policy says `ask`. The UI
// layer supplies it, which keeps this module free of terminal code.
pub type AskFn = fn (req Request) Approval

// Engine evaluates permission requests against configured policy plus the
// grants the user handed out during this session.
@[heap]
pub struct Engine {
pub mut:
	mode              string = 'ask'
	auto_approve_read bool   = true
	confine_to_root   bool   = true
	root              string
	allow_rules       []string
	deny_rules        []string
	interactive       bool  = true
	ask_fn            AskFn = unsafe { nil }
mut:
	session_allow  map[string]bool // tool or rule granted "always" this session
	session_reject bool            // user answered "reject all"
	log            &utils.Logger = unsafe { nil }
}

pub fn new_engine(cfg config.PermissionConfig, root string, mut log utils.Logger) Engine {
	return Engine{
		mode:              cfg.mode
		auto_approve_read: cfg.auto_approve_read
		confine_to_root:   cfg.confine_to_root
		root:              root
		allow_rules:       cfg.allow.clone()
		deny_rules:        cfg.deny.clone()
		log:               &log
	}
}

// evaluate applies policy only. It never blocks and never prompts.
pub fn (e &Engine) evaluate(req Request) Decision {
	if e.session_reject {
		return .deny
	}
	// Explicit deny rules win over everything, including `mode: allow`.
	for rule in e.deny_rules {
		if rule_matches(rule, req) {
			return .deny
		}
	}
	if req.danger != '' {
		// A destructive operation is always worth a confirmation, unless the
		// user has taken responsibility with a blanket `allow` mode and an
		// explicit allow rule for it.
		if e.mode == 'allow' && e.matches_allow(req) {
			return .allow
		}
		return if e.interactive { Decision.ask } else { Decision.deny }
	}
	if req.level == .read && e.auto_approve_read {
		return .allow
	}
	if e.matches_allow(req) {
		return .allow
	}
	if req.tool in e.session_allow || e.session_allow[req.summary] {
		return .allow
	}
	return match e.mode {
		'allow' {
			Decision.allow
		}
		'deny' {
			Decision.deny
		}
		else {
			if e.interactive {
				Decision.ask
			} else {
				Decision.deny
			}
		}
	}
}

fn (e &Engine) matches_allow(req Request) bool {
	for rule in e.allow_rules {
		if rule_matches(rule, req) {
			return true
		}
	}
	return false
}

// rule_matches supports four rule shapes:
//   "tool_name"            -> any call to that tool
//   "tool_name:<glob>"     -> that tool, when its target matches the glob
//   "<glob with *>"        -> the summary or target matches the glob
//   "<prefix>"             -> the summary or target starts with the prefix
//
// The prefix form is checked against the target as well as the summary,
// because the summary is tool-qualified ("shell git push ...") while a rule is
// normally written the way the user would type the command ("git push").
fn rule_matches(rule string, req Request) bool {
	r := rule.trim_space()
	if r == '' {
		return false
	}
	if r == '*' {
		return true
	}
	if r == req.tool {
		return true
	}
	if r.contains(':') {
		parts := r.split_nth(':', 2)
		if parts[0] == req.tool {
			pat := parts[1].trim_space()
			return utils.glob_match(pat, req.target) || utils.glob_match(pat, req.summary)
		}
	}
	if r.contains('*') {
		return utils.glob_match(r, req.summary) || utils.glob_match(r, req.target)
	}
	return req.summary.trim_space().starts_with(r) || req.target.trim_space().starts_with(r)
}

// authorize is the call sites' entry point: it evaluates policy, prompts when
// policy is undecided, records any "always" grant, and returns whether the
// operation may proceed.
pub fn (mut e Engine) authorize(req Request) !bool {
	decision := e.evaluate(req)
	match decision {
		.allow {
			e.audit(req, 'allow (policy)')
			return true
		}
		.deny {
			e.audit(req, 'deny (policy)')
			return false
		}
		.ask {}
	}

	if e.ask_fn == unsafe { nil } {
		e.audit(req, 'deny (no prompt available)')
		return false
	}
	answer := e.ask_fn(req)
	match answer {
		.once {
			e.audit(req, 'allow (user, once)')
			return true
		}
		.always {
			key := if req.tool != '' { req.tool } else { req.summary }
			e.session_allow[key] = true
			e.audit(req, 'allow (user, always)')
			return true
		}
		.reject {
			e.audit(req, 'deny (user)')
			return false
		}
		.reject_all {
			e.session_reject = true
			e.audit(req, 'deny (user, all)')
			return false
		}
	}
}

fn (mut e Engine) audit(req Request, outcome string) {
	if e.log != unsafe { nil } {
		e.log.info('permission ${req.level.str()} ${req.tool} -> ${outcome} :: ${utils.first_line(req.summary)}')
	}
}

// granted_this_session is shown by /status so the user can see what they have
// handed out without re-reading the log.
pub fn (e &Engine) granted_this_session() []string {
	mut out := e.session_allow.keys()
	out.sort()
	return out
}

// reset_session_grants drops every "always allow" the user gave; /clear uses it.
pub fn (mut e Engine) reset_session_grants() {
	e.session_allow.clear()
	e.session_reject = false
}
