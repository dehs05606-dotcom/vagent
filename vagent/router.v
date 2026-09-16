module vagent

import x.json2

// router.v — the cost brain (smart model routing).
//
// Every subtask is routed to the CHEAPEST model that is still capable of
// doing it well. Routing is deterministic (rung 1): a multi-axis difficulty
// classifier scores the task, a capability/cost table scores the models, and
// the cheapest model whose capability clears the task's difficulty wins. A
// quality guardrail escalates to a stronger model when a cheap one would be
// out of its depth.
//
// Nothing here calls a model. Every decision is sealed as a
// 'router.decision' event, so the routing history is replayable and the
// savings are auditable: the fold can always answer "what did we spend, and
// what would always using the strongest model have cost?"

pub struct ModelSpec {
pub:
	// 0.0..1.0 — how strong the model is on hard tasks
	capability f64
	// relative $ per 1k tokens (free tiers are 0). These are relative units
	// used to compare routes, not billing truth.
	cost_in   f64
	cost_out  f64
	tools     bool
	reasoning bool
}

pub const model_table = {
	'mimo-v2.5-free':                            ModelSpec{
		capability: 0.55
	}
	'big-pickle':                                ModelSpec{
		capability: 0.60
		tools:      true
	}
	'grok-code-fast-1':                          ModelSpec{
		capability: 0.72
		cost_in:    0.0006
		cost_out:   0.0024
		tools:      true
	}
	'claude-sonnet-4-5':                         ModelSpec{
		capability: 0.88
		cost_in:    0.003
		cost_out:   0.015
		tools:      true
	}
	'claude-opus-4-6':                           ModelSpec{
		capability: 0.95
		cost_in:    0.015
		cost_out:   0.075
		tools:      true
		reasoning:  true
	}
	'gemini-3.1-pro':                            ModelSpec{
		capability: 0.90
		cost_in:    0.00125
		cost_out:   0.010
		tools:      true
		reasoning:  true
	}
	'gpt-5.2':                                   ModelSpec{
		capability: 0.92
		cost_in:    0.005
		cost_out:   0.020
		tools:      true
		reasoning:  true
	}
	'muse-spark-1.2-contributor-free':           ModelSpec{
		capability: 0.82
		tools:      true
		reasoning:  true
	}
	'opencode/muse-spark-1.2-contributor-free':  ModelSpec{
		capability: 0.82
		tools:      true
		reasoning:  true
	}
	'qwen/qwen3.8-max-free':                     ModelSpec{
		capability: 0.70
		tools:      true
		reasoning:  true
	}
	'deepseek-ai/DeepSeek-V3.2':                 ModelSpec{
		capability: 0.80
		cost_in:    0.00027
		cost_out:   0.0011
		tools:      true
		reasoning:  true
	}
	'deepseek/deepseek-v4-pro-0813-free':        ModelSpec{
		capability: 0.85
		tools:      true
		reasoning:  true
	}
	'moonshotai/Kimi-K2-Instruct':               ModelSpec{
		capability: 0.78
		cost_in:    0.0006
		cost_out:   0.0025
		tools:      true
	}
	'agnes-2.5-flash':                           ModelSpec{
		capability: 0.74
		tools:      true
		reasoning:  true
	}
	'deepseek-ai/deepseek-v4-pro-0813':          ModelSpec{
		capability: 0.85
		cost_in:    0.000435
		cost_out:   0.00087
		tools:      true
		reasoning:  true
	}
}

// strongest_model is the escalation ceiling — the highest capability in the
// table, with the id breaking ties so the choice is reproducible.
fn strongest_of(table map[string]ModelSpec) string {
	mut best := ''
	mut best_cap := -1.0
	mut ids := table.keys()
	ids.sort()
	for id in ids {
		cap_value := (table[id] or { ModelSpec{} }).capability
		if cap_value > best_cap {
			best = id
			best_cap = cap_value
		}
	}
	return best
}

pub const strongest_model = strongest_of(model_table)

// ---------------------------------------------------------------------------
// Difficulty classification (rung 1)
// ---------------------------------------------------------------------------

const reasoning_words = ['prove', 'derive', 'theorem', 'optimize', 'optimise',
	'algorithm', 'complexity', 'architect', 'design', 'refactor', 'debug',
	'diagnose', 'root cause', 'trade-off', 'tradeoff', 'reason', 'why',
	'analyse', 'analyze', 'security', 'vulnerab']

const tool_words = ['run', 'execute', 'build', 'test', 'install', 'git', 'grep',
	'search', 'file', 'read', 'write', 'edit', 'command', 'shell', 'compile']

const code_markers = ['```', 'def ', 'class ', 'import ', '=>', '::', '{{', '\${']

// Difficulty is the multi-axis difficulty score of one task (0.0 .. 1.0).
pub struct Difficulty {
pub:
	score           f64
	needs_tools     bool
	needs_reasoning bool
	axes            map[string]f64
}

pub fn (d &Difficulty) to_json() map[string]json2.Any {
	mut axes := map[string]json2.Any{}
	for k, v in d.axes {
		axes[k] = json2.Any(v)
	}
	return {
		'score':           json2.Any(round3(d.score))
		'needs_tools':     json2.Any(d.needs_tools)
		'needs_reasoning': json2.Any(d.needs_reasoning)
		'axes':            json2.Any(axes)
	}
}

fn round3(v f64) f64 {
	return f64(int(v * 1000.0 + 0.5)) / 1000.0
}

fn count_occurrences(low string, needles []string) int {
	mut n := 0
	for w in needles {
		if low.contains(w) {
			n++
		}
	}
	return n
}

// classify scores a task's difficulty across cheap heuristic axes.
pub fn classify(text string) Difficulty {
	low := text.to_lower()
	mut words := text.split_any(' \t\n').filter(it != '').len
	if words < 1 {
		words = 1
	}

	mut code_hits := 0
	for marker in code_markers {
		code_hits += text.count(marker)
	}
	code_density := min_f(1.0, f64(code_hits) / 6.0)
	reasoning_hits := count_occurrences(low, reasoning_words)
	tool_hits := count_occurrences(low, tool_words)
	reasoning := min_f(1.0, f64(reasoning_hits) / 3.0)
	tooling := min_f(1.0, f64(tool_hits) / 4.0)
	length := min_f(1.0, f64(words) / 120.0)

	// weighted blend — reasoning and code weigh most
	mut score := 0.34 * reasoning + 0.26 * code_density + 0.20 * tooling +
		0.12 * length + 0.08 * min_f(1.0, f64(reasoning_hits) / 5.0)
	score = max_f(0.05, min_f(1.0, score))
	return Difficulty{
		score:           score
		needs_tools:     tool_hits >= 2
		needs_reasoning: reasoning_hits >= 2
		axes:            {
			'reasoning': round3(reasoning)
			'code':      round3(code_density)
			'tooling':   round3(tooling)
			'length':    round3(length)
		}
	}
}

fn min_f(a f64, b f64) f64 {
	return if a < b { a } else { b }
}

fn max_f(a f64, b f64) f64 {
	return if a > b { a } else { b }
}

// ---------------------------------------------------------------------------
// Router
// ---------------------------------------------------------------------------

pub struct RouteChoice {
pub:
	model_id   string
	difficulty f64
	reason     string
	escalated  bool
	est_cost   f64
}

pub fn (c &RouteChoice) to_json() map[string]json2.Any {
	return {
		'model':      json2.Any(c.model_id)
		'difficulty': json2.Any(round3(c.difficulty))
		'reason':     json2.Any(c.reason)
		'escalated':  json2.Any(c.escalated)
		'est_cost':   json2.Any(f64(int(c.est_cost * 1e6 + 0.5)) / 1e6)
	}
}

// Router routes tasks to the cheapest capable model. All decisions are
// sealed into the event log; state is recovered by folding.
@[heap]
pub struct Router {
pub mut:
	log   &EventLog
	table map[string]ModelSpec
}

pub fn new_router(log &EventLog, table map[string]ModelSpec) &Router {
	return &Router{
		log:   unsafe { log }
		table: if table.len > 0 { table.clone() } else { model_table.clone() }
	}
}

fn (r &Router) capable(model_id string, diff Difficulty) bool {
	m := r.table[model_id] or { return false }
	if diff.needs_tools && !m.tools {
		return false
	}
	if diff.needs_reasoning && !m.reasoning {
		return false
	}
	return true
}

fn (r &Router) cost(model_id string, est_tokens int) f64 {
	m := r.table[model_id] or { return 0.0 }
	// rough split: 2/3 prompt, 1/3 completion
	tin := est_tokens * 2 / 3
	tout := est_tokens - tin
	return f64(tin) / 1000.0 * m.cost_in + f64(tout) / 1000.0 * m.cost_out
}

// choose picks the cheapest model whose capability clears the task.
//
// `prefer` pins a model when the caller (or the user) insists; it is still
// capability-checked, and if it cannot do the job the router escalates past
// it and says so.
pub fn (mut r Router) choose(task string, est_tokens int, prefer string) RouteChoice {
	diff := classify(task)
	// Quality guardrail: require a capability MARGIN above the task's
	// difficulty, so a hard task never sits right at a cheap model's
	// ceiling. This is what forces genuine escalation.
	required := max_f(0.30, min_f(0.97, diff.score + 0.25))

	if prefer != '' {
		if pinned_spec := r.table[prefer] {
			if r.capable(prefer, diff) && pinned_spec.capability >= required {
				choice := RouteChoice{
					model_id:   prefer
					difficulty: diff.score
					reason:     "pinned '${prefer}' is capable"
					est_cost:   r.cost(prefer, est_tokens)
				}
				r.seal(task, diff, choice)
				return choice
			}
			// the pinned model cannot do it — escalate past it
		}
	}

	mut ids := r.table.keys()
	ids.sort()
	mut candidates := []string{}
	for m in ids {
		if r.capable(m, diff) && (r.table[m] or { ModelSpec{} }).capability >= required {
			candidates << m
		}
	}
	mut escalated := false
	if candidates.len == 0 {
		// nothing cheap clears the bar -> the strongest capable model
		candidates = ids.filter(r.capable(it, diff))
		escalated = true
	}
	if candidates.len == 0 {
		// even the fallback capability check cleared nothing (a custom table
		// without a tool-capable model, or an empty table) — degrade to the
		// table's best instead of failing
		if r.table.len == 0 {
			choice := RouteChoice{
				model_id:   strongest_model
				difficulty: diff.score
				reason:     "no models in routing table — defaulting to '${strongest_model}'"
				escalated:  true
			}
			r.seal(task, diff, choice)
			return choice
		}
		candidates = ids.clone()
		escalated = true
	}

	mut best := candidates[0]
	if escalated {
		for m in candidates {
			bs := r.table[best] or { ModelSpec{} }
			ms := r.table[m] or { ModelSpec{} }
			if ms.capability > bs.capability
				|| (ms.capability == bs.capability
				&& r.cost(m, est_tokens) < r.cost(best, est_tokens)) {
				best = m
			}
		}
	} else {
		// cheapest first; break ties toward higher capability
		for m in candidates {
			bc := r.cost(best, est_tokens)
			mc := r.cost(m, est_tokens)
			if mc < bc || (mc == bc && (r.table[m] or { ModelSpec{} }).capability >
				(r.table[best] or { ModelSpec{} }).capability) {
				best = m
			}
		}
	}
	chosen := r.table[best] or { ModelSpec{} }
	choice := RouteChoice{
		model_id:   best
		difficulty: diff.score
		reason:     "difficulty ${diff.score:.2f} -> cheapest capable '${best}' " +
			'(cap ${chosen.capability:.2f})'
		escalated:  escalated || best == strongest_model
		est_cost:   r.cost(best, est_tokens)
	}
	r.seal(task, diff, choice)
	return choice
}

fn (mut r Router) seal(task string, diff Difficulty, choice RouteChoice) {
	mut payload := choice.to_json()
	payload['task'] = clip_plain(task, 200)
	mut axes := map[string]json2.Any{}
	for k, v in diff.axes {
		axes[k] = json2.Any(v)
	}
	payload['axes'] = axes
	r.log.append('router.decision', payload, AppendOpts{ actor: 'router' })
}

// savings compares what was actually routed against always using the
// strongest model, from the sealed decisions alone.
pub fn (mut r Router) savings() (f64, f64) {
	decisions := fold(mut r.log, '').router_decisions
	mut spent := 0.0
	mut ceiling := 0.0
	for d in decisions {
		spent += jf64(d, 'est_cost')
		ceiling += r.cost(strongest_model, 1500)
	}
	return spent, ceiling
}

pub fn (mut r Router) format_report() string {
	decisions := fold(mut r.log, '').router_decisions
	if decisions.len == 0 {
		return 'router: no decisions yet'
	}
	spent, ceiling := r.savings()
	mut lines := ['ROUTER — ${decisions.len} decision(s)',
		'  est spend \$${spent:.6f}   always-strongest \$${ceiling:.6f}']
	start := if decisions.len > 8 { decisions.len - 8 } else { 0 }
	for d in decisions[start..] {
		mark := if jbool(d, 'escalated') { '↑' } else { ' ' }
		lines << '  ${mark} ${pad_right(jstr(d, "model"), 34)} ' +
			'diff ${jf64(d, "difficulty"):.2f}  ${clip_plain(jstr(d, "task"), 40)}'
	}
	return lines.join('\n')
}
