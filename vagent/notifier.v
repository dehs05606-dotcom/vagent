module vagent

import net.http
import os
import time
import x.json2

// notifier.v — enterprise event notifications.
//
// Selected kernel events are fired at a file sink or an HTTP webhook, so a
// long-running session can tell someone what happened without them watching
// the terminal.
//
// It never fails outward. A notification is a courtesy; a webhook that is
// down must not be able to take a turn with it, so a delivery failure is
// recorded on the notifier and the turn carries on.

pub const notify_events = ['goal.closed', 'focus.stop', 'workflow.done', 'crew.done',
	'provider.failover']

const notify_timeout = 5 * time.second

@[heap]
pub struct Notifier {
pub mut:
	log &EventLog
	// '' is off; otherwise 'file:<path>' or an http(s) URL
	sink       string
	sent       int
	last_error string
}

pub fn new_notifier(log &EventLog) &Notifier {
	return &Notifier{
		log: unsafe { log }
	}
}

pub fn (mut n Notifier) configure(raw_sink string) !string {
	sink := raw_sink.trim_space()
	if sink == '' || sink == 'off' {
		n.sink = ''
		return 'off'
	}
	if sink.starts_with('file:') {
		path := os.expand_tilde_to_home(sink[5..])
		dir := os.dir(path)
		if dir != '' {
			os.mkdir_all(dir) or { return error('cannot create ${dir}: ${err}') }
		}
		n.sink = 'file:${path}'
		return n.sink
	}
	if sink.starts_with('http://') || sink.starts_with('https://') {
		n.sink = sink
		return sink
	}
	return error("sink must be 'off', 'file:<path>', or an http(s):// URL")
}

pub fn (mut n Notifier) emit(event_type string, payload map[string]json2.Any) bool {
	if n.sink == '' {
		return false
	}
	mut record := payload.clone()
	record['event'] = json2.Any(event_type)
	record['ts'] = json2.Any(now_ts())
	record['app'] = json2.Any('fullagent')
	line := json2.encode(json2.Any(record))

	if n.sink.starts_with('file:') {
		append_line(n.sink[5..], line) or {
			n.last_error = err.msg()
			return false
		}
		n.sent++
		return true
	}
	mut req := http.Request{
		url:           n.sink
		method:        .post
		data:          line
		read_timeout:  notify_timeout
		write_timeout: notify_timeout
	}
	req.add_header(.content_type, 'application/json')
	resp := req.do() or {
		n.last_error = err.msg()
		return false
	}
	if resp.status_code >= 400 {
		// a 500 from the webhook is a failed delivery, not a delivered one
		n.last_error = 'HTTP ${resp.status_code}'
		return false
	}
	n.sent++
	return true
}

pub fn (n &Notifier) status() string {
	state := if n.sink != '' { n.sink } else { 'off' }
	mut extra := ''
	if n.sent > 0 {
		extra += ' · sent ${n.sent}'
	}
	if n.last_error != '' {
		extra += ' · last error: ${n.last_error}'
	}
	return 'notifications: ${state}${extra} · events: ' + notify_events.join(', ')
}
