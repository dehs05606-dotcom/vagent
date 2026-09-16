module vagent

import net
import time
import x.json2

fn bravo_executor(task string, role string) !map[string]json2.Any {
	if task.contains('boom') {
		return error('worker exploded')
	}
	return {
		'status':  json2.Any('done')
		'summary': json2.Any('B ran ${task} as ' + if role != '' { role } else { 'any' })
	}
}

// raw_exchange sends one line and reads one back, the way any process that
// can open a socket would — the protocol is not this codebase's private API.
fn raw_exchange(port int, line string) map[string]json2.Any {
	mut conn := net.dial_tcp('127.0.0.1:${port}') or { panic(err) }
	defer {
		conn.close() or {}
	}
	conn.set_read_timeout(10 * time.second)
	conn.write_string(line + '\n') or { panic(err) }
	reply := conn.read_line_max(mesh_recv_limit)
	parsed := json2.decode[json2.Any](reply.trim_space()) or { panic(err) }
	return parsed.as_map()
}

fn test_two_nodes_discover_each_other_and_delegate_work() {
	mut log_a := new_event_log(tmp_log_path('mesh1a'), 'main', 'test')
	mut log_b := new_event_log(tmp_log_path('mesh1b'), 'main', 'test')
	mut a := new_relay_node(log_a, 'alpha')
	mut b := new_mesh_node(log_b, 'bravo', bravo_executor)
	port_a := a.serve(0) or { panic(err) }
	port_b := b.serve(0) or { panic(err) }
	defer {
		a.stop()
		b.stop()
	}
	assert port_a > 0 && port_b > 0
	assert port_a != port_b

	peer := a.discover('127.0.0.1', port_b) or { panic('discovery failed') }
	assert jstr(peer.capabilities, 'node') == 'bravo'
	assert jbool(peer.capabilities, 'executor')
	assert jstr(peer.capabilities, 'protocol') == mesh_protocol
	assert 'bravo' in a.peers

	reply := a.delegate('do something', '', '')
	assert jbool(reply, 'ok'), reply.str()
	assert jstr(jmap(reply, 'result'), 'summary').contains('B ran'), reply.str()

	// the work really ran on B, and both halves are sealed on B's kernel
	assert b.handled == 1
	kinds := log_b.events('main').map(it.typ)
	assert 'mesh.task' in kinds
	assert 'mesh.result' in kinds
	assert 'mesh.node' in kinds
}

fn test_a_node_without_an_executor_refuses_work_politely() {
	mut log := new_event_log(tmp_log_path('mesh2'), 'main', 'test')
	mut relay := new_relay_node(log, 'charlie')
	port := relay.serve(0) or { panic(err) }
	defer {
		relay.stop()
	}
	assert !jbool(relay.capabilities(), 'executor')

	reply := raw_exchange(port, '{"verb":"TASK","task":"anything","from":"x"}')
	assert !jbool(reply, 'ok')
	assert jstr(reply, 'error') == 'node cannot execute'
	// refusing is not executing: nothing was sealed as work
	assert 'mesh.task' !in log.events('main').map(it.typ)
}

fn test_a_failing_worker_is_reported_and_the_node_stays_up() {
	mut log_a := new_event_log(tmp_log_path('mesh3a'), 'main', 'test')
	mut log_b := new_event_log(tmp_log_path('mesh3b'), 'main', 'test')
	mut a := new_relay_node(log_a, 'alpha')
	mut b := new_mesh_node(log_b, 'bravo', bravo_executor)
	a.serve(0) or { panic(err) }
	port_b := b.serve(0) or { panic(err) }
	defer {
		a.stop()
		b.stop()
	}
	a.discover('127.0.0.1', port_b) or { panic('discovery failed') }

	err_reply := a.delegate('make it boom', '', '')
	// the RPC succeeded; the TASK failed. Those are different things.
	assert jbool(err_reply, 'ok'), err_reply.str()
	result := jmap(err_reply, 'result')
	assert jstr(result, 'status') == 'error'
	assert jstr(result, 'summary').contains('exploded'), result.str()
	assert b.handled == 1

	// and the node is still serving
	ok_reply := a.delegate('carry on', 'coder', '')
	assert jbool(ok_reply, 'ok')
	assert jstr(jmap(ok_reply, 'result'), 'summary').contains('as coder')
	assert b.handled == 2
}

fn test_a_heartbeat_keeps_the_living_and_drops_the_dead() {
	mut log_a := new_event_log(tmp_log_path('mesh4a'), 'main', 'test')
	mut log_b := new_event_log(tmp_log_path('mesh4b'), 'main', 'test')
	mut log_c := new_event_log(tmp_log_path('mesh4c'), 'main', 'test')
	mut a := new_relay_node(log_a, 'alpha')
	mut b := new_mesh_node(log_b, 'bravo', bravo_executor)
	mut c := new_relay_node(log_c, 'charlie')
	a.serve(0) or { panic(err) }
	port_b := b.serve(0) or { panic(err) }
	port_c := c.serve(0) or { panic(err) }
	defer {
		a.stop()
		c.stop()
	}
	a.discover('127.0.0.1', port_b) or { panic('discovery failed') }
	a.discover('127.0.0.1', port_c) or { panic('discovery failed') }
	assert a.peers.len == 2

	b.stop()
	statuses := a.heartbeat()
	assert statuses['bravo'] == false, statuses.str()
	assert statuses['charlie'] == true, statuses.str()
	// a peer that does not answer leaves the roster rather than lingering
	// as a route that silently fails later
	assert 'bravo' !in a.peers
	assert 'charlie' in a.peers

	again := a.heartbeat()
	assert again.len == 1
	assert again['charlie'] == true
}

fn test_delegating_with_an_empty_roster_is_a_clean_error() {
	mut log := new_event_log(tmp_log_path('mesh5'), 'main', 'test')
	mut lonely := new_relay_node(log, 'alone')
	reply := lonely.delegate('x', '', '')
	assert !jbool(reply, 'ok')
	assert jstr(reply, 'error').contains('no peers')
}

fn test_discovering_a_closed_port_fails_without_raising() {
	mut log := new_event_log(tmp_log_path('mesh6'), 'main', 'test')
	mut a := new_relay_node(log, 'alpha')
	mut dead := new_relay_node(new_event_log(tmp_log_path('mesh6d'), 'main', 'test'), 'dead')
	port := dead.serve(0) or { panic(err) }
	dead.stop()

	if _ := a.discover('127.0.0.1', port) {
		assert false, 'a closed port must not yield a peer'
	}
	assert a.peers.len == 0
}

fn test_a_malformed_or_unknown_message_gets_a_clean_error() {
	mut log := new_event_log(tmp_log_path('mesh7'), 'main', 'test')
	mut node := new_relay_node(log, 'charlie')
	port := node.serve(0) or { panic(err) }
	defer {
		node.stop()
	}

	garbage := raw_exchange(port, 'this is not json')
	assert !jbool(garbage, 'ok')
	assert jstr(garbage, 'error') == 'malformed json'

	// valid JSON that is not an object is still not a message
	not_an_object := raw_exchange(port, '[1, 2, 3]')
	assert jstr(not_an_object, 'error') == 'malformed json'

	unknown := raw_exchange(port, '{"verb":"DANCE"}')
	assert jstr(unknown, 'error').contains('unknown verb'), unknown.str()

	// and the node is still answering after all of that
	pong := raw_exchange(port, '{"verb":"PING"}')
	assert jbool(pong, 'pong')
	assert jstr(pong, 'node') == 'charlie'
}

fn test_an_empty_task_is_refused_before_the_executor_is_reached() {
	mut log := new_event_log(tmp_log_path('mesh8'), 'main', 'test')
	mut b := new_mesh_node(log, 'bravo', bravo_executor)
	port := b.serve(0) or { panic(err) }
	defer {
		b.stop()
	}
	reply := raw_exchange(port, '{"verb":"TASK","task":"   "}')
	assert !jbool(reply, 'ok')
	assert jstr(reply, 'error') == 'empty task'
	assert b.handled == 0
}

fn test_a_peer_past_its_ttl_is_not_a_delegation_target() {
	stale := Peer{
		host:      '127.0.0.1'
		port:      1
		last_seen: now_ts() - mesh_default_ttl - 1.0
	}
	assert !stale.alive(mesh_default_ttl)
	fresh := Peer{
		host:      '127.0.0.1'
		port:      1
		last_seen: now_ts()
	}
	assert fresh.alive(mesh_default_ttl)
	assert fresh.addr() == '127.0.0.1:1'

	mut log := new_event_log(tmp_log_path('mesh9'), 'main', 'test')
	mut a := new_relay_node(log, 'alpha')
	a.peers['ghost'] = stale
	reply := a.delegate('x', '', '')
	assert !jbool(reply, 'ok')
	assert jstr(reply, 'error').contains('no peers')
}
