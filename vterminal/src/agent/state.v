module agent

import src.model
import src.tui

// State is the agent's short-term memory plus the counters the loop needs to
// keep itself honest: iteration budget, repeated-failure detection, and what
// the user actually asked for at the top of this turn.
@[heap]
pub struct State {
pub mut:
	messages   []model.Message
	mode       tui.Mode = .agent
	turn       int
	iterations int
	tool_calls int
	failures   int
	// last_failed_call fingerprints the previous failing call so the loop can
	// notice the model looping on an identical mistake.
	last_failed_call string
	repeat_failures  int
	interrupted      bool
	task             string
}

// reset clears the conversation but keeps the mode, which is what /clear means.
pub fn (mut s State) reset() {
	s.messages = []
	s.turn = 0
	s.iterations = 0
	s.tool_calls = 0
	s.failures = 0
	s.last_failed_call = ''
	s.repeat_failures = 0
}

// set_system installs or replaces the system prompt in slot 0, so the prompt
// can be rebuilt every turn without accumulating stale copies.
pub fn (mut s State) set_system(content string) {
	if s.messages.len > 0 && s.messages[0].role == .system {
		s.messages[0].content = content
		return
	}
	s.messages.prepend(model.system_msg(content))
}

pub fn (mut s State) push(msg model.Message) {
	s.messages << msg
}

// user_visible_messages excludes the system prompt, for /context and counters.
pub fn (s &State) user_visible_messages() int {
	mut n := 0
	for m in s.messages {
		if m.role != .system {
			n++
		}
	}
	return n
}

// note_failure tracks consecutive identical failures so the loop can break a
// model out of a retry loop instead of burning its whole iteration budget.
pub fn (mut s State) note_failure(fingerprint string) int {
	s.failures++
	if fingerprint == s.last_failed_call {
		s.repeat_failures++
	} else {
		s.last_failed_call = fingerprint
		s.repeat_failures = 1
	}
	return s.repeat_failures
}

pub fn (mut s State) note_success() {
	s.last_failed_call = ''
	s.repeat_failures = 0
}
