module vagent

import time
import x.json2

// compiler.v — the intent compiler: goal → IR → optimized execution plan.
//
// A database plans queries; this plans agent work. A natural-language goal
// is drafted ONCE into a typed intermediate representation (a flat list of
// work items), and every step after that is a deterministic, mechanical
// optimizer pass — exactly like a query planner:
//
//     parse      goal → IR items (model-drafted once; validated structurally)
//     dedupe     identical/near-identical items collapse (hash on
//                role + normalized task)
//     prune      unreachable items die (dependencies that name no item)
//     layers     topological layering — items in a layer have no mutual
//                dependencies and run in one ordered wave
//     cost       role-based cost estimates
//     lockpass   write-exclusivity: two items writing overlapping path-sets
//                can never share a wave
//
// The optimizer never trusts the draft: malformed items are dropped, not
// executed. The compiled plan is sealed (compile.plan) before anything runs,
// waves stream as compile.wave, and the run lands as compile.done — the whole
// compilation replays like everything else on the kernel.
//
// The drafter is injectable so the tests run fully offline; production uses
// the model through chat_blocking.

// deterministic per-role cost estimates (abstract units: the tool budget the
// role typically burns per item — writers cost more than readers)
const role_cost = {
	'planner':    4
	'architect':  6
	'researcher': 4
	'reviewer':   3
	'analyst':    4
	'coder':      8
	'tester':     5
	'debugger':   6
	'optimizer':  5
	'refactorer': 7
	'documenter': 4
	'devops':     6
	'integrator': 7
}
const default_role_cost = 5
const max_plan_items = 24
const max_plan_waves = 8

// roles whose items actually write, and so contend for paths
const writer_roles = ['coder', 'architect', 'refactorer', 'documenter', 'devops', 'integrator']

// norm_task normalises a task string for duplicate detection: everything that
// is not a lowercase letter or a digit becomes a single space.
fn norm_task(task string) string {
	mut out := []u8{}
	mut in_gap := false
	for c in task.to_lower() {
		if (c >= `a` && c <= `z`) || (c >= `0` && c <= `9`) {
			out << c
			in_gap = false
			continue
		}
		if !in_gap {
			out << ` `
			in_gap = true
		}
	}
	return out.bytestr().trim_space()
}

// PlanItem is one work item of the IR.
//
// The original carried these as untyped dicts and stashed the two parser-only
// fields under `_`-prefixed keys so they could be stripped before the item was
// sealed. Here they are ordinary fields that to_json() simply does not emit,
// which is the same thing without the naming convention doing the work.
pub struct PlanItem {
pub mut:
	id         string
	task       string
	role       string
	paths      []string
	depends_on []string
	// the position this item held in the raw draft — dependencies are
	// written against draft positions, and parse drops entries, so the two
	// numberings do not coincide
	draft_idx int
	// filled in by items(); meaningless before the plan is laid out
	wave int
}

pub fn (it &PlanItem) to_json() map[string]json2.Any {
	return {
		'task':       json2.Any(it.task)
		'role':       json2.Any(it.role)
		'paths':      json2.Any(strs_to_any(it.paths))
		'id':         json2.Any(it.id)
		'depends_on': json2.Any(strs_to_any(it.depends_on))
	}
}

fn (it &PlanItem) to_json_with_wave() map[string]json2.Any {
	mut d := it.to_json()
	d['wave'] = json2.Any(it.wave)
	return d
}

// item_key is the stable identity of an item — role plus normalised task.
fn item_key(it &PlanItem) string {
	payload := canonical(json2.Any({
		'role': json2.Any(it.role)
		'task': json2.Any(norm_task(it.task))
	}))
	return hash(payload)[..16]
}

// CompiledPlan is the optimized plan: ordered waves of work items.
pub struct CompiledPlan {
pub mut:
	goal       string
	waves      [][]PlanItem
	dropped    []map[string]json2.Any
	est_cost   int
	compile_ms int
}

pub fn (p &CompiledPlan) items() []PlanItem {
	mut out := []PlanItem{}
	for i, wave in p.waves {
		for item in wave {
			mut it := item
			it.wave = i
			out << it
		}
	}
	return out
}

pub fn (p &CompiledPlan) to_json() map[string]json2.Any {
	mut waves := []json2.Any{}
	for wave in p.waves {
		waves << json2.Any(wave.map(json2.Any(it.to_json())))
	}
	return {
		'goal':       json2.Any(p.goal)
		'waves':      json2.Any(waves)
		'dropped':    json2.Any(p.dropped.len)
		'est_cost':   json2.Any(p.est_cost)
		'compile_ms': json2.Any(p.compile_ms)
		'n_items':    json2.Any(p.items().len)
		'n_waves':    json2.Any(p.waves.len)
	}
}

// -- the drafter --------------------------------------------------------------

// PlanDrafter turns a goal into raw, untrusted IR entries. Anything may come
// back: the compiler validates rather than assumes.
pub type PlanDrafter = fn (goal string) []json2.Any

pub fn draft_prompt(goal string) []Message {
	mut names := []string{}
	for name, _ in roles {
		names << name
	}
	names.sort()
	return [
		Message{
			role:    'system'
			content: 'You are the front-end of an agent work compiler. Decompose ' + 'the goal into 4-12 work items. Reply with ONLY a JSON array; ' + 'each element: {"task": string, "role": one of ' + names.join(', ') + ', "paths": [files this item may write or read], "depends_on": ' + '[indexes of items that must finish first, 0-based]}. ' + 'No prose, no markdown fence.'
		},
		Message{
			role:    'user'
			content: 'GOAL: ${goal}'
		},
	]
}

// strip_fence removes a leading ```lang line and a trailing ``` line.
fn strip_fence(text string) string {
	mut t := text.trim_space()
	if !t.starts_with('```') {
		return t
	}
	if nl := t.index('\n') {
		t = t[nl + 1..]
	} else {
		return ''
	}
	t = t.trim_space()
	if t.ends_with('```') {
		t = t[..t.len - 3]
	}
	return t.trim_space()
}

// parse_draft_array is the shared "the model replied with a JSON array" path:
// anything that is not an array is no plan at all.
pub fn parse_draft_array(text string) []json2.Any {
	body := strip_fence(text)
	if body == '' {
		return []
	}
	parsed := json2.decode[json2.Any](body) or { return [] }
	if parsed is []json2.Any {
		return parsed
	}
	return []
}

// -- the compiler -------------------------------------------------------------

@[heap]
pub struct IntentCompiler {
pub mut:
	log     &EventLog
	drafter PlanDrafter @[required]
	// runs ONE wave of items, in order; none means the plan compiles but
	// cannot run
	executor WaveExecutor = unsafe { nil }
}

// WaveExecutor runs one wave and returns one report per item.
pub type WaveExecutor = fn (wave []PlanItem) []map[string]json2.Any

pub fn new_intent_compiler(log &EventLog, drafter PlanDrafter) &IntentCompiler {
	return &IntentCompiler{
		log:     unsafe { log }
		drafter: drafter
	}
}

// parse validates the draft ONCE: well-formed items are kept with their raw
// draft positions preserved, and the rest are dropped with a reason.
fn (mut c IntentCompiler) parse(goal string) ([]PlanItem, [][]int, []map[string]json2.Any) {
	raw := c.drafter(goal)
	mut items := []PlanItem{}
	mut raw_deps := [][]int{}
	mut dropped := []map[string]json2.Any{}
	mut limit := raw.len
	if limit > max_plan_items {
		limit = max_plan_items
	}
	for draft_idx in 0 .. limit {
		entry := raw[draft_idx]
		if entry !is map[string]json2.Any {
			dropped << {
				'reason': json2.Any('not an object')
				'item':   json2.Any(clip_plain(entry.str(), 80))
			}
			continue
		}
		obj := entry.as_map()
		task := jstr(obj, 'task').trim_space()
		if task == '' {
			dropped << {
				'reason': json2.Any('empty task')
				'item':   json2.Any(obj.clone())
			}
			continue
		}
		mut role := jstr(obj, 'role').trim_space().to_lower()
		if !role_registry.has(role) {
			// the generic default, and the cheapest fix
			role = 'coder'
		}
		// a scalar or garbage `paths` is emptied rather than crashing
		mut paths := []string{}
		for p in jarr(obj, 'paths') {
			text := if p is string { p } else { p.str() }
			if text.trim_space() != '' {
				paths << text
			}
		}
		// dependencies are draft positions; anything that is not an integer
		// names nothing and is dropped in remap_deps
		mut deps := []int{}
		for d in jarr(obj, 'depends_on') {
			deps << int_of_any(d) or { continue }
		}
		items << PlanItem{
			task:      task
			role:      role
			paths:     paths
			draft_idx: draft_idx
		}
		raw_deps << deps
	}
	return items, raw_deps, dropped
}

// int_of_any accepts the two shapes a draft index arrives in — a JSON number
// and a numeric string — and refuses everything else.
fn int_of_any(v json2.Any) ?int {
	match v {
		int, i32, i16, i8, i64, u64, f32, f64 { return int(v) }
		string { return if is_int_text(v) { v.int() } else { none } }
		else { return none }
	}
}

fn is_int_text(s string) bool {
	if s == '' {
		return false
	}
	for i, c in s {
		if i == 0 && (c == `-` || c == `+`) {
			if s.len == 1 {
				return false
			}
			continue
		}
		if c < `0` || c > `9` {
			return false
		}
	}
	return true
}

// remap_deps resolves draft-index dependencies to item ids, then cuts any
// cycle it finds — a transitively self-dependent item can never be scheduled.
fn (mut c IntentCompiler) remap_deps(mut items []PlanItem, raw_deps [][]int) {
	for i in 0 .. items.len {
		items[i].id = 'i${i}'
	}
	mut by_draft_idx := map[int]string{}
	for it in items {
		by_draft_idx[it.draft_idx] = it.id
	}
	for i in 0 .. items.len {
		mut deps := []string{}
		for d in raw_deps[i] {
			target := by_draft_idx[d] or { continue }
			if target != items[i].id {
				deps << target
			}
		}
		items[i].depends_on = deps
	}
	for {
		mut changed := false
		outer: for i in 0 .. items.len {
			for dep in items[i].depends_on.clone() {
				mut seen := map[string]bool{}
				if dep_reaches(items, dep, items[i].id, mut seen) {
					items[i].depends_on = items[i].depends_on.filter(it != dep)
					changed = true
					break outer
				}
			}
		}
		if !changed {
			break
		}
	}
}

fn dep_reaches(items []PlanItem, src string, dst string, mut seen map[string]bool) bool {
	if src == dst {
		return true
	}
	if seen[src] {
		return false
	}
	seen[src] = true
	for it in items {
		if it.id != src {
			continue
		}
		for next in it.depends_on {
			if dep_reaches(items, next, dst, mut seen) {
				return true
			}
		}
		return false
	}
	return false
}

// dedupe collapses identical items. The dependencies of a dropped duplicate
// merge into its kept twin, so the work still happens exactly once.
fn (mut c IntentCompiler) dedupe(items []PlanItem, mut dropped []map[string]json2.Any) []PlanItem {
	mut seen := map[string]int{} // key → index into out
	mut out := []PlanItem{}
	mut remap := map[string]string{}
	for it in items {
		key := item_key(&it)
		if kept_idx := seen[key] {
			for dep in it.depends_on {
				if dep != out[kept_idx].id && dep !in out[kept_idx].depends_on {
					out[kept_idx].depends_on << dep
				}
			}
			dropped << {
				'reason': json2.Any('duplicate')
				'item':   json2.Any(it.task)
			}
			remap[it.id] = out[kept_idx].id
			continue
		}
		seen[key] = out.len
		out << it
	}
	// a dependency pointing at a dropped duplicate resolves to its kept twin
	for i in 0 .. out.len {
		out[i].depends_on = out[i].depends_on.map(remap[it] or { it })
	}
	return out
}

// prune_unreachable drops dependencies that name no surviving item: they can
// never be satisfied, so keeping them would stall the layering forever.
fn (mut c IntentCompiler) prune_unreachable(items []PlanItem) []PlanItem {
	mut ids := map[string]bool{}
	for it in items {
		ids[it.id] = true
	}
	mut out := items.clone()
	for i in 0 .. out.len {
		out[i].depends_on = out[i].depends_on.filter(ids[it])
	}
	return out
}

// layers is the topological layering: layer k holds the items whose
// dependencies all sit in layers below k. Cycles were cut in remap_deps, so
// this terminates.
fn (mut c IntentCompiler) layers(items []PlanItem) [][]PlanItem {
	mut placed := map[string]bool{}
	mut waves := [][]PlanItem{}
	mut remaining := items.clone()
	for remaining.len > 0 && waves.len < max_plan_waves {
		mut wave := []PlanItem{}
		for it in remaining {
			mut ready := true
			for d in it.depends_on {
				if !placed[d] {
					ready = false
					break
				}
			}
			if ready {
				wave << it
			}
		}
		if wave.len == 0 {
			// defensive: nothing is ready, so cut one dependency edge
			remaining[0].depends_on = []
			continue
		}
		for it in wave {
			placed[it.id] = true
		}
		waves << wave
		remaining = remaining.filter(!placed[it.id])
	}
	if remaining.len > 0 {
		// the wave cap was hit with work left — a final wave takes the rest
		waves << remaining
	}
	return waves
}

// lockpass is write-exclusivity: within a wave, two items with overlapping
// write-path sets cannot coexist, so the later one is pushed forward.
fn (mut c IntentCompiler) lockpass(waves [][]PlanItem) [][]PlanItem {
	mut out := [][]PlanItem{len: waves.len}
	mut locked := []map[string]bool{len: waves.len, init: map[string]bool{}}
	mut dropped := []map[string]json2.Any{}
	for wi, wave in waves {
		for item in wave {
			writer := item.paths.len > 0 && item.role in writer_roles
			mut cur := wi
			// Walk forward until the wave's locked-path set does not overlap
			// this writer's paths, bounded so the search terminates. If even
			// the last wave is contended the item MUST be dropped: silently
			// merging two writers into one wave would let them clobber each
			// other, which is the whole thing this pass exists to prevent.
			for writer && overlaps(item.paths, locked[cur]) && cur + 1 < max_plan_waves + 4 {
				cur++
				if cur >= out.len {
					out << []PlanItem{}
					locked << map[string]bool{}
				}
			}
			if writer && overlaps(item.paths, locked[cur]) {
				mut d := item.to_json()
				d['dropped'] = json2.Any('lockpass_overflow')
				mut sorted_paths := item.paths.clone()
				sorted_paths.sort()
				d['reason'] = json2.Any('could not place writer for paths ' + '${sorted_paths} within wave budget')
				dropped << d
				continue
			}
			if writer {
				for p in item.paths {
					locked[cur][p] = true
				}
			}
			out[cur] << item
		}
	}
	// surface the dropped items so the executor and the UI can report them
	// rather than having them vanish
	for d in dropped {
		c.log.append('plan.dropped', d, AppendOpts{ actor: 'compiler' })
	}
	return out.filter(it.len > 0)
}

fn overlaps(paths []string, locked map[string]bool) bool {
	for p in paths {
		if locked[p] {
			return true
		}
	}
	return false
}

// compile is the full pipeline: draft → validate → dedupe → prune → layer →
// lock paths. It seals compile.plan and returns the optimized plan.
pub fn (mut c IntentCompiler) compile(raw_goal string) CompiledPlan {
	goal := raw_goal.trim_space()
	t0 := time.now()
	mut items, raw_deps, mut dropped := c.parse(goal)
	// ids resolve BEFORE dedupe shifts the list
	c.remap_deps(mut items, raw_deps)
	items = c.dedupe(items, mut dropped)
	items = c.prune_unreachable(items)
	waves := c.lockpass(c.layers(items))
	mut est_cost := 0
	for wave in waves {
		for it in wave {
			est_cost += role_cost[it.role] or { default_role_cost }
		}
	}
	plan := CompiledPlan{
		goal:       goal
		waves:      waves
		dropped:    dropped
		est_cost:   est_cost
		compile_ms: int((time.now() - t0).milliseconds())
	}
	c.log.append('compile.plan', plan.to_json(), AppendOpts{ actor: 'kernel' })
	return plan
}

// -- execution ----------------------------------------------------------------

// execute runs the plan wave by wave. Each wave's items run in order through
// the executor, and a wave's reports land before the next wave starts, so
// dependencies are satisfied by construction.
pub fn (mut c IntentCompiler) execute(plan &CompiledPlan) !map[string]json2.Any {
	if c.executor == unsafe { nil } {
		return error('no executor attached — plan compiled only')
	}
	mut all_reports := []map[string]json2.Any{}
	for i, wave in plan.waves {
		c.log.append('compile.wave', {
			'index': json2.Any(i)
			'items': json2.Any(wave.len)
			'roles': json2.Any(strs_to_any(wave.map(it.role)))
		}, AppendOpts{ actor: 'kernel' })
		all_reports << c.executor(wave)
	}
	mut counts := {
		'done':    0
		'blocked': 0
		'error':   0
	}
	for r in all_reports {
		status := jstr(r, 'status')
		if status in counts {
			counts[status] = counts[status] + 1
		}
	}
	result := {
		'goal':       json2.Any(plan.goal)
		'waves':      json2.Any(plan.waves.len)
		'items':      json2.Any(all_reports.len)
		'done':       json2.Any(counts['done'])
		'blocked':    json2.Any(counts['blocked'])
		'error':      json2.Any(counts['error'])
		'est_cost':   json2.Any(plan.est_cost)
		'compile_ms': json2.Any(plan.compile_ms)
	}
	c.log.append('compile.done', result, AppendOpts{ actor: 'system' })
	return result
}

pub fn (c &IntentCompiler) format(plan &CompiledPlan) string {
	dropped_note := if plan.dropped.len > 0 { ' · ${plan.dropped.len} dropped' } else { '' }
	mut lines := [
		'COMPILED PLAN — goal: ${plan.goal}',
		'${plan.items().len} items · ${plan.waves.len} ordered waves · ' + 'est cost ${plan.est_cost} · ${plan.compile_ms}ms${dropped_note}',
	]
	for i, wave in plan.waves {
		lines << '  wave ${i + 1}:'
		for it in wave {
			deps := if it.depends_on.len > 0 { '  ← ' + it.depends_on.join(',') } else { '' }
			mut head := it.paths.clone()
			if head.len > 3 {
				head = head[..3].clone()
			}
			paths := if head.len > 0 { '  [' + head.join(', ') + ']' } else { '' }
			lines << '    [${it.role}] ${clip_plain(it.task, 80)}${paths}${deps}'
		}
	}
	return lines.join('\n')
}
