module vagent

fn rx(p string) Regex {
	return compile_regex(p) or { panic('compile ${p}: ${err}') }
}

fn test_literals_and_dot() {
	assert rx('abc').matches('xxabcyy')
	assert !rx('abc').matches('abd')
	assert rx('a.c').matches('abc')
	assert rx('a.c').matches('a c')
	assert !rx('a.c').matches('ac')
	// `.` does not cross a newline unless dotall is set
	assert !rx('a.c').matches('a\nc')
	dotall := compile_regex_flags('a.c', RxFlags{ dotall: true }) or { panic(err) }
	assert dotall.matches('a\nc')
}

fn test_alternation_the_stdlib_could_not_do() {
	re := rx('foo|bar')
	assert re.matches('xxbarxx')
	assert re.matches('a foo b')
	assert !re.matches('baz')
	// alternation inside a group, with a suffix that must still match
	assert rx('(cat|dog)s').matches('two dogs here')
	assert !rx('(cat|dog)s').matches('two dog here')
}

fn test_quantifiers() {
	assert rx('ab*c').matches('ac')
	assert rx('ab*c').matches('abbbc')
	assert !rx('ab+c').matches('ac')
	assert rx('ab+c').matches('abc')
	assert rx('ab?c').matches('ac')
	assert rx('a{2}b').matches('aab')
	assert !rx('a{2}b').matches('ab')
	assert rx('a{2,}b').matches('aaaab')
	assert rx('a{2,3}b').matches('aaab')
	// search semantics: 'aaaab' contains 'aaab' from index 1, so it DOES
	// match — only a full match rejects the extra leading 'a'
	assert rx('a{2,3}b').matches('aaaab')
	assert !rx('a{2,3}b').full_match('aaaab')
	assert !rx('a{2,3}b').matches('ab')
}

fn test_lazy_vs_greedy() {
	greedy := rx('<.*>').search('<a><b>') or { panic('no match') }
	assert greedy.text == '<a><b>'
	lazy := rx('<.*?>').search('<a><b>') or { panic('no match') }
	assert lazy.text == '<a>'
}

fn test_classes_and_escapes() {
	assert rx(r'\d+').matches('abc 1234')
	assert !rx(r'\d+').matches('abcd')
	assert rx(r'\w+').matches('hello_1')
	assert rx(r'\s').matches('a b')
	assert rx('[abc]').matches('xbx')
	assert !rx('[abc]').matches('xyz')
	assert rx('[^abc]').matches('xyz')
	assert rx('[a-f0-9]+').matches('deadbeef')
	assert rx(r'[\d.]+').matches('3.14')
	// a `-` at the end of a class is a literal
	assert rx('[a-]').matches('-')
}

fn test_anchors_and_word_boundaries() {
	assert rx('^abc').matches('abcdef')
	assert !rx('^abc').matches('xabcdef')
	assert rx('abc$').matches('xxabc')
	assert !rx('abc$').matches('abcx')
	assert rx(r'\bcat\b').matches('a cat sat')
	assert !rx(r'\bcat\b').matches('concatenate')
	assert rx(r'\Bcat').matches('concat')

	ml := compile_regex_flags('^bar', RxFlags{ multiline: true }) or { panic(err) }
	assert ml.matches('foo\nbar')
	assert !rx('^bar').matches('foo\nbar')
}

fn test_inline_flags() {
	assert rx('(?i)hello').matches('say HELLO now')
	assert !rx('hello').matches('say HELLO now')
	assert rx('(?i)[a-z]+').matches('ABC')
	assert rx('(?im)^warn').matches('ok\nWARNING')
}

fn test_capture_groups() {
	re := rx(r'(\d+)\.(\d+)')
	m := re.search('version 12.34 here') or { panic('no match') }
	assert m.text == '12.34'
	assert group_text('version 12.34 here', &m, 1) == '12'
	assert group_text('version 12.34 here', &m, 2) == '34'
	assert group_text('version 12.34 here', &m, 0) == '12.34'

	// a non-capturing group does not consume a group number
	re2 := rx(r'(?:a|b)(\d)')
	m2 := re2.search('b7') or { panic('no match') }
	assert group_text('b7', &m2, 1) == '7'
}

fn test_find_all_and_replace() {
	re := rx(r'\d+')
	all := re.find_all('a1 b22 c333')
	assert all.map(it.text) == ['1', '22', '333']
	assert re.replace_all('a1 b22', '#') == 'a# b#'

	tags := rx('<[^>]+>')
	assert tags.replace_all('<b>hi</b>', ' ') == ' hi '

	caps := rx(r'(\w+)=(\w+)')
	assert caps.replace_all('a=1,b=2', '$2:$1') == '1:a,2:b'
}

fn test_full_match_vs_search() {
	re := rx(r'\d+')
	assert re.matches('abc123')
	assert !re.full_match('abc123')
	assert re.full_match('123')
}

fn test_literal_braces_are_not_quantifiers() {
	// `interface{}` is a real search people run; the brace must stay literal
	assert rx(r'interface\{\}').matches('var x interface{}')
	assert rx('a{x}').matches('a{x}')
}

fn test_bad_patterns_error_rather_than_matching_nothing() {
	if _ := compile_regex('(unclosed') {
		assert false, 'unbalanced ( compiled'
	}
	if _ := compile_regex('[unclosed') {
		assert false, 'unterminated [ compiled'
	}
	if _ := compile_regex('*bad') {
		assert false, 'leading quantifier compiled'
	}
}

fn test_nested_groups_and_alternation() {
	re := rx('^(GET|POST) (/[a-z/]*) HTTP/(1\\.1|2)\$')
	m := re.search('POST /api/users HTTP/1.1') or { panic('no match') }
	line := 'POST /api/users HTTP/1.1'
	assert group_text(line, &m, 1) == 'POST'
	assert group_text(line, &m, 2) == '/api/users'
	assert group_text(line, &m, 3) == '1.1'
	assert !re.matches('PUT /api HTTP/1.1')
}

fn test_lookahead_asserts_without_consuming() {
	// the shape the specification's @output rules use
	re := compile_regex(r'(?i)tests? (pass|fail)\w*(?![^.]*exit)') or { panic(err) }
	assert re.matches('The tests pass.')
	assert !re.matches('tests pass with exit 0.')

	// positive lookahead
	pos := compile_regex(r'foo(?=bar)') or { panic(err) }
	m := pos.search('foobar') or { panic('no match') }
	assert m.start == 0 && m.end == 3, '${m.start}..${m.end}'
	assert !pos.matches('foobaz')

	// it is zero-width: the assertion's text is still available afterwards
	both := compile_regex(r'(?=ab)a\w') or { panic(err) }
	assert both.full_match('ab')

	// a negative lookahead at the end of the pattern
	neg := compile_regex(r'\d+(?!%)') or { panic(err) }
	assert neg.matches('42 items')

	// alternation inside the assertion works like anywhere else
	alt := compile_regex(r'x(?!(a|b))') or { panic(err) }
	assert alt.matches('xc')
	assert !alt.matches('xa')
	assert !alt.matches('xb')

	// lookbehind and named groups are still refused, and say so
	if _ := compile_regex(r'(?<=a)b') {
		assert false, 'lookbehind must be refused'
	} else {
		assert err.msg().contains('lookbehind')
	}
	if _ := compile_regex(r'(?P<name>a)') {
		assert false, 'named groups must be refused'
	} else {
		assert err.msg().contains('named groups')
	}
}

fn test_hex_escapes_name_a_character_by_its_code() {
	// the shape effects.v uses for a quote inside a raw-string pattern
	q := compile_regex(r'["\x27]') or { panic(err) }
	assert q.matches("'")
	assert q.matches('"')
	assert !q.matches('x')

	// outside a class too
	bare := compile_regex(r'a\x2Ab') or { panic(err) }
	assert bare.full_match('a*b')
	assert !bare.full_match('aab')

	// a range whose ends are hex escapes
	digits := compile_regex(r'^[\x30-\x39]+$') or { panic(err) }
	assert digits.matches('907')
	assert !digits.matches('9a7')

	// \u for anything wider than a byte
	wide := compile_regex(r'é') or { panic(err) }
	assert wide.matches('café')

	// a malformed escape falls back to the literal letter rather than
	// failing the whole pattern
	short := compile_regex(r'a\xZZ') or { panic(err) }
	assert short.matches('axZZ')
}
