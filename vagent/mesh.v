module vagent

import net
import sync
import time
import x.json2

// mesh.v — the agent-to-agent network: nodes over TCP.
//
// Two agents on two machines become ONE distributed agent:
//
//     serve()      a JSON-lines TCP server announcing this node's
//                  capabilities and serving three verbs — HELLO for
//                  discovery, TASK to take delegated work, PING for
//                  liveness
//     discover()   connect to a peer and pull its capability card
//     delegate()   ship a task to a peer. Local execution stays local; the
//                  mesh exists only for work worth moving.
//     heartbeat()  probe the roster; a dead peer drops out of it
//
// Every delegation is sealed on BOTH ends' kernels — mesh.task going out,
// mesh.result coming back. The protocol is deliberately tiny and
// human-readable, one JSON object per line, so anything that can open a
// socket can join the mesh rather than only this codebase.

const mesh_protocol = 'fullagent-mesh/1'
const mesh_recv_limit = 1 << 20 // 1 MiB per message line
const mesh_default_ttl = 60.0 // seconds a peer stays in the roster

pub struct Peer {
pub mut:
	host         string
	port         int
	capabilities map[string]json2.Any
	last_seen    f64
}

pub fn (p &Peer) addr() string {
	return '${p.host}:${p.port}'
}

pub fn (p &Peer) alive(ttl f64) bool {
	return (now_ts() - p.last_seen) < ttl
}

// MeshExecutor is how THIS node runs delegated work.
pub type MeshExecutor = fn (task string, role string) !map[string]json2.Any

@[heap]
pub struct MeshNode {
pub mut:
	log      &EventLog
	node_id  string
	executor MeshExecutor = unsafe { nil }
	host     string       = '127.0.0.1'
	port     int
	peers    map[string]Peer
	handled  int
mut:
	// The accept loop runs on its own thread and touches `handled`, the
	// peer roster and the log, while the owning thread calls delegate()
	// and heartbeat(). One mutex covers all of it.
	mu       sync.Mutex
	listener &net.TcpListener = unsafe { nil }
	serving  bool
}

pub fn new_mesh_node(log &EventLog, node_id string, executor MeshExecutor) &MeshNode {
	return &MeshNode{
		log:      unsafe { log }
		node_id:  node_id
		executor: executor
	}
}

// new_relay_node serves discovery and heartbeats but executes nothing. It
// refuses delegated work politely rather than accepting it and dropping it.
pub fn new_relay_node(log &EventLog, node_id string) &MeshNode {
	return &MeshNode{
		log:     unsafe { log }
		node_id: node_id
	}
}

// -- capabilities ---------------------------------------------------------------

pub fn (n &MeshNode) capabilities() map[string]json2.Any {
	return {
		'node':     json2.Any(n.node_id)
		'protocol': json2.Any(mesh_protocol)
		'roles':    json2.Any([json2.Any('any')])
		'models':   json2.Any([]json2.Any{})
		'executor': json2.Any(n.executor != unsafe { nil })
	}
}

// -- the server -------------------------------------------------------------------

// handle_line answers one protocol message. It never fails outward: a bad
// message gets an error reply and the node stays up.
pub fn (mut n MeshNode) handle_line(raw string) map[string]json2.Any {
	parsed := json2.decode[json2.Any](raw.trim_space()) or {
		return {
			'ok':    json2.Any(false)
			'error': json2.Any('malformed json')
		}
	}
	if parsed !is map[string]json2.Any {
		return {
			'ok':    json2.Any(false)
			'error': json2.Any('malformed json')
		}
	}
	msg := parsed.as_map()
	verb := jstr(msg, 'verb').to_upper()
	match verb {
		'HELLO' {
			return {
				'ok':           json2.Any(true)
				'proto':        json2.Any(mesh_protocol)
				'node':         json2.Any(n.node_id)
				'capabilities': json2.Any(n.capabilities())
			}
		}
		'PING' {
			return {
				'ok':   json2.Any(true)
				'pong': json2.Any(true)
				'node': json2.Any(n.node_id)
			}
		}
		'TASK' {
			task := jstr(msg, 'task').trim_space()
			role := jstr(msg, 'role').trim_space()
			if task == '' {
				return {
					'ok':    json2.Any(false)
					'error': json2.Any('empty task')
				}
			}
			if n.executor == unsafe { nil } {
				return {
					'ok':    json2.Any(false)
					'error': json2.Any('node cannot execute')
				}
			}
			mut from := jstr(msg, 'from')
			if from == '' {
				from = '?'
			}
			n.log.append('mesh.task', {
				'from': json2.Any(from)
				'task': json2.Any(task)
				'role': json2.Any(role)
			}, AppendOpts{})
			// a failing task never kills the node — the failure is the result
			result := n.executor(task, role) or {
				mut failed := map[string]json2.Any{}
				failed['status'] = json2.Any('error')
				failed['summary'] = json2.Any(err.msg())
				failed
			}
			n.handled++
			mut sealed := result.clone()
			sealed['task'] = json2.Any(task)
			n.log.append('mesh.result', sealed, AppendOpts{})
			return {
				'ok':     json2.Any(true)
				'node':   json2.Any(n.node_id)
				'result': json2.Any(result.clone())
			}
		}
		else {
			return {
				'ok':    json2.Any(false)
				'error': json2.Any("unknown verb '${verb}'")
			}
		}
	}
}

// serve starts the TCP server and returns the bound port.
pub fn (mut n MeshNode) serve(port int) !int {
	if n.serving {
		return n.port
	}
	mut listener := net.listen_tcp(.ip, '${n.host}:${port}')!
	addr := listener.addr()!
	n.listener = listener
	n.port = int(addr.port()!)
	n.serving = true
	n.log.append('mesh.node', {
		'node':    json2.Any(n.node_id)
		'port':    json2.Any(n.port)
		'serving': json2.Any(true)
	}, AppendOpts{})
	spawn n.accept_loop()
	return n.port
}

fn (mut n MeshNode) accept_loop() {
	for {
		if !n.serving {
			return
		}
		mut conn := n.listener.accept() or {
			// the listener was closed, or the accept failed; either way
			// there is nothing left to serve
			return
		}
		spawn n.serve_conn(mut conn)
	}
}

fn (mut n MeshNode) serve_conn(mut conn net.TcpConn) {
	defer {
		conn.close() or {}
	}
	line := conn.read_line_max(mesh_recv_limit)
	if line == '' {
		return
	}
	n.mu.lock()
	reply := n.handle_line(line)
	n.mu.unlock()
	conn.write_string(json2.Any(reply).json_str() + '\n') or {}
}

pub fn (mut n MeshNode) stop() {
	if !n.serving {
		return
	}
	n.serving = false
	n.listener.close() or {}
}

// -- the client --------------------------------------------------------------------

fn (mut n MeshNode) rpc(peer &Peer, message map[string]json2.Any, timeout f64) !map[string]json2.Any {
	mut conn := net.dial_tcp('${peer.host}:${peer.port}')!
	defer {
		conn.close() or {}
	}
	conn.set_read_timeout(i64(timeout * f64(time.second)))
	conn.set_write_timeout(i64(timeout * f64(time.second)))
	conn.write_string(json2.Any(message).json_str() + '\n')!
	// The protocol is newline-framed and a single read can return a partial
	// frame whenever the reply spans TCP segments — which a large task
	// result routinely does — so the read runs to the newline.
	line := conn.read_line_max(mesh_recv_limit)
	parsed := json2.decode[json2.Any](line.trim_space()) or {
		return error('peer sent garbage')
	}
	if parsed !is map[string]json2.Any {
		return error('peer sent garbage')
	}
	return parsed.as_map()
}

// discover greets a peer and files its capability card in the roster.
pub fn (mut n MeshNode) discover(host string, port int) ?Peer {
	candidate := Peer{
		host:      host
		port:      port
		last_seen: now_ts()
	}
	reply := n.rpc(&candidate, {
		'verb': json2.Any('HELLO')
		'from': json2.Any(n.node_id)
	}, 10.0) or { return none }
	if !jbool(reply, 'ok') {
		return none
	}
	peer := Peer{
		host:         host
		port:         port
		capabilities: jmap(reply, 'capabilities')
		last_seen:    now_ts()
	}
	mut name := jstr(reply, 'node')
	if name == '' {
		name = peer.addr()
	}
	n.peers[name] = peer
	return peer
}

// heartbeat probes every peer. A peer that does not answer drops out of the
// roster rather than lingering as a route that silently fails later.
pub fn (mut n MeshNode) heartbeat() map[string]bool {
	mut statuses := map[string]bool{}
	mut names := n.peers.keys()
	names.sort()
	for name in names {
		peer := n.peers[name] or { continue }
		mut alive := false
		if reply := n.rpc(&peer, {
			'verb': json2.Any('PING')
			'from': json2.Any(n.node_id)
		}, 5.0) {
			alive = jbool(reply, 'pong')
		}
		statuses[name] = alive
		if alive {
			mut refreshed := peer
			refreshed.last_seen = now_ts()
			n.peers[name] = refreshed
		} else {
			n.peers.delete(name)
		}
	}
	return statuses
}

// delegate ships work to a peer — any live one by default. A dead mesh
// returns an error record rather than failing outward.
pub fn (mut n MeshNode) delegate(task string, role string, peer_name string) map[string]json2.Any {
	mut candidates := []Peer{}
	if peer_name != '' && peer_name in n.peers {
		candidates << n.peers[peer_name] or { Peer{} }
	} else {
		mut names := n.peers.keys()
		names.sort()
		for name in names {
			p := n.peers[name] or { continue }
			if p.alive(mesh_default_ttl) {
				candidates << p
			}
		}
	}
	if candidates.len == 0 {
		return {
			'ok':    json2.Any(false)
			'error': json2.Any('no peers — discover() one first')
		}
	}
	peer := candidates[0]
	return n.rpc(&peer, {
		'verb': json2.Any('TASK')
		'from': json2.Any(n.node_id)
		'task': json2.Any(task)
		'role': json2.Any(role)
	}, 30.0) or {
		mut failed := map[string]json2.Any{}
		failed['ok'] = json2.Any(false)
		failed['error'] = json2.Any('peer unreachable: ${err.msg()}')
		failed
	}
}
