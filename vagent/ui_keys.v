module vagent

// ui_keys.v — what each key means, given what the UI is doing.
//
// The Python original expressed this as prompt_toolkit KeyBindings guarded
// by Condition filters: `focused & ~ov & idle & not busy`. Filters compose
// nicely but they are invisible at runtime — the only way to find out what
// Ctrl+C does while a turn is running and an overlay is open is to open one
// and press it.
//
// Here the same table is one pure function from (key, state) to action, so
// every binding can be asserted in a test. The loop in ui.v does nothing but
// apply what this returns.
//
// Precedence follows the original exactly, and the order matters:
//
//   1. the approval bar swallows EVERYTHING it does not handle, so a stray
//      keystroke cannot edit the input line behind a y/n prompt;
//   2. an open overlay takes the navigation keys;
//   3. everything else is ordinary editing.

pub enum Action {
	ignore
	// input
	insert_text
	submit
	newline
	backspace
	delete_forward
	// motion
	cursor_left
	cursor_right
	cursor_up
	cursor_down
	word_left
	word_right
	line_start
	line_end
	// editing
	kill_to_end
	kill_to_start
	kill_word_back
	yank
	// history
	history_prev
	history_next
	search_history
	// the slash-command completion menu
	complete_next
	complete_prev
	complete_page_next
	complete_page_prev
	complete_cancel
	// overlay
	overlay_select
	overlay_close
	overlay_up
	overlay_down
	overlay_page_up
	overlay_page_down
	overlay_first
	overlay_last
	// approval bar
	approve_yes
	approve_no
	approve_all
	// session
	cancel_turn
	clear_input
	quit_hint
	exit_app
	clear_screen
	open_models
	open_efforts
	external_editor
}

// UiState is everything a binding is allowed to depend on. Keeping it a
// value — rather than reaching into the UI — is what makes the table a pure
// function.
pub struct UiState {
pub:
	overlay_open bool
	approving    bool
	// a turn is running: submitting another would start a second agent loop
	// over the same message list
	busy          bool
	buffer_empty  bool
	on_first_line bool
	on_last_line  bool
	// the completion menu is showing
	completing bool
	// Ctrl+X was pressed and is waiting for its second key
	ctrl_x_pending bool
}

// decide maps one keypress to the action the UI should take.
pub fn decide(k &Key, st &UiState) Action {
	// -- Ctrl+X Ctrl+E: the two-key external-editor binding ------------------
	if st.ctrl_x_pending {
		if k.is_ctrl(`e`) && !st.overlay_open && !st.approving {
			return .external_editor
		}
		// any other second key abandons the prefix; the caller clears it and
		// re-offers this key, so nothing is swallowed
		return .ignore
	}

	// -- 1. the approval bar -------------------------------------------------
	if st.approving {
		if k.kind == .char_ {
			return match k.ch {
				`y`, `Y` { Action.approve_yes }
				`n`, `N` { Action.approve_no }
				`a`, `A` { Action.approve_all }
				else { Action.ignore }
			}
		}
		// Enter, Escape and Ctrl+C all mean "no": the safe answer is the one
		// you get by flinching
		if k.kind == .enter || k.kind == .escape || k.is_ctrl(`c`) {
			return .approve_no
		}
		return .ignore
	}

	// -- 2. an open overlay --------------------------------------------------
	if st.overlay_open {
		return match k.kind {
			.enter { Action.overlay_select }
			.escape { Action.overlay_close }
			.up, .back_tab { Action.overlay_up }
			.down, .tab { Action.overlay_down }
			.page_up { Action.overlay_page_up }
			.page_down { Action.overlay_page_down }
			.home { Action.overlay_first }
			.end { Action.overlay_last }
			.ctrl {
				match k.ch {
					`c` { Action.overlay_close }
					`p` { Action.overlay_up }
					`n` { Action.overlay_down }
					else { Action.ignore }
				}
			}
			else { Action.ignore }
		}
	}

	// -- 3. ordinary input ---------------------------------------------------
	match k.kind {
		.char_ {
			return .insert_text
		}
		.enter {
			// while a turn runs the buffer is still a multi-line editor, so
			// Enter does what it does in one: it breaks the line
			return if st.busy { Action.newline } else { Action.submit }
		}
		.tab {
			return .complete_next
		}
		.back_tab {
			return .complete_prev
		}
		.alt {
			// Esc+Enter is the newline binding; Alt+b / Alt+f are the word
			// motions every readline user expects
			if k.alt_of == .enter {
				return .newline
			}
			return match k.ch {
				`b` { Action.word_left }
				`f` { Action.word_right }
				else { Action.ignore }
			}
		}
		.escape {
			// a lone Escape interrupts a running turn, closes the completion
			// menu, and means nothing otherwise — Esc+Enter arrives as .alt
			// above, not as this
			if st.busy {
				return .cancel_turn
			}
			return if st.completing { Action.complete_cancel } else { Action.ignore }
		}
		.backspace {
			return .backspace
		}
		.delete {
			return .delete_forward
		}
		.left {
			return .cursor_left
		}
		.right {
			return .cursor_right
		}
		.up {
			// history only at the edges, so a multi-line draft stays navigable
			return if st.on_first_line { Action.history_prev } else { Action.cursor_up }
		}
		.down {
			return if st.on_last_line { Action.history_next } else { Action.cursor_down }
		}
		.home {
			return .line_start
		}
		.end {
			return .line_end
		}
		.page_up {
			return if st.completing { Action.complete_page_prev } else { Action.ignore }
		}
		.page_down {
			return if st.completing { Action.complete_page_next } else { Action.ignore }
		}
		.ctrl {
			return ctrl_action(k.ch, st)
		}
		.unknown {
			return .ignore
		}
	}
}

fn ctrl_action(ch rune, st &UiState) Action {
	return match ch {
		// Ctrl+C is three different things, and which one depends entirely on
		// what is in front of the user: stop the turn, clear the line, or say
		// how to quit. It never exits on its own — that is Ctrl+D's job, and
		// only on an empty line.
		`c` {
			if st.busy {
				Action.cancel_turn
			} else if !st.buffer_empty {
				Action.clear_input
			} else {
				Action.quit_hint
			}
		}
		`d` {
			if st.buffer_empty { Action.exit_app } else { Action.delete_forward }
		}
		`a` { Action.line_start }
		`e` { Action.open_efforts }
		`b` { Action.cursor_left }
		`f` { Action.cursor_right }
		`k` { Action.kill_to_end }
		`u` { Action.kill_to_start }
		`w` { Action.kill_word_back }
		`y` { Action.yank }
		`l` { Action.clear_screen }
		`t` { Action.open_models }
		`r` { Action.search_history }
		// Ctrl+P and Ctrl+N are Up and Down, edge rule included
		`p` {
			if st.on_first_line { Action.history_prev } else { Action.cursor_up }
		}
		`n` {
			if st.on_last_line { Action.history_next } else { Action.cursor_down }
		}
		else { Action.ignore }
	}
}
