module vagent

import math
import time
import x.json2

// mcts.v — Tree-of-Agents: Monte Carlo Tree Search over strategies.
//
// When a goal admits several strategies — which role attacks which item, in
// what approach — a linear agent picks one and hopes. This explores the
// space instead:
//
//   select      descend fully-expanded nodes by UCB1, balancing proven
//               value against uncertain branches
//   expand      add one untried (item, strategy) choice at the frontier
//   simulate    complete the remaining items at random and score the whole
//               assignment with the injected evaluator
//   backprop    the score flows back up the path that was selected
//
// The evaluator is injected: production scores a real but cheap worker run,
// the tests score a synthetic objective with a known optimum and prove the
// search finds it.
//
// One documented difference from the original: the randomness. CPython's
// `random.Random(seed)` is a Mersenne Twister, and reproducing its exact
// stream in V would be a large amount of code in service of nothing — what
// the search needs is that the SAME seed gives the SAME search, so a run can
// be replayed and audited. The generator below is seeded, deterministic and
// self-contained, and the tests assert exactly that property.

// exploration is sqrt(2), the classic UCB1 constant.
pub const exploration = 1.41

pub struct Choice {
pub:
	item     int
	strategy string
}

@[heap]
pub struct StrategyNode {
pub mut:
	// item index -> strategy id; a partial assignment is a partial strategy
	assignment map[int]string
	parent     &StrategyNode = unsafe { nil }
	children   []&StrategyNode
	visits     int
	value      f64
	untried    []Choice
}

// ucb1 is a node's attractiveness. An unvisited node is infinitely
// attractive, which is what forces the search to try everything once before
// it starts preferring anything.
pub fn (n &StrategyNode) ucb1(c f64) f64 {
	if n.visits == 0 {
		return math.inf(1)
	}
	if isnil(n.parent) || n.parent.visits == 0 {
		return n.value / f64(n.visits)
	}
	return n.value / f64(n.visits) +
		c * math.sqrt(math.log(f64(n.parent.visits)) / f64(n.visits))
}

pub fn (n &StrategyNode) best_child() &StrategyNode {
	mut best := n.children[0]
	mut best_score := best.ucb1(exploration)
	for child in n.children[1..] {
		s := child.ucb1(exploration)
		if s > best_score {
			best = child
			best_score = s
		}
	}
	return best
}

pub struct SearchReport {
pub mut:
	best_assignment map[int]string
	best_score      f64
	iterations      int
	nodes           int
	depth           int
	elapsed_ms      int
}

pub fn (r &SearchReport) to_json() map[string]json2.Any {
	mut assign := map[string]json2.Any{}
	for k, v in r.best_assignment {
		assign[k.str()] = json2.Any(v)
	}
	return {
		'best_assignment': json2.Any(assign)
		'best_score':      json2.Any(round_to(r.best_score, 4))
		'iterations':      json2.Any(r.iterations)
		'nodes':           json2.Any(r.nodes)
		'depth':           json2.Any(r.depth)
		'elapsed_ms':      json2.Any(r.elapsed_ms)
	}
}

// MctsEvaluator scores a complete assignment in [0, 1]. It is called once
// per iteration, so it has to be cheap — that is the whole point of a
// rollout.
pub type MctsEvaluator = fn (assignment map[int]string) f64

@[heap]
pub struct TreeSearch {
pub mut:
	log       &EventLog
	evaluator MctsEvaluator
	rng       Rng
}

pub fn new_tree_search(log &EventLog, evaluator MctsEvaluator, seed u64) &TreeSearch {
	return &TreeSearch{
		log:       unsafe { log }
		evaluator: evaluator
		rng:       new_rng(seed)
	}
}

// search finds the best item -> strategy assignment it can within
// `iterations` rollouts or `deadline_s` seconds, whichever comes first.
pub fn (mut t TreeSearch) search(items []string, strategies []string, iterations int, deadline_s f64) SearchReport {
	t0 := time.now()
	if items.len == 0 || strategies.len == 0 {
		return SearchReport{}
	}

	mut root := &StrategyNode{
		untried: strategies.map(Choice{
			item:     0
			strategy: it
		})
	}
	mut best := map[int]string{}
	// the evaluator's range is [0, 1], so zero is a real floor rather than a
	// sentinel that could leak into a report
	mut best_score := 0.0
	mut it := 0

	for it < iterations && (time.now() - t0).seconds() < deadline_s {
		it++
		mut node := root

		// SELECT — descend fully-expanded nodes by UCB1
		for node.untried.len == 0 && node.children.len > 0 {
			node = node.best_child()
		}

		// EXPAND — take one untried choice at the frontier
		if node.untried.len > 0 {
			idx := t.rng.below(node.untried.len)
			choice := node.untried[idx]
			node.untried.delete(idx)
			mut assignment := node.assignment.clone()
			assignment[choice.item] = choice.strategy
			mut child := &StrategyNode{
				assignment: assignment
				parent:     node
			}
			if choice.item + 1 < items.len {
				child.untried = strategies.map(Choice{
					item:     choice.item + 1
					strategy: it
				})
			}
			node.children << child
			node = child
		}

		// SIMULATE — complete the remaining items at random
		mut assignment := node.assignment.clone()
		for i := assignment.len; i < items.len; i++ {
			assignment[i] = strategies[t.rng.below(strategies.len)]
		}
		score := t.evaluator(assignment)

		// BACKPROPAGATE — the score flows up the path that was selected
		mut walk := node
		for !isnil(walk) {
			walk.visits++
			walk.value += score
			walk = walk.parent
		}

		if score > best_score {
			best_score = score
			best = assignment.clone()
		}
	}

	mut nodes := 0
	mut depth := 0
	mut stack := [root]
	for stack.len > 0 {
		n := stack.pop()
		nodes++
		if n.assignment.len > depth {
			depth = n.assignment.len
		}
		for child in n.children {
			stack << child
		}
	}

	report := SearchReport{
		best_assignment: best
		best_score:      best_score
		iterations:      it
		nodes:           nodes
		depth:           depth
		elapsed_ms:      int((time.now() - t0).milliseconds())
	}
	t.log.append('mcts.search', report.to_json(), AppendOpts{ actor: 'kernel' })
	return report
}

// ---------------------------------------------------------------------------
// The generator
// ---------------------------------------------------------------------------

// Rng is a seeded splitmix64. It is here rather than in `rand` because the
// search must be replayable: a global generator shared with anything else in
// the process would make the same seed give a different search.
pub struct Rng {
pub mut:
	state u64
}

pub fn new_rng(seed u64) Rng {
	// a zero seed would keep splitmix64 at zero forever
	return Rng{
		state: if seed == 0 { u64(0x9e3779b97f4a7c15) } else { seed }
	}
}

pub fn (mut r Rng) next() u64 {
	r.state += 0x9e3779b97f4a7c15
	mut z := r.state
	z = (z ^ (z >> 30)) * 0xbf58476d1ce4e5b9
	z = (z ^ (z >> 27)) * 0x94d049bb133111eb
	return z ^ (z >> 31)
}

// below returns a value in [0, n). It is unbiased by rejection rather than
// by modulo, because a modulo over a non-power-of-two range favours the low
// values and a biased search is not the search that was asked for.
pub fn (mut r Rng) below(n int) int {
	if n <= 0 {
		return 0
	}
	bound := u64(n)
	limit := u64(0xffffffffffffffff) - (u64(0xffffffffffffffff) % bound) - 1
	for {
		v := r.next()
		if v <= limit {
			return int(v % bound)
		}
	}
	return 0
}

pub fn (mut r Rng) f64() f64 {
	return f64(r.next() >> 11) / f64(u64(1) << 53)
}
