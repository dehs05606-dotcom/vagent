module main

import src.utils

fn test_glob_match_single_star_stays_in_segment() {
	assert utils.glob_match('*.v', 'main.v')
	assert utils.glob_match('src/*.v', 'src/main.v')
	// A single star must not cross a directory separator.
	assert !utils.glob_match('src/*.v', 'src/tools/main.v')
	assert !utils.glob_match('*.v', 'src/main.v')
}

fn test_glob_match_double_star_crosses_segments() {
	assert utils.glob_match('**/*.v', 'src/tools/shell.v')
	assert utils.glob_match('src/**/*.v', 'src/a/b/c.v')
	// `**/` also has to match zero directories.
	assert utils.glob_match('**/*.v', 'main.v')
	assert !utils.glob_match('**/*.go', 'src/main.v')
}

fn test_glob_match_question_mark_and_exact() {
	assert utils.glob_match('test_?.v', 'test_1.v')
	assert !utils.glob_match('test_?.v', 'test_12.v')
	assert utils.glob_match('exact.txt', 'exact.txt')
	assert utils.glob_match('*', 'anything')
}

fn test_truncate_marks_the_cut() {
	assert utils.truncate('hello', 100) == 'hello'
	out := utils.truncate('abcdefghij', 4)
	assert out.starts_with('abcd')
	assert out.contains('truncated')
}

fn test_truncate_middle_keeps_both_ends() {
	long := 'H'.repeat(100) + 'MIDDLE' + 'T'.repeat(100)
	out := utils.truncate_middle(long, 40)
	assert out.starts_with('HHHH')
	assert out.ends_with('TTTT')
	assert out.contains('omitted')
	assert !out.contains('MIDDLE')
}

fn test_first_sentence_survives_abbreviations() {
	assert utils.first_sentence('Find files by glob, e.g. "**/*.v". Returns paths.') == 'Find files by glob, e.g. "**/*.v"'
	assert utils.first_sentence('One sentence only') == 'One sentence only'
	assert utils.first_sentence('First. Second.') == 'First'
}

fn test_count_lines_ignores_trailing_newline() {
	assert utils.count_lines('') == 0
	assert utils.count_lines('a') == 1
	assert utils.count_lines('a\n') == 1
	assert utils.count_lines('a\nb') == 2
	assert utils.count_lines('a\nb\n') == 2
}

fn test_estimate_tokens_scales_with_length() {
	assert utils.estimate_tokens('') == 0
	short := utils.estimate_tokens('hello world')
	long := utils.estimate_tokens('hello world'.repeat(10))
	assert long > short
}

fn test_human_count_abbreviates() {
	assert utils.human_count(999) == '999'
	assert utils.human_count(1500) == '1.5K'
	assert utils.human_count(2500000) == '2.50M'
}

fn test_parse_object_tolerates_empty_arguments() {
	empty := utils.parse_object('') or { panic(err) }
	assert empty.len == 0
	obj := utils.parse_object('{"a": 1}') or { panic(err) }
	assert utils.jint(obj, 'a', 0) == 1
	// A JSON array is not a valid tool-argument object.
	if _ := utils.parse_object('[1,2]') {
		assert false, 'an array should not decode as an object'
	}
}

fn test_json_getters_coerce_and_default() {
	obj := utils.parse_object('{"s":"x","n":"7","b":"yes","f":2.5,"nil":null}') or { panic(err) }
	assert utils.jstr(obj, 's', '') == 'x'
	assert utils.jint(obj, 'n', 0) == 7
	assert utils.jbool(obj, 'b', false) == true
	assert utils.jf64(obj, 'f', 0.0) == 2.5
	// A null value falls back to the default rather than producing an empty one.
	assert utils.jstr(obj, 'nil', 'fallback') == 'fallback'
	assert utils.jstr(obj, 'absent', 'fallback') == 'fallback'
}
