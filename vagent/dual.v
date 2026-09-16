module vagent

import time
import x.json2

// dual.v — System 1 / System 2: metacognitive routing.
//
// Kahneman's architecture, mechanical. Every request meets the FAST path
// first and only earns the SLOW one when it has to:
//
//   System 1   a cache of previously-verified answers plus one cheap model
//              call. Pattern-match first; think only if nothing matches.
//   System 2   the deliberate stack — deep tools, debate, judge
//              verification. Injected, because what "deliberate" means is
//              the caller's business.
//
// Between them sits the metacognition: before answering, the router
// ESTIMATES how much to trust the fast path. Hedging language in the fast
// answer ("maybe", "not sure"), complexity markers in the question (several
// questions at once, comparisons, "prove", "step by step"), novelty against
// what the brain knows, and cache staleness all push the estimate down.
// Below the bar it escalates and records that it did.
//
// So an easy question costs one cheap call, and a hard one is never bluffed.
// The escalation ledger is sealed, which is what makes the split measurable:
// what fraction of the work genuinely needed deep thought.

pub const escalate_bar = 0.62

// A hard cap on the answer cache. Without it a long-lived session leaks
// without bound: a prompt-injection payload that asks the agent to enumerate
// 1..N with a unique suffix per call forces one model call per nonce and
// pins every response forever. 256 entries amortises the real repeat-question
// traffic; the rest is evicted least-recently-used.
pub const dual_cache_max = 256

const hedge_pattern = r'(?i)\b(maybe|perhaps|i think|not sure|unsure|possibly|might be|probably|guess|honestly not|no idea|cannot determine)\b'
const complexity_pattern = r'(?i)[?;]|\b(vs|versus|compare|why|how come|prove|derive|trade-?off|step by step)\b'

pub struct RouteDecision2 {
pub:
	// 1 or 2
	system     int
	answer     string
	confidence f64
	why        string
	cached     bool
	elapsed_ms int
}

struct CacheEntry {
mut:
	answer    string
	sealed_at f64
	// the answer came from System 2, so it carries deep-process provenance
	from_slow bool
}

// DualFn is either half of the pair: question in, answer out.
pub type DualFn = fn (question string) string

pub struct DualStats {
pub mut:
	system1     int
	system2     int
	cache_hits  int
	escalations int
}

@[heap]
pub struct DualProcess {
pub mut:
	log     &EventLog
	fast_fn DualFn
	slow_fn DualFn
	// optional: the novelty signal. nil means the router has no opinion
	// about how familiar a domain is.
	brain &Brain = unsafe { nil }
	bar   f64    = escalate_bar
	cache map[string]CacheEntry
	// insertion/use order for the LRU eviction, oldest first
	order []string
	stats DualStats
}

pub fn new_dual_process(log &EventLog, fast_fn DualFn, slow_fn DualFn, brain &Brain, bar f64) &DualProcess {
	return &DualProcess{
		log:     unsafe { log }
		fast_fn: fast_fn
		slow_fn: slow_fn
		brain:   unsafe { brain }
		bar:     bar
	}
}

fn (mut d DualProcess) cache_put(key string, entry CacheEntry) {
	if key !in d.cache {
		d.order << key
	} else {
		d.touch(key)
	}
	d.cache[key] = entry
	for d.cache.len > dual_cache_max {
		oldest := d.order[0]
		d.order.delete(0)
		d.cache.delete(oldest)
	}
}

fn (mut d DualProcess) touch(key string) {
	idx := d.order.index(key)
	if idx >= 0 {
		d.order.delete(idx)
	}
	d.order << key
}

// -- metacognition -----------------------------------------------------------

// confidence estimates how much to trust the fast path for this pair.
// Mechanical signals only — nothing here asks a model what it thinks of
// itself.
pub fn (mut d DualProcess) confidence(question string, answer string, cache_age f64, has_age bool) f64 {
	mut conf := 0.75
	hedges := count_matches(hedge_pattern, answer)
	conf -= 0.18 * f64(min_int(hedges, 3))
	complexity := count_matches(complexity_pattern, question)
	conf -= 0.06 * f64(min_int(complexity, 4))

	if !isnil(d.brain) {
		mut brain := d.brain
		known := brain.recall(question, 3, '')
		has_memory := brain.memories.len > 0
		if known.len > 0 {
			// a familiar, reinforced domain
			conf += 0.10
		} else if has_memory {
			// novel relative to everything this agent has experienced
			conf -= 0.12
		}
		// an empty brain carries no novelty signal either way
	}
	if has_age {
		conf -= min_f64(cache_age / 86400.0, 0.25)
	}
	if answer.trim_space() == '' {
		conf = 0.0
	}
	if conf < 0.0 {
		conf = 0.0
	}
	if conf > 1.0 {
		conf = 1.0
	}
	return conf
}

// count_matches is how many times a pattern occurs — Python's findall length.
pub fn count_matches(pattern string, text string) int {
	if text == '' {
		return 0
	}
	re := compile_regex(pattern) or { return 0 }
	return re.find_all(text).len
}

// -- the router --------------------------------------------------------------

// ask answers via System 1 unless the metacognition escalates.
pub fn (mut d DualProcess) ask(question string) RouteDecision2 {
	q := question.trim_space()
	t0 := time.now()
	if q == '' {
		return RouteDecision2{
			system: 1
			why:    'empty question'
		}
	}

	key := clip_plain(q.to_lower(), 200)
	if entry := d.cache[key] {
		age := now_ts() - entry.sealed_at
		mut conf := d.confidence(q, entry.answer, age, true)
		if entry.from_slow {
			conf = min_f64(1.0, conf + 0.15)
		}
		if conf >= d.bar {
			d.touch(key)
			d.stats.cache_hits++
			d.stats.system1++
			d.log.append('dual.route', {
				'system':     json2.Any(1)
				'cached':     json2.Any(true)
				'confidence': json2.Any(round_to(conf, 3))
			}, AppendOpts{})
			return RouteDecision2{
				system:     1
				answer:     entry.answer
				confidence: conf
				why:        'verified cache hit'
				cached:     true
				elapsed_ms: int((time.now() - t0).milliseconds())
			}
		}
	}

	fast := d.fast_fn(q)
	conf := d.confidence(q, fast, 0.0, false)
	if conf >= d.bar {
		d.stats.system1++
		d.cache_put(key, CacheEntry{
			answer:    fast
			sealed_at: now_ts()
		})
		d.log.append('dual.route', {
			'system':     json2.Any(1)
			'cached':     json2.Any(false)
			'confidence': json2.Any(round_to(conf, 3))
		}, AppendOpts{})
		return RouteDecision2{
			system:     1
			answer:     fast
			confidence: conf
			why:        'fast path cleared the bar'
			elapsed_ms: int((time.now() - t0).milliseconds())
		}
	}

	// escalate — never bluff
	d.stats.system2++
	d.stats.escalations++
	d.log.append('dual.escalation', {
		'question':        json2.Any(clip_plain(q, 200))
		'fast_confidence': json2.Any(round_to(conf, 3))
		'bar':             json2.Any(d.bar)
		'signals':         json2.Any({
			'hedges':     json2.Any(count_matches(hedge_pattern, fast))
			'complexity': json2.Any(count_matches(complexity_pattern, q))
		})
	}, AppendOpts{})
	slow := d.slow_fn(q)
	d.cache_put(key, CacheEntry{
		answer:    slow
		sealed_at: now_ts()
		from_slow: true
	})
	return RouteDecision2{
		system:     2
		answer:     slow
		confidence: max_f64(conf, 0.8)
		why:        'escalated: fast confidence ${conf:.2f} < bar ${d.bar:.2f}'
		elapsed_ms: int((time.now() - t0).milliseconds())
	}
}

pub fn (d &DualProcess) format_stats() string {
	s := d.stats
	total := max_int(1, s.system1 + s.system2)
	pct := 100.0 * f64(s.system1) / f64(total)
	return 'DUAL PROCESS — system1 ${s.system1} (${pct:.0f}%) · system2 ${s.system2} · ' +
		'cache hits ${s.cache_hits} · escalations ${s.escalations}\n  bar: ${d.bar:.2f}'
}
