module tools

import os
import regex
import strings
import x.json2
import src.utils

// max_scanned_files bounds a search so a stray `**/*` on a huge monorepo does
// not hang the agent loop.
const max_scanned_files = 20000

// -------------------------------------------------------------- search_files

pub struct SearchFilesTool {}

pub fn (t SearchFilesTool) spec() Spec {
	return Spec{
		name:          'search_files'
		description:   'Find files by glob pattern, e.g. "**/*.v" or "src/**/test_*.py". Returns paths relative to the project root, most recently modified first.'
		level:         .read
		summary_param: 'pattern'
		params:        [
			Param{
				name:        'pattern'
				description: 'Glob pattern. `*` matches within one path segment, `**` matches across segments.'
				required:    true
			},
			Param{
				name:        'path'
				description: 'Directory to search under. Defaults to the working directory.'
			},
			Param{
				name:        'max_results'
				typ:         'integer'
				description: 'Cap on returned paths. Defaults to 200.'
			},
		]
	}
}

pub fn (t SearchFilesTool) execute(mut ctx Context, args map[string]json2.Any) Result {
	pattern := utils.jstr(args, 'pattern', '')
	if pattern == '' {
		return fail_result('pattern is required')
	}
	base := ctx.resolve_path(utils.jstr(args, 'path', '.')) or { return fail_result(err.msg()) }
	if !os.is_dir(base) {
		return fail_result('${ctx.rel(base)} is not a directory')
	}
	max_results := if m := utils.jget(args, 'max_results') { m.int() } else { 200 }
	files := collect_files(base, max_scanned_files)
	mut hits := []FileHit{}
	for f in files {
		rel := relative_to(base, f)
		if utils.glob_match(pattern, rel) || utils.glob_match(pattern, os.base(f)) {
			hits << FileHit{
				path:  f
				mtime: os.file_last_mod_unix(f)
			}
		}
	}
	if hits.len == 0 {
		return ok_result('no files matched "${pattern}" under ${ctx.rel(base)}', 'no matches')
	}
	hits.sort(a.mtime > b.mtime)
	mut sb := strings.new_builder(1024)
	shown := if hits.len < max_results { hits.len } else { max_results }
	for i in 0 .. shown {
		sb.write_string('${ctx.rel(hits[i].path)}\n')
	}
	if hits.len > shown {
		sb.write_string('... [${hits.len - shown} more matches not shown]\n')
	}
	return ok_result(sb.str(), '${hits.len} file(s) match "${pattern}"')
}

struct FileHit {
	path  string
	mtime i64
}

// --------------------------------------------------------------- search_text

pub struct SearchTextTool {}

pub fn (t SearchTextTool) spec() Spec {
	return Spec{
		name:          'search_text'
		description:   'Search file contents and return matching lines with file:line prefixes. This is the fastest way to locate a symbol, a config key or an error string across the project.'
		level:         .read
		summary_param: 'pattern'
		params:        [
			Param{
				name:        'pattern'
				description: 'Text to look for. Treated as a regular expression when regex=true, otherwise as a literal substring.'
				required:    true
			},
			Param{
				name:        'path'
				description: 'Directory or single file to search. Defaults to the working directory.'
			},
			Param{
				name:        'glob'
				description: 'Only search files whose relative path matches this glob, e.g. "**/*.v".'
			},
			Param{
				name:        'regex'
				typ:         'boolean'
				description: 'Interpret pattern as a regular expression.'
			},
			Param{
				name:        'ignore_case'
				typ:         'boolean'
				description: 'Case-insensitive matching. Defaults to false.'
			},
			Param{
				name:        'max_results'
				typ:         'integer'
				description: 'Cap on matching lines. Defaults to 200.'
			},
		]
	}
}

pub fn (t SearchTextTool) execute(mut ctx Context, args map[string]json2.Any) Result {
	pattern := utils.jstr(args, 'pattern', '')
	if pattern == '' {
		return fail_result('pattern is required')
	}
	base := ctx.resolve_path(utils.jstr(args, 'path', '.')) or { return fail_result(err.msg()) }
	glob := utils.jstr(args, 'glob', '')
	use_regex := utils.jbool(args, 'regex', false)
	ignore_case := utils.jbool(args, 'ignore_case', false)
	max_results := if m := utils.jget(args, 'max_results') { m.int() } else { 200 }

	// V's regex engine has no case-insensitive flag, so fold the pattern and
	// the haystack instead. For literal search we fold both the same way.
	needle := if ignore_case { pattern.to_lower() } else { pattern }
	mut re := regex.RE{}
	if use_regex {
		re = regex.regex_opt(needle) or {
			return fail_result('invalid regular expression "${pattern}": ${err.msg()}')
		}
	}

	targets := if os.is_dir(base) {
		collect_files(base, max_scanned_files)
	} else {
		[base]
	}
	mut sb := strings.new_builder(4096)
	mut matches := 0
	mut files_hit := 0
	mut truncated := false
	for f in targets {
		rel_for_glob := relative_to(base, f)
		if glob != '' && !utils.glob_match(glob, rel_for_glob)
			&& !utils.glob_match(glob, os.base(f)) {
			continue
		}
		content := os.read_file(f) or { continue }
		if looks_binary(content) {
			continue
		}
		mut file_matched := false
		for i, line in content.split('\n') {
			hay := if ignore_case { line.to_lower() } else { line }
			found := if use_regex {
				start, _ := re.find(hay)
				start >= 0
			} else {
				hay.contains(needle)
			}
			if !found {
				continue
			}
			if !file_matched {
				file_matched = true
				files_hit++
			}
			matches++
			if matches > max_results {
				truncated = true
				break
			}
			sb.write_string('${ctx.rel(f)}:${i + 1}: ${utils.truncate(line.trim_right('\r'), 400)}\n')
		}
		if truncated {
			break
		}
	}
	if matches == 0 {
		return ok_result('no matches for "${pattern}"', 'no matches')
	}
	if truncated {
		sb.write_string('... [stopped at ${max_results} matches; narrow the search with path= or glob=]\n')
	}
	return ok_result(sb.str(), '${matches} match(es) in ${files_hit} file(s)')
}

// ------------------------------------------------------------------ helpers

// collect_files walks a directory tree, skipping generated and VCS folders,
// and stops once `limit` files have been seen.
fn collect_files(base string, limit int) []string {
	mut out := []string{cap: 256}
	mut stack := [base]
	for stack.len > 0 {
		dir := stack.pop()
		entries := os.ls(dir) or { continue }
		for e in entries {
			full := os.join_path(dir, e)
			if os.is_dir(full) {
				if is_skipped_dir(e) {
					continue
				}
				stack << full
			} else if os.is_file(full) {
				out << full
				if out.len >= limit {
					return out
				}
			}
		}
	}
	return out
}

fn relative_to(base string, path string) string {
	prefix := os.norm_path(base) + os.path_separator
	if path.starts_with(prefix) {
		return path#[prefix.len..].replace('\\', '/')
	}
	return path.replace('\\', '/')
}
