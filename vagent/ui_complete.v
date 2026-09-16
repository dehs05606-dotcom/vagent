module vagent

// ui_complete.v — the slash-command completion menu.
//
// Tab in the prompt box offers the commands, and for four of them it offers
// their SUBCOMMANDS instead, because `/goal` alone does nothing useful and a
// list of seventy commands is not an answer to someone who has already typed
// `/goal `.
//
// Completion only applies to a single line that starts with a slash: the
// moment the draft is multi-line it is prose, not a command.

pub struct Completion {
pub:
	// the whole replacement text — the original replaced from the start of
	// the line rather than from the cursor word, so a half-typed command is
	// swapped out entirely
	text string
	meta string
}

// autonomy_levels is what each level means. It lives here because the
// completer offers them; the agent enforces them.
pub const autonomy_levels = [
	'Observer — reads only, no mutations',
	'Advisor — proposes, applies nothing',
	'Assistant — every mutation needs approval',
	'Collaborator — safe actions free, risky need approval (default)',
	'Pilot — auto-approve except deletes',
	'Autonomous — full freedom within budget',
]

pub const goal_subcommands = [
	Completion{
		text: 'set'
		meta: 'set <statement> | <clause> | <clause> …'
	},
	Completion{
		text: 'prove'
		meta: 'prove <clause-id> — run its own predicate'
	},
	Completion{
		text: 'prove-all'
		meta: 'prove every clause from scratch'
	},
	Completion{
		text: 'close'
		meta: 'closure ritual — compute the terminal state'
	},
	Completion{
		text: 'status'
		meta: 'the Goal Compass: distance, velocity, focus'
	},
	Completion{
		text: 'waive'
		meta: "waive <clause-id> --reason '…' (human waiver)"
	},
	Completion{
		text: 'clear'
		meta: 'deactivate the goal'
	},
]

pub const judge_predicates = [
	Completion{
		text: 'exit_code'
		meta: '{"command": "pytest -q", "expect": 0}'
	},
	Completion{
		text: 'file_exists'
		meta: '{"path": "src/x.py"}'
	},
	Completion{
		text: 'file_contains'
		meta: '{"path": "src/x.py", "text": "def foo"}'
	},
	Completion{
		text: 'file_matches'
		meta: '{"path": "src/x.py", "pattern": "…"}'
	},
	Completion{
		text: 'command_output_contains'
		meta: '{"command": "python -V", "text": "Python"}'
	},
]

pub const slash_commands = [
	Completion{
		text: '/model'
		meta: 'select model — PgUp/PgDn/Tab to navigate'
	},
	Completion{
		text: '/effort'
		meta: 'low · medium · high · extrahigh · ultrahigh'
	},
	Completion{
		text: '/goal'
		meta: 'goal contract — set · prove · close · status · waive · clear'
	},
	Completion{
		text: '/autonomy'
		meta: 'autonomy level 0-5 (observer → autonomous)'
	},
	Completion{
		text: '/focus'
		meta: 'deep-work mode — /focus <1-20> auto-continues until done'
	},
	Completion{
		text: '/render'
		meta: 'toggle rendered-markdown replies — /render [on|off]'
	},
	Completion{
		text: '/workflow'
		meta: 'saved pipelines — /workflow [list|run <name>|delete <name>]'
	},
	Completion{
		text: '/export'
		meta: 'enterprise audit report — /export [md|html]'
	},
	Completion{
		text: '/forecast'
		meta: 'projection from measured velocity + usage'
	},
	Completion{
		text: '/health'
		meta: 'provider health — model errors + failovers'
	},
	Completion{
		text: '/notify'
		meta: 'event notifications — /notify <url|file:path|off>'
	},
	Completion{
		text: '/resume'
		meta: 'resume a previous session — /resume [branch]'
	},
	Completion{
		text: '/state'
		meta: 'live projection of the event log (cost, goal, dead-ends)'
	},
	Completion{
		text: '/rewind'
		meta: 'rewind timeline + files to a seq — /rewind <seq>'
	},
	Completion{
		text: '/revert'
		meta: 'revert FILES only to a seq (agent keeps memory)'
	},
	Completion{
		text: '/fork'
		meta: 'fork the timeline into a new branch — /fork [name]'
	},
	Completion{
		text: '/why'
		meta: 'causal chain for an event — /why <seq>'
	},
	Completion{
		text: '/impact'
		meta: 'code impact analysis — /impact <symbol> [path]'
	},
	Completion{
		text: '/forge'
		meta: 'environment digest + drift — /forge [probe|drift]'
	},
	Completion{
		text: '/oracle'
		meta: 'post-run analysis, calibration, facts'
	},
	Completion{
		text: '/budget'
		meta: 'budget governor status/extend — /budget steps N|usd X|reset'
	},
	Completion{
		text: '/constitution'
		meta: 'standing rules — /constitution [show|edit]'
	},
	Completion{
		text: '/replay'
		meta: 'replay the session log as a film (text)'
	},
	Completion{
		text: '/memory'
		meta: 'recent episodes + dead-end ledger'
	},
	Completion{
		text: '/judge'
		meta: 'deterministic check — /judge <type> <json-or-args>'
	},
	Completion{
		text: '/compile'
		meta: 'intent compiler: goal → optimized ordered waves'
	},
	Completion{
		text: '/evolve'
		meta: 'evolve a role brief — /evolve [role|rollback <role>]'
	},
	Completion{
		text: '/brain'
		meta: 'cognitive memory — /brain <query>|sleep|stats'
	},
	Completion{
		text: '/merge'
		meta: 'semantic timeline merge — /merge <branchA> <branchB>'
	},
	Completion{
		text: '/theater'
		meta: 'time-travel debugger — /theater <seq|why N|cf N|diff A B>'
	},
	Completion{
		text: '/debate'
		meta: 'multi-model debate tournament — /debate <question>'
	},
	Completion{
		text: '/market'
		meta: 'task market auction — /market <t1> | <t2>'
	},
	Completion{
		text: '/tower'
		meta: 'web control tower dashboard — /tower [port]'
	},
	Completion{
		text: '/verify'
		meta: 'formal LTL verification — /verify <goal>|log'
	},
	Completion{
		text: '/mcts'
		meta: 'tree-of-agents strategy search — /mcts <i1>; <i2>; …'
	},
	Completion{
		text: '/causal'
		meta: 'causal analysis — /causal | /causal do <feature>'
	},
	Completion{
		text: '/bandit'
		meta: 'thompson router — /bandit | /bandit <task>'
	},
	Completion{
		text: '/mesh'
		meta: 'agent-to-agent network — /mesh serve|discover|delegate'
	},
	Completion{
		text: '/roleforge'
		meta: 'create a NEW specialist role — /roleforge <mission>'
	},
	Completion{
		text: '/synth'
		meta: 'synthesize a new tool — /synth {json spec}'
	},
	Completion{
		text: '/ci'
		meta: 'CI pilot — /ci start|stop|status'
	},
	Completion{
		text: '/tune'
		meta: 'auto-tune knobs (TPE) — /tune [trials]'
	},
	Completion{
		text: '/dual'
		meta: 'system 1/2 routing — /dual <q>|stats'
	},
	Completion{
		text: '/predict'
		meta: 'predict change impact — /predict <path>'
	},
	Completion{
		text: '/race'
		meta: 'racing strategy universes — /race <task>'
	},
	Completion{
		text: '/vitals'
		meta: 'homeostasis check + self-repair'
	},
	Completion{
		text: '/attention'
		meta: 'last context token auction'
	},
	Completion{
		text: '/fabric'
		meta: 'bitemporal knowledge — /fabric ask|assert|history'
	},
	Completion{
		text: '/crew'
		meta: 'persistent subagents — /crew [spawn|send|wait|close|resume|status]'
	},
	Completion{
		text: '/auto'
		meta: 'autopilot self-routing — /auto [on|off|status]'
	},
	Completion{
		text: '/prompt'
		meta: 'system prompt — /prompt [main|master|list]'
	},
	Completion{
		text: '/covenant'
		meta: 'specification bound to the action boundary — /covenant [report|clauses|test]'
	},
	Completion{
		text: '/enforce'
		meta: 'the whole boundary: what is in force, stopped and owed — /enforce [status|audit|owed|integrity|witness|grants]'
	},
	Completion{
		text: '/mastermind'
		meta: 'prompt coherence ledger — sealed prompts, gate, lineage'
	},
	Completion{
		text: '/dashboard'
		meta: 'live observability — cost, goal, agents, router, spec'
	},
	Completion{
		text: '/router'
		meta: 'smart model routing — decisions + savings'
	},
	Completion{
		text: '/spec'
		meta: 'speculative execution — prefetch stats + hit-rate'
	},
	Completion{
		text: '/recall'
		meta: 'semantic memory — /recall <question>'
	},
	Completion{
		text: '/mission'
		meta: 'daemon missions — /mission [start|tick|list|abandon]'
	},
	Completion{
		text: '/heal'
		meta: 'self-healing ledger — root causes captured + healed'
	},
	Completion{
		text: '/skills'
		meta: 'skill forge — self-authored tools'
	},
	Completion{
		text: '/council'
		meta: 'adversarial debate — /council <proposition>'
	},
	Completion{
		text: '/analyze'
		meta: 'static analysis — /analyze <path> (taint, complexity, cycles)'
	},
	Completion{
		text: '/graph'
		meta: 'knowledge graph — /graph [index <path>|query <name>|impact <name>]'
	},
	Completion{
		text: '/coverage'
		meta: 'line-coverage ledger — last measured runs'
	},
	Completion{
		text: '/fuzz'
		meta: 'fuzzing ledger — runs, crashes, shrunk reproducers'
	},
	Completion{
		text: '/mutate'
		meta: 'mutation testing — /mutate <file> <suite-command>'
	},
	Completion{
		text: '/help'
		meta: 'commands and key bindings'
	},
	Completion{
		text: '/clear'
		meta: 'clear the screen'
	},
	Completion{
		text: '/new'
		meta: 'fresh conversation'
	},
	Completion{
		text: '/history'
		meta: 'browse previous turns'
	},
	Completion{
		text: '/save'
		meta: 'save session to disk'
	},
	Completion{
		text: '/approve'
		meta: 'toggle auto-approve for tools'
	},
	Completion{
		text: '/reasoning'
		meta: 'toggle showing model reasoning'
	},
	Completion{
		text: '/usage'
		meta: 'token usage for this session'
	},
	Completion{
		text: '/about'
		meta: 'about FullAgent'
	},
	Completion{
		text: '/exit'
		meta: 'quit FullAgent'
	},]

// complete_slash offers the completions for the text before the cursor.
//
// An empty result means "no menu": the caller must not open one, because a
// menu with nothing in it still steals the next Tab.
pub fn complete_slash(text_before_cursor string) []Completion {
	text := text_before_cursor
	if !text.starts_with('/') || text.contains('\n') {
		return []
	}
	word := text.to_lower()

	// the four commands whose arguments are worth offering
	if sub := sub_arg(word, '/effort') {
		mut out := []Completion{}
		for e in efforts {
			if e.key.starts_with(sub) {
				out << Completion{
					text: '/effort ${e.key}'
					meta: e.description
				}
			}
		}
		return out
	}
	if sub := sub_arg(word, '/goal') {
		mut out := []Completion{}
		for c in goal_subcommands {
			if c.text.starts_with(sub) {
				out << Completion{
					text: '/goal ${c.text}'
					meta: c.meta
				}
			}
		}
		return out
	}
	if sub := sub_arg(word, '/autonomy') {
		mut out := []Completion{}
		for level, desc in autonomy_levels {
			if level.str().starts_with(sub) {
				out << Completion{
					text: '/autonomy ${level}'
					meta: desc
				}
			}
		}
		return out
	}
	if sub := sub_arg(word, '/judge') {
		mut out := []Completion{}
		for c in judge_predicates {
			if c.text.starts_with(sub) {
				out << Completion{
					// the trailing space is deliberate: the predicate always
					// takes a JSON argument after it
					text: '/judge ${c.text} '
					meta: c.meta
				}
			}
		}
		return out
	}

	mut out := []Completion{}
	for c in slash_commands {
		if c.text.starts_with(word) {
			out << c
		}
	}
	return out
}

// sub_arg reports the argument typed after `cmd`, if the line is that
// command. `/goal` on its own completes its subcommands from '', and
// `/goalkeeper` is not `/goal` at all.
fn sub_arg(word string, cmd string) ?string {
	if word == cmd {
		return ''
	}
	if word.starts_with(cmd + ' ') {
		return word[cmd.len + 1..].trim_space()
	}
	return none
}

// ---------------------------------------------------------------------------
// The menu
// ---------------------------------------------------------------------------

pub const completion_window = 8

// CompletionMenu is the open menu: the offers, which one is highlighted, and
// the text the draft had before any of it was previewed.
@[heap]
pub struct CompletionMenu {
pub mut:
	items []Completion
	index int
	top   int
}

pub fn new_completion_menu(items []Completion) &CompletionMenu {
	return &CompletionMenu{
		items: items
	}
}

pub fn (mut m CompletionMenu) move(delta int) {
	if m.items.len == 0 {
		return
	}
	m.index = mod_floor(m.index + delta, m.items.len)
	if m.index < m.top {
		m.top = m.index
	} else if m.index >= m.top + completion_window {
		m.top = m.index - completion_window + 1
	}
}

pub fn (m &CompletionMenu) selected() string {
	if m.index < 0 || m.index >= m.items.len {
		return ''
	}
	return m.items[m.index].text
}

// rows renders the menu as the lines drawn above the prompt box.
pub fn (m &CompletionMenu) rows(width int) [][]Span {
	mut out := [][]Span{}
	if m.items.len == 0 {
		return out
	}
	// the widest command decides the column the descriptions line up in
	mut name_w := 0
	for c in m.items {
		w := display_width(c.text)
		if w > name_w {
			name_w = w
		}
	}
	name_w = min_int(name_w, max_int(8, width / 3))

	last := min_int(m.top + completion_window, m.items.len)
	for i := m.top; i < last; i++ {
		c := m.items[i]
		selected := i == m.index
		name := pad_width(truncate_width(c.text, name_w, '…'), name_w)
		mut row := [
			span(if selected { ' ▶ ' } else { '   ' }, Style{ fg: c_accent }),
			span(name, Style{
				fg:   if selected { c_cyan } else { c_fg }
				bold: selected
				bg:   if selected { c_selection_bg } else { '' }
			}),
		]
		room := width - display_width(spans_text(row)) - 2
		if room > 4 && c.meta != '' {
			row << span('  ' + truncate_width(c.meta, room, '…'), Style{ fg: c_dim })
		}
		out << row
	}
	if m.items.len > completion_window {
		out << [
			span('   … ${m.items.len} matches', Style{ fg: c_dim }),
		]
	}
	return out
}
