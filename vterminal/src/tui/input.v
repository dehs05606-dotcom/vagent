module tui

import os

// Mode is the agent's interaction posture for a turn. The mode does not change
// what tools exist; it changes the instructions the model is given, which is
// what actually makes `/plan` behave differently from `/execute`.
pub enum Mode {
	agent
	chat
	plan
	execute
	review
	debug
	search
}

pub fn (m Mode) str() string {
	return match m {
		.agent { 'agent' }
		.chat { 'chat' }
		.plan { 'plan' }
		.execute { 'execute' }
		.review { 'review' }
		.debug { 'debug' }
		.search { 'search' }
	}
}

pub fn mode_from_string(s string) ?Mode {
	return match s.to_lower() {
		'agent' { Mode.agent }
		'chat' { Mode.chat }
		'plan' { Mode.plan }
		'execute', 'exec' { Mode.execute }
		'review' { Mode.review }
		'debug' { Mode.debug }
		'search' { Mode.search }
		else { none }
	}
}

// Command is a parsed line of user input. Exactly one of `slash` / `text` is
// meaningful: a line starting with `/` is a command, anything else is a prompt.
pub struct Command {
pub:
	is_slash bool
	name     string
	args     string
	text     string
}

// parse_input splits a raw input line into a command or a prompt. A mode name
// used as a command (`/plan add caching`) carries its argument as the prompt,
// which is what makes `/plan <task>` a one-shot mode switch plus a request.
pub fn parse_input(raw string) Command {
	line := raw.trim_space()
	if !line.starts_with('/') {
		return Command{
			text: line
		}
	}
	body := line#[1..]
	idx := body.index(' ') or { return Command{
		is_slash: true
		name:     body.to_lower()
	} }
	return Command{
		is_slash: true
		name:     body#[..idx].to_lower()
		args:     body#[idx + 1..].trim_space()
	}
}

// read_line prompts and reads one line, returning none on EOF (Ctrl-D) so the
// caller can exit cleanly instead of spinning on an empty string forever.
pub fn (mut r Renderer) read_line(mode Mode) ?string {
	r.break_stream()
	s := r.style
	label := if mode == .agent { '' } else { s.grey('(' + mode.str() + ') ') }
	r.out('${label}${s.bold(s.green(s.glyph(.prompt)))} ')
	line := os.get_line()
	if line == '' && !r.interactive {
		return none
	}
	// os.get_line returns '' both for an empty line and for EOF; distinguish
	// them by checking whether stdin is still readable.
	if line == '' {
		if eof_reached() {
			return none
		}
		return ''
	}
	return line.trim_right('\r\n')
}

fn eof_reached() bool {
	return C.feof(C.stdin) != 0
}

// help_text is printed by /help. It is a plain string rather than generated
// from a table because the ordering here is pedagogical, not alphabetical.
pub fn help_text(style Style) string {
	b := style.bold
	g := style.grey
	return '
${b('session')}
  /help              show this help
  /status            model, tokens, tools, git and permission state
  /model [name]      show or switch the active model
  /tools             list registered tools and their permission levels
  /context           what is currently in the model context
  /memory            show project memory notes
  /clear             forget the conversation and session grants
  /compact           summarise the conversation to reclaim context
  /quit              exit

${b('modes')}
  /agent  <task>     plan, act, verify, self-correct  ${g('(default)')}
  /chat   <text>     answer without touching the project
  /plan   <task>     produce a plan, do not execute it
  /execute <task>    act directly, minimal planning
  /review [target]   review the current changes
  /debug  <symptom>  investigate a failure
  /search <query>    find things in the project

${b('input')}
  anything not starting with / is sent to the agent
  Ctrl-D or /quit exits; the session is saved after every turn
'
}
