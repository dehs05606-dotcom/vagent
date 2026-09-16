module vagent

import time
import x.json2

// report.v — enterprise export and forecasting.
//
// Two capabilities, both pure folds over the event log, both deterministic
// and neither making a model call:
//
//   * EXPORT — a full audit report of the session: timeline, tool calls,
//     verdicts, goal outcome, costs, subagent activity. Markdown or
//     self-contained HTML, for handoff, review or compliance.
//   * FORECAST — a projection from measured reality: tokens per turn, cost
//     per turn, and goal velocity into turns remaining. Numbers, not vibes;
//     and when there is no measurable velocity it says so rather than
//     extrapolating from one data point.

// the events worth a row in the timeline — the ones a human reviewing the
// session would actually stop on
pub const interesting_events = ['user.message', 'assistant.message', 'tool.call', 'tool.result',
	'judge.verdict', 'clause.proven', 'clause.regressed', 'goal.closed', 'focus.stop', 'workflow.done',
	'crew.done', 'snapshot.taken', 'autonomy.changed']

struct ModelUsage {
mut:
	tokens_in  int
	tokens_out int
	usd        f64
	calls      int
}

struct TimelineRow {
	seq  int
	ts   f64
	typ  string
	data map[string]json2.Any
}

struct Gathered {
mut:
	st            State
	event_count   int
	tools         map[string]int
	tool_errors   int
	verdicts_pass int
	verdicts_fail int
	timeline      []TimelineRow
	models        map[string]ModelUsage
}

// gather is the one pass over the log every export shares.
fn gather(mut log EventLog) Gathered {
	st := fold(mut log, log.branch)
	events := log.events(log.branch)
	mut g := Gathered{
		st:          st
		event_count: events.len
	}
	for ev in events {
		d := ev.data.clone()
		match ev.typ {
			'tool.call' {
				mut name := jstr(d, 'name')
				if name == '' {
					name = '?'
				}
				g.tools[name] = g.tools[name] + 1
			}
			'tool.result' {
				if jstr(d, 'status') == 'error' {
					g.tool_errors++
				}
			}
			'judge.verdict' {
				if jbool(d, 'passed') {
					g.verdicts_pass++
				} else {
					g.verdicts_fail++
				}
			}
			'cost.incurred' {
				mut model := jstr(d, 'model')
				if model == '' {
					model = '?'
				}
				mut m := g.models[model] or { ModelUsage{} }
				m.tokens_in += jint(d, 'tokens_in')
				m.tokens_out += jint(d, 'tokens_out')
				m.usd += jf64(d, 'usd')
				m.calls++
				g.models[model] = m
			}
			else {}
		}
		if ev.typ in interesting_events {
			g.timeline << TimelineRow{
				seq:  ev.seq
				ts:   ev.ts
				typ:  ev.typ
				data: d.clone()
			}
		}
	}
	return g
}

// -- markdown export ------------------------------------------------------------

pub fn export_markdown(mut log EventLog, title string) string {
	mut g := gather(mut log)
	st := g.st
	now := time.now().format_ss()
	mut lines := [
		'# ${title}',
		'_generated ${now} — every number below is a fold of the event log; ' + 'nothing is estimated or narrated._',
		'',
		'## Summary',
		'- **events**: ${g.event_count}   **branch**: ${st.branch}   ' + '**head seq**: ${st.head_seq}',
		'- **tool calls**: ${st.tool_calls} (errors: ${g.tool_errors})   ' + '**commands run**: ${st.commands_run}',
		'- **judge verdicts**: ${g.verdicts_pass} passed / ${g.verdicts_fail} failed',
		'- **cost**: ${st.cost_summary()}',
		'- **episodes**: ${st.episodes.len}   **dead-ends**: ${st.dead_ends.len}   ' + '**facts**: ${st.facts.len}',
	]
	if st.files_touched.len > 0 {
		lines << '- **files touched**: ${st.files_touched.len}'
	}

	if g.models.len > 0 {
		lines << ''
		lines << '## Model usage'
		lines << '| model | calls | tokens in | tokens out |'
		lines << '|---|---|---|---|'
		mut names := g.models.keys()
		names.sort()
		for name in names {
			m := g.models[name] or { ModelUsage{} }
			lines << '| ${name} | ${m.calls} | ${thousands(m.tokens_in)} | ' + '${thousands(m.tokens_out)} |'
		}
	}

	if g.tools.len > 0 {
		lines << ''
		lines << '## Tool calls'
		lines << '| tool | count |'
		lines << '|---|---|'
		// most used first, with an alphabetical tiebreak so two exports of
		// one log are identical
		mut names := g.tools.keys()
		names.sort()
		names.sort_with_compare(fn [g] (a &string, b &string) int {
			na := g.tools[*a] or { 0 }
			nb := g.tools[*b] or { 0 }
			if na != nb {
				return nb - na
			}
			return if *a < *b {
				-1
			} else if *a > *b { 1 } else { 0 }
		})
		for name in names {
			lines << '| ${name} | ${g.tools[name]} |'
		}
	}

	if goal := st.goal {
		mut closed := jstr(goal, 'closed_state')
		if closed == '' {
			closed = 'still active'
		}
		lines << ''
		lines << '## Goal'
		lines << '- statement: ' + jstr(goal, 'statement')
		lines << '- clauses: ${jarr(goal, 'clauses').len}'
		lines << '- closed: ${closed}'
	}

	lines << ''
	lines << '## Timeline (key events)'
	lines << '| seq | time | event | detail |'
	lines << '|---|---|---|---|'
	mut rows := g.timeline.clone()
	if rows.len > 200 {
		rows = rows[rows.len - 200..].clone()
	}
	for row in rows {
		stamp := time.unix(i64(row.ts)).format_ss().all_after_last(' ')
		lines << '| ${row.seq} | ${stamp} | ${row.typ} | ' + timeline_detail(row) + ' |'
	}

	lines << ''
	lines << '---'
	lines << '_The complete history — every event, including the parts trimmed ' + 'above — remains in the append-only event log and can be replayed._'
	return lines.join('\n') + '\n'
}

// timeline_detail is the one-cell summary of an event. Pipes are escaped
// rather than stripped, so a message that contains one still renders as a
// single cell and still says what it said.
fn timeline_detail(row &TimelineRow) string {
	d := row.data.clone()
	mut detail := ''
	match row.typ {
		'user.message', 'assistant.message' {
			detail = clip_plain(jstr(d, 'text'), 80)
		}
		'tool.call' {
			detail = jstr(d, 'name')
		}
		'tool.result' {
			detail = jstr(d, 'name') + ' -> ' + jstr(d, 'status')
		}
		'judge.verdict' {
			verdict := if jbool(d, 'passed') { 'PASS' } else { 'FAIL' }
			detail = '${verdict} ' + jstr(d, 'kind') + ': ' + clip_plain(jstr(d, 'detail'), 60)
		}
		else {
			detail = clip_plain(canonical(json2.Any(d.clone())), 80)
		}
	}
	return detail.replace('|', '\\|').replace('\n', ' ')
}

// -- HTML export ------------------------------------------------------------------

const report_html_style = ' body{font-family:ui-monospace,SFMono-Regular,Menlo,monospace;
      background:#1e1f29;color:#f8f8f2;margin:2rem auto;max-width:960px;
      padding:0 1rem;line-height:1.5}
 h1{color:#bd93f9} h2{color:#8be9fd;border-bottom:1px solid #44475a;
      padding-bottom:.3rem}
 table{border-collapse:collapse;width:100%;margin:.8rem 0;font-size:.85rem}
 th,td{border:1px solid #44475a;padding:.35rem .6rem;text-align:left}
 th{background:#282a36;color:#50fa7b}
 tr:nth-child(even){background:#232530}
 code{background:#282a36;padding:.1rem .3rem;border-radius:3px}
 .pass{color:#50fa7b} .fail{color:#ff5555}
 em{color:#6272a4}'

pub fn html_escape(s string) string {
	return s.replace('&', '&amp;').replace('<', '&lt;').replace('>', '&gt;').replace("'", '&#x27;').replace('"', '&quot;')
}

// export_html renders the markdown report as self-contained HTML. Nothing is
// fetched at view time: a compliance artefact that needs a CDN to render is
// not an artefact.
pub fn export_html(mut log EventLog, title string) string {
	md := export_markdown(mut log, title)
	mut body := []string{}
	mut in_table := false
	for raw in split_lines(md) {
		line := raw.trim_right(' \t\r')
		if line.starts_with('# ') {
			body << '<h1>' + html_escape(line[2..]) + '</h1>'
			continue
		}
		if line.starts_with('## ') {
			body << '<h2>' + html_escape(line[3..]) + '</h2>'
			continue
		}
		if line.starts_with('|') {
			cells := split_export_row(line)
			if is_export_separator_row(cells) {
				continue
			}
			tag := if !in_table { 'th' } else { 'td' }
			if !in_table {
				body << '<table>'
				in_table = true
			}
			mut rendered := ''
			for c in cells {
				mut cls := ''
				if c.starts_with('PASS') {
					cls = ' class="pass"'
				} else if c.starts_with('FAIL') {
					cls = ' class="fail"'
				}
				rendered += '<${tag}${cls}>' + html_escape(c) + '</${tag}>'
			}
			body << '<tr>' + rendered + '</tr>'
			continue
		}
		if in_table {
			body << '</table>'
			in_table = false
		}
		if line.starts_with('- ') {
			body << '<p>•&nbsp;' + html_escape(line[2..]).replace('**', '') + '</p>'
		} else if line.starts_with('_') && line.ends_with('_') && line.len > 1 {
			body << '<p><em>' + html_escape(line.trim('_')) + '</em></p>'
		} else if line.trim_space() != '' {
			body << '<p>' + html_escape(line).replace('**', '') + '</p>'
		}
	}
	if in_table {
		body << '</table>'
	}
	return '<!DOCTYPE html>\n<html><head><meta charset="utf-8"><title>' + html_escape(title) + '</title>\n<style>\n' + report_html_style + '\n</style></head><body>\n' + body.join('\n') + '\n</body></html>\n'
}

// split_export_row splits on unescaped pipes only: a `\|` inside a cell is
// data the exporter escaped, not a column boundary.
fn split_export_row(line string) []string {
	mut cells := []string{}
	mut cur := []u8{}
	mut i := 0
	for i < line.len {
		c := line[i]
		if c == `\\` && i + 1 < line.len && line[i + 1] == `|` {
			cur << `|`
			i += 2
			continue
		}
		if c == `|` {
			cells << cur.bytestr()
			cur = []u8{}
			i++
			continue
		}
		cur << c
		i++
	}
	cells << cur.bytestr()
	// the leading and trailing empties come from the row's outer pipes
	if cells.len >= 2 {
		cells = cells[1..cells.len - 1].clone()
	}
	return cells.map(it.trim_space())
}

fn is_export_separator_row(cells []string) bool {
	if cells.len == 0 {
		return false
	}
	for c in cells {
		for ch in c {
			if ch != `-` && ch != `:` && ch != ` ` {
				return false
			}
		}
	}
	return true
}

// -- forecast -----------------------------------------------------------------------

pub struct Forecast {
pub mut:
	turns      int
	tokens_in  int
	tokens_out int
	cost_usd   f64
	// per-turn rates, absent until there has been a turn to divide by
	tokens_in_per_turn  ?int
	tokens_out_per_turn ?int
	cost_per_turn_usd   ?f64
	// goal projection, absent when there is no goal or no measurement
	goal_distance     ?f64
	velocity_per_tick ?f64
	// none means stalled: the distance is not moving, so no honest number
	// of remaining ticks exists
	est_ticks_remaining ?int
}

pub fn (f &Forecast) to_json() map[string]json2.Any {
	mut d := {
		'turns':      json2.Any(f.turns)
		'tokens_in':  json2.Any(f.tokens_in)
		'tokens_out': json2.Any(f.tokens_out)
		'cost_usd':   json2.Any(f.cost_usd)
	}
	if v := f.tokens_in_per_turn {
		d['tokens_in_per_turn'] = json2.Any(v)
	}
	if v := f.tokens_out_per_turn {
		d['tokens_out_per_turn'] = json2.Any(v)
	}
	if v := f.cost_per_turn_usd {
		d['cost_per_turn_usd'] = json2.Any(round_to(v, 6))
	}
	if v := f.goal_distance {
		d['goal_distance'] = json2.Any(v)
	}
	if v := f.velocity_per_tick {
		d['velocity_per_tick'] = json2.Any(round_to(v, 4))
	}
	if v := f.est_ticks_remaining {
		d['est_ticks_remaining'] = json2.Any(v)
	}
	return d
}

// forecast is a deterministic projection from what was measured: tokens and
// cost per turn, and — when a goal is active and its distance has actually
// been measured more than once — the turns remaining at the real velocity.
pub fn forecast(mut log EventLog) Forecast {
	st := fold(mut log, log.branch)
	events := log.events(log.branch)
	user_turns := events.filter(it.typ == 'user.message').len
	mut f := Forecast{
		turns:      user_turns
		tokens_in:  st.tokens_in
		tokens_out: st.tokens_out
		cost_usd:   st.cost_usd
	}
	if user_turns > 0 {
		f.tokens_in_per_turn = banker_round(f64(st.tokens_in) / f64(user_turns))
		f.tokens_out_per_turn = banker_round(f64(st.tokens_out) / f64(user_turns))
		f.cost_per_turn_usd = round_to(st.cost_usd / f64(user_turns), 6)
	}

	goal := st.goal or { return f }
	if jarr(goal, 'clauses').len == 0 {
		return f
	}
	measures := st.distance_measures
	if measures.len >= 2 {
		first := jf64_or(measures[0], 'distance', 1.0)
		last := jf64_or(measures[measures.len - 1], 'distance', first)
		span := if measures.len - 1 > 1 { measures.len - 1 } else { 1 }
		delta := (first - last) / f64(span)
		f.goal_distance = last
		f.velocity_per_tick = delta
		if delta > 1e-6 {
			f.est_ticks_remaining = int(last / delta + 0.999)
		}
		// otherwise it stays none: the distance is not moving, and no
		// honest number of remaining ticks exists
		return f
	}
	if 'distance' in goal {
		f.goal_distance = jf64_or(goal, 'distance', 1.0)
	}
	return f
}

pub fn format_forecast(f &Forecast) string {
	mut lines := [
		'FORECAST — measured, not guessed',
		'  turns so far      : ${f.turns}',
		'  tokens            : ${thousands(f.tokens_in)} in / ${thousands(f.tokens_out)} out',
	]
	if tin := f.tokens_in_per_turn {
		tout := f.tokens_out_per_turn or { 0 }
		cost := f.cost_per_turn_usd or { 0.0 }
		suffix := if cost != 0.0 { ' · \$${cost:.4f}' } else { '' }
		lines << '  per turn          : ~${thousands(tin)} in / ~${thousands(tout)} out' + suffix
	}
	if distance := f.goal_distance {
		done := (1.0 - distance) * 100.0
		lines << '  goal progress     : ${done:.0f}% (distance ${distance:.2f})'
		if est := f.est_ticks_remaining {
			lines << '  projection        : ~${est} goal-tick(s) to done at current velocity'
		} else if _ := f.velocity_per_tick {
			lines << '  projection        : ⚠ no measurable velocity — stalled or ' + 'not enough data'
		}
	}
	return lines.join('\n')
}
