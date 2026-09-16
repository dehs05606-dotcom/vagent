module vagent

import sync
import time
import x.json2

// race.v — racing universes: the first verified strategy wins.
//
// One problem, N strategies, tried ONE AT A TIME in lane order. Each
// universe pursues a different approach — a role and its instructions — and
// the moment one produces a result the verifier accepts, it takes the race:
// every remaining lane is skipped and sealed as cancelled.
//
// The losers' partial work is discarded by design. You bought thoroughness;
// you paid the compute.
//
// Lanes are SERIAL, not parallel, which is worth stating because the name
// suggests otherwise. The original ran them one after another too: three
// concurrent agents over one working tree is a merge conflict, not a race.
// The cancel flag exists so a long-running lane can notice the deadline and
// bail out, and the deadline is armed as a timer rather than checked between
// lanes — a runner that never returns would otherwise block forever.

pub struct Strategy {
pub:
	id           string
	role         string
	instructions string
}

pub const default_strategies = [
	Strategy{
		id:           'direct'
		role:         'coder'
		instructions: 'Solve it directly and verify as you go.'
	},
	Strategy{
		id:           'careful'
		role:         'architect'
		instructions: 'Map the problem first, then implement the safest solution.'
	},
	Strategy{
		id:           'split'
		role:         'planner'
		instructions: 'Break the work into parts and assemble them.'
	},
]

// CancelFlag is the deadline signal the runner is expected to poll. It is a
// heap struct with a mutex rather than a bare bool because the timer thread
// and the lane read and write it at the same time.
@[heap]
pub struct CancelFlag {
mut:
	mu    sync.Mutex
	value bool
}

pub fn new_cancel_flag() &CancelFlag {
	return &CancelFlag{}
}

pub fn (mut c CancelFlag) set() {
	c.mu.@lock()
	c.value = true
	c.mu.unlock()
}

pub fn (mut c CancelFlag) is_set() bool {
	c.mu.@lock()
	v := c.value
	c.mu.unlock()
	return v
}

pub struct UniverseOutcome {
pub mut:
	strategy   string
	result     string
	passed     bool
	cancelled  bool
	elapsed_ms int
}

pub fn (o &UniverseOutcome) to_json() map[string]json2.Any {
	return {
		'strategy':   json2.Any(o.strategy)
		'result':     json2.Any(o.result)
		'passed':     json2.Any(o.passed)
		'cancelled':  json2.Any(o.cancelled)
		'elapsed_ms': json2.Any(o.elapsed_ms)
	}
}

pub struct RaceResult {
pub mut:
	task       string
	winner     string
	answer     string
	outcomes   []UniverseOutcome
	elapsed_ms int
}

pub fn (r &RaceResult) to_json() map[string]json2.Any {
	return {
		'task':       json2.Any(clip_plain(r.task, 200))
		'winner':     json2.Any(r.winner)
		'elapsed_ms': json2.Any(r.elapsed_ms)
		'outcomes':   json2.Any(r.outcomes.map(json2.Any(it.to_json())))
	}
}

// UniverseRunner runs one lane. It must poll `cancel` and bail out when the
// flag is set; a runner that ignores it simply finishes late and its result
// is discarded.
pub type UniverseRunner = fn (strategy Strategy, task string, cancel &CancelFlag) !string

// RaceVerifier decides whether a lane's result is good enough to win.
pub type RaceVerifier = fn (task string, result string) !bool

@[heap]
pub struct RacingUniverses {
pub mut:
	log        &EventLog
	runner     UniverseRunner
	verifier   RaceVerifier
	strategies []Strategy
}

pub fn new_racing_universes(log &EventLog, runner UniverseRunner, verifier RaceVerifier, strategies []Strategy) &RacingUniverses {
	return &RacingUniverses{
		log:        unsafe { log }
		runner:     runner
		verifier:   verifier
		strategies: if strategies.len > 0 { strategies.clone() } else { default_strategies }
	}
}

// race runs the strategies in order and returns the first verified pass.
pub fn (mut r RacingUniverses) race(task string, timeout f64) RaceResult {
	t := task.trim_space()
	mut result := RaceResult{
		task: t
	}
	if t == '' || r.strategies.len == 0 {
		return result
	}
	t0 := time.now()
	r.log.append('race.start', {
		'task':       json2.Any(clip_plain(t, 300))
		'strategies': json2.Any(r.strategies.map(json2.Any(it.id)))
	}, AppendOpts{ actor: 'kernel' })

	mut cancel := new_cancel_flag()
	mut done := new_cancel_flag()
	if timeout > 0 {
		spawn arm_deadline(mut cancel, mut done, timeout)
	}

	mut winner_idx := -1
	for s in r.strategies {
		if elapsed_s(t0) >= timeout && timeout > 0 {
			break
		}
		started := time.now()
		mut outcome := UniverseOutcome{
			strategy: s.id
		}
		// a crashing universe loses the lane; it does not end the race
		out := r.runner(s, t, cancel) or {
			outcome.result = 'ERROR: ${err.msg()}'
			outcome.elapsed_ms = int((time.now() - started).milliseconds())
			result.outcomes << outcome
			if cancel.is_set() && elapsed_s(t0) >= timeout && timeout > 0 {
				break
			}
			continue
		}
		outcome.result = out
		outcome.elapsed_ms = int((time.now() - started).milliseconds())
		if cancel.is_set() && timeout > 0 && elapsed_s(t0) >= timeout {
			result.outcomes << outcome
			break
		}
		// a verifier that raises fails the lane rather than the race
		outcome.passed = r.verifier(t, outcome.result) or {
			outcome.result = 'VERIFIER ERROR: ${err.msg()}'
			false
		}
		result.outcomes << outcome
		if outcome.passed {
			winner_idx = result.outcomes.len - 1
			cancel.set()
			break
		}
	}
	done.set()

	// every lane after the winner, or after the deadline, never ran
	mut landed := map[string]bool{}
	for o in result.outcomes {
		landed[o.strategy] = true
	}
	for s in r.strategies {
		if !landed[s.id] {
			result.outcomes << UniverseOutcome{
				strategy:  s.id
				cancelled: true
			}
		}
	}

	if winner_idx >= 0 {
		result.winner = result.outcomes[winner_idx].strategy
		result.answer = result.outcomes[winner_idx].result
	} else {
		// nobody passed: surface the least-bad failure as evidence. A lane
		// that ran beats one that was cancelled, and the quickest of those
		// is the one with the least to explain.
		mut ranked := result.outcomes.clone()
		ranked.sort_with_compare(fn (a &UniverseOutcome, b &UniverseOutcome) int {
			if a.cancelled != b.cancelled {
				return if a.cancelled { 1 } else { -1 }
			}
			if a.elapsed_ms < b.elapsed_ms {
				return -1
			}
			if a.elapsed_ms > b.elapsed_ms {
				return 1
			}
			return 0
		})
		if ranked.len > 0 {
			result.answer = ranked[0].result
		}
	}
	result.elapsed_ms = int((time.now() - t0).milliseconds())
	r.log.append(if winner_idx >= 0 { 'race.winner' } else { 'race.cancel' }, result.to_json(),
		AppendOpts{ actor: 'kernel' })
	return result
}

// arm_deadline sets the cancel flag once the timeout passes. It polls a
// second flag so the thread goes away as soon as the race does, rather than
// sleeping out a five-minute timeout after a race that took a second.
fn arm_deadline(mut cancel CancelFlag, mut done CancelFlag, timeout f64) {
	deadline := time.now().add(time.Duration(i64(timeout * f64(time.second))))
	for time.now() < deadline {
		if done.is_set() {
			return
		}
		time.sleep(10 * time.millisecond)
	}
	if !done.is_set() {
		cancel.set()
	}
}

fn elapsed_s(t0 time.Time) f64 {
	return (time.now() - t0).seconds()
}

pub fn (r &RacingUniverses) format(result &RaceResult) string {
	head := if result.winner != '' { result.winner } else { 'NONE (best failure shown)' }
	mut lines := ['RACE — ${result.task}', '  winner: ${head} · ${result.elapsed_ms}ms']
	for o in result.outcomes {
		icon := if o.passed { '✓' } else if o.cancelled { '⊘' } else { '✗' }
		lines << '  ${icon} [${o.strategy}] ${o.elapsed_ms}ms · ${clip_plain(o.result, 120)}'
	}
	if result.answer != '' {
		lines << '  ANSWER: ' + clip_plain(result.answer, 800)
	}
	return lines.join('\n')
}
