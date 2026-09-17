module main

import os
import vagent

// main.v — the entry point.
//
// Interactive TUI by default; a headless subcommand operates on the
// persistent event log without ever drawing a box. The split is the same
// one the Python original made, and it is deliberate: the log is the
// product, so an integrity check or a causal chain has to be available to a
// script, not only to a session someone has open.
//
// Nothing here formats anything. run_headless returns lines and an exit
// code, the UI owns the screen, and this file only decides which of the two
// is in charge and where their output goes.

fn main() {
	argv := os.args[1..]

	if argv.len > 0 && argv[0] in ['--version', '-v'] {
		println('${vagent.app_name.to_lower()} v${vagent.version}')
		return
	}
	if argv.len > 0 && argv[0] in ['--help', '-h', 'help'] {
		println(vagent.cli_usage)
		return
	}

	vagent.ensure_dirs()
	cfg := vagent.load_config()
	mut agent := vagent.new_agent(cfg)

	if argv.len > 0 {
		result := agent.run_headless(argv)
		for line in result.out {
			println(line)
		}
		for line in result.errs {
			eprintln(line)
		}
		exit(result.code)
	}

	mut ui := vagent.new_ui(mut agent)
	ui.print_banner()
	ui.run()
}
