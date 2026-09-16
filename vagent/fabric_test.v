module vagent


import x.json2
import time
fn fabric_of(name string) &KnowledgeFabric {
	return new_knowledge_fabric(new_event_log(tmp_log_path(name), 'main', 'test'))
}

fn test_a_contradicting_fact_expires_its_predecessor_rather_than_deleting_it() {
	mut f := fabric_of('fabric1')
	now := now_ts()
	t1 := now - 90.0 * 86400.0
	t2 := now - 30.0 * 86400.0

	// the dependency was flask, then became fastapi
	f.assert_fact('api', 'framework', 'flask', AssertOpts{ valid_from: t1 }) or { panic(err) }
	f.assert_fact('api', 'framework', 'fastapi', AssertOpts{ valid_from: t2 }) or { panic(err) }

	// now: fastapi. Sixty days ago: flask. Before either: nothing.
	assert f.ask_now('api', 'framework') == 'fastapi'
	assert f.ask('api', 'framework', t1 + 59.0 * 86400.0) == 'flask'
	assert f.ask('api', 'framework', t1 - 1.0) == ''

	// the expired fact is still there, with its provenance
	flask := f.facts.filter(it.obj == 'flask')[0]
	assert flask.valid_to != fabric_forever
	assert flask.superseded_by == 'api|framework|fastapi'
}

fn test_different_predicates_do_not_compete() {
	mut f := fabric_of('fabric2')
	t1 := now_ts() - 90.0 * 86400.0
	f.assert_fact('api', 'framework', 'fastapi', AssertOpts{ valid_from: t1 }) or { panic(err) }
	f.assert_fact('api', 'language', 'python', AssertOpts{ valid_from: t1 }) or { panic(err) }
	assert f.ask_now('api', 'language') == 'python'
	assert f.ask_now('api', 'framework') == 'fastapi'
	assert f.live_all().len == 2
}

fn test_a_future_dated_fact_expires_nothing_and_surfaces_its_contradiction() {
	mut f := fabric_of('fabric3')
	now := now_ts()
	tomorrow := now + 86400.0
	t1 := now - 90.0 * 86400.0

	// its window has not opened, so it cannot expire anything
	f.assert_fact('db', 'driver', 'postgres', AssertOpts{ valid_from: tomorrow }) or { panic(err) }
	assert f.contradictions_now().len == 0

	marker := now_ts()
	// the transaction clock has millisecond resolution, so step past it
	// before asking what is new — the original slept here for the same reason
	time.sleep(20 * time.millisecond)
	// and a present-dated rival cannot expire IT either
	f.assert_fact('db', 'driver', 'mysql', AssertOpts{ valid_from: t1 }) or { panic(err) }
	learned := f.since(marker)
	assert learned.len == 1, '${learned.len}'
	assert learned[0].obj == 'mysql'

	// tomorrow both are live, and that is reported rather than resolved
	cons := f.contradictions(tomorrow + 1.0)
	assert cons.len == 1
	assert cons[0].a.obj != cons[0].b.obj
}

fn test_history_renders_every_era() {
	mut f := fabric_of('fabric4')
	now := now_ts()
	f.assert_fact('api', 'framework', 'flask', AssertOpts{ valid_from: now - 90.0 * 86400.0 }) or {
		panic(err)
	}
	f.assert_fact('api', 'framework', 'fastapi', AssertOpts{ valid_from: now - 30.0 * 86400.0 }) or {
		panic(err)
	}
	f.assert_fact('api', 'framework', 'litestar', AssertOpts{ valid_from: now + 86400.0 }) or {
		panic(err)
	}
	text := f.history('api', 'framework')
	assert text.contains('flask')
	assert text.contains('fastapi')
	assert text.contains('expired')
	assert text.contains('live')
	assert text.contains('not yet valid')
	// oldest first
	assert text.index('flask') or { 0 } < text.index('fastapi') or { 0 }

	assert f.history('nothing', 'here') == 'no history for nothing·here'
}

fn test_every_part_of_a_fact_is_required() {
	mut f := fabric_of('fabric5')
	f.assert_fact('', 'x', 'y', AssertOpts{}) or {
		assert err.msg().contains('required')
		f.assert_fact('s', '  ', 'y', AssertOpts{}) or {
			f.assert_fact('s', 'p', '', AssertOpts{}) or {
				assert f.facts.len == 0
				return
			}
			assert false, 'an empty object must be rejected'
			return
		}
		assert false, 'a blank predicate must be rejected'
		return
	}
	assert false, 'an empty subject must be rejected'
}

fn test_whitespace_is_trimmed_off_every_part() {
	mut f := fabric_of('fabric6')
	f.assert_fact('  api ', ' framework ', ' fastapi ', AssertOpts{}) or { panic(err) }
	assert f.ask_now('api', 'framework') == 'fastapi'
}

fn test_both_writes_are_sealed_in_the_log() {
	mut log := new_event_log(tmp_log_path('fabric7'), 'main', 'test')
	mut f := new_knowledge_fabric(log)
	t1 := now_ts() - 100.0
	f.assert_fact('api', 'framework', 'flask', AssertOpts{ valid_from: t1 }) or { panic(err) }
	f.assert_fact('api', 'framework', 'fastapi', AssertOpts{}) or { panic(err) }
	kinds := log.events('main').map(it.typ)
	assert 'fabric.assert' in kinds
	assert 'fabric.retract' in kinds

	// an open-ended fact writes its end as null, not as a float nobody can
	// round-trip
	live := f.facts.last().to_json()
	assert live['valid_to'] or { json2.Any(0) } is json2.Null

	// while an expired one carries the instant it closed
	expired := f.facts[0].to_json()
	assert jf64(expired, 'valid_to') > 0.0
}
