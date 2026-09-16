module vagent

import os

fn test_no_embedded_harness_carries_a_control_character() {
	// A `\b` inside a borrowed regex once became a backspace byte here, and
	// the safety gate it belonged to silently stopped matching. Nothing
	// crashed; the check simply evaporated. This is the test that would
	// have caught it.
	for name, text in embedded_harnesses() {
		offsets := harness_control_bytes(text)
		assert offsets.len == 0, '${name}: control bytes at ${offsets}'
	}
}

fn test_no_embedded_page_carries_a_control_character() {
	for name, text in embedded_pages() {
		offsets := harness_control_bytes(text)
		assert offsets.len == 0, '${name}: control bytes at ${offsets}'
	}
	// and the page really is self-contained: nothing to fetch at view time
	page := embedded_pages()['tower_page'] or { '' }
	assert page.len > 1000
	assert !page.contains('http://')
	assert !page.contains('https://')
	assert page.contains('CONTROL TOWER')
	assert page.contains('/api/events')
}

fn test_every_embedded_harness_still_parses_as_python() {
	python := find_python() or {
		eprintln('harness: no python interpreter — skipping')
		return
	}
	dir := os.join_path(os.temp_dir(), 'vagent-harness-check-${os.getpid()}')
	os.mkdir_all(dir) or { panic(err) }
	defer {
		os.rmdir_all(dir) or {}
	}
	for name, text in embedded_harnesses() {
		path := os.join_path(dir, '${name}.py')
		os.write_file(path, text) or { panic(err) }
		// a harness that does not compile will never judge anything, and
		// the module that owns it would report an unreadable-output error
		// rather than the analysis it promised
		res := os.execute('${quote_arg(python)} -c ' + quote_arg('import ast,sys; ast.parse(open(sys.argv[1]).read())') + ' ' + quote_arg(path))
		assert res.exit_code == 0, '${name}: ${res.output.trim_space()}'
	}
}

fn test_every_harness_is_named_and_non_empty() {
	harnesses := embedded_harnesses()
	for want in ['cov', 'taint', 'kgraph', 'mutate', 'skills', 'synth'] {
		text := harnesses[want] or { '' }
		assert text.len > 200, '${want} is ${text.len} chars'
	}
	assert harnesses.len == 6
}

fn test_the_control_byte_check_actually_detects_one() {
	assert harness_control_bytes('clean source\n\ttabbed\n').len == 0
	// the exact corruption that got through: a word-boundary escape that
	// became a backspace
	assert harness_control_bytes('r"\x08(exec|eval)\x08"') == [2, 14]
}
