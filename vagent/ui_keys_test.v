module vagent

fn key_char(c rune) Key {
	return Key{
		kind: .char_
		ch:   c
	}
}

fn key_of(kind KeyKind) Key {
	return Key{
		kind: kind
	}
}

fn key_ctrl(c rune) Key {
	return Key{
		kind: .ctrl
		ch:   c
	}
}

fn act(k Key, st UiState) Action {
	return decide(&k, &st)
}

fn test_the_approval_bar_swallows_everything_it_does_not_answer() {
	ap := UiState{
		approving: true
	}
	assert act(key_char(`y`), ap) == .approve_yes
	assert act(key_char(`Y`), ap) == .approve_yes
	assert act(key_char(`n`), ap) == .approve_no
	assert act(key_char(`a`), ap) == .approve_all

	// flinching is safe: Enter, Escape and Ctrl+C all deny
	assert act(key_of(.enter), ap) == .approve_no
	assert act(key_of(.escape), ap) == .approve_no
	assert act(key_ctrl(`c`), ap) == .approve_no

	// nothing else reaches the input line behind the bar
	assert act(key_char(`z`), ap) == .ignore
	assert act(key_of(.backspace), ap) == .ignore
	assert act(key_of(.up), ap) == .ignore
	assert act(key_ctrl(`l`), ap) == .ignore
	assert act(key_ctrl(`d`), ap) == .ignore

	// and it outranks the overlay and a running turn
	both := UiState{
		approving:    true
		overlay_open: true
		busy:         true
	}
	assert act(key_of(.enter), both) == .approve_no
}

fn test_an_open_overlay_takes_the_navigation_keys() {
	ov := UiState{
		overlay_open: true
	}
	assert act(key_of(.enter), ov) == .overlay_select
	assert act(key_of(.escape), ov) == .overlay_close
	assert act(key_ctrl(`c`), ov) == .overlay_close
	assert act(key_of(.up), ov) == .overlay_up
	assert act(key_of(.back_tab), ov) == .overlay_up
	assert act(key_ctrl(`p`), ov) == .overlay_up
	assert act(key_of(.down), ov) == .overlay_down
	assert act(key_of(.tab), ov) == .overlay_down
	assert act(key_ctrl(`n`), ov) == .overlay_down
	assert act(key_of(.page_up), ov) == .overlay_page_up
	assert act(key_of(.page_down), ov) == .overlay_page_down
	assert act(key_of(.home), ov) == .overlay_first
	assert act(key_of(.end), ov) == .overlay_last

	// typing does not leak into the draft behind the overlay
	assert act(key_char(`x`), ov) == .ignore
	assert act(key_of(.backspace), ov) == .ignore
	// nor does Ctrl+L, which the original also gated behind ~overlay
	assert act(key_ctrl(`l`), ov) == .ignore
}

fn test_enter_submits_unless_a_turn_is_running() {
	assert act(key_of(.enter), UiState{}) == .submit
	// a multi-line editor breaks the line when it cannot send
	assert act(key_of(.enter), UiState{ busy: true }) == .newline
	// Esc+Enter is always a newline
	alt_enter := Key{
		kind:   .alt
		alt_of: .enter
	}
	assert act(alt_enter, UiState{}) == .newline
	assert act(alt_enter, UiState{ busy: true }) == .newline
}

fn test_up_and_down_reach_history_only_at_the_edges() {
	first := UiState{
		on_first_line: true
	}
	middle := UiState{}
	last := UiState{
		on_last_line: true
	}
	assert act(key_of(.up), first) == .history_prev
	assert act(key_of(.up), middle) == .cursor_up
	assert act(key_of(.down), last) == .history_next
	assert act(key_of(.down), middle) == .cursor_down

	// Ctrl+P and Ctrl+N follow the same rule
	assert act(key_ctrl(`p`), first) == .history_prev
	assert act(key_ctrl(`p`), middle) == .cursor_up
	assert act(key_ctrl(`n`), last) == .history_next
	assert act(key_ctrl(`n`), middle) == .cursor_down
}

fn test_ctrl_c_is_three_different_things() {
	assert act(key_ctrl(`c`), UiState{ busy: true }) == .cancel_turn
	assert act(key_ctrl(`c`), UiState{ buffer_empty: false }) == .clear_input
	assert act(key_ctrl(`c`), UiState{ buffer_empty: true }) == .quit_hint
	// it never exits on its own — that is Ctrl+D's job
	assert act(key_ctrl(`c`), UiState{ buffer_empty: true }) != .exit_app
}

fn test_ctrl_d_only_exits_on_an_empty_line() {
	assert act(key_ctrl(`d`), UiState{ buffer_empty: true }) == .exit_app
	assert act(key_ctrl(`d`), UiState{ buffer_empty: false }) == .delete_forward
}

fn test_a_lone_escape_interrupts_a_running_turn() {
	assert act(key_of(.escape), UiState{ busy: true }) == .cancel_turn
	assert act(key_of(.escape), UiState{}) == .ignore
	assert act(key_of(.escape), UiState{ completing: true }) == .complete_cancel
	// but a busy turn still wins over the menu
	assert act(key_of(.escape), UiState{
		busy:       true
		completing: true
	}) == .cancel_turn
}

fn test_the_editing_and_motion_keys_are_the_readline_ones() {
	st := UiState{}
	assert act(key_ctrl(`a`), st) == .line_start
	assert act(key_ctrl(`k`), st) == .kill_to_end
	assert act(key_ctrl(`u`), st) == .kill_to_start
	assert act(key_ctrl(`w`), st) == .kill_word_back
	assert act(key_ctrl(`y`), st) == .yank
	assert act(key_ctrl(`b`), st) == .cursor_left
	assert act(key_ctrl(`f`), st) == .cursor_right
	assert act(key_of(.home), st) == .line_start
	assert act(key_of(.end), st) == .line_end
	assert act(key_of(.backspace), st) == .backspace
	assert act(key_of(.delete), st) == .delete_forward
	assert act(key_char(`q`), st) == .insert_text

	// Alt+b / Alt+f are the word motions
	assert act(Key{ kind: .alt, ch: `b` }, st) == .word_left
	assert act(Key{ kind: .alt, ch: `f` }, st) == .word_right
	assert act(Key{ kind: .alt, ch: `z` }, st) == .ignore
}

fn test_the_session_keys_open_what_they_say() {
	st := UiState{}
	assert act(key_ctrl(`t`), st) == .open_models
	assert act(key_ctrl(`e`), st) == .open_efforts
	assert act(key_ctrl(`l`), st) == .clear_screen
	assert act(key_ctrl(`r`), st) == .search_history
	assert act(key_ctrl(`z`), st) == .ignore
}

fn test_ctrl_x_ctrl_e_opens_the_external_editor() {
	pending := UiState{
		ctrl_x_pending: true
	}
	assert act(key_ctrl(`e`), pending) == .external_editor
	// any other second key abandons the prefix without acting on it
	assert act(key_char(`e`), pending) == .ignore
	assert act(key_of(.enter), pending) == .ignore
	// and the prefix does not survive into an overlay or the approval bar
	assert act(key_ctrl(`e`), UiState{
		ctrl_x_pending: true
		overlay_open:   true
	}) == .ignore
	assert act(key_ctrl(`e`), UiState{
		ctrl_x_pending: true
		approving:      true
	}) == .ignore
}

fn test_tab_drives_the_completion_menu() {
	st := UiState{}
	assert act(key_of(.tab), st) == .complete_next
	assert act(key_of(.back_tab), st) == .complete_prev
	// the page keys only mean something while the menu is open
	assert act(key_of(.page_down), st) == .ignore
	assert act(key_of(.page_down), UiState{ completing: true }) == .complete_page_next
	assert act(key_of(.page_up), UiState{ completing: true }) == .complete_page_prev
}
