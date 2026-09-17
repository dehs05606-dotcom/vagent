module vagent

import time
import x.json2

// ui_turn.v — running a turn, and showing it happening.
//
// A turn runs on its own thread so the loop keeps reading keys; that is
// what makes Ctrl+C able to cancel one. Everything below is a callback the
// agent invokes FROM that thread, so every one of them goes through the
// Screen, which serialises the pinned region against the input thread.
//
// Two ideas shape the streaming:
//
//   * Complete lines scroll, partial lines preview. The screen can only
//     interleave output above a pinned box when every write ends in a
//     newline, so a reply's finished lines are printed and the trailing
//     fragment lives in the box border until it finishes. That is also why
//     the border, not the scrollback, is where a half-sentence appears.
//
//   * A file change is shown WHILE the model generates it. on_tool_args
//     feeds the growing JSON to a LiveWrite tracker, and the lines cascade
//     down the terminal as they are produced — a true live write, not a
//     replay after the tool ran.

// start_turn runs one user turn on a worker thread.
fn (mut u UI) start_turn(text string) {
	spawn fn [mut u, text] () {
		u.run_turn_thread(text)
	}()
}

// start_job runs a deferred slash command off the input thread, as the
// original's `_bg` did — with its failure reported rather than printed to a
// stderr nobody can see behind the box.
fn (mut u UI) start_job(job string, arg string) {
	spawn fn [mut u, job, arg] () {
		r := u.agent.slash_job(job, arg)
		u.print_result(&r)
	}()
}

fn (mut u UI) reset_stream_state() {
	u.stream_tail = ''
	u.stream_blank = false
	u.last_preview = 0.0
	u.md_buf = ''
	u.shell_active = false
	u.shell_streamed = false
	u.shell_lines = 0
	u.clear_live_file()
}

fn (mut u UI) clear_live_file() {
	u.live = unsafe { nil }
	u.live_kind = ''
	u.live_head = false
	u.live_count = 0
	u.live_held = []
	u.live_path = ''
	u.live_old = false
}

fn (mut u UI) run_turn_thread(text string) {
	mut remaining_text := text
	for {
		u.busy = true
		u.cancelled = false
		u.set_status('thinking…')
		u.start_spinner()
		u.reset_stream_state()
		u.md_mode = jbool(u.agent.cfg.extra, 'render_markdown')

		turn := u.agent.run_turn(remaining_text, u.turn_callbacks())

		// whatever is left of the reply's last line has no newline to end
		// it, so it never scrolled — print it now, and otherwise leave one
		// blank line between the reply and what follows it
		tail := u.stream_tail.trim('\n')
		u.stream_tail = ''
		if tail != '' {
			u.emit([[plain(tail)]])
		} else {
			u.emit([[]Span{}])
		}
		u.stop_spinner()
		u.busy = false
		u.set_status('')

		if u.md_mode && turn.assistant_text.trim_space() != '' && turn.error == '' {
			// the finished reply, rendered once
			u.emit([[]Span{}])
			u.emit(render_markdown(turn.assistant_text, u.width()))
		}
		if turn.reasoning != '' && u.agent.cfg.show_reasoning {
			u.print_reasoning(turn.reasoning)
		}
		if turn.error != '' {
			if turn.error == 'cancelled' {
				u.print_info('⊘ cancelled', c_yellow)
			} else {
				u.print_error(turn.error)
			}
		}
		u.print_turn_stats(&turn)
		u.agent.save_session() or { '' }

		// FOCUS MODE — the kernel decides whether work remains; the UI
		// drives the next continuation turn automatically.
		if u.agent.focus_remaining <= 0 || u.cancelled {
			return
		}
		cont := u.agent.focus_continue(&turn, u.agent.focus_remaining) or {
			mut reason := 'complete'
			for ev in u.agent.log.events(u.agent.log.branch) {
				if ev.typ == 'focus.stop' {
					reason = jstr(ev.data, 'reason')
				}
			}
			u.agent.focus_remaining = 0
			u.invalidate()
			u.print_info('🎯 focus ended — ${reason}', c_yellow)
			return
		}
		u.agent.focus_remaining--
		u.invalidate()
		u.print_info('🎯 focus · auto-continuing (${u.agent.focus_remaining} turn(s) left)…', c_pink)
		u.emit_user('CONTINUE (focus mode)')
		// the original recursed here; a loop does the same work without
		// growing the stack once a long focus run gets going
		remaining_text = cont
	}
}

fn (mut u UI) turn_callbacks() TurnCallbacks {
	return TurnCallbacks{
		on_token:       fn [mut u] (piece string) {
			u.on_token(piece)
		}
		on_reasoning:   fn [mut u] (piece string) {
			u.set_status('reasoning…')
		}
		on_tool_call:   fn [mut u] (ev &ToolEvent) {
			u.on_tool_call(ev)
		}
		on_tool_update: fn [mut u] (ev &ToolEvent) {
			u.on_tool_update(ev)
		}
		on_status:      fn [mut u] (s string) {
			u.on_status(s)
		}
		on_route:       fn [mut u] (route &RouteDecision) {
			u.print_info('AUTOPILOT  ' + route.summary(), c_pink)
			for r in route.reasons {
				u.print_info('  ↳ ${r}', c_dim)
			}
		}
		on_tool_output: fn [mut u] (line string, stream string) {
			u.on_tool_output(line, stream)
		}
		on_tool_args:   fn [mut u] (name string, chunk string) {
			u.on_tool_args(name, chunk)
		}
		approve:        fn [mut u] (tool &Tool, args map[string]json2.Any) bool {
			return u.approve_blocking(tool, args)
		}
		should_cancel:  fn [mut u] () bool {
			return u.cancelled
		}
	}
}

// -- the reply -----------------------------------------------------------------

fn (mut u UI) preview_width() int {
	w := u.width() - preview_margin
	return if w > 10 { w } else { 10 }
}

fn (mut u UI) on_token(piece string) {
	now := time.now().unix_milli()
	if f64(now) / 1000.0 - u.last_preview < preview_interval {
		// coalesce border redraws: a long reply streams thousands of
		// chunks and redrawing on each one makes the box stutter
		if u.md_mode {
			u.md_buf += piece
		} else {
			u.stream_tail += piece
		}
		return
	}
	u.last_preview = f64(now) / 1000.0

	if u.md_mode {
		// markdown mode: nothing raw reaches the scrollback — the live
		// preview runs in the border and the finished reply is printed
		// once, rendered.
		u.md_buf += piece
		maxw := u.preview_width()
		mut preview := u.md_buf
		if preview.len > maxw {
			preview = preview[preview.len - maxw..]
		}
		preview = preview.trim('\n')
		u.set_status(if preview != '' { preview } else { 'writing…' })
		return
	}

	mut tail := u.stream_tail + piece
	if tail.contains('\n') {
		cut := tail.last_index('\n') or { -1 }
		before := tail[..cut]
		rem := tail[cut + 1..]
		// collapse blank-line runs: the model likes '\n\n\n' between tool
		// calls, and one blank line says the same thing
		mut out := [][]Span{}
		for ln in before.split('\n') {
			if ln.trim_space() == '' {
				if u.stream_blank {
					continue
				}
				u.stream_blank = true
			} else {
				u.stream_blank = false
			}
			out << [plain(ln)]
		}
		if out.len > 0 {
			u.emit(out)
		}
		tail = rem
	}
	u.stream_tail = tail
	maxw := u.preview_width()
	mut preview := tail.trim('\n')
	if preview.len > maxw {
		preview = preview[preview.len - maxw..]
	}
	u.set_status(if preview != '' { preview } else { 'writing…' })
}

fn (mut u UI) on_status(s string) {
	if s == 'thinking' {
		u.set_status('thinking…')
	} else if s.starts_with('tool:') {
		u.set_status('calling ${s[5..]}…')
	} else if s.starts_with('running:') {
		u.set_status('running ${s[8..]}…')
	} else {
		u.set_status(s)
	}
}

pub fn (mut u UI) print_reasoning(text string) {
	mut preview := text.trim_space().fields().join(' ')
	if preview.len > 300 {
		preview = preview[..297] + '…'
	}
	u.emit([
		[
			fg('  💭 ', c_pink),
			span(preview, Style{
				fg:     c_dim
				italic: true
			}),
		],
	])
}

fn (mut u UI) print_turn_stats(turn &Turn) {
	mut parts := ['${turn.duration:.1f}s']
	if turn.has_usage {
		tin := int_of_any(turn.usage['prompt_tokens'] or { json2.Any(0) }) or { 0 }
		tout := int_of_any(turn.usage['completion_tokens'] or { json2.Any(0) }) or { 0 }
		if tin != 0 || tout != 0 {
			parts << '${tin}→${tout} tokens'
		}
	}
	u.emit([[fg(parts.join('  ·  '), c_dim)]])
}

// -- live shell output ---------------------------------------------------------

fn (mut u UI) on_tool_output(line string, stream string) {
	if !u.shell_active {
		return
	}
	if u.shell_lines == live_output_cap {
		// flood guard — the full output stays in the tool result
		u.shell_lines++
		u.emit([
			[
				fg(' │ … live view truncated (full output kept in the tool result)', c_dim),
			],
		])
		return
	}
	if u.shell_lines > live_output_cap {
		return
	}
	u.shell_lines++
	u.shell_streamed = true
	colour := if stream == 'err' { c_orange } else { c_fg }
	u.emit([[fg(' │ ' + line, colour)]])
}

// -- live file changes ---------------------------------------------------------

const live_file_tools = ['write_file', 'edit_file', 'apply_patch']

fn live_kind_of(name string) string {
	return match name {
		'write_file' { 'write' }
		'edit_file' { 'edit' }
		'apply_patch' { 'patch' }
		else { '' }
	}
}

fn live_field_of(kind string) string {
	return match kind {
		'write' { 'content' }
		'edit' { 'new_string' }
		else { 'patch' }
	}
}

fn (mut u UI) lf_write_line(line string) {
	u.live_count++
	u.emit([
		[
			fg(' │ ', c_dim),
			fg('${u.live_count:4} ', c_dim),
			fg('+  ', c_green),
			fg(line, c_fg),
		],
	])
}

fn (mut u UI) lf_edit_line(line string, plus bool) {
	u.live_count++
	if plus {
		u.emit([[fg(' │ ', c_dim), fg('+  ', c_green), fg(line, c_fg)]])
	} else {
		u.emit([[fg(' │ ', c_dim), fg('-  ', c_red), fg(line, c_red)]])
	}
}

fn (mut u UI) lf_patch_line(line string) {
	u.live_count++
	colour := if line.starts_with('@@') {
		c_cyan
	} else if line.starts_with('+++ ') || line.starts_with('--- ') {
		c_dim
	} else if line.starts_with('+') {
		c_green
	} else if line.starts_with('-') {
		c_red
	} else {
		c_fg
	}
	u.emit([[fg(' │ ', c_dim), fg(line, colour)]])
}

fn (mut u UI) lf_emit(line string) {
	match u.live_kind {
		'write' { u.lf_write_line(line) }
		'edit' { u.lf_edit_line(line, true) }
		else { u.lf_patch_line(line) }
	}
}

fn (mut u UI) on_tool_args(name string, chunk string) {
	if name !in live_file_tools {
		return
	}
	// the animation can be turned off; the change then renders at once
	// when the tool finishes, as it did before this existed
	if 'live_stream_edits' in u.agent.cfg.extra
		&& !jbool(u.agent.cfg.extra, 'live_stream_edits') {
		return
	}
	kind := live_kind_of(name)
	if u.live == unsafe { nil } {
		u.live = new_live_write(live_field_of(kind))
		u.live_kind = kind
	}
	new_lines := u.live.feed(chunk)

	// the header goes out once the path is known; a patch has no single
	// path, so its header can go immediately
	if !u.live_head {
		mut ready := kind == 'patch'
		if kind != 'patch' {
			if p := u.live.path() {
				u.live_path = p
				ready = true
			}
		}
		if ready {
			verb := match kind {
				'write' { 'Wrote' }
				'edit' { 'Edited' }
				else { 'Applied patch' }
			}
			label := if kind == 'patch' { verb } else { '${verb} ${rel_path(u.live_path)}' }
			u.emit([[bold_fg(' ⏺ ', c_accent), bold_fg(label, c_fg)]])
			u.live_head = true
		}
	}

	// an edit shows the REMOVED lines once old_string is complete, before
	// any added line streams — otherwise the diff reads backwards
	if kind == 'edit' && u.live_head && !u.live_old {
		if old := json_field(u.live.buf, 'old_string') {
			for ol in old.split('\n') {
				u.lf_edit_line(ol, false)
			}
			u.live_old = true
			held := u.live_held.clone()
			u.live_held = []
			for h in held {
				u.lf_emit(h)
			}
		}
	}

	ready := u.live_head && (kind != 'edit' || u.live_old)
	if !ready {
		u.live_held << new_lines
		return
	}
	for ln in new_lines {
		u.lf_emit(ln)
	}
	if new_lines.len > 0 {
		verb := match kind {
			'write' { 'writing' }
			'edit' { 'editing' }
			else { 'patching' }
		}
		if kind != 'patch' {
			u.set_status('${verb} ${rel_path(u.live_path)} · ${u.live_count} lines…')
		} else {
			u.set_status('${verb} · ${u.live_count} lines…')
		}
	}
}

// -- tool blocks ---------------------------------------------------------------

const live_block_tools = ['run_command', 'live_shell', 'apply_patch', 'write_file', 'edit_file',
	'read_file']

fn (mut u UI) on_tool_call(ev &ToolEvent) {
	// a tool call ends the reply's current line: print what was streaming
	rem := u.stream_tail.trim('\n')
	u.stream_tail = ''
	u.stream_blank = false
	if rem != '' {
		u.emit([[plain(rem)]])
	}
	u.shell_active = ev.name in ['run_command', 'live_shell']
	u.shell_streamed = false
	u.shell_lines = 0
	if ev.name !in live_file_tools {
		// a non file-change tool starting clears stale live state
		u.clear_live_file()
	}
	if ev.name in live_block_tools {
		// for a file-change tool the header already went out during the
		// live stream, so it is not repeated here
		if !(ev.name in live_file_tools && u.live_head) {
			u.emit(live_rows(ev, u.width()))
		}
	} else {
		u.emit([tool_call_line(ev)])
	}
	u.set_status('running ${ev.name}…')
}

fn (mut u UI) on_tool_update(ev &ToolEvent) {
	settled := ev.status in ['done', 'error']
	if ev.name == 'wait_for_agents' && ev.status == 'done' {
		// subagent reports deserve a real panel, not one line
		u.emit(tool_result_block(ev, u.width()))
	} else if ev.name in live_file_tools && settled && u.live_count > 0 {
		// the change already streamed: flush the last partial line and
		// close the block, with no replay cascade after it
		if u.live != unsafe { nil } {
			if last := u.live.flush() {
				u.lf_emit(last)
			}
		}
		u.emit([write_footer(ev, u.live_count)])
	} else if ev.name in live_file_tools && settled {
		u.emit(live_rows(ev, u.width()))
	} else if ev.name in ['run_command', 'live_shell'] && settled {
		if u.shell_streamed {
			// output already streamed live — just close the block
			u.emit([shell_footer(ev)])
		} else {
			u.emit(live_rows(ev, u.width()))
		}
	} else if ev.name == 'read_file' && settled {
		u.emit(live_rows(ev, u.width()))
	} else {
		u.emit(tool_result_block(ev, u.width()))
	}
	u.shell_active = false
	u.clear_live_file()
	u.set_status('thinking…')
}
