module vagent

import x.json2

// slash.v — the slash-command router.
//
// The Python original routed commands straight into the terminal: every
// branch of `_route_slash` ended in a `self.print_info(...)` or a
// `self.console.print(...)`, so the command logic and the drawing were the
// same statement. That is convenient right up to the point where you want to
// know whether `/budget usd 12` actually moved the ceiling, because the only
// way to find out is to run a terminal and read it.
//
// Here the router is a function on the Agent that RETURNS what should be
// shown. The UI prints it. Nothing in this file touches a screen, so every
// command is testable with an ordinary assertion, and the TUI keeps exactly
// one place where output turns into escape codes.
//
// Three things a command can ask the UI for besides text:
//
//   * an overlay — /model, /effort, /help and /history build the picker and
//     hand it over, because the picker is data, not drawing.
//   * an action — 'exit' and 'clear' are things only the event loop can do.
//   * a job — the commands the original ran on a background thread. They are
//     named, not closured: `job` and `job_arg` are strings the UI feeds back
//     to `slash_job`. A closure stored in a struct field and invoked through
//     a reference is the one V construct this port has already been bitten
//     by, and a command router is not the place to risk it again.
//
// Guarantees the original had that are kept here: an unknown command is an
// error, not a crash; a command that fails reports the failure rather than
// unwinding; and the argument split is `split(None, 1)` — the command word,
// then the ENTIRE rest of the line, unsplit, so `/goal set ship the thing`
// keeps its sentence.

// SlashLine is one line of command output: the text, its colour, and whether
// the UI should frame it as an error the way the original's red panel did.
pub struct SlashLine {
pub:
	spans []Span
	// 'info' | 'error'
	kind string = 'info'
}

// SlashResult is everything a command asks of the UI.
pub struct SlashResult {
pub mut:
	lines   []SlashLine
	overlay &OverlayList = unsafe { nil }
	// '' | 'exit' | 'clear'
	action string
	// a transient one-line note in the status bar, not scrollback
	flash        string
	flash_colour string
	// deferred work: the UI runs slash_job(job, job_arg) off the event
	// thread and prints the result, as the original's _bg did.
	job     string
	job_arg string
}

// -- constructors --------------------------------------------------------------

// info_line is print_info: one colour for the whole block, cyan by default.
pub fn info_line(text string, colour string) SlashLine {
	c := if colour == '' { c_cyan } else { colour }
	return SlashLine{
		spans: [fg(text, c)]
	}
}

// error_line is print_error: the red panel.
pub fn error_line(text string) SlashLine {
	return SlashLine{
		spans: [fg(text, c_red)]
		kind:  'error'
	}
}

pub fn info_result(text string, colour string) SlashResult {
	return SlashResult{
		lines: [info_line(text, colour)]
	}
}

pub fn error_result(text string) SlashResult {
	return SlashResult{
		lines: [error_line(text)]
	}
}

// text renders a result's lines without colour, which is what the tests and
// the headless CLI both want.
pub fn (r &SlashResult) text() string {
	mut out := []string{}
	for ln in r.lines {
		out << spans_text(ln.spans)
	}
	return out.join('\n')
}

// -- dispatch ------------------------------------------------------------------

// split_command splits an input line into the lowercased command word and
// the untouched remainder, matching Python's `text.strip().split(None, 1)`:
// any run of whitespace separates them, and only the first run does.
pub fn split_command(text string) (string, string) {
	s := text.trim_space()
	if s == '' {
		return '', ''
	}
	mut i := 0
	for i < s.len && !s[i].is_space() {
		i++
	}
	cmd := s[..i].to_lower()
	arg := s[i..].trim_space()
	return cmd, arg
}

// handle_slash is the guarded entry point: it routes, and turns any failure
// into an error line. The original wrapped `_route_slash` in a bare `except`
// for exactly this reason — a typo in one command must never unwind through
// the event loop and take the session with it.
pub fn (mut a Agent) handle_slash(text string) SlashResult {
	cmd, arg := split_command(text)
	if cmd == '' {
		return SlashResult{}
	}
	return a.route_slash(cmd, arg)
}

// first_word is `arg.split()[0] if arg else ""` — used by the commands that
// accept a single token and ignore whatever trails it.
fn first_word(arg string) string {
	f := arg.fields()
	return if f.len > 0 { f[0] } else { '' }
}

pub fn (mut a Agent) route_slash(cmd string, arg string) SlashResult {
	match cmd {
		'/exit', '/quit', '/q' {
			a.save_session() or { '' }
			return SlashResult{
				lines:  [info_line('bye — session ${a.session_id} saved', c_dim)]
				action: 'exit'
			}
		}
		'/new' {
			a.reset()
			return info_result('✓ new conversation started (session ${a.session_id})', c_green)
		}
		'/clear' {
			return SlashResult{
				action: 'clear'
			}
		}
		'/model' {
			return a.cmd_model(first_word(arg))
		}
		'/effort' {
			return a.cmd_effort(first_word(arg))
		}
		'/help' {
			return help_overlay()
		}
		'/history' {
			return a.history_overlay()
		}
		'/save' {
			path := a.save_session() or { '' }
			if path != '' {
				return info_result('✓ session saved → ${path}', c_green)
			}
			return error_result('could not save session')
		}
		'/approve' {
			a.cfg.auto_approve = !a.cfg.auto_approve
			a.cfg.save()
			state := if a.cfg.auto_approve { 'ON' } else { 'OFF' }
			colour := if a.cfg.auto_approve { c_yellow } else { c_dim }
			return info_result('✓ auto-approve: ${state}', colour)
		}
		'/reasoning' {
			a.cfg.show_reasoning = !a.cfg.show_reasoning
			a.cfg.save()
			state := if a.cfg.show_reasoning { 'ON' } else { 'OFF' }
			return info_result('✓ reasoning display: ${state}', c_pink)
		}
		'/usage' {
			return usage_result(a.turns)
		}
		'/goal' {
			return a.cmd_goal(arg)
		}
		'/autonomy' {
			return a.cmd_autonomy(arg)
		}
		'/focus' {
			return a.cmd_focus(arg)
		}
		'/render' {
			return a.cmd_render(arg)
		}
		'/workflow' {
			return a.cmd_workflow(arg)
		}
		'/export' {
			return a.cmd_export(arg)
		}
		'/forecast' {
			return info_result(a.get_forecast(), c_cyan)
		}
		'/health' {
			return a.cmd_health()
		}
		'/notify' {
			return a.cmd_notify(arg)
		}
		'/resume' {
			return a.cmd_resume(arg)
		}
		'/state' {
			return a.cmd_state()
		}
		'/rewind' {
			return a.cmd_rewind(arg)
		}
		'/revert' {
			return a.cmd_revert(arg)
		}
		'/fork' {
			return a.cmd_fork(arg)
		}
		'/why' {
			return a.cmd_why(arg)
		}
		'/impact' {
			return a.cmd_impact(arg)
		}
		'/forge' {
			return a.cmd_forge(arg)
		}
		'/oracle' {
			return info_result(a.oracle.format_report(), c_cyan)
		}
		'/budget' {
			return a.cmd_budget(arg)
		}
		'/constitution' {
			return a.cmd_constitution(arg)
		}
		'/replay' {
			return a.cmd_replay()
		}
		'/memory' {
			return a.cmd_memory()
		}
		'/judge' {
			return a.cmd_judge(arg)
		}
		'/compile' {
			return a.cmd_compile(arg)
		}
		'/evolve' {
			return a.cmd_evolve(arg)
		}
		'/brain' {
			return a.cmd_brain(arg)
		}
		'/merge' {
			return a.cmd_merge(arg)
		}
		'/theater' {
			return a.cmd_theater(arg)
		}
		'/debate' {
			return a.cmd_debate(arg)
		}
		'/market' {
			return a.cmd_market(arg)
		}
		'/tower' {
			return a.cmd_tower(arg)
		}
		'/verify' {
			return a.cmd_verify(arg)
		}
		'/mcts' {
			return a.cmd_mcts(arg)
		}
		'/causal' {
			return a.cmd_causal(arg)
		}
		'/bandit' {
			return a.cmd_bandit(arg)
		}
		'/mesh' {
			return a.cmd_mesh(arg)
		}
		'/roleforge' {
			return a.cmd_roleforge(arg)
		}
		'/synth' {
			return a.cmd_synth(arg)
		}
		'/ci' {
			return a.cmd_ci(arg)
		}
		'/tune' {
			return a.cmd_tune(arg)
		}
		'/dual' {
			return a.cmd_dual(arg)
		}
		'/predict' {
			return a.cmd_predict_impact(arg)
		}
		'/race' {
			return a.cmd_race(arg)
		}
		'/vitals' {
			return info_result(a.homeo.check_and_repair().format(), c_cyan)
		}
		'/attention' {
			return info_result(a.attention.format_last(), c_cyan)
		}
		'/fabric' {
			return a.cmd_fabric(arg)
		}
		'/crew' {
			return a.cmd_crew(arg)
		}
		'/auto' {
			return a.cmd_auto(arg)
		}
		'/prompt' {
			return a.cmd_prompt(arg)
		}
		'/covenant' {
			return a.cmd_covenant(arg)
		}
		'/enforce' {
			return a.cmd_enforce(arg)
		}
		'/mastermind' {
			return info_result(a.mastermind.format_status(), c_pink)
		}
		'/dashboard' {
			return info_result(a.dashboard.render(62), c_cyan)
		}
		'/router' {
			// the original called this `format_status`; the ported Router
			// names it format_report. Same report, same command.
			return info_result(a.router.format_report(), c_green)
		}
		'/spec' {
			return info_result(a.speculator.format_status(), c_cyan)
		}
		'/recall' {
			return a.cmd_recall(arg)
		}
		'/mission' {
			return a.cmd_mission(arg)
		}
		'/heal' {
			return info_result(a.healer.format_status(), c_yellow)
		}
		'/skills' {
			return info_result(a.skill_forge.format_status(), c_pink)
		}
		'/council' {
			return a.cmd_council(arg)
		}
		'/analyze' {
			return a.cmd_analyze(arg)
		}
		'/graph' {
			return a.cmd_graph(arg)
		}
		'/coverage' {
			return info_result(a.coverage.format_status(), c_cyan)
		}
		'/fuzz' {
			return info_result(a.fuzzer.format_status(), c_yellow)
		}
		'/mutate' {
			return a.cmd_mutate(arg)
		}
		'/about' {
			return SlashResult{
				lines: [
					info_line('${app_name} v${version} — advanced terminal AI agent', c_accent),
					info_line('  V + a hand-written terminal engine · OpenCode Zen & TokenRouter providers', c_dim),
				]
			}
		}
		else {
			return error_result('unknown command: ${cmd} — try /help')
		}
	}
}

// -- the simple commands -------------------------------------------------------

fn (mut a Agent) cmd_model(arg string) SlashResult {
	if arg == '' {
		return model_overlay(a.cfg.model_id)
	}
	m := model_by_id(arg) or {
		return error_result('unknown model: ${arg} — use /model to browse')
	}
	a.cfg.model_id = m.id
	a.cfg.save()
	return info_result('✓ model → ${m.label} (${m.id})', c_green)
}

fn (mut a Agent) cmd_effort(arg string) SlashResult {
	if arg == '' {
		return effort_overlay(a.cfg.effort)
	}
	e := effort_by_key(arg.to_lower()) or {
		mut keys := []string{}
		for x in efforts {
			keys << x.key
		}
		return error_result('effort levels: ' + keys.join(' · '))
	}
	a.cfg.effort = e.key
	a.cfg.save()
	return info_result('✓ effort → ${e.label}', e.color)
}

// usage_result is print_usage: one line, three differently-coloured runs.
pub fn usage_result(turns []Turn) SlashResult {
	mut total_in := 0
	mut total_out := 0
	for t in turns {
		if t.has_usage {
			total_in += int_of_any(t.usage['prompt_tokens'] or { json2.Any(0) }) or { 0 }
			total_out += int_of_any(t.usage['completion_tokens'] or { json2.Any(0) }) or { 0 }
		}
	}
	return SlashResult{
		lines: [
			SlashLine{
				spans: [
					fg(' turns: ${turns.len}', c_fg),
					fg('   prompt tokens: ${total_in}', c_dim),
					fg('   completion tokens: ${total_out}', c_dim),
				]
			},
		]
	}
}

// -- the overlays --------------------------------------------------------------

fn model_overlay(current_id string) SlashResult {
	mut items := []OverlayItem{}
	mut current := 0
	for i, m in models {
		provider := providers[m.provider] or { Provider{} }
		tag := if m.tag != '' { ' [${m.tag}]' } else { '' }
		items << OverlayItem{
			text: '${m.label}${tag} ${m.id} · ${provider.name}'
			meta: m.id
		}
		if m.id == current_id {
			current = i
		}
	}
	return SlashResult{
		overlay: new_overlay('SELECT MODEL', items, current, 'model', '')
	}
}

fn effort_overlay(current_key string) SlashResult {
	mut items := []OverlayItem{}
	mut current := 0
	for i, e in efforts {
		items << OverlayItem{
			text: '${e.label} ${e.description}'
			meta: e.key
		}
		if e.key == current_key {
			current = i
		}
	}
	return SlashResult{
		overlay: new_overlay('SELECT EFFORT', items, current, 'effort', '')
	}
}

// help_rows is the help overlay's contents, as command/description pairs.
// Kept as data so the completer and the help screen can never drift apart.
pub const help_rows = [
	['/model', 'select model (PgUp/PgDn/Tab to navigate)'],
	['/effort', 'low · medium · high · extrahigh · ultrahigh'],
	['/goal', 'set · prove · close · status · waive · clear'],
	['/autonomy', '0-5 observer → autonomous'],
	['/state', 'live projection of the event log'],
	['/rewind', 'rewind timeline+files · /revert files only'],
	['/fork', 'branch the timeline · /verify Merkle spine'],
	['/why', 'causal chain for an event seq'],
	['/impact', 'code blast-radius analysis (Nexus)'],
	['/forge', 'environment digest + drift'],
	['/oracle', 'post-run analysis + calibration'],
	['/budget [steps N|usd X|reset]', 'budget governor status/extend'],
	['/constitution', 'standing rules (human-owned)'],
	['/replay', 'replay the session log as a film'],
	['/memory', 'episodes + dead-end ledger'],
	['/judge', 'deterministic check (exit_code, file_exists, …)'],
	['/new', 'fresh conversation'],
	['/history', 'browse previous turns'],
	['/save', 'save session to disk'],
	['/approve', 'toggle auto-approve for tools'],
	['/reasoning', 'toggle reasoning display'],
	['/usage', 'token usage'],
	['/clear', 'clear screen'],
	['/exit', 'quit'],
	['Enter', 'send    Esc+Enter: newline    Ctrl+R: search history'],
	['Ctrl+T', 'models    Ctrl+E: effort    Ctrl+L: clear'],
]

fn help_overlay() SlashResult {
	mut items := []OverlayItem{}
	for row in help_rows {
		items << OverlayItem{
			text: '${row[0]} ${row[1]}'
		}
	}
	return SlashResult{
		overlay: new_overlay('HELP', items, 0, 'help', 'Esc close')
	}
}

fn (a &Agent) history_overlay() SlashResult {
	if a.turns.len == 0 {
		return SlashResult{
			flash:        'no history yet'
			flash_colour: c_dim
		}
	}
	mut start := a.turns.len - 15
	if start < 0 {
		start = 0
	}
	mut items := []OverlayItem{}
	for t in a.turns[start..] {
		// the original escaped this text because prompt_toolkit parsed it
		// as XML and a stray '&' in a user message would kill the render
		// loop. Nothing here parses markup, so the text goes through as
		// typed — but it is still truncated to one short line.
		mut preview := t.user_text.replace('\n', ' ')
		if preview.len > 70 {
			preview = preview[..70]
		}
		items << OverlayItem{
			text: '${t.timestamp} ${preview}'
		}
	}
	return SlashResult{
		overlay: new_overlay('HISTORY (recent turns)', items, items.len - 1, 'history', '')
	}
}
