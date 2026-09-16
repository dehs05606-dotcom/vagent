module vagent

import x.json2

// evolution.v — the self-improvement engine for role briefs.
//
// The agent gets better at its own job, mechanically:
//
//     assess    every worker report carries a status (done/blocked/error),
//               and per ROLE fitness is the trailing success rate over the
//               recent runs
//     mutate    the weakest role's brief is rewritten by the model into K
//               candidate variants (the mutator is injectable, so the tests
//               evolve deterministically and offline)
//     evaluate  every candidate runs the SAME benchmark task as a real
//               worker, graded deterministically
//     select    the champion must beat the incumbent by a margin; a tie
//               keeps the incumbent, because drift without evidence is not
//               improvement
//     deploy    the winner is registered as the worker prompt and re-sealed
//               by the vault on its next resolve. The full OLD text lives in
//               the evolution.deployed event, so rollback is one command and
//               the lineage stays auditable forever
//
// The guardrails are mechanical rather than advice:
//
//   * only WORKER briefs evolve — the sovereign prompts are never touched
//   * at most ONE role evolves per generation
//   * a failed evaluation deploys nothing
//   * generations are capped per session, because evolution is deliberate
//     work and not a background process

// a candidate must beat the incumbent by this margin to deploy
pub const deploy_margin = 0.10
pub const max_generations_per_session = 5
// recent reports per role that count towards fitness
const eval_window = 12
const benchmark_timeout = 240.0

// The evolvable set is frozen to the briefs the agent shipped with. Roles
// forged at runtime by meta.v have no history to improve on and no author to
// answer for the words, so they are left alone.
pub fn evolvable_roles() []string {
	mut out := []string{}
	for name, _ in role_briefs {
		out << name
	}
	out.sort()
	return out
}

fn is_evolvable(role string) bool {
	return role in role_briefs
}

pub struct Generation {
pub mut:
	gen             int
	role            string
	incumbent_score f64
	champion        string
	champion_score  f64
	deployed        bool
	reason          string
	ts              f64
}

pub fn (g &Generation) to_json() map[string]json2.Any {
	return {
		'gen':             json2.Any(g.gen)
		'role':            json2.Any(g.role)
		'incumbent_score': json2.Any(round_to(g.incumbent_score, 3))
		'champion':        json2.Any(clip_plain(g.champion, 200))
		'champion_score':  json2.Any(round_to(g.champion_score, 3))
		'deployed':        json2.Any(g.deployed)
		'reason':          json2.Any(g.reason)
	}
}

// default_benchmark is a fixed, role-neutral task per role — the same
// yardstick every generation, so scores stay comparable across time.
pub fn default_benchmark(role string) string {
	return 'EVOLUTION BENCHMARK [${role}]: survey the current directory ' + 'tree, then produce your standard work product for the role ' + '${role} on what you find. Final line must be ' + "'STATUS: DONE' or 'STATUS: BLOCKED' plus a SUMMARY."
}

// Mutator proposes k candidate briefs for a role.
pub type Mutator = fn (role string, incumbent string, k int) []string

// BriefEvaluator runs a REAL worker with the candidate brief and returns its
// final reply and a score in [0, 1].
pub type BriefEvaluator = fn (role string, brief string) !(string, f64)

// Benchmark is the task every candidate for a role is measured on.
pub type Benchmark = fn (role string) string

@[heap]
pub struct EvolutionEngine {
pub mut:
	log         &EventLog
	mutator     Mutator        @[required]
	evaluator   BriefEvaluator @[required]
	benchmark   Benchmark = default_benchmark
	margin      f64       = deploy_margin
	generations int
}

pub fn new_evolution_engine(log &EventLog, mutator Mutator, evaluator BriefEvaluator) &EvolutionEngine {
	return &EvolutionEngine{
		log:       unsafe { log }
		mutator:   mutator
		evaluator: evaluator
	}
}

// -- fitness from history -----------------------------------------------------

// fitness is the trailing success rate per role from the sealed worker
// reports: done is 1.0, blocked 0.4, error 0.0, and the newer half of a
// role's window weighs double.
pub fn (mut e EvolutionEngine) fitness() map[string]f64 {
	// The filter to evolvable roles runs BEFORE the window is cut. The
	// other order let a chatty non-evolvable role push real evolvable
	// events off the end, so a role whose performance was declining looked
	// stable — its decline had simply fallen out of the slice.
	mut rows := []Rec{}
	for ev in e.log.events(e.log.branch) {
		if ev.typ != 'crew.done' {
			continue
		}
		if !is_evolvable(jstr(ev.data, 'role').trim_space()) {
			continue
		}
		rows << ev.data.clone()
	}
	window := eval_window * evolvable_roles().len
	if rows.len > window {
		rows = rows[rows.len - window..].clone()
	}

	mut scores := map[string][]f64{}
	mut order := []string{}
	for d in rows {
		role := jstr(d, 'role').trim_space()
		mut status := jstr(d, 'status')
		if status == '' {
			status = jstr(d, 'state')
		}
		score := match status {
			'done' { 1.0 }
			'blocked' { 0.4 }
			else { 0.0 }
		}
		if role !in scores {
			order << role
		}
		scores[role] << score
	}

	mut out := map[string]f64{}
	for role in order {
		vals := scores[role]
		mut total := 0.0
		mut weight_sum := 0.0
		for i, v in vals {
			w := if i >= vals.len / 2 { 2.0 } else { 1.0 }
			total += v * w
			weight_sum += w
		}
		out[role] = if weight_sum > 0 { total / weight_sum } else { 0.0 }
	}
	return out
}

// weakest_role is the evolvable role with the worst trailing fitness and at
// least one recorded run — a role with no history has nothing to improve on.
pub fn (mut e EvolutionEngine) weakest_role() ?string {
	fit := e.fitness()
	if fit.len == 0 {
		return none
	}
	// ties resolve alphabetically, so two runs over one log agree
	mut names := fit.keys()
	names.sort()
	mut worst := names[0]
	for name in names {
		if fit[name] < fit[worst] {
			worst = name
		}
	}
	return worst
}

// -- one generation -----------------------------------------------------------

// evolve runs ONE generation: it mutates the weakest (or named) role's brief,
// evaluates every candidate on the fixed benchmark, and deploys the champion
// only if it clears the incumbent by the margin.
pub fn (mut e EvolutionEngine) evolve(requested_role string) Generation {
	if e.generations >= max_generations_per_session {
		return Generation{
			gen:    e.generations
			role:   if requested_role != '' { requested_role } else { '?' }
			reason: 'generation cap reached for this session'
			ts:     now_ts()
		}
	}
	mut role := requested_role
	if role == '' {
		role = e.weakest_role() or { '' }
	}
	if role == '' || !is_evolvable(role) {
		return Generation{
			gen:    e.generations
			role:   if role != '' { role } else { '?' }
			reason: 'no role history to evolve on yet'
			ts:     now_ts()
		}
	}
	e.generations++

	mut reg := role_registry
	incumbent := reg.brief(role) or { role_briefs[role] or { '' } }
	_, incumbent_score := e.evaluator(role, incumbent) or { '', 0.0 }

	mut gen := Generation{
		gen:             e.generations
		role:            role
		incumbent_score: incumbent_score
		ts:              now_ts()
	}

	candidates := e.mutator(role, incumbent, 3).filter(it != '' && it != incumbent)
	mut best_text := ''
	mut best_score := incumbent_score
	for cand in candidates {
		// a bad candidate never kills a run — it simply does not win
		_, score := e.evaluator(role, cand) or { continue }
		if score > best_score {
			best_text = cand
			best_score = score
		}
	}

	if best_text == '' || best_score < incumbent_score + e.margin {
		gen.reason = 'champion ${best_score:.2f} did not clear incumbent ' + '${incumbent_score:.2f} + margin ${e.margin:.2f} — incumbent kept'
		e.log.append('evolution.generation', gen.to_json(), AppendOpts{ actor: 'kernel' })
		return gen
	}

	gen.champion = best_text
	gen.champion_score = best_score
	gen.deployed = true
	gen.reason = 'champion cleared incumbent by ${best_score - incumbent_score:.2f}'
	// the brief is updated FIRST, then the built worker prompt is
	// re-registered; the vault re-seals it on its next resolve
	reg.set_brief(role, best_text)
	register('worker:${role}', prompt_worker(role, max_workers)) or {}
	e.log.append('evolution.deployed', {
		'gen':   json2.Any(gen.gen)
		'role':  json2.Any(role)
		'old':   json2.Any(incumbent)
		'new':   json2.Any(best_text)
		'score': json2.Any(best_score)
	}, AppendOpts{ actor: 'kernel' })
	e.log.append('evolution.generation', gen.to_json(), AppendOpts{ actor: 'kernel' })
	return gen
}

// -- rollback and history -----------------------------------------------------

// rollback restores the brief recorded in the LAST evolution.deployed event
// for this role. The vault picks the restored copy up on its next resolve.
pub fn (mut e EvolutionEngine) rollback(role string) string {
	mut deploys := []Rec{}
	for ev in e.log.events(e.log.branch) {
		if ev.typ == 'evolution.deployed' && jstr(ev.data, 'role') == role {
			deploys << ev.data.clone()
		}
	}
	if deploys.len == 0 {
		return "no deployed evolution for role '${role}' — nothing to roll back"
	}
	old := jstr(deploys[deploys.len - 1], 'old')
	if old == '' {
		return 'deployed event carried no old text — cannot roll back'
	}
	mut reg := role_registry
	reg.set_brief(role, old)
	register('worker:${role}', prompt_worker(role, max_workers)) or {}
	e.log.append('evolution.rollback', {
		'role': json2.Any(role)
	}, AppendOpts{ actor: 'human' })
	return 'rolled back ${role} to its pre-evolution brief'
}

pub fn (mut e EvolutionEngine) history() []Rec {
	mut out := []Rec{}
	for ev in e.log.events(e.log.branch) {
		if ev.typ in ['evolution.generation', 'evolution.deployed', 'evolution.rollback'] {
			out << ev.data.clone()
		}
	}
	return out
}

pub fn (e &EvolutionEngine) format(gen &Generation) string {
	verdict := if gen.deployed { 'DEPLOYED ✓' } else { 'kept incumbent' }
	return [
		'GENERATION ${gen.gen} — role: ${gen.role} · ${verdict}',
		'  incumbent ${gen.incumbent_score:.2f} · champion ${gen.champion_score:.2f}',
		'  ${gen.reason}',
	].join('\n')
}
