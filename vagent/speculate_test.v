module vagent

import x.json2

__global (
	spec_calls []string
)

fn spec_stub_runner(name string, args map[string]json2.Any) !string {
	spec_calls << name
	if name == 'read_file' && jstr(args, 'path').contains('missing') {
		return error('file not found')
	}
	return 'OK:${name}:' + canonical(json2.Any(args))
}

fn new_spec(name string) &Speculator {
	spec_calls = []
	return new_speculator(new_event_log(tmp_log_path(name), 'main', 'test'), spec_stub_runner)
}

fn test_a_path_in_the_user_message_is_the_strongest_signal() {
	preds := predict('please look at src/main.py and fix it', [])
	assert preds.any(it.tool == 'read_file' && jstr(it.args, 'path') == 'src/main.py'), preds.map(it.tool).str()
	// and the read outranks the file_info that comes with it
	read := preds.filter(it.tool == 'read_file')[0]
	assert read.score == 0.9
	assert read.why == 'path in user message'
	// never more than the prefetch cap
	assert preds.len <= max_prefetch
}

fn test_a_directory_is_listed_rather_than_read() {
	// a trailing slash makes it a listing, not a read
	preds := predict('check ./src/ for me', [])
	assert preds.any(it.tool == 'list_dir' && jstr(it.args, 'path') == './src'), preds.map(it.tool).str()
	assert !preds.any(it.tool == 'read_file')

	// a bare 'src/' is NOT recognised as a path: the pattern needs a
	// leading ./ ~ or a segment after the slash. That is the original's
	// behaviour, and a prediction that guessed wider would prefetch words.
	bare := predict('check src/ for me', [])
	assert bare.len == 1 && bare[0].why == 'default cwd probe'
}

fn test_a_search_verb_predicts_a_search() {
	preds := predict('find the parser bug', [])
	assert preds.any(it.tool == 'search_files' && jstr(it.args, 'pattern').contains('the parser bug'))
}

fn test_a_recent_read_predicts_its_siblings() {
	recent := [
		ToolEvent{
			name: 'read_file'
			args: {
				'path': json2.Any('app/core/parser.py')
			}
		},
	]
	preds := predict('what next', recent)
	assert preds.any(it.tool == 'list_dir' && jstr(it.args, 'path') == 'app/core')
}

fn test_with_nothing_signalled_it_probes_the_working_directory() {
	preds := predict('hello there', [])
	assert preds.len == 1
	assert preds[0].tool == 'list_dir'
	assert jstr(preds[0].args, 'path') == '.'
	assert preds[0].why == 'default cwd probe'
}

fn test_a_prefetched_call_is_served_from_the_cache_once() {
	mut s := new_spec('spec1')
	n := s.speculate('please look at src/main.py and fix it', [])
	assert n >= 1, '${n}'
	assert 'read_file' in spec_calls

	got := s.serve('read_file', {
		'path': json2.Any('src/main.py')
	}) or { panic('expected a cache hit') }
	assert got.starts_with('OK:read_file')
	assert s.hits == 1

	// asking again is a miss: the entry was consumed
	assert s.serve('read_file', {
		'path': json2.Any('src/main.py')
	}) == none
	assert s.misses == 1
}

fn test_a_write_tool_can_never_be_served_speculatively() {
	mut s := new_spec('spec2')
	assert s.serve('write_file', {
		'path':    json2.Any('x')
		'content': json2.Any('y')
	}) == none
	// and it is not even counted as a miss: it was never a candidate
	assert s.misses == 0
	for t in speculative_tools {
		assert t !in write_tools, t
	}
}

fn test_an_erroring_prefetch_is_dropped_never_cached() {
	mut s := new_spec('spec3')
	s.speculate('read missing/file.txt', [])
	assert s.serve('read_file', {
		'path': json2.Any('missing/file.txt')
	}) == none
}

fn test_a_stale_entry_is_evicted_after_its_ttl() {
	mut s := new_spec('spec4')
	s.speculate('look at src/main.py', [])
	assert s.cache.len > 0
	for _ in 0 .. cache_ttl_turns + 2 {
		s.speculate('hello there', [])
	}
	assert s.serve('read_file', {
		'path': json2.Any('src/main.py')
	}) == none
	kinds := s.log.events('main').map(it.typ)
	assert 'spec.evict' in kinds
}

fn test_the_hit_rate_is_folded_from_the_ledger() {
	mut s := new_spec('spec5')
	s.speculate('look at src/main.py', [])
	s.serve('read_file', {
		'path': json2.Any('src/main.py')
	})
	s.serve('read_file', {
		'path': json2.Any('nowhere.py')
	})
	st := s.stats()
	assert jint(st, 'hits') == 1
	assert jint(st, 'misses') == 1
	assert jf64(st, 'hit_rate') == 0.5
	assert jint(st, 'prefetched') >= 1

	text := s.format_status()
	assert text.contains('SPECULATOR')
	assert text.contains('hit-rate 50%')
	assert text.contains('read_file')
}

fn test_a_speculator_with_no_runner_prefetches_nothing() {
	mut s := new_speculator(new_event_log(tmp_log_path('spec6'), 'main', 'test'), unsafe { nil })
	assert s.speculate('look at src/main.py', []) == 0
}
