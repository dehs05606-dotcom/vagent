module vagent

import math
import x.json2

fn scripted_market_worker(task string, role string) !map[string]json2.Any {
	if task.contains('crash') {
		return {
			'status':     json2.Any('error')
			'summary':    json2.Any('could not reproduce')
			'tool_calls': json2.Any(9)
		}
	}
	if task.contains('blocked') {
		return {
			'status':     json2.Any('blocked')
			'summary':    json2.Any('needs credentials')
			'tool_calls': json2.Any(2)
		}
	}
	return {
		'status':     json2.Any('done')
		'summary':    json2.Any('${role} handled it')
		'tool_calls': json2.Any(4)
	}
}

fn exploding_market_worker(task string, role string) !map[string]json2.Any {
	return error('the worker never came back')
}

fn bid_roles(bids []Bid) []string {
	return bids.map(it.role)
}

fn test_the_task_text_decides_which_capability_is_wanted() {
	assert task_needs('write the new auth module') == ['write']
	assert task_needs('run the full test suite') == ['run']
	// a task naming nothing in particular is a reading task, open to all
	assert task_needs('the thing') == ['read']
	// several needs at once are all recognised
	needs := task_needs('research the latest release online and write it up')
	assert 'write' in needs
	assert 'read' in needs
	assert 'web' in needs
}

fn test_a_web_task_gates_out_every_role_without_web_tools() {
	mut log := new_event_log(tmp_log_path('mar1'), 'main', 'test')
	mut m := new_task_market(log, scripted_market_worker)
	web := m.auction('research the latest flask release online')
	assert web.awarded in ['researcher', 'analyst'], web.awarded
	// the gate is hard: a role with no web tools does not bid at all,
	// rather than bidding low and winning on trust some day
	for role in ['coder', 'refactorer', 'reviewer', 'tester', 'planner'] {
		assert role !in bid_roles(web.bids), role
	}
}

fn test_a_write_task_goes_to_a_role_that_can_actually_write() {
	mut log := new_event_log(tmp_log_path('mar2'), 'main', 'test')
	mut m := new_task_market(log, scripted_market_worker)
	c := m.auction('write the new auth module and its tests')
	assert c.awarded in ['coder', 'refactorer', 'integrator', 'architect', 'documenter', 'devops'], c.awarded
	assert c.status == 'done'
	assert jstr(c.report, 'summary').contains('handled it')
}

fn test_bids_are_ordered_deterministically() {
	mut log := new_event_log(tmp_log_path('mar3'), 'main', 'test')
	mut m := new_task_market(log, scripted_market_worker)
	bids := m.bid('analyze the system design')
	assert bids.len > 1
	for i in 1 .. bids.len {
		assert bids[i - 1].amount >= bids[i].amount
		if bids[i - 1].amount == bids[i].amount {
			// a tie breaks on trust and then on name, never on map order
			assert bids[i - 1].trust > bids[i].trust
				|| (bids[i - 1].trust == bids[i].trust && bids[i - 1].role < bids[i].role)
		}
	}
	// two bids over an unchanged market agree exactly
	assert bid_roles(m.bid('analyze the system design')) == bid_roles(bids)
}

fn test_a_failed_contract_sinks_the_role_that_failed_it() {
	mut log := new_event_log(tmp_log_path('mar4'), 'main', 'test')
	mut m := new_task_market(log, scripted_market_worker)
	crash := m.auction('debug the crash in the worker pool')
	assert crash.status == 'error'
	assert m.trust_of(crash.awarded) < market_default_trust

	before := m.trust_of('debugger')
	mut direct := Contract{
		task:    'deep dive'
		awarded: 'debugger'
	}
	m.settle(mut direct, {
		'status':     json2.Any('error')
		'summary':    json2.Any('boom')
		'tool_calls': json2.Any(3)
	})
	assert m.trust_of('debugger') < before
}

fn test_finished_work_lifts_the_role_that_did_it() {
	mut log := new_event_log(tmp_log_path('mar5'), 'main', 'test')
	mut m := new_task_market(log, scripted_market_worker)
	c := m.auction('write the new auth module and its tests')
	assert m.trust_of(c.awarded) > market_default_trust
	// trust never runs past its ceiling, however many contracts land
	for _ in 0 .. 100 {
		mut k := Contract{
			task:    'more work'
			awarded: c.awarded
		}
		m.settle(mut k, {
			'status': json2.Any('done')
		})
	}
	assert m.trust_of(c.awarded) <= market_trust_ceil
	assert m.trust_of(c.awarded) > 0.95
}

fn test_a_blocked_contract_dips_trust_slightly_rather_than_cratering_it() {
	mut log := new_event_log(tmp_log_path('mar6'), 'main', 'test')
	mut m := new_task_market(log, scripted_market_worker)
	before := m.trust_of('researcher')
	c := m.auction('research the blocked archive')
	assert c.status == 'blocked'
	after := m.trust_of(c.awarded)
	// blocked is not failure: something outside the role stopped real work
	assert after < before
	assert before - after <= 0.05 + 1e-9, '${before} -> ${after}'
	// an error on the same role would cost far more
	mut k := Contract{
		task:    'x'
		awarded: c.awarded
	}
	m.settle(mut k, {
		'status': json2.Any('error')
	})
	assert before - m.trust_of(c.awarded) > 0.05
}

fn test_the_pace_prior_recalibrates_from_the_actual_cost() {
	mut log := new_event_log(tmp_log_path('mar7'), 'main', 'test')
	mut m := new_observing_market(log)
	before := m.pace_of('coder')
	mut c := Contract{
		task:    'a long haul'
		awarded: 'coder'
	}
	// far more tool calls than the prior assumed: the role is slower at
	// this than the market thought
	m.settle(mut c, {
		'status':     json2.Any('done')
		'tool_calls': json2.Any(40)
	})
	assert m.pace_of('coder') > before
	// and the recalibration is bounded on both sides
	for _ in 0 .. 50 {
		mut k := Contract{
			task:    'x'
			awarded: 'coder'
		}
		m.settle(mut k, {
			'status':     json2.Any('done')
			'tool_calls': json2.Any(900)
		})
	}
	assert m.pace_of('coder') <= 2.0
}

fn test_the_trust_table_survives_a_rebuild_from_the_log() {
	mut log := new_event_log(tmp_log_path('mar8'), 'main', 'test')
	mut m := new_task_market(log, scripted_market_worker)
	m.auction('debug the crash in the worker pool')
	after := m.trust_of('debugger')
	pace := m.pace_of('debugger')

	// a market that knows nothing but the events agrees exactly
	mut reloaded := new_observing_market(log)
	assert math.abs(reloaded.trust_of('debugger') - after) < 1e-9
	assert math.abs(reloaded.pace_of('debugger') - pace) < 1e-9
}

fn test_a_worker_that_never_returns_settles_as_an_error() {
	mut log := new_event_log(tmp_log_path('mar9'), 'main', 'test')
	mut m := new_task_market(log, exploding_market_worker)
	c := m.auction('write something')
	assert c.status == 'error'
	assert jstr(c.report, 'summary').contains('never came back')
	// the market is still open for business
	assert m.auction('write something else').status == 'error'
}

fn test_an_empty_task_is_refused_before_anything_is_announced() {
	mut log := new_event_log(tmp_log_path('mar10'), 'main', 'test')
	mut m := new_task_market(log, scripted_market_worker)
	bad := m.auction('   ')
	assert bad.status == 'error'
	assert jstr(bad.report, 'summary') == 'empty task'
	assert bad.bids.len == 0
	assert log.head('main') == -1
	// a batch skips the blanks rather than failing on them
	assert m.run(['', '  ', 'write the docs']).len == 1
}

fn test_the_whole_cycle_is_sealed_and_rendered() {
	mut log := new_event_log(tmp_log_path('mar11'), 'main', 'test')
	mut m := new_task_market(log, scripted_market_worker)
	contracts := m.run(['write docs for the api', 'run the full test suite'])
	assert contracts.len == 2

	st := fold(mut log, 'main')
	mut kinds := map[string]bool{}
	for e in st.advanced_events {
		kinds[jstr(e, 'type')] = true
	}
	for want in ['market.announce', 'market.bid', 'market.award', 'market.settle'] {
		assert kinds[want], want
	}

	text := m.format(contracts)
	assert text.contains('MARKET — 2 contract(s)')
	assert text.contains('trust board')
	assert text.contains('bids:')
	assert text.contains('✓')

	board := m.leaderboard()
	assert board.len == roles.len
	for i in 1 .. board.len {
		assert board[i - 1].trust >= board[i].trust
	}
}
