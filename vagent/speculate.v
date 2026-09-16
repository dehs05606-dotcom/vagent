module vagent

import sync
import x.json2

// speculate.v — speculative execution, for the zero-latency feel.
//
// While the model is thinking, the agent PREDICTS which read-only calls it
// is likely to make next and runs them ahead of time. When the model
// actually asks, the answer is served from the cache instantly.
//
// Hard safety rules, mechanical rather than advisory:
//
//   * ONLY whitelisted read-only tools are ever prefetched. A speculative
//     write is structurally impossible — the whitelist is the gate, and
//     serve() refuses anything outside it even if something managed to put
//     it in the cache.
//   * Predictions are deterministic: paths named in the last user message,
//     files referenced by recent calls, the parent of a recent read. No
//     model call is made to decide what to prefetch.
//   * Every prefetch, hit, miss and eviction is sealed, so the hit rate —
//     the actual dividend — is auditable rather than claimed.

// the ONLY tools speculation may ever run
pub const speculative_tools = ['read_file', 'list_dir', 'file_info', 'search_files',
	'glob_files']

pub const max_prefetch = 4
// a prefetched result expires after this many turns
pub const cache_ttl_turns = 6

// a path: starts with ./~ OR contains a slash OR ends with a short extension
const spec_path_pattern = '(?:^|[\\s\'"\x60(])((?:[./~][\\w./~-]{0,200})|(?:[\\w~-]+(?:/[\\w.-]+)+)|(?:[\\w~-]+\\.\\w{1,6}))(?=\$|[\\s\'"\x60),:;])'

pub struct Prediction {
pub:
	tool  string
	args  map[string]json2.Any
	score f64
	why   string
}

pub fn (p &Prediction) key() string {
	return prediction_key(p.tool, p.args)
}

// prediction_key is the cache key. The original used the sorted arg pairs;
// canonical JSON is the same idea and is already the project's one way of
// turning a map into a stable string.
pub fn prediction_key(tool string, args map[string]json2.Any) string {
	return '${tool}:' + canonical(json2.Any(args))
}

// predict is the read-only calls the model is likely to make next, strongest
// signal first.
pub fn predict(user_text string, recent_tools []ToolEvent) []Prediction {
	mut preds := []Prediction{}
	mut seen := map[string]bool{}

	// 1 + 2: paths named by the user
	if re := compile_regex(spec_path_pattern) {
		for m in re.find_all(user_text) {
			path := group_text(user_text, &m, 1)
			if path.ends_with('/') || path.ends_with('.') {
				trimmed := path.trim_right('/')
				add_prediction(mut preds, mut seen, Prediction{
					tool:  'list_dir'
					args:  {
						'path': json2.Any(if trimmed != '' { trimmed } else { '.' })
					}
					score: 0.9
					why:   'path in user message'
				})
			} else {
				add_prediction(mut preds, mut seen, Prediction{
					tool:  'read_file'
					args:  {
						'path': json2.Any(path)
					}
					score: 0.9
					why:   'path in user message'
				})
				add_prediction(mut preds, mut seen, Prediction{
					tool:  'file_info'
					args:  {
						'path': json2.Any(path)
					}
					score: 0.4
					why:   'path in user message'
				})
			}
		}
	}

	// 3: a search verb and its term
	low := user_text.to_lower()
	if re := compile_regex(r'\b(?:search|find|grep|dhundo)\b\s+(?:for\s+)?[\x27"]?([\w .-]{2,40})') {
		if m := re.search(low) {
			term := group_text(low, &m, 1).trim_space()
			if term != '' {
				add_prediction(mut preds, mut seen, Prediction{
					tool:  'search_files'
					args:  {
						'pattern': json2.Any(term)
					}
					score: 0.6
					why:   'search verb in user message'
				})
			}
		}
	}

	// 4: the siblings of recently read files
	start := max_int(0, recent_tools.len - 3)
	for call in recent_tools[start..] {
		if call.name != 'read_file' {
			continue
		}
		p := jstr(call.args, 'path')
		if p.contains('/') {
			parent := p.all_before_last('/')
			add_prediction(mut preds, mut seen, Prediction{
				tool:  'list_dir'
				args:  {
					'path': json2.Any(parent)
				}
				score: 0.5
				why:   'sibling of recent read'
			})
		}
	}

	// 5: with nothing else signalled, look at the working directory
	if preds.len == 0 {
		add_prediction(mut preds, mut seen, Prediction{
			tool:  'list_dir'
			args:  {
				'path': json2.Any('.')
			}
			score: 0.2
			why:   'default cwd probe'
		})
	}

	preds.sort(a.score > b.score)
	return preds[..min_int(max_prefetch, preds.len)].clone()
}

fn add_prediction(mut preds []Prediction, mut seen map[string]bool, p Prediction) {
	k := p.key()
	if k in seen {
		return
	}
	seen[k] = true
	preds << p
}

struct SpecCacheEntry {
	tool       string
	args       map[string]json2.Any
	result     string
	born_turn  int
}

// SpecRunner executes one tool call. In the agent it is bound to the real
// read-only handlers; in the tests it is a stub.
pub type SpecRunner = fn (name string, args map[string]json2.Any) !string

@[heap]
pub struct Speculator {
pub mut:
	log    &EventLog
	runner SpecRunner = unsafe { nil }
	turn   int
	hits   int
	misses int
mut:
	mu    sync.Mutex
	cache map[string]SpecCacheEntry
}

pub fn new_speculator(log &EventLog, runner SpecRunner) &Speculator {
	return &Speculator{
		log:    unsafe { log }
		runner: runner
	}
}

// -- the speculation round ---------------------------------------------------

struct PrefetchResult {
	pred   Prediction
	result string
}

fn run_prediction(runner SpecRunner, p Prediction) PrefetchResult {
	// speculation must never surface an error: a failed guess is simply a
	// guess that is not cached
	out := runner(p.tool, p.args.clone()) or {
		return PrefetchResult{
			pred:   p
			result: 'ERROR: ${err.msg()}'
		}
	}
	return PrefetchResult{
		pred:   p
		result: out
	}
}

// speculate predicts and prefetches, and returns how many landed.
pub fn (mut s Speculator) speculate(user_text string, recent_tools []ToolEvent) int {
	s.turn++
	s.expire()
	preds := predict(user_text, recent_tools)

	s.mu.@lock()
	mut fresh := []Prediction{}
	for p in preds {
		if p.key() !in s.cache {
			fresh << p
		}
	}
	s.mu.unlock()

	if fresh.len == 0 || isnil(s.runner) {
		return 0
	}

	mut threads := []thread PrefetchResult{}
	for p in fresh {
		threads << spawn run_prediction(s.runner, p)
	}
	mut done := 0
	for t in threads {
		r := t.wait()
		if r.result.starts_with('ERROR:') {
			continue
		}
		s.mu.@lock()
		s.cache[r.pred.key()] = SpecCacheEntry{
			tool:      r.pred.tool
			args:      r.pred.args.clone()
			result:    r.result
			born_turn: s.turn
		}
		s.mu.unlock()
		s.log.append('spec.prefetch', {
			'tool':  json2.Any(r.pred.tool)
			'args':  json2.Any(r.pred.args.clone())
			'score': json2.Any(r.pred.score)
			'why':   json2.Any(r.pred.why)
			'chars': json2.Any(r.result.len)
		}, AppendOpts{ actor: 'speculator' })
		done++
	}
	return done
}

// -- serving -----------------------------------------------------------------

// serve returns the prefetched result for this exact call, or none — in
// which case the caller runs it for real.
pub fn (mut s Speculator) serve(tool string, args map[string]json2.Any) ?string {
	if tool !in speculative_tools {
		return none
	}
	key := prediction_key(tool, args)
	// The counter increment and the event both happen inside the lock.
	// Releasing it between the delete and the increment let two threads
	// asking for the same prefetched call each miss-then-hit, and the audit
	// log would record a miss before a hit for what was one legitimate hit.
	s.mu.@lock()
	entry := s.cache[key] or {
		s.misses++
		s.mu.unlock()
		s.log.append('spec.miss', {
			'tool': json2.Any(tool)
			'args': json2.Any(args.clone())
		}, AppendOpts{ actor: 'speculator' })
		return none
	}
	s.cache.delete(key)
	s.hits++
	s.mu.unlock()
	s.log.append('spec.hit', {
		'tool':  json2.Any(tool)
		'args':  json2.Any(args.clone())
		'chars': json2.Any(entry.result.len)
	}, AppendOpts{ actor: 'speculator' })
	return entry.result
}

// -- housekeeping ------------------------------------------------------------

fn (mut s Speculator) expire() {
	s.mu.@lock()
	mut stale := []string{}
	for k, e in s.cache {
		if s.turn - e.born_turn > cache_ttl_turns {
			stale << k
		}
	}
	for k in stale {
		s.cache.delete(k)
	}
	s.mu.unlock()
	if stale.len > 0 {
		s.log.append('spec.evict', {
			'count': json2.Any(stale.len)
		}, AppendOpts{ actor: 'speculator' })
	}
}

pub fn (mut s Speculator) stats() map[string]json2.Any {
	st := fold(mut s.log, s.log.branch)
	mut prefetched := 0
	mut hits := 0
	mut misses := 0
	for e in st.spec_events {
		match jstr(e, 'type') {
			'spec.prefetch' { prefetched++ }
			'spec.hit' { hits++ }
			'spec.miss' { misses++ }
			else {}
		}
	}
	rate := f64(hits) / f64(max_int(1, hits + misses))
	return {
		'prefetched': json2.Any(prefetched)
		'hits':       json2.Any(hits)
		'misses':     json2.Any(misses)
		'hit_rate':   json2.Any(round_to(rate, 3))
		'cached':     json2.Any(s.cache.len)
	}
}

pub fn (mut s Speculator) format_status() string {
	st := s.stats()
	rate := jf64(st, 'hit_rate') * 100.0
	return 'SPECULATOR — speculative execution\n' +
		'  prefetched ${jint(st, "prefetched")}   hits ${jint(st, "hits")}   ' +
		'misses ${jint(st, "misses")}   hit-rate ${rate:.0f}%\n' +
		'  only read-only tools are ever prefetched: ' + speculative_tools.join(', ')
}
