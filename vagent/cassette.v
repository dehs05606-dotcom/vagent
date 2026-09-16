module vagent

import os
import sync
import x.json2

// cassette.v — record/replay of model calls (§20.2, §35).
//
// Every request/response pair is recorded; a session replays against the
// cassette with ZERO API cost. This is how the test suite runs, and it is
// the dividend 'deterministic testing' from the Mul Bindu table (§0.2).
//
// Design:
//   * Key = sha256(canonical(model, messages, tools, effort)) — the
//     request hash.
//   * record mode: real calls pass through and are stored keyed by hash.
//   * replay mode: matching requests return the stored response; a miss is
//     a hard error (never a silent live call), so replays are
//     deterministic.
//   * Cassettes are JSONL, one line per pair, human-inspectable.

// request_key is the cassette key for one request (§8.1: blake3(request) —
// here sha256, same role).
//
// `effort_key` participates in the hash: sampling params (max_tokens,
// temperature) change with effort but NOT with messages, so two requests
// that differ only in effort must not collide on one recorded response.
pub fn request_key(model string, messages []Message, tools []json2.Any, effort_key string) string {
	payload := canonical(json2.Any({
		'model':    json2.Any(model)
		'messages': json2.Any(messages_to_json(messages))
		'tools':    json2.Any(tools)
		'effort':   json2.Any(effort_key)
	}))
	return hash(payload)
}

// Cassette records or replays model request/response pairs.
@[heap]
pub struct Cassette {
pub:
	path string
	// 'off' | 'record' | 'replay'
	mode string = 'off'
pub mut:
	hits   int
	misses int
mut:
	mu    sync.Mutex
	store map[string]string // key -> the response, as canonical JSON
}

pub fn new_cassette(path string, mode string) !&Cassette {
	if mode !in ['off', 'record', 'replay'] {
		return error('mode must be off | record | replay')
	}
	mut c := &Cassette{
		path: path
		mode: mode
	}
	if mode != 'off' && os.exists(path) {
		c.load()
	}
	return c
}

fn (mut c Cassette) load() {
	content := os.read_file(c.path) or { return }
	for raw in content.split('\n') {
		line := raw.trim_space()
		if line == '' {
			continue
		}
		pair := decode_obj(line)
		key := jstr(pair, 'key')
		if key == '' {
			continue
		}
		resp := pair['response'] or { continue }
		c.store[key] = canonical(resp)
	}
}

fn (mut c Cassette) persist(key string, response string) {
	dir := os.dir(c.path)
	if dir != '' {
		os.mkdir_all(dir) or { return }
	}
	line := canonical(json2.Any({
		'key':      json2.Any(key)
		'response': json2.decode[json2.Any](response) or { json2.null }
	}))
	append_line(c.path, line) or {}
}

// record stores a real response (record mode only).
pub fn (mut c Cassette) record(model string, messages []Message, tools []json2.Any, response map[string]json2.Any, effort_key string) {
	if c.mode != 'record' {
		return
	}
	key := request_key(model, messages, tools, effort_key)
	// The response is stored as canonical JSON text rather than a live map:
	// a caller mutating its own copy afterwards must not rewrite what the
	// cassette recorded, and a replayed copy must not corrupt every future
	// replay of the same key. Serialising is V's equivalent of the Python
	// original's deep copies, in both directions at once.
	stored := canonical(json2.Any(response))
	c.mu.@lock()
	c.store[key] = stored
	c.mu.unlock()
	c.persist(key, stored)
}

// replay returns the stored response for a request (replay mode only).
//
// A miss returns none and counts as a miss — the caller must treat it as a
// hard error, never fall back to a live call, or the replay is no longer
// deterministic.
pub fn (mut c Cassette) replay(model string, messages []Message, tools []json2.Any, effort_key string) ?map[string]json2.Any {
	if c.mode != 'replay' {
		return none
	}
	key := request_key(model, messages, tools, effort_key)
	c.mu.@lock()
	defer {
		c.mu.unlock()
	}
	stored := c.store[key] or {
		c.misses++
		return none
	}
	c.hits++
	return decode_obj(stored)
}

pub fn (mut c Cassette) len() int {
	c.mu.@lock()
	defer {
		c.mu.unlock()
	}
	return c.store.len
}
