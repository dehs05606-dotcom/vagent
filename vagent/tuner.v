module vagent

import x.json2

// tuner.v — Bayesian-ish auto-tuning of the agent's own knobs.
//
// Which effort level and worker step count make turns score best? Rather
// than guess, this runs the Tree-structured Parzen Estimator loop:
//
//   suggest   split the observed (config, score) history into GOOD (the
//             top γ) and REST, then sample each knob from the good set's
//             histogram with probability l(x) ∝ good / (good + rest) —
//             the TPE density ratio. With no history it space-fills, and
//             ε of the time it explores uniformly regardless, so no value
//             is ever permanently locked out.
//   observe   every trial's score feeds the history
//   best      the argmax config so far
//
// Knob values are strings. The original allowed any hashable, but every
// space the agent actually tunes is a set of labels — effort keys, worker
// step buckets — and typing them as strings makes the config both a map key
// and a JSON payload without a conversion in between.

// the fraction of history counted as GOOD
pub const tuner_gamma = 0.25
// the uniform exploration probability
pub const tuner_epsilon = 0.10

pub struct Trial {
pub:
	config   map[string]string
	score    f64
	ts_order int
}

pub struct TunerReport {
pub:
	best_config map[string]string
	best_score  f64
	trials      int
	distinct    int
}

pub fn (r &TunerReport) to_json() map[string]json2.Any {
	mut cfg := map[string]json2.Any{}
	for k, v in r.best_config {
		cfg[k] = json2.Any(v)
	}
	return {
		'best_config': json2.Any(cfg)
		'best_score':  json2.Any(round_to(r.best_score, 4))
		'trials':      json2.Any(r.trials)
		'distinct':    json2.Any(r.distinct)
	}
}

// TunerObjective scores one configuration. Production runs a scored
// benchmark turn; the tests use a synthetic landscape with a known optimum.
pub type TunerObjective = fn (config map[string]string) f64

@[heap]
pub struct ParzenTuner {
pub mut:
	log &EventLog
	// knob -> allowed values; a knob with no values is dropped
	space     map[string][]string
	knobs     []string
	rng       Rng
	objective TunerObjective = unsafe { nil }
	history   []Trial
	n         int
}

pub fn new_parzen_tuner(log &EventLog, space map[string][]string, seed u64, objective TunerObjective) &ParzenTuner {
	mut t := &ParzenTuner{
		log:       unsafe { log }
		rng:       new_rng(seed)
		objective: objective
	}
	// knob order is fixed once, so a suggestion is reproducible: iterating a
	// V map is not guaranteed to be stable across builds
	mut keys := []string{}
	for k, v in space {
		if v.len == 0 {
			continue
		}
		t.space[k] = v.clone()
		keys << k
	}
	keys.sort()
	t.knobs = keys
	return t
}

// -- TPE internals -----------------------------------------------------------

// density is the histogram likelihood of `value` under `values`, with a
// smoothing floor so an empty bin never zeroes the ratio out.
fn density(value string, values []string) f64 {
	if values.len == 0 {
		return 1.0
	}
	mut hits := 0
	for v in values {
		if v == value {
			hits++
		}
	}
	return (f64(hits) + 0.5) / (f64(values.len) + 0.5)
}

fn (mut t ParzenTuner) sample_knob(knob string, good []Trial, rest []Trial) string {
	values := t.space[knob]
	if good.len == 0 {
		// space-fill early: with nothing observed there is nothing to exploit
		return values[t.rng.below(values.len)]
	}
	good_vals := good.map(it.config[knob])
	rest_vals := rest.map(it.config[knob])
	mut weights := []f64{}
	mut total := 0.0
	for v in values {
		pg := density(v, good_vals)
		pr := density(v, rest_vals)
		w := pg / (pg + pr)
		weights << w
		total += w
	}
	if total <= 0 {
		return values[t.rng.below(values.len)]
	}
	pick := t.rng.f64() * total
	mut acc := 0.0
	for i, v in values {
		acc += weights[i]
		if pick <= acc {
			return v
		}
	}
	return values.last()
}

// -- the loop ----------------------------------------------------------------

// suggest proposes one configuration: ε of the time uniformly, otherwise by
// the density ratio.
pub fn (mut t ParzenTuner) suggest() map[string]string {
	n_good := max_int(1, int(f64(t.history.len) * tuner_gamma))
	mut ranked := t.history.clone()
	ranked.sort(a.score > b.score)
	good := ranked[..min_int(n_good, ranked.len)].clone()
	rest := if n_good < ranked.len { ranked[n_good..].clone() } else { []Trial{} }

	mut out := map[string]string{}
	if t.history.len == 0 || t.rng.f64() < tuner_epsilon {
		for k in t.knobs {
			vals := t.space[k]
			out[k] = vals[t.rng.below(vals.len)]
		}
		return out
	}
	for k in t.knobs {
		out[k] = t.sample_knob(k, good, rest)
	}
	return out
}

pub fn (mut t ParzenTuner) observe(config map[string]string, score f64) {
	t.n++
	t.history << Trial{
		config:   config.clone()
		score:    score
		ts_order: t.n
	}
	mut cfg := map[string]json2.Any{}
	for k, v in config {
		cfg[k] = json2.Any(v)
	}
	t.log.append('tuner.trial', {
		'config': json2.Any(cfg)
		'score':  json2.Any(round_to(score, 4))
		'n':      json2.Any(t.n)
	}, AppendOpts{ actor: 'kernel' })
}

// step is suggest, evaluate, observe.
pub fn (mut t ParzenTuner) step() !Trial {
	if isnil(t.objective) {
		return error('no objective attached')
	}
	config := t.suggest()
	score := t.objective(config)
	t.observe(config, score)
	return t.history.last()
}

pub fn (t &ParzenTuner) best() ?Trial {
	if t.history.len == 0 {
		return none
	}
	mut b := t.history[0]
	for trial in t.history[1..] {
		if trial.score > b.score {
			b = trial
		}
	}
	return b
}

pub fn (mut t ParzenTuner) run(n int) !TunerReport {
	for _ in 0 .. n {
		t.step()!
	}
	b := t.best() or { return error('no trials ran') }
	mut seen := map[string]bool{}
	for trial in t.history {
		seen[config_key(trial.config)] = true
	}
	report := TunerReport{
		best_config: b.config.clone()
		best_score:  b.score
		trials:      t.history.len
		distinct:    seen.len
	}
	t.log.append('tuner.best', report.to_json(), AppendOpts{})
	return report
}

fn config_key(config map[string]string) string {
	mut keys := config.keys()
	keys.sort()
	return keys.map('${it}=${config[it]}').join('|')
}

pub fn (t &ParzenTuner) format() string {
	mut lines := ['TUNER — ${t.history.len} trials']
	if b := t.best() {
		mut keys := b.config.keys()
		keys.sort()
		parts := keys.map('${it}=${b.config[it]}')
		lines << '  best score ${b.score:.4f} with ' + parts.join(', ')
	}
	return lines.join('\n')
}
