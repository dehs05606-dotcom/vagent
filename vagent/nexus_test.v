module vagent

import os
import x.json2

fn nexus_repo() string {
	root := os.join_path(os.temp_dir(), 'vagent-nexus-${os.getpid()}')
	os.rmdir_all(root) or {}
	os.mkdir_all(os.join_path(root, 'pkg')) or { panic(err) }
	os.mkdir_all(os.join_path(root, 'tests')) or { panic(err) }
	os.write_file(os.join_path(root, 'pkg', '__init__.py'),
		'from .auth import verify_token\n') or { panic(err) }
	os.write_file(os.join_path(root, 'pkg', 'auth.py'),
		'def verify_token(token):\n    """Check a token."""\n    return bool(token)\n\n' +
		'def login(token):\n    return verify_token(token)\n') or { panic(err) }
	os.write_file(os.join_path(root, 'pkg', 'api.py'),
		'from .auth import login\n\n\ndef handle(req):\n    return login(req)\n') or {
		panic(err)
	}
	os.write_file(os.join_path(root, 'tests', 'test_auth.py'),
		'from pkg.auth import verify_token\n\n\ndef test_verify():\n' +
		"    assert verify_token('x')\n") or { panic(err) }
	return root
}

fn test_nexus_indexes_symbols_and_edges() {
	root := nexus_repo()
	mut nx := new_nexus()
	idx := nx.index(root, 5000)
	assert idx.symbols.len >= 4, '${idx.symbols.keys()}'
	assert idx.errors.len == 0, '${idx.errors}'

	// imports are captured per file
	api := os.join_path(root, 'pkg', 'api.py')
	assert 'auth' in (idx.imports[api] or { [] }), '${idx.imports[api]}'
}

fn test_indexing_is_incremental() {
	root := nexus_repo()
	mut nx := new_nexus()
	nx.index(root, 5000)
	auth := os.join_path(root, 'pkg', 'auth.py')

	// already indexed at the same hash — not re-scanned
	assert nx.index_file(auth) == false
	os.write_file(auth, os.read_file(auth)! + '\n# touched\n') or { panic(err) }
	// the hash changed — re-scanned
	assert nx.index_file(auth) == true
}

fn test_find_symbol_and_callers() {
	root := nexus_repo()
	mut nx := new_nexus()
	nx.index(root, 5000)

	defs := nx.find_symbol('verify_token')
	assert defs.len == 1
	assert defs[0].kind == 'def'
	assert defs[0].params == ['token']
	assert defs[0].docstring == 'Check a token.', defs[0].docstring

	callers := nx.callers('verify_token')
	assert callers.len >= 1
	mut paths := callers.map(it.path)
	mut saw := false
	for p in paths {
		if p.contains('auth.py') || p.contains('test_auth.py') {
			saw = true
		}
	}
	assert saw, '${paths}'

	// a definition line is not a call site
	assert nx.callers('handle').len == 0
}

fn test_methods_are_distinguished_from_functions() {
	root := os.join_path(os.temp_dir(), 'vagent-nexus-m-${os.getpid()}')
	os.rmdir_all(root) or {}
	os.mkdir_all(root) or { panic(err) }
	os.write_file(os.join_path(root, 'm.py'),
		'class Thing:\n    def method(self):\n        pass\n\n\ndef free():\n    pass\n') or {
		panic(err)
	}
	mut nx := new_nexus()
	nx.index(root, 10)
	assert nx.find_symbol('method')[0].kind == 'method'
	assert nx.find_symbol('free')[0].kind == 'def'
	assert nx.find_symbol('Thing')[0].kind == 'class'
}

fn test_impact_is_the_blast_radius() {
	root := nexus_repo()
	mut nx := new_nexus()
	nx.index(root, 5000)

	imp := nx.impact('verify_token')
	assert imp.direct_callers >= 1
	assert imp.public_api, 'verify_token is re-exported in __init__.py'
	assert imp.risk in ['LOW', 'MEDIUM', 'HIGH']
	mut covered := false
	for t in imp.tests_covering {
		if t.contains('test') {
			covered = true
		}
	}
	assert covered, '${imp.tests_covering}'

	text := nx.format_impact('verify_token')
	assert text.contains('impact(verify_token)')
	assert text.contains('risk')
}

fn test_unknown_symbol_gives_a_well_formed_empty_report() {
	root := nexus_repo()
	mut nx := new_nexus()
	nx.index(root, 5000)
	imp := nx.impact('no_such_fn')
	assert imp.direct_callers == 0
	assert imp.definitions.len == 0
	assert !imp.public_api
	assert nx.format_impact('no_such_fn').contains('definitions     : 0')
}

// -- cassette ----------------------------------------------------------------

fn cassette_path(name string) string {
	dir := os.join_path(os.temp_dir(), 'vagent-cassette-${os.getpid()}')
	os.mkdir_all(dir) or {}
	p := os.join_path(dir, name)
	os.rm(p) or {}
	return p
}

fn test_cassette_records_and_replays() {
	path := cassette_path('cassette.jsonl')
	msgs := [user_message('hello')]
	resp := {
		'content': json2.Any('hi there')
		'usage':   json2.Any({
			'prompt_tokens':     json2.Any(5)
			'completion_tokens': json2.Any(3)
		})
	}

	mut rec := new_cassette(path, 'record') or { panic(err) }
	rec.record('model-x', msgs, []json2.Any{}, resp, '')
	assert rec.len() == 1

	mut play := new_cassette(path, 'replay') or { panic(err) }
	got := play.replay('model-x', msgs, []json2.Any{}, '') or { panic('a recorded call missed') }
	assert jstr(got, 'content') == 'hi there'
	assert jint(jmap(got, 'usage'), 'prompt_tokens') == 5
	assert play.hits == 1 && play.misses == 0

	// a different request is a miss — never a silent live call
	other := [user_message('different')]
	assert play.replay('model-x', other, []json2.Any{}, '') == none
	assert play.misses == 1
}

fn test_effort_participates_in_the_key() {
	path := cassette_path('effort.jsonl')
	msgs := [user_message('hi')]
	mut rec := new_cassette(path, 'record') or { panic(err) }
	rec.record('m', msgs, []json2.Any{}, {
		'content': json2.Any('low answer')
	}, 'low')

	mut play := new_cassette(path, 'replay') or { panic(err) }
	// the same messages at a different effort must NOT collide
	assert play.replay('m', msgs, []json2.Any{}, 'high') == none
	assert play.replay('m', msgs, []json2.Any{}, 'low') != none
}

fn test_off_mode_neither_records_nor_replays() {
	path := cassette_path('off.jsonl')
	mut off := new_cassette(path, 'off') or { panic(err) }
	off.record('model-x', [user_message('hi')], []json2.Any{}, {
		'content': json2.Any('x')
	}, '')
	assert off.replay('model-x', [user_message('hi')], []json2.Any{}, '') == none
	assert off.len() == 0
	assert !os.exists(path)
}

fn test_cassette_file_is_inspectable_jsonl_and_survives_reload() {
	path := cassette_path('reload.jsonl')
	msgs := [user_message('hello')]
	resp := {
		'content': json2.Any('hi there')
	}
	mut rec := new_cassette(path, 'record') or { panic(err) }
	rec.record('model-x', msgs, []json2.Any{}, resp, '')

	lines := os.read_file(path)!.trim_space().split('\n')
	assert lines.len == 1
	pair := decode_obj(lines[0])
	assert 'key' in pair
	assert jstr(jmap(pair, 'response'), 'content') == 'hi there'

	mut play := new_cassette(path, 'replay') or { panic(err) }
	again := play.replay('model-x', msgs, []json2.Any{}, '') or { panic('reload lost the pair') }
	assert jstr(again, 'content') == 'hi there'
}

fn test_replayed_responses_are_independent_copies() {
	path := cassette_path('copies.jsonl')
	msgs := [user_message('hi')]
	mut rec := new_cassette(path, 'record') or { panic(err) }
	rec.record('m', msgs, []json2.Any{}, {
		'content': json2.Any('original')
	}, '')

	mut play := new_cassette(path, 'replay') or { panic(err) }
	mut first := play.replay('m', msgs, []json2.Any{}, '') or { panic('miss') }
	// annotating one replay must not corrupt every future replay
	first['content'] = 'MUTATED'
	second := play.replay('m', msgs, []json2.Any{}, '') or { panic('miss') }
	assert jstr(second, 'content') == 'original'
}

fn test_bad_mode_is_refused() {
	if _ := new_cassette(cassette_path('bad.jsonl'), 'nonsense') {
		assert false, 'an unknown cassette mode was accepted'
	}
}
