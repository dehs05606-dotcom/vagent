module app

import os
import src.agent
import src.config
import src.context
import src.memory
import src.model
import src.security
import src.tools
import src.tui
import src.utils

// App wires every subsystem together and owns the read-eval-print loop. It is
// the only place that knows about all of them; each module below it stays
// independently testable.
@[heap]
pub struct App {
pub mut:
	cfg      config.Config
	log      utils.Logger
	ui       tui.Renderer
	perms    security.Engine
	registry tools.Registry
	snapshot context.Snapshot
	pmem     memory.ProjectMemory
	session  memory.Session
	running  bool = true
mut:
	gateway &model.Gateway = unsafe { nil }
	ag      &agent.Agent   = unsafe { nil }
}

// new_app performs startup in dependency order and fails loudly on a bad
// configuration, because a half-initialised agent is worse than none.
pub fn new_app(cfg config.Config) !&App {
	cfg.validate() or {
		return utils.err_hint(.config, err.msg(),
			'run `vagent --init` to write a starter config, or set the environment variables listed in --help')
	}
	mut a := &App{
		cfg: cfg
	}
	a.log = utils.new_logger(cfg.log.file, utils.level_from_string(cfg.log.level),
		cfg.log.to_stderr)
	a.log.info('starting V-AGENT in ${cfg.project_root} (provider=${cfg.provider.name} model=${cfg.provider.model})')

	a.ui = tui.new_renderer(cfg.ui.color, cfg.ui.unicode, cfg.ui.compact, cfg.ui.show_plan)

	a.perms = security.new_engine(cfg.permissions, cfg.project_root, mut a.log)
	mut ui := &a.ui
	a.perms.ask_fn = fn [mut ui] (req security.Request) security.Approval {
		return ui.ask_permission(req)
	}
	a.perms.interactive = a.ui.interactive

	mut tctx := tools.Context{
		root:          cfg.project_root
		workdir:       cfg.workdir
		max_output:    cfg.agent.max_tool_output
		shell_timeout: cfg.agent.shell_timeout_secs
		confine:       cfg.permissions.confine_to_root
		log:           &a.log
	}
	tctx.probe_environment()
	a.registry = tools.new_registry(tctx, mut a.perms)
	a.registry.register_builtins()

	a.snapshot = context.collect(cfg.project_root, cfg.workdir)
	a.pmem = memory.load_project_memory(cfg.project_root)
	a.session = memory.new_session(cfg.project_root)

	a.gateway = model.new_gateway(cfg.provider, mut a.log)!

	mut gw := a.gateway
	mut reg := &a.registry
	mut rui := &a.ui
	mut log := &a.log
	a.ag = agent.new_agent(agent.AgentOpts{
		cfg:       cfg.agent
		perm_mode: cfg.permissions.mode
		snapshot:  a.snapshot
		pmem:      a.pmem
		session:   a.session
		limit:     cfg.provider.context_limit
	}, mut gw, mut reg, mut rui, mut log)
	// Build the system prompt now, so /context and /status report the real
	// baseline rather than zero before the first turn.
	a.ag.prime()
	return a
}

pub fn (mut a App) shutdown() {
	a.log.info('session ended after ${a.ag.state.turn} turn(s), ${a.ag.state.tool_calls} tool call(s)')
	a.log.close()
}

// run_once executes a single prompt and returns. This is the path used by
// `vagent "do the thing"` and by scripts. When `interactive` is false there is
// nobody to answer a permission prompt, so policy decides on its own.
pub fn (mut a App) run_once(prompt string, interactive bool) ! {
	a.perms.interactive = interactive
	a.ui.user_echo(prompt)
	// A one-shot prompt may still name a mode: `vagent "/review my changes"`
	// should behave the same as typing it at the prompt.
	cmd := tui.parse_input(prompt)
	if cmd.is_slash {
		a.handle_command(cmd) or {
			a.ui.error(describe(err))
			return err
		}
		return
	}
	a.ag.run_turn(prompt) or {
		a.ui.error(describe(err))
		return err
	}
}

// run_interactive is the REPL.
pub fn (mut a App) run_interactive(initial string) ! {
	a.ui.banner(a.cfg.provider.model, a.cfg.provider.name, a.cfg.project_root, a.registry.len())
	if a.snapshot.summary() != '' {
		a.ui.info('  ${a.snapshot.summary()}')
		a.ui.raw('')
	}
	mut pending := initial
	for a.running {
		mut line := pending
		pending = ''
		if line == '' {
			line = a.ui.read_line(a.ag.mode()) or {
				a.ui.raw('')
				break
			}
		}
		if line.trim_space() == '' {
			continue
		}
		cmd := tui.parse_input(line)
		if cmd.is_slash {
			a.handle_command(cmd) or { a.ui.error(describe(err)) }
			continue
		}
		a.ui.raw('')
		a.ag.run_turn(cmd.text) or {
			a.ui.error(describe(err))
			// A provider failure is not fatal to the session: the user may want
			// to switch model, compact, or just retry.
			continue
		}
	}
}

// describe unwraps an AgentError into its message plus hint, and falls back to
// the plain message for errors that came from vlib.
fn describe(e IError) string {
	if e is utils.AgentError {
		return e.msg()
	}
	return e.msg()
}

// -------------------------------------------------------------- commands

fn (mut a App) handle_command(cmd tui.Command) ! {
	match cmd.name {
		'help', 'h', '?' {
			a.ui.raw(tui.help_text(a.ui.style))
		}
		'quit', 'exit', 'q' {
			a.running = false
		}
		'status' {
			a.cmd_status()
		}
		'model' {
			a.cmd_model(cmd.args)!
		}
		'tools' {
			a.cmd_tools()
		}
		'context' {
			a.cmd_context()
		}
		'memory' {
			a.cmd_memory(cmd.args)!
		}
		'clear' {
			a.ag.clear()
			a.perms.reset_session_grants()
			a.ui.notice('conversation, plan and session permissions cleared')
		}
		'compact' {
			report := a.ag.compact_now()
			a.ui.notice('compacted ${utils.human_count(report.before_tokens)} -> ${utils.human_count(report.after_tokens)} tokens (${report.trimmed} tool outputs trimmed, ${report.dropped} messages dropped)')
		}
		'mcp' {
			a.ui.info('MCP gateway is not wired up in this build. Configure servers under .vagent/ and they will appear here once the transport lands.')
		}
		'init' {
			path := os.join_path(utils.project_config_dir(a.cfg.project_root), 'config.json')
			config.write_example(path)!
			a.ui.notice('wrote ${path}')
		}
		'agent', 'chat', 'plan', 'execute', 'exec', 'review', 'debug', 'search' {
			a.cmd_mode(cmd.name, cmd.args)!
		}
		else {
			a.ui.error('unknown command /${cmd.name} — try /help')
		}
	}
}

fn (mut a App) cmd_mode(name string, args string) ! {
	mode := tui.mode_from_string(name) or { return utils.err(.internal, 'unknown mode ${name}') }
	a.ag.set_mode(mode)
	if args.trim_space() == '' {
		a.ui.notice('mode: ${mode.str()}')
		return
	}
	a.ui.raw('')
	a.ag.run_turn(args) or {
		a.ui.error(describe(err))
		return
	}
}

fn (mut a App) cmd_status() {
	git := if a.snapshot.git_branch != '' {
		'${a.snapshot.git_branch}${if a.snapshot.git_dirty > 0 { '*' } else { '' }}'
	} else {
		''
	}
	a.ui.status(tui.StatusLine{
		model:    a.gateway.model_id()
		tokens:   a.ag.context_tokens()
		limit:    a.gateway.context_limit()
		cost:     a.gateway.estimated_cost()
		tools:    a.registry.len()
		mode:     a.ag.mode().str()
		git:      git
		messages: a.ag.state.user_visible_messages()
	})
	s := a.ui.style
	a.ui.raw('  ${s.grey('provider')}    ${a.cfg.provider.name} (${a.cfg.provider.kind}) ${a.cfg.provider.base_url}')
	a.ui.raw('  ${s.grey('api key')}     ${a.cfg.redacted_api_key()}')
	a.ui.raw('  ${s.grey('streaming')}   ${a.cfg.provider.streaming}')
	a.ui.raw('  ${s.grey('permissions')} mode=${a.cfg.permissions.mode} confined=${a.cfg.permissions.confine_to_root}')
	grants := a.perms.granted_this_session()
	if grants.len > 0 {
		a.ui.raw('  ${s.grey('granted')}     ${grants.join(', ')}')
	}
	a.ui.raw('  ${s.grey('usage')}       ${a.gateway.total.prompt_tokens} in / ${a.gateway.total.completion_tokens} out over ${a.gateway.requests} request(s)')
	a.ui.raw('  ${s.grey('session')}     ${a.session.path()}')
	a.ui.raw('  ${s.grey('config')}      ${a.cfg.sources.join(' <- ')}')
}

fn (mut a App) cmd_model(args string) ! {
	if args.trim_space() == '' {
		a.ui.raw('  current model: ${a.gateway.model_id()}')
		a.ui.info('  pass a name to switch, e.g. /model gpt-oss-20b')
		return
	}
	old := a.gateway.model_id()
	a.gateway.switch_model(args.trim_space())!
	a.cfg.provider.model = a.gateway.model_id()
	a.ui.notice('model: ${old} -> ${a.gateway.model_id()}')
}

fn (mut a App) cmd_tools() {
	s := a.ui.style
	a.ui.raw('')
	for spec in a.registry.specs() {
		// Pad before colouring: escape sequences have width 0 but length > 0,
		// so padding a coloured string misaligns the column.
		name := '${spec.name:-22}'
		level := '${spec.level.str():-9}'
		a.ui.raw('  ${s.bold(name)} ${s.grey(level)} ${utils.first_sentence(spec.description)}')
	}
	a.ui.raw('')
	a.ui.info('  ${a.registry.len()} tools registered')
}

fn (mut a App) cmd_context() {
	s := a.ui.style
	tokens := a.ag.context_tokens()
	limit := a.gateway.context_limit()
	pct := if limit > 0 { int(f64(tokens) * 100.0 / f64(limit)) } else { 0 }
	a.ui.raw('')
	a.ui.raw('  ${s.bold('context')} ${utils.human_count(tokens)} / ${utils.human_count(limit)} tokens (${pct}%)')
	a.ui.raw('  ${s.grey('messages')}  ${a.ag.state.user_visible_messages()} (plus system prompt)')
	a.ui.raw('  ${s.grey('project')}   ${a.snapshot.summary()}')
	if a.snapshot.build_commands.len > 0 {
		a.ui.raw('  ${s.grey('build')}     ${a.snapshot.build_commands.join(' | ')}')
	}
	if a.snapshot.rules.len > 0 {
		a.ui.raw('  ${s.grey('rules')}     ${a.snapshot.rules.len} project rule file(s) loaded')
	}
	files := a.registry.ctx.read_files.keys()
	if files.len > 0 {
		a.ui.raw('  ${s.grey('read')}      ${files.len} file(s) this session')
	}
	a.ui.raw('')
}

fn (mut a App) cmd_memory(args string) ! {
	if args.trim_space() == '' {
		a.ui.raw('  ${a.pmem.summary()}')
		for n in a.pmem.notes {
			a.ui.raw('  - ${n}')
		}
		a.ui.info('  /memory <note> to remember something about this project')
		return
	}
	a.pmem.remember(args)!
	a.ag.pmem = a.pmem
	a.ui.notice('remembered: ${args}')
}
