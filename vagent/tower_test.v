module vagent

import net
import time
import x.json2

fn tower_log(name string) &EventLog {
	mut log := new_event_log(tmp_log_path(name), 'main', 'test')
	log.append('user.message', {
		'text': json2.Any('hello tower')
	}, AppendOpts{})
	log.append('tool.call', {
		'name': json2.Any('read_file')
		'args': json2.Any({
			'path': json2.Any('x.py')
		})
	}, AppendOpts{})
	log.append('assistant.message', {
		'text': json2.Any('done reading')
	}, AppendOpts{})
	return log
}

// http_get is a deliberately small client: the point of the test is that the
// tower speaks real HTTP, not that it speaks this codebase's dialect.
fn http_get(url_path string, port int) (int, string) {
	return http_request('GET', url_path, port, '')
}

fn http_request(method string, url_path string, port int, body string) (int, string) {
	mut conn := net.dial_tcp('127.0.0.1:${port}') or { panic(err) }
	defer {
		conn.close() or {}
	}
	conn.set_read_timeout(10 * time.second)
	mut req := '${method} ${url_path} HTTP/1.1\r\nHost: 127.0.0.1\r\n'
	if body != '' {
		req += 'Content-Type: application/json\r\nContent-Length: ${body.len}\r\n'
	}
	req += 'Connection: close\r\n\r\n' + body
	conn.write_string(req) or { panic(err) }

	status_line := conn.read_line_max(1 << 20).trim_right('\r\n')
	mut length := 0
	for {
		header := conn.read_line_max(1 << 20).trim_right('\r\n')
		if header == '' {
			break
		}
		if header.to_lower().starts_with('content-length:') {
			length = header.all_after_first(':').trim_space().int()
		}
	}
	mut buf := []u8{len: length}
	mut read := 0
	for read < length {
		n := conn.read(mut buf[read..]) or { break }
		if n <= 0 {
			break
		}
		read += n
	}
	code := status_line.split(' ')[1] or { '0' }
	return code.int(), buf[..read].bytestr()
}

fn json_body(text string) map[string]json2.Any {
	parsed := json2.decode[json2.Any](text) or { return map[string]json2.Any{} }
	if parsed is map[string]json2.Any {
		return parsed
	}
	return map[string]json2.Any{}
}

fn test_the_state_endpoint_serves_real_fold_data() {
	mut log := tower_log('tow1')
	mut t := new_tower(log)
	port_url := t.start(0) or { panic(err) }
	defer {
		t.stop()
	}
	assert port_url.starts_with('http://127.0.0.1:')

	code, body := http_get('/api/state', t.port)
	assert code == 200
	s := json_body(body)
	assert jint(s, 'tool_calls') == 1
	assert jstr(s, 'branch') == 'main'
	assert jstr(s, 'cost').starts_with('\$')
	assert jint(s, 'crew_agents') == 0
	assert jint(s, 'branches') == 1
}

fn test_the_event_river_streams_only_what_is_new() {
	mut log := tower_log('tow2')
	mut t := new_tower(log)
	t.start(0) or { panic(err) }
	defer {
		t.stop()
	}

	_, first := http_get('/api/events?since=-1', t.port)
	evs := jarr(json_body(first), 'events')
	assert evs.len == 3
	assert jstr(evs[0].as_map(), 'type') == 'user.message'
	assert jint(evs[2].as_map(), 'seq') == 2

	_, empty := http_get('/api/events?since=2', t.port)
	assert jarr(json_body(empty), 'events').len == 0

	log.append('fact.learned', {
		'fact': json2.Any('tower works')
	}, AppendOpts{})
	_, after := http_get('/api/events?since=2', t.port)
	rows := jarr(json_body(after), 'events')
	assert rows.len == 1
	assert jstr(rows[0].as_map(), 'type') == 'fact.learned'

	// a malformed cursor falls back to the beginning rather than failing
	_, junk := http_get('/api/events?since=abc', t.port)
	assert jarr(json_body(junk), 'events').len == 4
}

fn test_the_timeline_and_frame_endpoints_answer() {
	mut log := tower_log('tow3')
	mut t := new_tower(log)
	t.start(0) or { panic(err) }
	defer {
		t.stop()
	}

	_, tl := http_get('/api/timeline', t.port)
	frames := jarr(json_body(tl), 'frames')
	assert frames.len == 3
	assert jstr(frames[0].as_map(), 'type') == 'user.message'

	code, body := http_get('/api/frame?seq=1', t.port)
	assert code == 200
	f := json_body(body)
	assert jint(f, 'tool_calls') == 1
	assert jstr(f, 'summary').contains('read_file')

	missing_code, _ := http_get('/api/frame?seq=99', t.port)
	assert missing_code == 404
	bad_code, _ := http_get('/api/frame', t.port)
	assert bad_code == 400
}

fn test_the_page_serves_and_needs_nothing_else() {
	mut log := tower_log('tow4')
	mut t := new_tower(log)
	t.start(0) or { panic(err) }
	defer {
		t.stop()
	}
	code, page := http_get('/', t.port)
	assert code == 200
	assert page.contains('CONTROL TOWER')
	assert page.contains('/api/events')
	// a dashboard that needs the network to render is useless exactly when
	// the network is what broke
	assert !page.contains('http://')
	assert !page.contains('https://')
}

fn test_an_unknown_path_is_a_clean_404() {
	mut log := tower_log('tow5')
	mut t := new_tower(log)
	t.start(0) or { panic(err) }
	defer {
		t.stop()
	}
	code, body := http_get('/nope', t.port)
	assert code == 404
	assert jstr(json_body(body), 'error') == 'not found'
}

fn test_the_command_endpoint_refuses_what_it_cannot_run() {
	mut log := tower_log('tow6')
	mut t := new_tower(log)
	t.start(0) or { panic(err) }
	defer {
		t.stop()
	}

	_, empty := http_request('POST', '/api/command', t.port, '{"text": ""}')
	assert !jbool(json_body(empty), 'ok')
	assert jstr(json_body(empty), 'error') == 'empty command'

	// with no agent attached, a real command says so rather than pretending
	_, detached := http_request('POST', '/api/command', t.port, '{"text": "do it"}')
	assert !jbool(json_body(detached), 'ok')
	assert jstr(json_body(detached), 'error') == 'no agent attached'

	// a body that is not an object would fail inside the handler and close
	// the connection with no reply at all
	array_code, array_body := http_request('POST', '/api/command', t.port, '[1, 2, 3]')
	assert array_code == 400
	assert jstr(json_body(array_body), 'error').contains('JSON object')

	junk_code, _ := http_request('POST', '/api/command', t.port, 'not json')
	assert junk_code == 400

	// and a POST anywhere else is a 404, not a command
	wrong_code, _ := http_request('POST', '/api/state', t.port, '{}')
	assert wrong_code == 404
}

fn test_the_sleep_command_needs_a_brain() {
	mut log := tower_log('tow7')
	mut t := new_tower(log)
	reply := t.command({
		'sleep': json2.Any(true)
	})
	assert !jbool(reply, 'ok')
	assert jstr(reply, 'error') == 'no brain attached'
}

fn test_routing_is_answerable_without_a_socket() {
	// the whole API is a function of the path and body, which is what makes
	// it testable and what keeps the socket layer thin
	mut log := tower_log('tow8')
	mut t := new_tower(log)
	state := t.route('GET', '/api/state', '')
	assert state.status == 200
	assert state.content_type == 'application/json'
	page := t.route('GET', '/index.html', '')
	assert page.content_type.starts_with('text/html')
	assert t.route('DELETE', '/api/state', '').status == 404
	assert t.route('GET', '/api/nope', '').status == 404
}

fn test_query_parsing_falls_back_rather_than_failing() {
	assert query_int('/api/events?since=12', 'since', -1) == 12
	assert query_int('/api/events?since=12&x=1', 'since', -1) == 12
	assert query_int('/api/events', 'since', -1) == -1
	assert query_int('/api/events?since=', 'since', -1) == -1
	assert query_int('/api/events?since=abc', 'since', -1) == -1
	assert query_int('/api/events?since=-3', 'since', -1) == -3
}
