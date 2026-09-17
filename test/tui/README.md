# TUI integration tests

The unit tests in `vagent/*_test.v` cover the pieces of the terminal UI in
isolation: the key table, the edit buffer, the box renderer, the completion
menu, the pinned region's arithmetic. What they cannot cover is the thing a
user actually sees, because that only exists once the escape sequences reach
a real terminal.

These tests run the built binary under a pty, drive it with keystrokes, and
replay its output through a small ANSI screen emulator — so the assertions
are about the rendered screen, not about the bytes that produced it.

That distinction has already paid for itself. The erase of the pinned region
used to assume the cursor sat on the region's last row, while the draw parks
it where the user is typing. Every unit test passed; on a real terminal,
every command typed with the completion menu open silently ate one line of
scrollback. Only a screen emulator could see it.

## Running them

    v -enable-globals -o vagent-bin cmd/vagent
    python3 test/tui/tui_check.py     # behaviour: keys, commands, overlays
    python3 test/tui/tui_check2.py    # layout: the box under load, at the edges

`VAGENT_BIN` overrides the binary's path and `VAGENT_TEST_HOME` the state
directory (which defaults to a throwaway under the system temp dir, so a run
never touches your own event log).
