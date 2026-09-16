module vagent

import time
import x.json2

// fabric.v — the bitemporal knowledge graph: facts with a lifespan.
//
// A normal knowledge base answers "what is true NOW". This one answers both
// that and "what did we know THEN", along two independent time axes:
//
//   valid time        when the fact was true in the WORLD
//   transaction time  when the fact entered the FABRIC
//
// Asserting a fact that contradicts a live one on the same (subject,
// predicate) does not delete the old one — it CLOSES its valid-time at the
// new fact's start. The old truth expired; it was never wrong to have
// believed it, and the fabric can still say what it believed and when.
//
// Every assert and every expiry is a sealed kernel event, so the knowledge
// base's own history is replayable in the Theater like anything else.

// fabric_forever is a valid_to that never arrives. V has no `math.inf` that
// survives a JSON round-trip, so an open-ended fact is written as null and
// read back as this.
pub const fabric_forever = f64(1e308) * 10.0

pub struct Fact {
pub mut:
	subject    string
	predicate  string
	obj        string
	valid_from f64
	valid_to   f64 = fabric_forever
	txn_time   f64
	confidence f64 = 1.0
	// the fact that replaced this one, if any
	superseded_by string
}

// fid identifies a fact by what it says, not by when it was said.
pub fn (f &Fact) fid() string {
	return '${f.subject}|${f.predicate}|${f.obj}'
}

// live reports whether the fact's valid-time window contains `at`. The
// window is half-open: a fact that expires at t is not live at t, which is
// what lets a replacement start at exactly the same instant.
pub fn (f &Fact) live(at f64) bool {
	return f.valid_from <= at && at < f.valid_to
}

pub fn (f &Fact) live_now() bool {
	return f.live(now_ts())
}

pub fn (f &Fact) to_json() map[string]json2.Any {
	return {
		's':          json2.Any(f.subject)
		'p':          json2.Any(f.predicate)
		'o':          json2.Any(f.obj)
		'valid_from': json2.Any(f.valid_from)
		'valid_to':   if f.valid_to == fabric_forever {
			json2.null
		} else {
			json2.Any(f.valid_to)
		}
		'txn':        json2.Any(round_to(f.txn_time, 3))
		'confidence': json2.Any(f.confidence)
	}
}

@[heap]
pub struct KnowledgeFabric {
pub mut:
	log   &EventLog
	facts []Fact
}

pub fn new_knowledge_fabric(log &EventLog) &KnowledgeFabric {
	return &KnowledgeFabric{
		log: unsafe { log }
	}
}

pub struct AssertOpts {
pub:
	// `none` means "true from now"
	valid_from ?f64
	confidence f64 = 1.0
}

// assert_fact records (subject, predicate, object).
//
// Any live fact on the same (subject, predicate) carrying a DIFFERENT object
// expires at this fact's start. A fact whose window has not opened yet
// expires nothing — it is not competing for the present.
pub fn (mut k KnowledgeFabric) assert_fact(subject string, predicate string, obj string, opts AssertOpts) !Fact {
	s := subject.trim_space()
	p := predicate.trim_space()
	o := obj.trim_space()
	if s == '' || p == '' || o == '' {
		return error('subject, predicate and object are all required')
	}
	now := now_ts()
	start := opts.valid_from or { now }
	fact := Fact{
		subject:    s
		predicate:  p
		obj:        o
		valid_from: start
		txn_time:   now
		confidence: opts.confidence
	}
	cut := if now > start { now } else { start }
	for i, old in k.facts {
		if old.subject == s && old.predicate == p && old.obj != o && old.live(cut)
			&& old.valid_to == fabric_forever {
			k.facts[i].valid_to = cut
			k.facts[i].superseded_by = fact.fid()
			k.log.append('fabric.retract', {
				'retracted': json2.Any(k.facts[i].to_json())
				'reason':    json2.Any('superseded')
				'by':        json2.Any(fact.fid())
			}, AppendOpts{ actor: 'kernel' })
		}
	}
	k.facts << fact
	k.log.append('fabric.assert', fact.to_json(), AppendOpts{ actor: 'sovereign' })
	return fact
}

// -- reads -------------------------------------------------------------------

// query is every fact for (subject, predicate) live at `at`, oldest first.
pub fn (k &KnowledgeFabric) query(subject string, predicate string, at f64) []Fact {
	mut out := []Fact{}
	for f in k.facts {
		if f.subject == subject && f.predicate == predicate && f.live(at) {
			out << f
		}
	}
	out.sort(a.valid_from < b.valid_from)
	return out
}

pub fn (k &KnowledgeFabric) query_now(subject string, predicate string) []Fact {
	return k.query(subject, predicate, now_ts())
}

// ask is the single answer: the most recently valid of the live facts, or
// '' when the fabric knows nothing.
pub fn (k &KnowledgeFabric) ask(subject string, predicate string, at f64) string {
	hits := k.query(subject, predicate, at)
	return if hits.len > 0 { hits.last().obj } else { '' }
}

pub fn (k &KnowledgeFabric) ask_now(subject string, predicate string) string {
	return k.ask(subject, predicate, now_ts())
}

// since is everything learned after a transaction time — what is new since
// the caller last looked.
pub fn (k &KnowledgeFabric) since(txn_time f64) []Fact {
	return k.facts.filter(it.txn_time > txn_time)
}

pub fn (k &KnowledgeFabric) live_all() []Fact {
	now := now_ts()
	return k.facts.filter(it.live(now))
}

pub struct Contradiction {
pub:
	a Fact
	b Fact
}

// contradictions are live facts on the same (subject, predicate) with
// different objects. Ordinary asserts cannot produce one — the expiry above
// prevents it — so this can only come from overlapping valid-times, such as
// a future-dated fact meeting a present-dated rival. It is surfaced rather
// than resolved, because which one is right is not the fabric's call.
pub fn (k &KnowledgeFabric) contradictions(at f64) []Contradiction {
	live := k.facts.filter(it.live(at))
	mut out := []Contradiction{}
	for i, a in live {
		for b in live[i + 1..] {
			if a.subject == b.subject && a.predicate == b.predicate && a.obj != b.obj {
				out << Contradiction{
					a: a
					b: b
				}
			}
		}
	}
	return out
}

pub fn (k &KnowledgeFabric) contradictions_now() []Contradiction {
	return k.contradictions(now_ts())
}

// -- reporting ---------------------------------------------------------------

pub fn (k &KnowledgeFabric) history(subject string, predicate string) string {
	mut rows := k.facts.filter(it.subject == subject && it.predicate == predicate)
	if rows.len == 0 {
		return 'no history for ${subject}·${predicate}'
	}
	rows.sort(a.valid_from < b.valid_from)
	mut lines := ['HISTORY — ${subject} ${predicate}:']
	for f in rows {
		vfrom := stamp_minute(f.valid_from)
		state := if f.live_now() {
			'live'
		} else if f.valid_to == fabric_forever {
			'not yet valid'
		} else {
			'expired @ ' + stamp_minute(f.valid_to)
		}
		lines << '  ${f.obj:-30} valid from ${vfrom} — ${state}  (conf ${f.confidence:.2f})'
	}
	return lines.join('\n')
}

fn stamp_minute(ts f64) string {
	t := time.unix(i64(ts))
	return '${t.year:04}-${t.month:02}-${t.day:02} ${t.hour:02}:${t.minute:02}'
}
