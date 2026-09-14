module utils

// AgentError is the single error type V-AGENT raises across module boundaries.
// `kind` lets callers branch without string matching, `hint` carries the
// actionable half of the message that gets shown to the user.
pub struct AgentError {
pub:
	kind ErrKind
	msg  string
	hint string
}

pub enum ErrKind {
	config
	provider
	network
	permission
	tool
	filesystem
	protocol
	cancelled
	internal
}

pub fn (e AgentError) msg() string {
	if e.hint.len > 0 {
		return '${e.msg}\n  hint: ${e.hint}'
	}
	return e.msg
}

pub fn (e AgentError) code() int {
	return int(e.kind)
}

pub fn err(kind ErrKind, msg string) IError {
	return AgentError{
		kind: kind
		msg:  msg
	}
}

pub fn err_hint(kind ErrKind, msg string, hint string) IError {
	return AgentError{
		kind: kind
		msg:  msg
		hint: hint
	}
}

// kind_of reports the ErrKind of an arbitrary IError, defaulting to .internal
// for errors raised by vlib rather than by us.
pub fn kind_of(e IError) ErrKind {
	if e is AgentError {
		return e.kind
	}
	return ErrKind.internal
}
