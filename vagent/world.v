module vagent

import math
import os
import x.json2

// world.v — the predictive model of the project: what breaks if I touch this?
//
// A static dependency graph says "these files import that one". This says
// "when auth.py changed, tests/auth_test.py broke four times out of five" —
// impact with LEARNED probabilities:
//
//   edges    from three signals: static imports, co-change history (files
//            written in the same turn), and failure co-occurrence (files
//            touched in turns that later errored)
//   risk     each edge carries times_seen and times_broken, and
//            P(break | touch upstream) is Laplace-smoothed, so small data
//            is honestly unsure rather than overconfident
//   predict  every downstream file ranked by edge probability × distance
//            decay, because a direct neighbour hurts more than a
//            transitive one
//   learn    each finished turn updates the stats, so the model sharpens
//            with every real session and spends no tokens doing it

const world_decay = 0.55
const world_max_hops = 3
// Laplace smoothing
const world_alpha = 1.0

pub struct Edge {
pub mut:
	src string
	dst string
	// co-change and dependency observations
	seen int = 1
	// times dst failed in a turn where src changed
	broken int
}

// risk is the Laplace-smoothed P(break | src touched). With one
// observation it sits near a half rather than at zero or one, which is the
// honest answer when almost nothing is known.
pub fn (e &Edge) risk() f64 {
	return (f64(e.broken) + world_alpha) / (f64(e.seen) + 2.0 * world_alpha)
}

pub fn (e &Edge) to_json() map[string]json2.Any {
	return {
		'src':    json2.Any(e.src)
		'dst':    json2.Any(e.dst)
		'seen':   json2.Any(e.seen)
		'broken': json2.Any(e.broken)
		'risk':   json2.Any(round_to(e.risk(), 3))
	}
}

pub struct ImpactRow {
pub:
	path        string
	probability f64
	via         string
}

pub fn (r &ImpactRow) to_json() map[string]json2.Any {
	return {
		'path':        json2.Any(r.path)
		'probability': json2.Any(round_to(r.probability, 3))
		'via':         json2.Any(r.via)
	}
}

pub struct Impact {
pub:
	path   string
	ranked []ImpactRow
}

pub fn (i &Impact) format() string {
	if i.ranked.len == 0 {
		return 'no known dependants of ${i.path}'
	}
	mut lines := ['IMPACT — touching ${i.path}:']
	for r in i.ranked {
		bars := '█'.repeat(max_int(1, int(r.probability * 10.0)))
		lines << '  ' + pad_width(r.path, 28) + ' ${r.probability * 100.0:.0f}% ${bars}  (via ${r.via})'
	}
	return lines.join('\n')
}

@[heap]
pub struct WorldModel {
pub mut:
	log  &EventLog
	root string
	// keyed 'src\x00dst', so the pair is one map key
	edges map[string]Edge
	// insertion order, because a V map's iteration order is not stable and
	// the ranking must be reproducible
	edge_order []string
}

pub fn new_world_model(log &EventLog, root string) &WorldModel {
	mut w := &WorldModel{
		log:  unsafe { log }
		root: root
	}
	if root != '' {
		w.scan_imports()
	}
	return w
}

fn edge_key(src string, dst string) string {
	return '${src}\x00${dst}'
}

// -- the static signal -------------------------------------------------------

// scan_imports adds an edge wherever one file imports another in the same
// project. It is pure regex — fast, language-tolerant, and it never executes
// what it reads.
fn (mut w WorldModel) scan_imports() {
	mut files := []string{}
	for p in walk_files(w.root, 200_000) {
		if !p.ends_with('.py') {
			continue
		}
		if rel_to(w.root, p).split('/').contains('.git') {
			continue
		}
		files << p
	}
	mut modules := map[string]string{}
	for p in files {
		rel := rel_to(w.root, p)
		if rel == '' {
			continue
		}
		stem := os.base(p).all_before_last('.')
		modules[stem] = rel
	}
	re := compile_regex(r'(?m)^\s*(?:from|import)\s+([a-zA-Z0-9_.]+)') or { return }
	for f in files {
		rel := rel_to(w.root, f)
		if rel == '' {
			continue
		}
		text := read_text_or_empty(f)
		for m in re.find_all(text) {
			module_name := group_text(text, &m, 1).all_before('.')
			target := modules[module_name] or { continue }
			if target == rel {
				continue
			}
			// the edge direction is the IMPACT direction: touching the
			// imported module affects its importer
			w.bump_seen(target, rel)
		}
	}
}

fn (mut w WorldModel) edge_of(src string, dst string) Edge {
	key := edge_key(src, dst)
	if key !in w.edges {
		w.edges[key] = Edge{
			src: src
			dst: dst
		}
		w.edge_order << key
	}
	return w.edges[key]
}

fn (mut w WorldModel) bump_seen(src string, dst string) {
	w.edge_of(src, dst)
	key := edge_key(src, dst)
	mut e := w.edges[key]
	e.seen++
	w.edges[key] = e
}

fn (mut w WorldModel) bump_broken(src string, dst string) {
	key := edge_key(src, dst)
	mut e := w.edges[key]
	e.broken++
	w.edges[key] = e
}

pub fn (w &WorldModel) edge(src string, dst string) ?Edge {
	return w.edges[edge_key(src, dst)] or { return none }
}

// -- the learned signals -----------------------------------------------------

// observe_turn ingests one finished turn: which files changed, and which
// later failed. Co-changes strengthen an edge; failures charge it.
pub fn (mut w WorldModel) observe_turn(changed []string, failures []string, dependants []string) {
	for src in changed {
		targets := if dependants.len > 0 { dependants.clone() } else { w.static_dependants(src) }
		for dst in targets {
			if dst == src {
				continue
			}
			w.bump_seen(src, dst)
			if dst in failures {
				w.bump_broken(src, dst)
			}
		}
	}
	mut sorted_failures := uniq_strings(failures)
	sorted_failures.sort()
	w.log.append('world.learn', {
		'changed':  json2.Any(changed[..min_int(10, changed.len)].map(json2.Any(it)))
		'failures': json2.Any(sorted_failures[..min_int(10, sorted_failures.len)].map(json2.Any(it)))
	}, AppendOpts{})
}

// static_dependants are the files that depend on `path` — the dst side of
// its impact edges.
pub fn (w &WorldModel) static_dependants(path string) []string {
	mut out := []string{}
	for key in w.edge_order {
		e := w.edges[key] or { continue }
		if e.src == path {
			out << e.dst
		}
	}
	return out
}

struct TurnTrace {
mut:
	changed []string
	failed  []string
}

// learn_from_log rebuilds the learned stats from kernel history: turns where
// files were written and tool errors followed.
pub fn (mut w WorldModel) learn_from_log() int {
	mut turns := []TurnTrace{}
	mut current := TurnTrace{}
	mut open := false
	for ev in w.log.events(w.log.branch) {
		if ev.typ == 'user.message' {
			if open {
				turns << current
			}
			current = TurnTrace{}
			open = true
			continue
		}
		if !open {
			continue
		}
		match ev.typ {
			'tool.call' {
				name := jstr(ev.data, 'name')
				if name == 'write_file' || name == 'edit_file' {
					args := jmap(ev.data, 'args')
					p := jstr(args, 'path')
					if p != '' {
						current.changed << p
					}
				}
			}
			'tool.result' {
				if jstr(ev.data, 'status') == 'error' {
					current.failed << current.changed
				}
			}
			else {}
		}
	}
	if open {
		turns << current
	}
	mut learned := 0
	for t in turns {
		if t.changed.len > 0 {
			w.observe_turn(t.changed, t.failed, [])
			learned++
		}
	}
	return learned
}

// -- prediction --------------------------------------------------------------

struct Frontier {
	path string
	hops int
}

// predict_impact walks the edges out from `path` and ranks every downstream
// file by probability × hop decay.
pub fn (mut w WorldModel) predict_impact(path string) Impact {
	mut frontier := [Frontier{
		path: path
		hops: 0
	}]
	mut seen := map[string]bool{}
	seen[path] = true
	mut best := map[string]f64{}
	mut via := map[string]string{}
	mut order := []string{}

	for frontier.len > 0 {
		cur := frontier[0]
		frontier.delete(0)
		if cur.hops >= world_max_hops {
			continue
		}
		for key in w.edge_order {
			e := w.edges[key] or { continue }
			if e.src != cur.path || seen[e.dst] {
				continue
			}
			seen[e.dst] = true
			p := e.risk() * math.pow(world_decay, f64(cur.hops))
			label := if cur.hops == 0 { 'direct' } else { '${cur.hops + 1} hops' }
			if e.dst !in best || p > best[e.dst] {
				if e.dst !in best {
					order << e.dst
				}
				best[e.dst] = p
				via[e.dst] = label
			}
			frontier << Frontier{
				path: e.dst
				hops: cur.hops + 1
			}
		}
	}

	mut rows := []ImpactRow{}
	for p in order {
		rows << ImpactRow{
			path:        p
			probability: round_to(best[p], 3)
			via:         via[p]
		}
	}
	rows.sort(a.probability > b.probability)
	top := rows[..min_int(12, rows.len)].clone()
	w.log.append('world.impact', {
		'path': json2.Any(path)
		'top':  json2.Any(top[..min_int(5, top.len)].map(json2.Any(it.to_json())))
	}, AppendOpts{ actor: 'kernel' })
	return Impact{
		path:   path
		ranked: top
	}
}

pub fn (w &WorldModel) stats() map[string]json2.Any {
	mut risky := 0
	for _, e in w.edges {
		if e.risk() > 0.5 {
			risky++
		}
	}
	return {
		'edges': json2.Any(w.edges.len)
		'risky': json2.Any(risky)
	}
}
