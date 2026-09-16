module vagent

import os
import x.json2

fn test_the_sink_is_validated_before_anything_is_sent() {
	mut log := new_event_log(tmp_log_path('not1'), 'main', 'test')
	mut n := new_notifier(log)
	assert n.configure('off') or { '' } == 'off'
	assert n.configure('   ') or { '' } == 'off'
	assert n.configure('https://example.invalid/hook') or { '' } == 'https://example.invalid/hook'

	n.configure('ftp://nope') or {
		assert err.msg().contains("must be 'off'")
		return
	}
	assert false, 'an unsupported sink must be refused'
}

fn test_a_file_sink_appends_one_json_line_per_event() {
	dir := os.join_path(os.temp_dir(), 'vagent-notify-${os.getpid()}')
	os.rmdir_all(dir) or {}
	defer {
		os.rmdir_all(dir) or {}
	}
	path := os.join_path(dir, 'nested', 'events.jsonl')

	mut log := new_event_log(tmp_log_path('not2'), 'main', 'test')
	mut n := new_notifier(log)
	// the parent directory is created rather than the sink silently failing
	assert n.configure('file:${path}') or { '' } == 'file:${path}'

	assert n.emit('goal.closed', {
		'goal': json2.Any('ship the parser')
	})
	assert n.emit('crew.done', {
		'id': json2.Any('crew-1')
	})
	assert n.sent == 2

	lines := split_lines(os.read_file(path) or { '' }).filter(it.trim_space() != '')
	assert lines.len == 2
	first := decode_obj(lines[0])
	assert jstr(first, 'event') == 'goal.closed'
	assert jstr(first, 'goal') == 'ship the parser'
	assert jstr(first, 'app') == 'fullagent'
	assert jf64(first, 'ts') > 0
}

fn test_a_notifier_that_is_off_sends_nothing() {
	mut log := new_event_log(tmp_log_path('not3'), 'main', 'test')
	mut n := new_notifier(log)
	assert !n.emit('goal.closed', map[string]json2.Any{})
	assert n.sent == 0
	assert n.status().contains('notifications: off')
	assert n.status().contains('goal.closed')
}

fn test_a_delivery_failure_is_recorded_and_never_raised() {
	mut log := new_event_log(tmp_log_path('not4'), 'main', 'test')
	mut n := new_notifier(log)
	// a host that cannot resolve: the emit must return false, not fail
	n.configure('http://127.0.0.1:1/hook') or { panic(err) }
	assert !n.emit('goal.closed', map[string]json2.Any{})
	assert n.sent == 0
	assert n.last_error != ''
	// a notification is a courtesy; the failure is visible in the status
	assert n.status().contains('last error:')
}

fn test_turning_the_sink_back_off_stops_delivery() {
	dir := os.join_path(os.temp_dir(), 'vagent-notify-off-${os.getpid()}')
	os.rmdir_all(dir) or {}
	defer {
		os.rmdir_all(dir) or {}
	}
	path := os.join_path(dir, 'events.jsonl')
	mut log := new_event_log(tmp_log_path('not5'), 'main', 'test')
	mut n := new_notifier(log)
	n.configure('file:${path}') or { panic(err) }
	assert n.emit('focus.stop', map[string]json2.Any{})
	n.configure('off') or { panic(err) }
	assert !n.emit('focus.stop', map[string]json2.Any{})
	assert n.sent == 1
	assert split_lines(os.read_file(path) or { '' }).filter(it.trim_space() != '').len == 1
}
