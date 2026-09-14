module security

// Level is the coarse capability a tool needs. Tools declare one; policy is
// written against it so a new tool inherits sane handling without new rules.
pub enum Level {
	read    // observe the filesystem or the environment
	write   // modify files inside the workspace
	execute // run arbitrary commands
	network // reach outside the machine
	admin   // privileged / irreversible operations
}

pub fn (l Level) str() string {
	return match l {
		.read { 'READ' }
		.write { 'WRITE' }
		.execute { 'EXECUTE' }
		.network { 'NETWORK' }
		.admin { 'ADMIN' }
	}
}

pub fn level_from_string(s string) Level {
	return match s.to_lower() {
		'write' { Level.write }
		'execute', 'exec' { Level.execute }
		'network', 'net' { Level.network }
		'admin' { Level.admin }
		else { Level.read }
	}
}

// Decision is the outcome of evaluating policy, before any user prompt.
pub enum Decision {
	allow
	deny
	ask
}

// Approval is what the user answered when policy said `ask`.
pub enum Approval {
	once
	always
	reject
	reject_all
}

// Request is everything the engine needs to judge a single tool invocation.
pub struct Request {
pub:
	tool    string
	level   Level
	summary string // one-line human description, e.g. the command line
	target  string // path or command the operation acts on, for rule matching
	danger  string // non-empty when a heuristic flagged this as destructive
}
