module vagent

import sync
import time
import x.json2

// The stub chat is gated: it holds the very first call until both agents are
// on the queue, so the serial order of the executor is observable rather than
// a race the test happens to win.
@[heap]
struct CrewProbe {
mut:
	mu       sync.Mutex
	released bool
	order    []string
	calls    int
}

__global (
	crew_probe &CrewProbe
)

fn stub_crew_chat(provider Provider, model Model, effort Effort, mut messages []Message, schemas []json2.Any, timeout f64) !StreamResult {
	for {
		crew_probe.mu.lock()
		released := crew_probe.released
		crew_probe.mu.unlock()
		if released {
			break
		}
		time.sleep(2 * time.millisecond)
	}
	mut last_user := ''
	for i := messages.len - 1; i >= 0; i-- {
		if messages[i].role == 'user' {
			last_user = messages[i].text()
			break
		}
	}
	mut content := 'STATUS: DONE\nSUMMARY: follow-up handled'
	if last_user.contains('YOUR TASK') {
		crew_probe.mu.lock()
		crew_probe.order << last_user
		crew_probe.calls++
		crew_probe.mu.unlock()
		content = 'STATUS: DONE\nSUMMARY: built the thing'
	}
	return StreamResult{
		content:       content
		finish_reason: 'stop'
		has_usage:     true
		usage:         {
			'prompt_tokens':     json2.Any(10)
			'completion_tokens': json2.Any(5)
		}
	}
}

fn stub_provider() Provider {
	return Provider{
		key:      't'
		name:     'T'
		base_url: 'http://t'
		api_key:  'sk-fake'
		color:    '#fff'
	}
}

fn stub_model() Model {
	return Model{
		id:             'stub'
		provider:       't'
		label:          'Stub'
		supports_tools: true
	}
}

fn stub_effort() Effort {
	return Effort{
		key:        'low'
		label:      'LOW'
		color:      '#fff'
		max_tokens: 100
	}
}

fn new_test_crew(name string) &Crew {
	crew_probe = &CrewProbe{}
	mut c := new_crew(new_event_log(tmp_log_path(name), 'main', 'test'), stub_provider(), stub_model(), stub_effort())
	c.chat = stub_crew_chat
	return c
}

fn release_crew_probe() {
	crew_probe.mu.lock()
	crew_probe.released = true
	crew_probe.mu.unlock()
}

fn test_spawning_returns_at_once_and_the_queue_runs_one_at_a_time() {
	mut c := new_test_crew('crew1')
	a1 := c.spawn('write a parser', SpawnOpts{ role: 'coder' }) or { panic(err) }
	a2 := c.spawn('research parsers', SpawnOpts{ role: 'researcher' }) or { panic(err) }
	assert a1.id == 'crew-1'
	assert a2.id == 'crew-2'
	// both are queued, neither has run — spawn did not block on the model
	assert a1.state == 'running'
	assert a2.state == 'running'

	release_crew_probe()
	states := c.wait([], 10.0) or { panic(err) }
	assert states[a1.id] == 'done', states.str()
	assert states[a2.id] == 'done', states.str()
	assert a1.summary.contains('built the thing')
	assert a1.tokens_in > 0 && a1.tokens_out > 0

	// strict FIFO: the first spawned is the first served
	crew_probe.mu.lock()
	first := crew_probe.order[0]
	calls := crew_probe.calls
	crew_probe.mu.unlock()
	assert first.contains('write a parser'), first
	assert calls == 2
}

fn test_a_follow_up_reuses_the_whole_conversation() {
	mut c := new_test_crew('crew2')
	release_crew_probe()
	mut a := c.spawn('write a parser', SpawnOpts{ role: 'coder' }) or { panic(err) }
	c.wait([a.id], 10.0) or { panic(err) }

	c.send(a.id, 'now add error handling', false) or { panic(err) }
	c.wait([a.id], 10.0) or { panic(err) }
	assert a.state == 'done'
	assert a.summary.contains('follow-up handled'), a.summary

	// the history survived: the task and the follow-up are both there
	users := a.messages.filter(it.role == 'user')
	assert users.len == 2, users.len.str()
	assert users[0].text().contains('YOUR TASK')
	assert users[1].text().contains('FOLLOW-UP')
	// an empty follow-up is refused rather than sent
	c.send(a.id, '   ', false) or {
		assert err.msg().contains('empty message')
		return
	}
	assert false, 'an empty follow-up must be refused'
}

fn test_a_closed_agent_refuses_sends_until_it_is_resumed() {
	mut c := new_test_crew('crew3')
	release_crew_probe()
	mut a := c.spawn('research parsers', SpawnOpts{ role: 'researcher' }) or { panic(err) }
	c.wait([a.id], 10.0) or { panic(err) }

	c.close(a.id) or { panic(err) }
	assert a.state == 'closed'
	mut refused := false
	c.send(a.id, 'hi', false) or {
		assert err is CrewError
		assert err.msg().contains('closed')
		refused = true
	}
	assert refused, 'a send to a closed agent must fail'

	c.resume(a.id) or { panic(err) }
	assert a.state == 'done'
	// a resume keeps the history, so the follow-up lands on the same context
	c.send(a.id, 'carry on', false) or { panic(err) }
	c.wait([a.id], 10.0) or { panic(err) }
	assert a.messages.filter(it.role == 'user').len == 2
}

fn test_an_unknown_id_names_the_roster() {
	mut c := new_test_crew('crew4')
	release_crew_probe()
	c.spawn('a task', SpawnOpts{ role: 'coder' }) or { panic(err) }
	c.wait([], 10.0) or { panic(err) }

	c.wait(['crew-99'], 1.0) or {
		assert err is CrewError
		assert err.msg().contains('crew-1'), err.msg()
		return
	}
	assert false, 'an unknown id must be refused'
}

fn test_a_subagent_cannot_be_spawned_without_a_task() {
	mut c := new_test_crew('crew5')
	release_crew_probe()
	c.spawn('   ', SpawnOpts{}) or {
		assert err.msg().contains('without a task')
		return
	}
	assert false, 'an empty task must be refused'
}

fn test_the_roster_has_a_ceiling() {
	mut c := new_test_crew('crew6')
	c.max_agents = 2
	// nothing is released, so all three stay 'running' and contend for slots
	c.spawn('one', SpawnOpts{}) or { panic(err) }
	c.spawn('two', SpawnOpts{}) or { panic(err) }
	c.spawn('three', SpawnOpts{}) or {
		assert err is CrewError
		assert err.msg().contains('capacity'), err.msg()
		release_crew_probe()
		c.wait([], 10.0) or { panic(err) }
		return
	}
	release_crew_probe()
	assert false, 'the roster ceiling must hold'
}

fn test_an_unknown_role_falls_back_rather_than_failing() {
	mut c := new_test_crew('crew7')
	release_crew_probe()
	a := c.spawn('do the thing', SpawnOpts{ role: 'astronaut' }) or { panic(err) }
	assert a.role == default_role
	c.wait([], 10.0) or { panic(err) }
}

fn test_every_lifecycle_transition_is_sealed() {
	mut c := new_test_crew('crew8')
	release_crew_probe()
	mut a1 := c.spawn('write a parser', SpawnOpts{ role: 'coder' }) or { panic(err) }
	mut a2 := c.spawn('research parsers', SpawnOpts{ role: 'researcher' }) or { panic(err) }
	c.wait([], 10.0) or { panic(err) }
	c.send(a1.id, 'now add error handling', false) or { panic(err) }
	c.wait([a1.id], 10.0) or { panic(err) }
	c.close(a2.id) or { panic(err) }
	c.resume(a2.id) or { panic(err) }

	types := c.log.events('main').map(it.typ)
	assert types.filter(it == 'crew.spawn').len == 2
	assert types.filter(it == 'crew.message').len == 1
	assert types.filter(it == 'crew.done').len >= 3
	assert 'crew.closed' in types
	assert 'crew.resumed' in types

	rep := c.format_all()
	assert rep.contains('crew-1')
	assert rep.contains('coder')
	status := c.format_status()
	assert status.contains('CREW')
	assert status.contains('2 subagent(s)')

	s := c.status()
	assert jint(s, 'total') == 2
	assert jint(s, 'tokens_in') > 0
}

fn test_an_empty_crew_says_so() {
	mut c := new_test_crew('crew9')
	release_crew_probe()
	assert c.format_all() == 'crew is empty — spawn a subagent first'
	assert c.list().len == 0
	assert c.running().len == 0
	if _ := c.get('crew-1') {
		assert false, 'an empty crew has no agents'
	}
}
