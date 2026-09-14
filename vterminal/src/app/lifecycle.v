module app

import os
import src.config
import src.utils

// Args is the parsed command line. Flags the user did not type are absent from
// `overrides`, which is what lets configuration layering work correctly: an
// unset flag must not clobber a configured value.
pub struct Args {
pub mut:
	prompt     string
	config     string
	overrides  map[string]string
	show_help  bool
	show_ver   bool
	do_init    bool
	list_tools bool
}

pub const version = '0.1.0'

// parse_args is a hand-rolled parser rather than vlib's `flag`, because the
// trailing free-form prompt (`vagent "fix the failing test"`) does not fit the
// flag-module model, and because unknown flags should be a clear error.
pub fn parse_args(argv []string) !Args {
	mut a := Args{}
	mut rest := []string{}
	mut i := 0
	for i < argv.len {
		arg := argv[i]
		match arg {
			'-h', '--help' {
				a.show_help = true
			}
			'-v', '--version' {
				a.show_ver = true
			}
			'--init' {
				a.do_init = true
			}
			'--tools' {
				a.list_tools = true
			}
			'--debug' {
				a.overrides['debug'] = '1'
			}
			'--no-color' {
				a.overrides['no-color'] = '1'
			}
			'--no-stream' {
				a.overrides['no-stream'] = '1'
			}
			'--yes', '--allow-all' {
				a.overrides['permission-mode'] = 'allow'
			}
			'--read-only' {
				a.overrides['permission-mode'] = 'deny'
			}
			'--config' {
				a.config = value_at(argv, i + 1, '--config')!
				i++
			}
			'--model', '-m' {
				a.overrides['model'] = value_at(argv, i + 1, '--model')!
				i++
			}
			'--provider' {
				a.overrides['provider'] = value_at(argv, i + 1, '--provider')!
				i++
			}
			'--base-url' {
				a.overrides['base-url'] = value_at(argv, i + 1, '--base-url')!
				i++
			}
			else {
				if arg.starts_with('-') && arg.len > 1 {
					return utils.err_hint(.config, 'unknown option ${arg}',
						'run `vagent --help` for the supported flags')
				}
				rest << arg
			}
		}

		i++
	}
	a.prompt = rest.join(' ').trim_space()
	return a
}

// value_at reads the argument that follows a flag, reporting a missing value
// as a configuration error rather than silently consuming the next flag.
fn value_at(argv []string, idx int, name string) !string {
	if idx >= argv.len {
		return utils.err(.config, '${name} requires a value')
	}
	v := argv[idx]
	if v.starts_with('--') {
		return utils.err(.config, '${name} requires a value, found ${v}')
	}
	return v
}

pub fn usage() string {
	return 'V-AGENT ${version} — native terminal AI coding agent

usage:
  vagent                      start an interactive session
  vagent "fix the failing test"
                              run one task and exit

options:
  -m, --model <name>          model to use for this run
      --provider <name>       provider name from the config
      --base-url <url>        override the API base URL
      --config <path>         load an additional config file
      --init                  write a starter .vagent/config.json
      --tools                 list the built-in tools and exit
      --yes, --allow-all      approve every tool call without asking
      --read-only             refuse every tool call that would change anything
      --no-stream             wait for whole responses instead of streaming
      --no-color              disable ANSI colour
      --debug                 verbose logging to stderr
  -h, --help                  show this help
  -v, --version               show the version

environment:
  VAGENT_API_KEY              API key (preferred over putting it in a file)
  VAGENT_BASE_URL             API base URL, e.g. https://router.example.com/v1
  VAGENT_MODEL                model name
  VAGENT_PROVIDER_KIND        openai | anthropic
  VAGENT_PERMISSION_MODE      ask | allow | deny
  VAGENT_HOME                 override ~/.vagent
  NO_COLOR                    disable colour

configuration is layered, later layers winning:
  defaults -> ~/.vagent/config.json -> ./.vagent/config.json -> --config -> env -> flags
'
}

// bootstrap resolves configuration and reports the failure in a way the user
// can act on, which is the whole reason it does not just propagate the error.
pub fn bootstrap(args Args) !config.Config {
	mut cfg := config.load(args.config, args.overrides)!
	if !os.is_dir(cfg.project_root) {
		return utils.err(.config, 'project root ${cfg.project_root} is not a directory')
	}
	return cfg
}
