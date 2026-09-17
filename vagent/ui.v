module vagent

import os
import sync
import time
import x.json2

// ui.v — the event loop: keys in, frames out, one turn at a time.
//
// The Python original was prompt_toolkit's Application: an invalidate/render
// cycle, KeyBindings guarded by Condition filters, and patch_stdout so that
// anything printed during a turn scrolled ABOVE the pinned prompt box. None
// of that exists here, so this file is the loop, and the pieces it drives
// were each built and tested on their own:
//
//   Terminal   raw mode and a read that times out (term_core.v)
//   KeyDecoder bytes → keys, escape sequences included (term_keys.v)
//   decide     (key, state) → action, as a pure table (ui_keys.v)
//   EditBuffer the multi-line draft and its history (term_buffer.v)
//   Screen     the pinned region: erase, print above, redraw (term_screen.v)
//   render_box the frame itself (ui_box.v, ui_overlay.v, ui_complete.v)
//   route_slash commands as data rather than drawing (slash.v)
//
// What is left is the wiring, and the two things only the loop can own:
//
//   * BUSY. A turn runs on its own thread so the loop keeps reading keys —
//     that is what makes Ctrl+C able to cancel. Exactly one turn runs at a
//     time; submitting during one is refused with a flash rather than
//     quietly starting a second agent loop over the same message list.
//   * APPROVAL. The gate blocks the TURN thread and the answer arrives on
//     the INPUT thread, so the handshake is a channel. Every path out of
//     the wait sends exactly one answer, and the default is no: a prompt
//     that is torn down without one would otherwise hang the turn forever.

// the live preview in the box border is redrawn at most this often — a long
// reply streams thousands of chunks, and redrawing on each one wastes the
// CPU and makes the box stutter
const preview_interval = 0.03

// how much of the border a status line may occupy
const preview_margin = 26

// live shell output stops scrolling past after this many lines; the full
// output is still in the tool result
const live_output_cap = 500

const spinner_interval_ms = 90

@[heap]
pub struct UI {
pub mut:
	agent  &Agent
	term   &Terminal
	screen &Screen
	buf    &EditBuffer

	overlay &OverlayList    = unsafe { nil }
	menu    &CompletionMenu = unsafe { nil }

	// -- what the border says ------------------------------------------
	status       string
	flash        string
	flash_colour string
	flash_until  f64

	// -- turn state ----------------------------------------------------
	busy        bool
	cancelled   bool
	spinner_i   int
	spinner_gen int
	spinner_on  bool

	// -- the approval handshake ----------------------------------------
	approving      bool
	approve_tool   string
	approve_answer chan bool = chan bool{ cap: 1 }

	// Ctrl+X is a prefix waiting for its second key
	ctrl_x_pending bool
	quit           bool

	// -- streaming scratch ---------------------------------------------
	//
	// One turn runs at a time, so this is a single set of fields rather
	// than a per-turn object — the same simplification the original made.
	stream_tail  string
	stream_blank bool
	last_preview f64
	md_mode      bool
	md_buf       string

	shell_active   bool
	shell_streamed bool
	shell_lines    int

	live       &LiveWrite = unsafe { nil }
	live_kind  string
	live_head  bool
	live_count int
	live_held  []string
	live_path  string
	live_old   bool
mut:
	mu sync.Mutex
}

pub fn new_ui(mut a Agent) &UI {
	mut term := new_terminal()
	colour := os.getenv('NO_COLOR') == ''
	return &UI{
		agent:  a
		term:   term
		screen: new_screen(term, colour)
		buf:    new_edit_buffer(history_file)
	}
}

// -- the frame -----------------------------------------------------------------

fn (u &UI) width() int {
	w, _ := u.term.size()
	return if w > 20 { w } else { 80 }
}

fn (mut u UI) box_state() BoxState {
	m := u.agent.model()
	e := u.agent.effort()
	goal := u.agent.goal.status()
	percent := if goal.active { int((1.0 - goal.distance) * 100.0) } else { -1 }
	frame := if u.spinner_on {
		spinner_frames[u.spinner_i % spinner_frames.len]
	} else {
		''
	}
	// a flash is transient: once its moment has passed the border goes back
	// to whatever the turn is actually doing
	mut flash := u.flash
	if flash != '' && time.now().unix() > i64(u.flash_until) {
		flash = ''
	}
	return BoxState{
		model_label:     m.label
		model_tag:       m.tag
		effort_label:    e.label
		effort_colour:   e.color
		autonomy:        u.agent.autonomy
		goal_percent:    percent
		focus_remaining: u.agent.focus_remaining
		context_percent: u.context_percent()
		session_id:      u.agent.session_id
		busy:            u.busy
		spinner_frame:   frame
		status:          u.status
		flash:           flash
		flash_colour:    u.flash_colour
		approving:       u.approving
		approve_tool:    u.approve_tool
	}
}

fn (mut u UI) context_percent() int {
	budget := u.agent.fit_budget()
	if budget <= 0 {
		return 0
	}
	pct := u.agent.messages_chars() * 100 / budget
	return if pct > 100 { 100 } else { pct }
}

// frame builds the pinned region: the overlay or the completion menu on
// top, then the box. They are mutually exclusive by construction — opening
// an overlay closes the menu — so only one ever occupies those rows.
fn (mut u UI) frame() ([][]Span, int, int) {
	w := u.width()
	mut above := [][]Span{}
	if u.overlay != unsafe { nil } && u.overlay.visible {
		above = u.overlay.rows(w)
	} else if u.menu != unsafe { nil } && u.menu.items.len > 0 {
		above = u.menu.rows(w)
	}
	st := u.box_state()
	// no placeholder: the original showed a bare arrow on an empty line,
	// and hint text in the input would be one more thing to erase before
	// the first character lands
	return render_box(st, u.buf, w, above, '')
}

// invalidate redraws the pinned region in place.
pub fn (mut u UI) invalidate() {
	if !u.term.interactive {
		return
	}
	rows, cr, cc := u.frame()
	u.screen.redraw(rows, cr, cc)
}

// emit prints styled lines ABOVE the box and puts the box back underneath.
pub fn (mut u UI) emit(rows [][]Span) {
	if rows.len == 0 {
		return
	}
	mut out := []string{cap: rows.len}
	for row in rows {
		out << render_spans(row, u.screen.colour)
	}
	if !u.term.interactive {
		u.screen.print_plain(out)
		return
	}
	frame, cr, cc := u.frame()
	u.screen.print_above(out, frame, cr, cc)
}

// emit_text prints one block of text in one colour, splitting it into the
// lines the screen needs. print_info, in other words.
pub fn (mut u UI) emit_text(text string, colour string) {
	mut rows := [][]Span{}
	for line in text.split('\n') {
		rows << [fg(line, colour)]
	}
	u.emit(rows)
}

pub fn (mut u UI) print_info(text string, colour string) {
	u.emit_text(text, if colour == '' { c_cyan } else { colour })
}

// print_error frames the message the way the original's red panel did.
pub fn (mut u UI) print_error(text string) {
	mut body := [][]Span{}
	for line in text.split('\n') {
		body << [fg(line, c_red)]
	}
	u.emit(panel_rows(body, u.width(), Style{ fg: c_red }, [fg('error', c_red)], []Span{}))
}

// print_result prints what a command produced and carries out whatever it
// asked the UI to do.
pub fn (mut u UI) print_result(r &SlashResult) {
	for line in r.lines {
		if line.kind == 'error' {
			u.print_error(spans_text(line.spans))
		} else {
			u.emit([line.spans])
		}
	}
	if r.flash != '' {
		u.set_flash(r.flash, r.flash_colour)
	}
	if r.overlay != unsafe { nil } {
		u.menu = unsafe { nil }
		u.overlay = r.overlay
		u.overlay.open()
		u.invalidate()
	}
	match r.action {
		'exit' {
			u.quit = true
		}
		'clear' {
			u.screen.clear_screen()
			u.invalidate()
		}
		else {}
	}
	if r.job != '' {
		u.start_job(r.job, r.job_arg)
	}
}

pub fn (mut u UI) set_flash(text string, colour string) {
	u.flash = text
	u.flash_colour = if colour == '' { c_yellow } else { colour }
	u.flash_until = f64(time.now().unix()) + 4.0
	u.invalidate()
}

pub fn (mut u UI) set_status(text string) {
	u.status = text
	u.invalidate()
}

// -- the loop ------------------------------------------------------------------

// run drives the session until the user leaves.
pub fn (mut u UI) run() {
	if !u.term.interactive {
		// stdin is a pipe or a CI log: there is no box to pin and no keys
		// to read, so say so rather than spinning on an EOF read forever.
		u.print_info('⊘ no interactive terminal — run vagent in a real TTY, or use the headless commands (vagent --help)', c_yellow)
		return
	}
	u.term.enable_raw()
	defer {
		u.stop_spinner()
		u.screen.leave()
		u.term.disable_raw()
		u.agent.save_session() or { '' }
	}
	u.invalidate()

	mut dec := KeyDecoder{}
	for !u.quit {
		bytes := u.term.read_bytes()
		if bytes.len == 0 {
			// the read timed out: nothing was typed, but the spinner and a
			// finished turn both need the frame refreshed
			u.tick()
			continue
		}
		dec.feed(bytes)
		for {
			// flush=true because a lone Escape is a real key here: the read
			// already timed out waiting for what would follow it
			k := dec.next(true) or { break }
			u.handle_key(&k)
			if u.quit {
				break
			}
		}
		if !u.quit {
			// on the way out the box is torn down, not redrawn: one more
			// frame here would print a box the shell then has to scroll past
			u.invalidate()
		}
	}
}

// tick is the idle refresh: the spinner frame and an expired flash are the
// only things that change without a keystroke.
fn (mut u UI) tick() {
	if u.spinner_on || u.flash != '' {
		u.invalidate()
	}
}

fn (u &UI) ui_state() UiState {
	return UiState{
		overlay_open:   u.overlay != unsafe { nil } && u.overlay.visible
		approving:      u.approving
		busy:           u.busy
		buffer_empty:   u.buf.is_empty()
		on_first_line:  u.buf.on_first_line()
		on_last_line:   u.buf.on_last_line()
		completing:     u.menu != unsafe { nil } && u.menu.items.len > 0
		ctrl_x_pending: u.ctrl_x_pending
	}
}

fn (mut u UI) handle_key(k &Key) {
	st := u.ui_state()
	action := decide(k, &st)
	if u.ctrl_x_pending {
		u.ctrl_x_pending = false
		if action == .ignore {
			// the prefix was abandoned; re-offer this key on its own
			fresh := u.ui_state()
			u.apply(decide(k, &fresh), k)
			return
		}
	}
	if k.is_ctrl(`x`) && !st.ctrl_x_pending && !st.overlay_open && !st.approving {
		u.ctrl_x_pending = true
		return
	}
	u.apply(action, k)
}

fn (mut u UI) apply(action Action, k &Key) {
	match action {
		.ignore {}
		.insert_text {
			u.buf.insert(k.ch.str())
			u.refresh_completions()
		}
		.submit {
			u.submit()
		}
		.newline {
			u.buf.insert('\n')
			u.close_menu()
		}
		.backspace {
			u.buf.backspace()
			u.refresh_completions()
		}
		.delete_forward {
			u.buf.delete_forward()
			u.refresh_completions()
		}
		.cursor_left { u.buf.move_left() }
		.cursor_right { u.buf.move_right() }
		.cursor_up { u.buf.move_up() }
		.cursor_down { u.buf.move_down() }
		.word_left { u.buf.move_word_left() }
		.word_right { u.buf.move_word_right() }
		.line_start { u.buf.move_home() }
		.line_end { u.buf.move_end() }
		.kill_to_end { u.buf.kill_to_end() }
		.kill_to_start { u.buf.kill_to_start() }
		.kill_word_back { u.buf.delete_word_back() }
		.yank { u.buf.yank() }
		.history_prev {
			u.buf.history_prev()
			u.close_menu()
		}
		.history_next {
			u.buf.history_next()
			u.close_menu()
		}
		.search_history {
			r := u.agent.handle_slash('/history')
			u.print_result(&r)
		}
		.complete_next {
			u.complete_move(1)
		}
		.complete_prev {
			u.complete_move(-1)
		}
		.complete_page_next {
			u.complete_move(completion_window)
		}
		.complete_page_prev {
			u.complete_move(-completion_window)
		}
		.complete_cancel {
			u.close_menu()
		}
		.overlay_select {
			u.overlay_select()
		}
		.overlay_close {
			u.close_overlay()
		}
		.overlay_up { u.overlay.move(-1) }
		.overlay_down { u.overlay.move(1) }
		.overlay_page_up { u.overlay.page(-1) }
		.overlay_page_down { u.overlay.page(1) }
		.overlay_first { u.overlay.go_first() }
		.overlay_last { u.overlay.go_last() }
		.approve_yes { u.answer_approval('y') }
		.approve_no { u.answer_approval('n') }
		.approve_all { u.answer_approval('a') }
		.cancel_turn {
			// the flag is read by should_cancel between steps: the turn
			// stops at the next checkpoint rather than being killed
			u.cancelled = true
			u.set_status('cancelling…')
		}
		.clear_input {
			u.buf.reset()
			u.close_menu()
			u.set_flash('input cleared — Ctrl+C again or /exit to quit', c_red)
		}
		.quit_hint {
			u.set_flash('type /exit or Ctrl+D to quit', c_dim)
		}
		.exit_app {
			r := u.agent.handle_slash('/exit')
			u.print_result(&r)
		}
		.clear_screen {
			u.screen.clear_screen()
			u.invalidate()
		}
		.open_models {
			r := u.agent.handle_slash('/model')
			u.print_result(&r)
		}
		.open_efforts {
			r := u.agent.handle_slash('/effort')
			u.print_result(&r)
		}
		.external_editor {
			u.external_editor()
		}
	}
}

// -- completions ---------------------------------------------------------------

fn (mut u UI) close_menu() {
	u.menu = unsafe { nil }
}

fn (mut u UI) refresh_completions() {
	// completion only applies to a single line that starts with a slash:
	// the moment the draft is prose, the menu is noise
	items := complete_slash(u.buf.text())
	if items.len == 0 {
		u.close_menu()
		return
	}
	u.menu = new_completion_menu(items)
}

fn (mut u UI) complete_move(delta int) {
	if u.menu == unsafe { nil } || u.menu.items.len == 0 {
		return
	}
	u.menu.move(delta)
	// the original replaced the whole line rather than the cursor word, so
	// a half-typed command is swapped out entirely
	u.buf.set_text(u.menu.selected())
}

// -- overlays ------------------------------------------------------------------

fn (mut u UI) close_overlay() {
	if u.overlay == unsafe { nil } {
		return
	}
	u.overlay.close()
	u.overlay = unsafe { nil }
}

fn (mut u UI) overlay_select() {
	if u.overlay == unsafe { nil } {
		return
	}
	kind := u.overlay.kind
	meta := u.overlay.selected_meta()
	u.close_overlay()
	// help and history are lists you read, not lists you pick from
	match kind {
		'model' {
			if m := model_by_id(meta) {
				u.agent.cfg.model_id = m.id
				u.agent.cfg.save()
				u.set_flash('model → ${m.label} (${m.id})', c_green)
			}
		}
		'effort' {
			if e := effort_by_key(meta) {
				u.agent.cfg.effort = e.key
				u.agent.cfg.save()
				u.set_flash('effort → ${e.label}', e.color)
			}
		}
		else {}
	}
}

// -- the external editor -------------------------------------------------------

// external_editor hands the draft to $EDITOR and takes back whatever comes
// out. The terminal leaves raw mode for the duration: an editor that thinks
// it is sharing the tty with a raw-mode reader paints garbage.
fn (mut u UI) external_editor() {
	editor := if e := os.getenv_opt('EDITOR') { e } else { 'vi' }
	path := os.join_path(os.temp_dir(), 'vagent-draft-${os.getpid()}.md')
	os.write_file(path, u.buf.text()) or {
		u.set_flash('could not open the editor: ${err.msg()}', c_red)
		return
	}
	defer {
		os.rm(path) or {}
	}
	u.screen.leave()
	u.term.disable_raw()
	os.system('${editor} ${os.quoted_path(path)}')
	u.term.enable_raw()
	text := os.read_file(path) or { '' }
	u.buf.set_text(text.trim_right('\n'))
	u.close_menu()
	u.invalidate()
}

// -- submitting ----------------------------------------------------------------

fn (mut u UI) submit() {
	text := u.buf.text().trim_space()
	if text == '' {
		return
	}
	u.buf.remember(u.buf.text())
	u.buf.reset()
	u.close_menu()
	u.dispatch(text)
}

fn (mut u UI) dispatch(text string) {
	if text.starts_with('/') {
		r := u.agent.handle_slash(text)
		u.print_result(&r)
		return
	}
	if u.busy {
		// never overlap two agent loops over the same message list
		u.set_flash('busy — wait for the current turn (Ctrl+C to cancel)', c_yellow)
		return
	}
	u.emit_user(text)
	u.start_turn(text)
}

pub fn (mut u UI) emit_user(text string) {
	mut rows := [][]Span{}
	for i, line in text.split('\n') {
		prefix := if i == 0 { bold_fg('❯ ', c_green) } else { plain('  ') }
		rows << [prefix, bold_fg(line, c_fg)]
	}
	u.emit(rows)
}

// -- the spinner ---------------------------------------------------------------

fn (mut u UI) start_spinner() {
	// generation token: back-to-back turns used to leak tick threads — an
	// old one wakes from its sleep after the flag flips and keeps looping.
	// A stale generation exits instead.
	u.spinner_gen++
	gen := u.spinner_gen
	u.spinner_on = true
	spawn fn [mut u, gen] () {
		for u.spinner_on && gen == u.spinner_gen {
			u.spinner_i++
			u.invalidate()
			time.sleep(spinner_interval_ms * time.millisecond)
		}
	}()
}

fn (mut u UI) stop_spinner() {
	u.spinner_gen++
	u.spinner_on = false
}

// -- approval ------------------------------------------------------------------

// approve_blocking runs on the TURN thread and blocks it until the input
// thread answers. Exactly one answer is ever sent, and nothing else can
// reach the channel, because only one tool is ever gated at a time.
fn (mut u UI) approve_blocking(tool &Tool, args map[string]json2.Any) bool {
	if u.agent.cfg.auto_approve {
		return true
	}
	u.emit([approval_line(tool.name, args)])
	if preview := diff_preview(tool.name, args) {
		u.emit(preview)
	}
	u.approve_tool = tool.name
	u.approving = true
	u.invalidate()

	answer := <-u.approve_answer

	u.approving = false
	u.approve_tool = ''
	u.invalidate()
	return answer
}

fn (mut u UI) answer_approval(answer string) {
	if !u.approving {
		return
	}
	mut yes := answer == 'y'
	if answer == 'a' {
		u.agent.cfg.auto_approve = true
		u.agent.cfg.save()
		u.print_info('  auto-approve enabled', c_yellow)
		yes = true
	}
	u.approve_answer <- yes
}

// approval_line is the one-line summary above the y/n bar.
pub fn approval_line(name string, args map[string]json2.Any) []Span {
	mut arg_str := json2.encode(json2.Any(args.clone()))
	if arg_str.len > 200 {
		arg_str = arg_str[..197] + '…'
	}
	return [
		bold_fg('  ⚠ ', c_yellow),
		bold_fg(name, c_yellow),
		fg('  ${arg_str}', c_fg),
	]
}

// diff_preview is a real preview of what the mutation will do: a unified
// diff for edit_file, an overwrite warning for write_file, nothing for
// anything else.
//
// This is the difference between approving a name and approving a change.
pub fn diff_preview(name string, args map[string]json2.Any) ?[][]Span {
	if name == 'write_file' {
		p := resolve_path(jstr(args, 'path'))
		if os.is_file(p) {
			size := os.file_size(p)
			return [[fg('  ⚠ overwrites existing file (${thousands64(i64(size))} bytes)', c_yellow)]]
		}
		return none
	}
	if name != 'edit_file' {
		return none
	}
	path := resolve_path(jstr(args, 'path'))
	old_s := jstr(args, 'old_string')
	new_s := jstr(args, 'new_string')
	text := os.read_file(path) or {
		return [[fg('  ⚠ file not readable: ${path}', c_red)]]
	}
	if old_s != '' && !text.contains(old_s) {
		return [
			[fg('  ⚠ old_string NOT FOUND in file — this edit will fail', c_red)],
		]
	}
	diff := unified_diff(old_s, new_s, 'before', 'after', 1)
	if diff.trim_space() == '' {
		return none
	}
	lines := diff.trim_right('\n').split('\n')
	mut rows := [][]Span{}
	for line in lines[..int_min(lines.len, 40)] {
		colour := if line.starts_with('+') {
			c_green
		} else if line.starts_with('-') {
			c_red
		} else {
			c_dim
		}
		rows << [fg(line, colour)]
	}
	if lines.len > 40 {
		rows << [fg('  … ${lines.len - 40} more diff line(s)', c_dim)]
	}
	return rows
}

// -- the opening ---------------------------------------------------------------

// print_banner draws the session's opening: the logo panel, what the
// session is configured to do, and the keys worth knowing.
pub fn (mut u UI) print_banner() {
	m := u.agent.model()
	e := u.agent.effort()
	mut rows := banner_rows(u.width(), u.agent.session_id)
	rows << banner_status(&m, &e, u.agent.autonomy, u.agent.session_id)
	rows << banner_hints()
	rows << []Span{}
	u.emit(rows)
}
