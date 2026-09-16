module vagent

import math
import x.json2

// debate.v — a mixture-of-agents tournament with calibrated fusion.
//
// One model's answer is a guess; a tournament of models that must survive
// each other's critiques is an argument. Three rounds, all real model calls:
//
//     PROPOSAL    every participant answers independently and blind —
//                 nobody has seen another's answer yet
//     CHALLENGE   every participant sees ALL the proposals and attacks the
//                 weakest claims, their own included
//     REVISION    every participant revises its own answer in the light of
//                 every critique
//
// Fusion is deterministic: each final answer becomes a sparse token vector,
// answers cluster by pairwise cosine similarity, each cluster's weight is the
// calibration mass of its members times how tightly they agree, and the
// champion cluster's strongest member becomes the verdict — carrying the full
// dissent record rather than burying it.
//
// CALIBRATION is the tournament's memory. Every participant starts at 0.5
// trust; when a verdict is later confirmed or refuted, everyone on the
// winning side gains and the losing side decays, bounded and exponential.
// Over time the tournament learns which models to believe about what. Trust
// only WEIGHTS the fusion — it never vetoes it, so a well-trusted model
// cannot overrule a majority on its own.

const trust_min = 0.05
const trust_max = 0.95
const trust_rate = 0.25 // the exponential update rate
const cluster_threshold = 0.45 // cosine similarity for the same cluster
const default_trust = 0.5

// token_vector is the sparse bag-of-words vector (token → count).
pub fn token_vector(text string) map[string]int {
	mut out := map[string]int{}
	mut cur := []u8{}
	for c in text.to_lower() {
		if (c >= `a` && c <= `z`) || (c >= `0` && c <= `9`) {
			cur << c
			continue
		}
		if cur.len > 0 {
			tok := cur.bytestr()
			out[tok] = out[tok] + 1
			cur = []u8{}
		}
	}
	if cur.len > 0 {
		tok := cur.bytestr()
		out[tok] = out[tok] + 1
	}
	return out
}

// token_cosine is cosine similarity over two sparse token vectors.
pub fn token_cosine(a map[string]int, b map[string]int) f64 {
	if a.len == 0 || b.len == 0 {
		return 0.0
	}
	mut dot := 0.0
	mut na := 0.0
	for k, v in a {
		na += f64(v) * f64(v)
		dot += f64(v) * f64(b[k] or { 0 })
	}
	mut nb := 0.0
	for _, v in b {
		nb += f64(v) * f64(v)
	}
	na = math.sqrt(na)
	nb = math.sqrt(nb)
	if na == 0.0 || nb == 0.0 {
		return 0.0
	}
	return dot / (na * nb)
}

pub struct DebatePosition {
pub mut:
	model_id string
	answer   string
	critique string
	revised  string
	cluster  int = -1
}

// final is the answer the fusion actually judges: the revision when there was
// one, the original proposal otherwise.
pub fn (p &DebatePosition) final() string {
	return if p.revised != '' { p.revised } else { p.answer }
}

pub struct DebateResult {
pub mut:
	question       string
	verdict        string
	champion_model string
	clusters       [][]string
	positions      []DebatePosition
	dissent        []string
	rounds         int
}

pub fn (r &DebateResult) to_json() map[string]json2.Any {
	mut clusters := []json2.Any{}
	for c in r.clusters {
		clusters << json2.Any(strs_to_any(c))
	}
	mut dissent := r.dissent.clone()
	if dissent.len > 4 {
		dissent = dissent[..4].clone()
	}
	return {
		'question':       json2.Any(r.question)
		'verdict':        json2.Any(clip_plain(r.verdict, 600))
		'champion_model': json2.Any(r.champion_model)
		'clusters':       json2.Any(clusters)
		'rounds':         json2.Any(r.rounds)
		'dissent':        json2.Any(strs_to_any(dissent))
		'participants':   json2.Any(strs_to_any(r.positions.map(it.model_id)))
	}
}

// DebateSpeaker routes one prompt to one participant.
pub type DebateSpeaker = fn (model_id string, prompt string) string

@[heap]
pub struct DebateTournament {
pub mut:
	log     &EventLog
	speaker DebateSpeaker @[required]
	models  []string
	trust   map[string]f64
mut:
	// the cluster that won the last run, so confirm() can credit every
	// member that argued the winning position rather than only the champion
	champion_cluster map[string]bool
}

pub fn new_debate_tournament(log &EventLog, speaker DebateSpeaker, models []string) &DebateTournament {
	mut t := &DebateTournament{
		log:     unsafe { log }
		speaker: speaker
		models:  models.clone()
	}
	t.load_trust()
	return t
}

// -- calibration, persisted in the log and nowhere else -----------------------

fn (mut t DebateTournament) load_trust() {
	for ev in t.log.events(t.log.branch) {
		if ev.typ == 'debate.calibration' {
			t.trust[jstr(ev.data, 'model')] = jf64_or(ev.data, 'trust', default_trust)
		}
	}
}

pub fn (t &DebateTournament) calibration(model_id string) f64 {
	return t.trust[model_id] or { default_trust }
}

fn (mut t DebateTournament) update(model_id string, won bool) f64 {
	cur := t.calibration(model_id)
	target := if won { trust_max } else { trust_min }
	mut updated := cur + (target - cur) * trust_rate
	updated = max_f64(trust_min, min_f64(trust_max, updated))
	t.trust[model_id] = updated
	t.log.append('debate.calibration', {
		'model':     json2.Any(model_id)
		'trust':     json2.Any(round_to(updated, 4))
		'direction': json2.Any(if won { 'up' } else { 'down' })
	}, AppendOpts{})
	return updated
}

// -- the tournament -----------------------------------------------------------

// run is the full three-round tournament. Fewer rounds degrade gracefully:
// two drops the revision, one is plain parallel sampling.
pub fn (mut t DebateTournament) run(raw_question string, rounds int) DebateResult {
	question := raw_question.trim_space()
	mut result := DebateResult{
		question: question
		rounds:   0
	}
	if question == '' || t.models.len == 0 {
		return result
	}
	mut positions := t.models.map(DebatePosition{
		model_id: it
	})

	// round 1 — blind proposals
	for i in 0 .. positions.len {
		positions[i].answer = t.speaker(positions[i].model_id, 'Answer this question directly and concisely. Stand ' + 'alone: you will defend it in a tournament.\n\n' + 'QUESTION: ${question}')
	}
	result.rounds = 1
	mut answers := map[string]json2.Any{}
	for p in positions {
		answers[p.model_id] = json2.Any(clip_plain(p.answer, 200))
	}
	t.log.append('debate.round', {
		'n':       json2.Any(1)
		'kind':    json2.Any('proposal')
		'answers': json2.Any(answers)
	}, AppendOpts{})

	if rounds >= 2 && positions.len >= 2 {
		// round 2 — mutual critique: everybody sees everything
		others := positions.map('[${it.model_id}] says: ' + clip_plain(it.answer, 600)).join('\n\n')
		for i in 0 .. positions.len {
			positions[i].critique = t.speaker(positions[i].model_id, "QUESTION: ${question}\n\nThe tournament's proposals:\n${others}\n\n" + 'You are [${positions[i].model_id}]. Attack the weakest claims above — ' + 'including your own. Name concrete errors, missing cases, bad ' + 'assumptions. Max 120 words.')
		}
		result.rounds = 2
		mut critiques := map[string]json2.Any{}
		for p in positions {
			critiques[p.model_id] = json2.Any(clip_plain(p.critique, 200))
		}
		t.log.append('debate.round', {
			'n':         json2.Any(2)
			'kind':      json2.Any('critique')
			'critiques': json2.Any(critiques)
		}, AppendOpts{})
	}

	if rounds >= 3 && positions.len >= 2 {
		// round 3 — revision under fire, which is pointless without critiques
		all_critiques := positions.map('[${it.model_id}] critiques: ' + clip_plain(it.critique, 400)).join('\n\n')
		for i in 0 .. positions.len {
			positions[i].revised = t.speaker(positions[i].model_id, 'QUESTION: ${question}\n\nYour original answer: ' + clip_plain(positions[i].answer, 600) + "\n\nThe tournament's critiques:\n${all_critiques}\n\n" + 'Revise YOUR answer. Keep what survived the critique, fix what ' + 'did not. Final answer only.')
		}
		result.rounds = 3
		mut revised := map[string]json2.Any{}
		for p in positions {
			revised[p.model_id] = json2.Any(clip_plain(p.revised, 200))
		}
		t.log.append('debate.round', {
			'n':       json2.Any(3)
			'kind':    json2.Any('revision')
			'revised': json2.Any(revised)
		}, AppendOpts{})
	}

	verdict, champion, clusters, dissent := t.fuse(mut positions)
	result.positions = positions
	result.verdict = verdict
	result.champion_model = champion
	result.clusters = clusters
	result.dissent = dissent

	t.champion_cluster = map[string]bool{}
	if clusters.len > 0 {
		for m in clusters[0] {
			t.champion_cluster[m] = true
		}
	} else {
		t.champion_cluster[champion] = true
	}
	t.log.append('debate.verdict', result.to_json(), AppendOpts{ actor: 'kernel' })
	return result
}

// -- deterministic fusion ------------------------------------------------------

struct WeightedCluster {
	members []int
	weight  f64
	// the position the cluster was formed in, which breaks a weight tie the
	// same way every time
	order int
}

// fuse clusters the final answers by cosine similarity, weights each cluster
// by its calibration mass and how tightly it agrees, and picks the strongest
// member of the strongest cluster.
fn (mut t DebateTournament) fuse(mut positions []DebatePosition) (string, string, [][]string, []string) {
	mut finals := []string{}
	mut vecs := []map[string]int{}
	for p in positions {
		finals << p.final()
		vecs << token_vector(p.final())
	}

	// single-link clustering over the similarity threshold
	mut groups := [][]int{}
	for i in 0 .. vecs.len {
		mut placed := false
		for gi in 0 .. groups.len {
			mut near := false
			for j in groups[gi] {
				if token_cosine(vecs[i], vecs[j]) >= cluster_threshold {
					near = true
					break
				}
			}
			if near {
				groups[gi] << i
				placed = true
				break
			}
		}
		if !placed {
			groups << [i]
		}
	}

	mut weighted := []WeightedCluster{}
	for gi, g in groups {
		weighted << WeightedCluster{
			members: g.clone()
			weight:  t.cluster_weight(g, vecs, positions)
			order:   gi
		}
	}
	// Heaviest first, and ties keep the order the clusters were formed in.
	// V's sort is not specified to be stable, so the formation index is
	// carried explicitly rather than assumed.
	weighted.sort_with_compare(fn (a &WeightedCluster, b &WeightedCluster) int {
		if a.weight > b.weight {
			return -1
		}
		if a.weight < b.weight {
			return 1
		}
		return a.order - b.order
	})

	for ci, c in weighted {
		for i in c.members {
			positions[i].cluster = ci
		}
	}

	// the champion member is the highest-calibration model in the winning
	// cluster; a tie goes to the first, so the choice is reproducible
	champion_members := weighted[0].members
	mut best := champion_members[0]
	for i in champion_members {
		if t.calibration(positions[i].model_id) > t.calibration(positions[best].model_id) {
			best = i
		}
	}

	mut dissent := []string{}
	if weighted.len > 1 {
		other := weighted[1].members
		mut top_other := other[0]
		for i in other {
			if t.calibration(positions[i].model_id) > t.calibration(positions[top_other].model_id) {
				top_other = i
			}
		}
		dissent << '[${positions[top_other].model_id}] dissents: ' + clip_plain(finals[top_other], 300)
	}

	mut names := [][]string{}
	for c in weighted {
		names << c.members.map(positions[it].model_id)
	}
	return finals[best], positions[best].model_id, names, dissent
}

// cluster_weight is the calibration mass of a cluster times how tightly its
// members actually agree — a large cluster of near-misses should not outweigh
// a small one that says the same thing twice.
fn (t &DebateTournament) cluster_weight(members []int, vecs []map[string]int, positions []DebatePosition) f64 {
	mut mass := 0.0
	for i in members {
		mass += t.calibration(positions[i].model_id)
	}
	if members.len < 2 {
		return mass
	}
	mut sims := []f64{}
	for a in members {
		for b in members {
			if a < b {
				sims << token_cosine(vecs[a], vecs[b])
			}
		}
	}
	mut tight := 1.0
	if sims.len > 0 {
		mut total := 0.0
		for s in sims {
			total += s
		}
		tight = total / f64(sims.len)
	}
	return mass * (0.5 + tight / 2.0)
}

// -- outcome feedback ----------------------------------------------------------

// confirm records that the verdict's cluster was RIGHT: its members gain
// trust and the dissenters decay.
pub fn (mut t DebateTournament) confirm(verdict_model string) map[string]f64 {
	mut winners := t.champion_cluster.clone()
	if winners.len == 0 || !winners[verdict_model] {
		// confirming a model that did not win its own cluster credits that
		// model alone rather than a cluster it never argued for
		winners = {
			verdict_model: true
		}
	}
	for m in t.models {
		t.update(m, winners[m])
	}
	return t.trust.clone()
}

// refute records that the dissent was right instead, flipping the flow of
// trust.
pub fn (mut t DebateTournament) refute(dissent_model string) map[string]f64 {
	for m in t.models {
		t.update(m, m == dissent_model)
	}
	return t.trust.clone()
}

// -- reporting -----------------------------------------------------------------

pub fn (t &DebateTournament) format(result &DebateResult) string {
	mut lines := [
		'DEBATE VERDICT — ${result.question}',
		'  champion: [${result.champion_model}] (${result.rounds} rounds, ' + '${result.positions.len} participants)',
		'  clusters: ' + result.clusters.map(it.join(', ')).join(' | '),
		'  VERDICT: ' + clip_plain(result.verdict, 1200),
	]
	for d in result.dissent {
		lines << '  ⚠ dissent — ${d}'
	}
	lines << '  calibration: ' + t.models.map('${it}=${t.calibration(it):.2f}').join(', ')
	lines << '  feedback: /debate confirm|refute <model-id>'
	return lines.join('\n')
}
