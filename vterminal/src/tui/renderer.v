module tui

import os
import strings
import src.security
import src.tools
import src.utils

// Renderer owns everything the user sees. It is deliberately line-based rather
// than a full-screen TUI: a scrollback-friendly transcript survives resizes,
// copy-paste, tmux and CI logs, which a repainted alternate screen does not.
@[heap]
pub struct Renderer {
pub mut:
	style     Style
	width     int = 80
	compact   bool
	show_plan bool = true
	// mid_stream tracks whether the cursor is parked at the end of a partially
	// printed assistant line, so anything else that prints can break the line
	// first instead of corrupting the transcript.
	mid_stream  bool
	interactive bool = true
}

pub fn new_renderer(color bool, unicode bool, compact bool, show_plan bool) Renderer {
	return Renderer{
		style:       Style{
			color:   color && is_tty()
			unicode: unicode
		}
		width:       terminal_width()
		compact:     compact
		show_plan:   show_plan
		interactive: is_tty()
	}
}

fn (mut r Renderer) out(s string) {
	print(s)
	os.flush()
}

// break_stream ends a partially written streaming line before other output.
pub fn (mut r Renderer) break_stream() {
	if r.mid_stream {
		r.out('\n')
		r.mid_stream = false
	}
}

pub fn (mut r Renderer) banner(model string, provider string, root string, tool_count int) {
	s := r.style
	r.out('\n')
	r.out('  ${s.bold('V-AGENT')} ${s.grey('v0.1.0')}  ${s.grey('—')}  native terminal AI coding agent\n')
	r.out('  ${s.grey('provider')} ${provider}   ${s.grey('model')} ${s.cyan(model)}   ${s.grey('tools')} ${tool_count}\n')
	r.out('  ${s.grey('project')}  ${root}\n')
	r.out('  ${s.grey('/help for commands, /quit to exit')}\n\n')
}

pub fn (mut r Renderer) user_echo(text string) {
	r.break_stream()
	s := r.style
	r.out('${s.bold(s.green(s.glyph(.prompt)))} ${text}\n\n')
}

// assistant_prefix is printed once before the first streamed token of a turn.
pub fn (mut r Renderer) assistant_prefix() {
	r.break_stream()
	r.out('${r.style.bold(r.style.cyan('assistant'))}\n')
}

// stream_text writes model output as it arrives.
pub fn (mut r Renderer) stream_text(chunk string) {
	if chunk == '' {
		return
	}
	r.out(chunk)
	r.mid_stream = !chunk.ends_with('\n')
}

pub fn (mut r Renderer) assistant_text(text string) {
	if text.trim_space() == '' {
		return
	}
	r.break_stream()
	r.out('${text}\n')
}

pub fn (mut r Renderer) end_turn() {
	r.break_stream()
	r.out('\n')
}

// thinking renders reasoning output dimmed, so it is visibly not the answer.
pub fn (mut r Renderer) thinking(chunk string) {
	if r.compact || chunk == '' {
		return
	}
	r.out(r.style.grey(chunk))
	r.mid_stream = !chunk.ends_with('\n')
}

pub fn (mut r Renderer) tool_start(name string, summary string) {
	r.break_stream()
	s := r.style
	line := if summary != '' { '${s.bold(name)} ${s.grey(summary)}' } else { s.bold(name) }
	r.out('  ${s.yellow(s.glyph(.bullet))} ${line}\n')
}

pub fn (mut r Renderer) tool_result(res tools.Result) {
	s := r.style
	if res.ok {
		r.out('  ${s.green(s.glyph(.done))} ${s.grey(res.summary)}\n')
	} else {
		r.out('  ${s.red(s.glyph(.failed))} ${s.red(utils.first_line(res.error))}\n')
	}
	if !r.compact && res.output.trim_space() != '' {
		preview := preview_lines(res.output, if res.ok { 8 } else { 14 })
		r.out(utils.indent(s.grey(preview), '      ') + '\n')
	}
}

// preview_lines shows the head of a tool's output; the model sees all of it,
// the user only needs enough to follow along.
fn preview_lines(output string, max int) string {
	lines := output.trim_right('\n').split('\n')
	if lines.len <= max {
		return lines.join('\n')
	}
	mut sb := strings.new_builder(256)
	for i in 0 .. max {
		sb.write_string(lines[i])
		sb.write_string('\n')
	}
	sb.write_string('... (${lines.len - max} more lines)')
	return sb.str()
}

pub fn (mut r Renderer) plan(steps []tools.PlanStep) {
	if !r.show_plan || steps.len == 0 {
		return
	}
	r.break_stream()
	s := r.style
	r.out('\n  ${s.bold('Plan')}\n')
	for st in steps {
		mark, painted := match st.status {
			'done' { s.glyph(.done), s.grey(st.title) }
			'active' { s.glyph(.active), s.bold(st.title) }
			'failed' { s.glyph(.failed), s.red(st.title) }
			else { s.glyph(.pending), s.grey(st.title) }
		}

		colored_mark := match st.status {
			'done' { s.green(mark) }
			'active' { s.cyan(mark) }
			'failed' { s.red(mark) }
			else { s.grey(mark) }
		}

		r.out('  ${colored_mark} ${painted}\n')
	}
	r.out('\n')
}

pub fn (mut r Renderer) info(msg string) {
	r.break_stream()
	r.out('${r.style.grey(msg)}\n')
}

pub fn (mut r Renderer) notice(msg string) {
	r.break_stream()
	r.out('${r.style.cyan(msg)}\n')
}

pub fn (mut r Renderer) warn(msg string) {
	r.break_stream()
	s := r.style
	r.out('${s.yellow(s.glyph(.warn))} ${s.yellow(msg)}\n')
}

pub fn (mut r Renderer) error(msg string) {
	r.break_stream()
	s := r.style
	r.out('${s.red(s.glyph(.failed))} ${s.red(msg)}\n')
}

pub fn (mut r Renderer) raw(msg string) {
	r.break_stream()
	r.out('${msg}\n')
}

// StatusLine is the data behind the single-line status bar.
pub struct StatusLine {
pub:
	model    string
	tokens   int
	limit    int
	cost     f64
	tools    int
	mode     string
	git      string
	messages int
}

pub fn (mut r Renderer) status(st StatusLine) {
	r.break_stream()
	s := r.style
	pct := if st.limit > 0 { int(f64(st.tokens) * 100.0 / f64(st.limit)) } else { 0 }
	mut parts := [
		s.cyan(st.model),
		'${utils.human_count(st.tokens)}/${utils.human_count(st.limit)} (${pct}%)',
		'${st.tools} tools',
		st.mode,
	]
	if st.cost > 0 {
		parts << '\$${st.cost:.4f}'
	}
	if st.git != '' {
		parts << st.git
	}
	parts << '${st.messages} msgs'
	r.out('${s.grey('  ' + parts.join('  │  '))}\n')
}

// ask_permission is the interactive half of the security engine. It is wired
// in as the engine's AskFn, which is why it has to match that signature.
pub fn (mut r Renderer) ask_permission(req security.Request) security.Approval {
	r.break_stream()
	s := r.style
	r.out('\n  ${s.yellow(s.glyph(.warn))} ${s.bold('permission required')} ${s.grey('(' +
		req.level.str() + ')')}\n')
	r.out('    ${req.summary}\n')
	if req.danger != '' {
		r.out('    ${s.red('danger: ' + req.danger)}\n')
	}
	r.out('    ${s.grey('[y] allow once   [a] always allow   [n] deny   [q] deny all')}\n')
	for {
		r.out('    ${s.bold('choice')} ${s.grey('[y/a/n/q]')} ')
		line := os.get_line().trim_space().to_lower()
		match line {
			'y', 'yes', '' { return .once }
			'a', 'always' { return .always }
			'n', 'no' { return .reject }
			'q', 'quit', 'all' { return .reject_all }
			else { r.out('    ${s.grey('please answer y, a, n or q')}\n') }
		}
	}
	return .reject
}
