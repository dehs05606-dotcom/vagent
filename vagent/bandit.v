module vagent

import math
import x.json2

// bandit.v — the contextual Thompson-sampling router.
//
// Which (model, effort) combination should serve a task? This answers with
// probability rather than with a hunch:
//
//   arms        the model×effort combinations actually configured
//   context     the task bucket read off the request text — code, write,
//               research, run or chat; different buckets learn separately
//   posteriors  one Beta(α, β) per (context, arm). α grows on good
//               outcomes, β on bad ones
//   recommend   draw one sample per arm and take the largest. That is
//               probability matching: an uncertain arm still wins
//               sometimes, which is how it ever gets learned, and a proven
//               arm dominates once the evidence is in
//   update      every finished turn feeds its score back
//
// The posteriors are not held anywhere but the log: `new_bandit_router`
// rebuilds them from the sealed bandit.update events, so the policy survives
// a restart without a second store to keep in sync.

pub const bandit_contexts = ['code', 'write', 'research', 'run', 'chat']

// a uniform Beta prior: before any evidence, no arm is presumed better
pub const bandit_prior_alpha = 1.0
pub const bandit_prior_beta = 1.0

// context_of buckets a request by its dominant signature.
//
// Execution verbs outrank nouns, and the order of these tests is the rule:
// "run the test suite" is a run, not a test, and reversing the first two
// checks would quietly reclassify half the traffic.
pub fn context_of(task string) string {
	t := task.to_lower()
	if re := compile_regex(r'\b(run|execute|command|build|install|deploy|benchmark)\b') {
		if _ := re.search(t) {
			return 'run'
		}
	}
	if re := compile_regex(r'\b(bug|fix|code|implement|refactor|function|class|test|error|stack|trace)\b') {
		if _ := re.search(t) {
			return 'code'
		}
	}
	if re := compile_regex(r'\b(write|document|readme|docs?|blog|letter|essay|email)\b') {
		if _ := re.search(t) {
			return 'write'
		}
	}
	if re := compile_regex(r'\b(research|latest|news|compare|find|who|what is|search)\b') {
		if _ := re.search(t) {
			return 'research'
		}
	}
	return 'chat'
}

// gamma_draw is Marsaglia–Tsang. The shape < 1 case is handled by boosting
// the shape and scaling back down, which is the standard trick: the
// rejection loop below is only valid for shape >= 1.
pub fn gamma_draw(shape f64, mut rng Rng) f64 {
	if shape < 1.0 {
		mut u := rng.f64()
		for u <= 1e-12 {
			u = rng.f64()
		}
		return gamma_draw(shape + 1.0, mut rng) * math.pow(u, 1.0 / shape)
	}
	d := shape - 1.0 / 3.0
	c := 1.0 / math.sqrt(9.0 * d)
	for {
		x := rng.gauss()
		mut v := 1.0 + c * x
		if v <= 0 {
			continue
		}
		v = v * v * v
		u := rng.f64()
		if u < 1.0 - 0.0331 * x * x * x * x {
			return d * v
		}
		if math.log(u) < 0.5 * x * x + d * (1.0 - v + math.log(v)) {
			return d * v
		}
	}
	return d
}

// beta_draw samples Beta(α, β) as the ratio of two Gamma draws.
pub fn beta_draw(alpha f64, beta f64, mut rng Rng) f64 {
	x := gamma_draw(alpha, mut rng)
	y := gamma_draw(beta, mut rng)
	return if x + y > 0 { x / (x + y) } else { 0.5 }
}

pub struct Recommendation {
pub:
	arm     string
	context string
	// this round's draw per arm
	sampled map[string]f64
	// the posterior mean per arm, α/(α+β)
	expected map[string]f64
}

@[heap]
pub struct BanditRouter {
pub mut:
	log  &EventLog
	arms []string
	rng  Rng
	// keyed 'context|arm'
	alpha map[string]f64
	beta  map[string]f64
}

pub fn new_bandit_router(log &EventLog, arms []string, seed u64) &BanditRouter {
	mut b := &BanditRouter{
		log:  unsafe { log }
		arms: if arms.len > 0 { arms.clone() } else { ['default'] }
		rng:  new_rng(seed)
	}
	b.load()
	return b
}

// load rebuilds the posteriors from the sealed updates. The last update for
// a (context, arm) carries the running totals, so replaying them in order
// lands on the same state the router had when it stopped.
fn (mut b BanditRouter) load() {
	for ev in b.log.events(b.log.branch) {
		if ev.typ != 'bandit.update' {
			continue
		}
		mut ctx := jstr(ev.data, 'context')
		if ctx == '' {
			ctx = 'chat'
		}
		key := posterior_key(ctx, jstr(ev.data, 'arm'))
		b.alpha[key] = jf64_or(ev.data, 'alpha', bandit_prior_alpha)
		b.beta[key] = jf64_or(ev.data, 'beta', bandit_prior_beta)
	}
}

fn posterior_key(context string, arm string) string {
	return '${context}|${arm}'
}

fn (b &BanditRouter) posterior(context string, arm string) (f64, f64) {
	key := posterior_key(context, arm)
	a := if key in b.alpha { b.alpha[key] } else { bandit_prior_alpha }
	bb := if key in b.beta { b.beta[key] } else { bandit_prior_beta }
	return a, bb
}

// recommend runs one Thompson round: sample every arm, take the argmax.
pub fn (mut b BanditRouter) recommend(task string) Recommendation {
	context := context_of(task)
	mut sampled := map[string]f64{}
	mut expected := map[string]f64{}
	for arm in b.arms {
		a, bb := b.posterior(context, arm)
		sampled[arm] = beta_draw(a, bb, mut b.rng)
		expected[arm] = a / (a + bb)
	}
	mut best := b.arms[0]
	for arm in b.arms[1..] {
		if sampled[arm] > sampled[best] {
			best = arm
		}
	}
	mut rounded := map[string]json2.Any{}
	for k, v in sampled {
		rounded[k] = json2.Any(round_to(v, 3))
	}
	b.log.append('bandit.pull', {
		'context': json2.Any(context)
		'arm':     json2.Any(best)
		'sampled': json2.Any(rounded)
	}, AppendOpts{})
	return Recommendation{
		arm:      best
		context:  context
		sampled:  sampled
		expected: expected
	}
}

// update feeds one outcome into the posterior. A reward outside 0..1 is
// clamped rather than rejected — a caller passing a percentage should skew
// the policy, not corrupt it.
pub fn (mut b BanditRouter) update(arm string, reward f64, context string) {
	mut r := reward
	if r < 0.0 {
		r = 0.0
	}
	if r > 1.0 {
		r = 1.0
	}
	ctx := if context != '' { context } else { 'chat' }
	mut a, mut bb := b.posterior(ctx, arm)
	// a fractional update: a half-good turn is half evidence each way
	a += r
	bb += 1.0 - r
	key := posterior_key(ctx, arm)
	b.alpha[key] = a
	b.beta[key] = bb
	b.log.append('bandit.update', {
		'context': json2.Any(ctx)
		'arm':     json2.Any(arm)
		'reward':  json2.Any(round_to(r, 3))
		'alpha':   json2.Any(round_to(a, 3))
		'beta':    json2.Any(round_to(bb, 3))
	}, AppendOpts{})
}

// policy is the expected success rate per (context, arm) — what has been
// learned, with no sampling in it.
pub fn (b &BanditRouter) policy() map[string]map[string]f64 {
	mut out := map[string]map[string]f64{}
	for ctx in bandit_contexts {
		mut row := map[string]f64{}
		for arm in b.arms {
			a, bb := b.posterior(ctx, arm)
			row[arm] = round_to(a / (a + bb), 3)
		}
		out[ctx] = row.clone()
	}
	return out
}

pub fn (b &BanditRouter) format() string {
	pol := b.policy()
	mut lines := ['BANDIT ROUTER — expected success per arm:']
	for ctx in bandit_contexts {
		row := pol[ctx].clone()
		mut arms := b.arms.clone()
		arms.sort_with_compare(fn [row] (a &string, b &string) int {
			av := row[*a]
			bv := row[*b]
			if av > bv {
				return -1
			}
			if av < bv {
				return 1
			}
			return 0
		})
		best := arms[0]
		parts := arms.map('${it}=${row[it]:.2f}')
		lines << '  ${ctx:-9} best=${best:-24} ${parts.join(" · ")}'
	}
	return lines.join('\n')
}
