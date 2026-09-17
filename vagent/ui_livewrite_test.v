module vagent

// ui_livewrite_test.v — the streaming JSON field reader.
//
// The interesting cases are all chunk boundaries: the model's stream splits
// wherever it likes, and every split has to be resumable.

fn test_a_whole_field_arriving_at_once_yields_its_lines() {
	mut w := new_live_write('content')
	out := w.feed('{"path": "a.txt", "content": "one\\ntwo\\nthree"}')
	assert out == ['one', 'two']
	assert w.flush() or { '' } == 'three'
	assert w.lines == 3
}

fn test_the_path_is_withheld_until_its_closing_quote_arrives() {
	mut w := new_live_write('content')
	w.feed('{"path": "src/parser')
	assert w.path() == none, 'a half-read path would name the wrong file'
	w.feed('.v", "content": "x')
	assert w.path() or { '' } == 'src/parser.v'
}

fn test_a_chunk_boundary_inside_an_escape_is_resumable() {
	mut w := new_live_write('content')
	// the chunk ends on the backslash of \n
	assert w.feed('{"content": "one\\') == []
	assert w.feed('ntwo\\n') == ['one', 'two']
}

fn test_a_chunk_boundary_inside_a_unicode_escape_is_resumable() {
	mut w := new_live_write('content')
	assert w.feed('{"content": "caf\\u00') == []
	// the complete prefix is decoded; the half escape is NOT consumed
	assert w.pending == 'caf'
	assert w.feed('e9 au lait"}') == []
	assert w.done
	assert w.flush() or { '' } == 'café au lait'
}

fn test_the_closing_quote_ends_the_field_and_the_rest_of_the_json_is_ignored() {
	mut w := new_live_write('content')
	w.feed('{"content": "done\\n", "path": "x.txt"}')
	assert w.done
	// trailing JSON must not leak into the file preview
	assert w.feed(', "more": "junk\\nlines"') == []
	assert w.flush() == none
}

fn test_every_json_escape_decodes_to_the_byte_it_names() {
	text, consumed, done := json_unescape('a\\nb\\tc\\\\d\\"e\\/f"tail')
	assert text == 'a\nb\tc\\d"e/f'
	assert done
	assert consumed == 'a\\nb\\tc\\\\d\\"e\\/f"'.len
}

fn test_an_unknown_escape_is_passed_through_rather_than_swallowed() {
	// the original kept the backslash; silently dropping it would corrupt
	// the content shown for the file
	text, _, _ := json_unescape('a\\qb"')
	assert text == 'a\\qb'
}

fn test_a_malformed_unicode_escape_is_passed_through_verbatim() {
	text, _, _ := json_unescape('x\\uZZZZy"')
	assert text == 'x\\uZZZZy'
}

fn test_an_unfinished_value_reports_what_it_consumed() {
	text, consumed, done := json_unescape('partial')
	assert text == 'partial'
	assert consumed == 7
	assert !done
}

fn test_the_key_is_matched_as_a_json_key_not_as_a_substring() {
	mut w := new_live_write('content')
	// "content" appears inside another value first; the tracker must wait
	// for the real key rather than streaming the decoy
	out := w.feed('{"note": "the content field", "content": "real\\n"}')
	assert out == ['real']
}

fn test_whitespace_between_the_key_and_its_value_is_allowed() {
	assert json_field('{"path"   :   "spaced.txt"}', 'path') or { '' } == 'spaced.txt'
	assert json_field('{"path":"tight.txt"}', 'path') or { '' } == 'tight.txt'
}

fn test_a_missing_field_is_none_not_an_empty_string() {
	assert json_field('{"other": "x"}', 'path') == none
}

fn test_a_tracker_fed_shapeless_json_simply_produces_nothing() {
	mut w := new_live_write('content')
	assert w.feed('not json at all') == []
	assert w.feed('[1, 2, 3]') == []
	assert w.flush() == none
	assert w.lines == 0
}

fn test_edit_file_streams_new_string_while_old_string_is_read_whole() {
	mut w := new_live_write('new_string')
	w.feed('{"path": "x.v", "old_string": "was here", "new_string": "now\\nhere')
	assert json_field(w.buf, 'old_string') or { '' } == 'was here'
	assert w.path() or { '' } == 'x.v'
	assert w.lines == 1
}
