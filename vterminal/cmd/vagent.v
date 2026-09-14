module main

import os
import src.app
import src.config
import src.security
import src.tools
import src.utils

// The entry point stays thin on purpose: parse, decide which of the three
// modes to run (help-ish, one-shot, interactive), and translate a failure into
// an exit code. Everything else lives in src/app.
fn main() {
	args := app.parse_args(os.args#[1..]) or {
		eprintln(err.msg())
		exit(2)
	}
	if args.show_help {
		print(app.usage())
		return
	}
	if args.show_ver {
		println('vagent ${app.version}')
		return
	}
	if args.do_init {
		run_init() or {
			eprintln(err.msg())
			exit(1)
		}
		return
	}
	if args.list_tools {
		list_tools()
		return
	}

	cfg := app.bootstrap(args) or {
		eprintln(format_error(err))
		exit(1)
	}
	mut application := app.new_app(cfg) or {
		eprintln(format_error(err))
		exit(1)
	}
	defer { application.shutdown() }

	if args.prompt != '' {
		// A prompt on the command line means one task, then exit. Permission
		// prompts still work when stdin is a terminal; in a pipeline there is
		// nobody to ask, so policy alone decides (see --yes / --read-only).
		application.run_once(args.prompt, os.is_atty(0) > 0) or { exit(1) }
		return
	}
	application.run_interactive('') or { exit(1) }
}

fn format_error(e IError) string {
	if e is utils.AgentError {
		return 'vagent: ${e.msg()}'
	}
	return 'vagent: ${e.msg()}'
}

fn run_init() ! {
	root := utils.find_project_root(os.getwd())
	path := os.join_path(utils.project_config_dir(root), 'config.json')
	config.write_example(path)!
	println('wrote ${path}')
	println('set your key with:  export VAGENT_API_KEY=...')
}

// list_tools prints the built-in tool table without needing a provider, which
// makes it usable as a smoke test of a fresh install.
fn list_tools() {
	mut log := utils.discard_logger()
	mut perms := security.new_engine(config.PermissionConfig{}, os.getwd(), mut log)
	mut reg := tools.new_registry(tools.Context{
		root:    os.getwd()
		workdir: os.getwd()
		log:     &log
	}, mut perms)
	reg.register_builtins()
	for spec in reg.specs() {
		println('${spec.name:-18} ${spec.level.str():-8} ${spec.description}')
	}
	println('\n${reg.len()} built-in tools')
}
