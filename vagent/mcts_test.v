module vagent

import math

const mcts_items = ['parser', 'docs', 'tests', 'deploy']
const mcts_strategies = ['A', 'B', 'C', 'D']

// the objective: item i must take strategy i. The optimum is 1.0.
fn mcts_evaluator(assignment map[int]string) f64 {
	mut correct := 0
	for i in 0 .. mcts_items.len {
		if assignment[i] == mcts_strategies[i] {
			correct++
		}
	}
	return f64(correct) / f64(mcts_items.len)
}

fn mcts_log(name string) &EventLog {
	return new_event_log(tmp_log_path(name), 'main', 'test')
}

fn test_the_search_finds_a_known_optimum() {
	mut ts := new_tree_search(mcts_log('mcts1'), mcts_evaluator, 11)
	r := ts.search(mcts_items, mcts_strategies, 400, 10.0)
	assert r.best_score == 1.0, '${r.best_score}'
	for i in 0 .. mcts_items.len {
		assert r.best_assignment[i] == mcts_strategies[i]
	}
	assert r.iterations >= 100
	assert r.nodes > 4
	// the tree actually branched all the way down
	assert r.depth == 4, '${r.depth}'
}

fn test_the_same_seed_gives_the_same_search() {
	mut a := new_tree_search(mcts_log('mcts2a'), mcts_evaluator, 11)
	mut b := new_tree_search(mcts_log('mcts2b'), mcts_evaluator, 11)
	ra := a.search(mcts_items, mcts_strategies, 200, 10.0)
	rb := b.search(mcts_items, mcts_strategies, 200, 10.0)
	assert ra.best_assignment == rb.best_assignment
	assert ra.best_score == rb.best_score
	assert ra.nodes == rb.nodes

	// and a different seed is free to search differently
	mut c := new_tree_search(mcts_log('mcts2c'), mcts_evaluator, 12)
	rc := c.search(mcts_items, mcts_strategies, 20, 10.0)
	assert rc.iterations == 20
}

fn test_the_deadline_is_respected() {
	mut ts := new_tree_search(mcts_log('mcts3'), mcts_evaluator, 3)
	mut many := []string{}
	for _ in 0 .. 10 {
		many << mcts_items
	}
	r := ts.search(many, mcts_strategies, 10_000_000, 0.5)
	assert r.elapsed_ms < 1500, '${r.elapsed_ms}'
	assert r.iterations < 10_000_000
}

fn test_empty_inputs_are_clean() {
	mut ts := new_tree_search(mcts_log('mcts4'), mcts_evaluator, 7)
	empty := ts.search([], ['A'], 10, 1.0)
	assert empty.best_assignment.len == 0
	assert empty.best_score == 0.0
	assert empty.nodes == 0
	no_strategies := ts.search(['x'], [], 10, 1.0)
	assert no_strategies.iterations == 0
}

fn test_an_unvisited_node_is_infinitely_attractive() {
	mut parent := &StrategyNode{
		visits: 10
		value:  6.0
	}
	mut fresh := &StrategyNode{
		parent: parent
	}
	assert fresh.ucb1(exploration) == math.inf(1)
	mut proven := &StrategyNode{
		parent: parent
		visits: 9
		value:  6.0
	}
	assert proven.ucb1(exploration) > 0
	parent.children = [fresh, proven]
	assert voidptr(parent.best_child()) == voidptr(fresh)

	// a root with no parent scores on its own average
	root := &StrategyNode{
		visits: 4
		value:  2.0
	}
	assert root.ucb1(exploration) == 0.5
}

fn test_every_search_is_sealed_in_the_log() {
	mut log := mcts_log('mcts5')
	mut ts := new_tree_search(log, mcts_evaluator, 5)
	ts.search(mcts_items, mcts_strategies, 50, 5.0)
	events := log.events('main')
	assert events.any(it.typ == 'mcts.search')
	last := events.filter(it.typ == 'mcts.search').last()
	assert jint(last.data, 'iterations') == 50
	assert jmap(last.data, 'best_assignment').len > 0
}

fn test_the_generator_is_seeded_uniform_and_in_range() {
	mut a := new_rng(42)
	mut b := new_rng(42)
	for _ in 0 .. 100 {
		assert a.next() == b.next()
	}
	mut c := new_rng(43)
	mut d := new_rng(42)
	assert c.next() != d.next()

	// a zero seed is not a stuck generator
	mut z := new_rng(0)
	assert z.next() != z.next()

	mut r := new_rng(9)
	mut counts := []int{len: 5, init: 0}
	for _ in 0 .. 5000 {
		v := r.below(5)
		assert v >= 0 && v < 5
		counts[v]++
	}
	// each bucket lands within a wide band of its expected 1000
	for n in counts {
		assert n > 800 && n < 1200, '${counts}'
	}
	assert r.below(0) == 0
	assert r.below(1) == 0

	mut f := new_rng(1)
	for _ in 0 .. 1000 {
		v := f.f64()
		assert v >= 0.0 && v < 1.0
	}
}
