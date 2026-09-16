module vagent

import os
import x.json2

// tools.v — the tool registry: everything the agent can do, over files,
// the shell, search and the web.

// ---------------------------------------------------------------------------
// Tool definition
// ---------------------------------------------------------------------------

pub const risk_safe = 'safe' // runs without asking
pub const risk_confirm = 'confirm' // needs user approval (unless auto-approve)

// ToolHandler takes the parsed arguments object and returns the tool's
// textual result. `sink` streams live output; pass `no_sink` for none.
pub type ToolHandler = fn (args map[string]json2.Any, sink OutputSink) string

pub struct Tool {
pub:
	name        string
	description string
	parameters  map[string]json2.Any
	handler     ToolHandler @[required]
	risk        string = risk_safe
pub mut:
	// True once Covenant.arm() has wrapped the handler in the boundary.
	// An executor holding an unguarded registry can act outside the
	// specification, so this is assertable rather than assumed.
	guarded bool
}

pub fn (t &Tool) openai_schema() map[string]json2.Any {
	return {
		'type':     json2.Any('function')
		'function': json2.Any({
			'name':        json2.Any(t.name)
			'description': json2.Any(t.description)
			'parameters':  json2.Any(t.parameters)
		})
	}
}

// clip_tool_output trims a tool result to the output ceiling, keeping the
// head and the tail — the two parts that carry the command's intent and its
// verdict. A middle-out clip is what makes a 300k-line build log readable
// without losing the error at the end.
pub fn clip_tool_output(text string) string {
	return clip_middle(text, max_tool_output_chars)
}

fn clip_middle(text string, limit int) string {
	if text.len <= limit {
		return text
	}
	head := text[..limit / 2]
	tail := text[text.len - limit / 4..]
	dropped := text.len - head.len - tail.len
	return '${head}\n… [${dropped} chars truncated] …\n${tail}'
}

// resolve_path expands `~` and makes a relative path absolute against the
// process working directory.
pub fn resolve_path(path string) string {
	mut p := path
	if p.starts_with('~') {
		p = os.home_dir() + p[1..]
	}
	if !os.is_abs_path(p) {
		p = os.join_path(os.getwd(), p)
	}
	return os.norm_path(p)
}

// edit_report is the live-coding style receipt: 'Updated X with N additions
// and M removals' — so the caller sees exactly what changed at a glance.
fn edit_report(path string, old string, new string) string {
	adds, removes := diff_summary(old, new)
	return 'Updated ${path} with ${adds} addition(s) and ${removes} removal(s)'
}

// line_numbered renders a file chunk the way read_file shows it: the first,
// last and every tenth line carry their number and an arrow, the rest are
// aligned under it. Numbering every line turns a 1000-line read into a wall
// of digits the model then has to look past.
fn line_numbered(text string, start int) string {
	lines := split_lines(text)
	if lines.len == 0 {
		return ''
	}
	width := (start + lines.len - 1).str().len
	mut out := []string{cap: lines.len}
	for i, line in lines {
		n := start + i
		if n == start || n == start + lines.len - 1 || n % 10 == 0 {
			num := n.str()
			pad := ' '.repeat(width - num.len)
			out << '${pad}${num}→${line}'
		} else {
			out << '${" ".repeat(width)} ${line}'
		}
	}
	return out.join('\n')
}

// ---------------------------------------------------------------------------
// File tools
// ---------------------------------------------------------------------------

// tool_read_file reads a text file with line numbers.
pub fn tool_read_file(path string, offset_in int, limit int) string {
	p := resolve_path(path)
	if !os.exists(p) {
		return 'ERROR: file not found: ${p}'
	}
	if os.is_dir(p) {
		return 'ERROR: ${p} is a directory (use list_dir)'
	}
	size := os.file_size(p)
	if size > 2_000_000 {
		return 'ERROR: file is very large (${size} bytes); use offset/limit'
	}
	text := os.read_file(p) or { return 'ERROR: ${err.msg()}' }
	lines := split_lines(text)
	offset := if offset_in < 1 { 1 } else { offset_in }
	if offset > lines.len {
		return '[${p} — ${lines.len} lines total; offset ${offset} is past the end of file]'
	}
	mut end_idx := offset - 1 + limit
	if end_idx > lines.len {
		end_idx = lines.len
	}
	chunk := lines[offset - 1..end_idx]
	end := offset + chunk.len - 1
	header := '[${p} — ${lines.len} lines total, showing ${offset}..${end}]'
	return '${header}\n${line_numbered(chunk.join("\n"), offset)}'
}

// tool_write_file creates or overwrites a file (parents created
// automatically).
pub fn tool_write_file(path string, content string) string {
	p := resolve_path(path)
	existed := os.exists(p)
	old := if existed { os.read_file(p) or { '' } } else { '' }
	atomic_write_text(p, content) or { return 'ERROR: ${err.msg()}' }
	if !existed || old == '' {
		// brand-new file — a pure-addition report reads better
		adds := split_lines(content).len
		return 'OK: created ${p} with ${adds} line(s) (${content.len} chars)'
	}
	adds, removes := diff_summary(old, content)
	return 'Updated ${p} with ${adds} addition(s) and ${removes} removal(s)'
}

// tool_edit_file replaces an exact string in a file. old_string must match
// exactly once (or set replace_all=true to replace every occurrence).
pub fn tool_edit_file(path string, old_string string, new_string string, replace_all bool) string {
	p := resolve_path(path)
	if !os.exists(p) {
		return 'ERROR: file not found: ${p}'
	}
	if old_string == '' {
		// counting the empty string finds len+1 positions, and replacing it
		// would interleave new_string between EVERY character — destroying
		// the file
		return 'ERROR: old_string must be a non-empty string'
	}
	text := os.read_file(p) or { return 'ERROR: ${err.msg()}' }
	if !text.is_pure_ascii() && !is_valid_utf8(text) {
		return 'ERROR: file is not valid UTF-8 text; refusing to edit ' +
			'(lossy rewrite would corrupt unrelated bytes)'
	}
	count := text.count(old_string)
	if count == 0 {
		return 'ERROR: old_string not found in file (it must match exactly, ' +
			'including indentation)'
	}
	if count > 1 && !replace_all {
		return 'ERROR: old_string matches ${count} places; add more context ' +
			'to make it unique or set replace_all=true'
	}
	new_text := if replace_all {
		text.replace(old_string, new_string)
	} else {
		text.replace_once(old_string, new_string)
	}
	atomic_write_text(p, new_text) or { return 'ERROR: ${err.msg()}' }
	adds, removes := diff_summary(text, new_text)
	n := if replace_all { count } else { 1 }
	return 'Updated ${p} — ${n} occurrence(s) replaced, ${adds} addition(s), ' +
		'${removes} removal(s)'
}

// is_valid_utf8 reports whether a byte string decodes as UTF-8. Editing a
// binary file through a text round-trip silently rewrites every byte the
// decoder could not represent.
fn is_valid_utf8(s string) bool {
	mut i := 0
	for i < s.len {
		b := s[i]
		mut extra := 0
		if b < 0x80 {
			i++
			continue
		} else if b & 0xE0 == 0xC0 {
			extra = 1
		} else if b & 0xF0 == 0xE0 {
			extra = 2
		} else if b & 0xF8 == 0xF0 {
			extra = 3
		} else {
			return false
		}
		if i + extra >= s.len {
			return false
		}
		for k := 1; k <= extra; k++ {
			if s[i + k] & 0xC0 != 0x80 {
				return false
			}
		}
		i += extra + 1
	}
	return true
}

// tool_list_dir lists a directory's contents (one level).
pub fn tool_list_dir(path string) string {
	p := resolve_path(path)
	if !os.is_dir(p) {
		return 'ERROR: not a directory: ${p}'
	}
	names := os.ls(p) or { return 'ERROR: ${err.msg()}' }
	// directories first, then files, each alphabetical case-insensitively
	mut dirs := []string{}
	mut files := []string{}
	for n in names {
		if os.is_dir(os.join_path(p, n)) {
			dirs << n
		} else {
			files << n
		}
	}
	dirs.sort_with_compare(fn (a &string, b &string) int {
		return compare_strings(a.to_lower(), b.to_lower())
	})
	files.sort_with_compare(fn (a &string, b &string) int {
		return compare_strings(a.to_lower(), b.to_lower())
	})
	mut entries := dirs.clone()
	entries << files
	mut lines := ['[${p}]']
	mut shown := 0
	for name in entries {
		if shown >= 300 {
			break
		}
		full := os.join_path(p, name)
		if os.is_dir(full) {
			lines << '  ${name}/'
		} else if os.exists(full) {
			lines << '  ${name}  (${os.file_size(full)} bytes)'
		} else {
			// broken symlink or vanished entry — don't crash the listing
			lines << '  ${name}  (unreadable)'
		}
		shown++
	}
	if entries.len > 300 {
		lines << '  … and ${entries.len - 300} more'
	}
	return if lines.len > 1 { lines.join('\n') } else { '[${p}] (empty)' }
}

// tool_file_info shows metadata about a file or directory.
pub fn tool_file_info(path string) string {
	p := resolve_path(path)
	if !os.exists(p) {
		return 'ERROR: not found: ${p}'
	}
	kind := if os.is_dir(p) { 'directory' } else { 'file' }
	size := os.file_size(p)
	mtime := os.file_last_mod_unix(p)
	return '${p}\n  type: ${kind}\n  size: ${size} bytes\n  modified: ${mtime}'
}

pub fn tool_create_directory(path string) string {
	p := resolve_path(path)
	os.mkdir_all(p) or { return 'ERROR: ${err.msg()}' }
	return 'OK: created directory ${p}'
}

pub fn tool_copy_path(src string, dst string) string {
	s := resolve_path(src)
	d := resolve_path(dst)
	if !os.exists(s) {
		return 'ERROR: source not found: ${s}'
	}
	if os.is_dir(s) {
		copy_tree(s, d) or { return 'ERROR: ${err.msg()}' }
	} else {
		parent := os.dir(d)
		if parent != '' {
			os.mkdir_all(parent) or { return 'ERROR: ${err.msg()}' }
		}
		os.cp(s, d) or { return 'ERROR: ${err.msg()}' }
	}
	return 'OK: copied ${s} -> ${d}'
}

// copy_tree is shutil.copytree(dirs_exist_ok=True): merge into an existing
// destination rather than failing on it.
fn copy_tree(src string, dst string) ! {
	os.mkdir_all(dst)!
	for name in os.ls(src)! {
		s := os.join_path(src, name)
		d := os.join_path(dst, name)
		if os.is_dir(s) {
			copy_tree(s, d)!
		} else {
			os.cp(s, d)!
		}
	}
}

pub fn tool_move_path(src string, dst string) string {
	s := resolve_path(src)
	d := resolve_path(dst)
	if !os.exists(s) {
		return 'ERROR: source not found: ${s}'
	}
	parent := os.dir(d)
	if parent != '' {
		os.mkdir_all(parent) or { return 'ERROR: ${err.msg()}' }
	}
	os.mv(s, d) or { return 'ERROR: ${err.msg()}' }
	return 'OK: moved ${s} -> ${d}'
}

pub fn tool_delete_path(path string) string {
	p := resolve_path(path)
	if !os.exists(p) {
		return 'ERROR: not found: ${p}'
	}
	if os.is_dir(p) {
		os.rmdir_all(p) or { return 'ERROR: ${err.msg()}' }
	} else {
		os.rm(p) or { return 'ERROR: ${err.msg()}' }
	}
	return 'OK: deleted ${p}'
}

// ---------------------------------------------------------------------------
// Search tools
// ---------------------------------------------------------------------------

// tool_search_files runs a regex search through file contents
// (ripgrep-style), respecting common ignore dirs. Returns matching lines as
// path:line:content.
pub fn tool_search_files(pattern string, path string, glob_filter string, max_results int) string {
	root := resolve_path(path)
	mut files := []string{}
	if os.is_file(root) {
		files << root
	} else {
		for f in walk_files(root, 5000) {
			if fnmatch_name(os.base(f), glob_filter) {
				files << f
			}
		}
	}
	mut rx := compile_regex(pattern) or { return 'ERROR: bad regex: ${err.msg()}' }
	mut hits := []string{}
	for f in files {
		text := os.read_file(f) or { continue }
		for i, line in split_lines(text) {
			if rx.matches(line) {
				hits << '${f}:${i + 1}:${clip_plain(line.trim_space(), 200)}'
				if hits.len >= max_results {
					return hits.join('\n') + '\n… (stopped at ${max_results} results)'
				}
			}
		}
	}
	return if hits.len > 0 { hits.join('\n') } else { 'no matches' }
}

// tool_glob_files finds files by glob pattern (e.g. '**/*.py').
pub fn tool_glob_files(pattern string, path string) string {
	root := resolve_path(path)
	if pattern.starts_with('/') {
		// an absolute pattern is not relative to the search path, so the
		// result would silently ignore `path` entirely
		return 'ERROR: pattern must be relative to the search path'
	}
	mut matches := glob_paths(root, pattern)
	if matches.len > 300 {
		matches = matches[..300].clone()
	}
	return if matches.len > 0 { matches.join('\n') } else { 'no matches' }
}

// ---------------------------------------------------------------------------
// apply_patch — a unified-diff applier for live multi-file editing
// ---------------------------------------------------------------------------

struct PatchHunk {
mut:
	lines     []string
	old_start int = 1
	new_start int = 1
}

struct PatchFile {
mut:
	old   string
	hunks []PatchHunk
}

// tool_apply_patch applies a unified diff to the working tree.
//
// Accepts standard `diff -u` / `git diff` output. File paths are read from
// ---/+++ headers (a/ b/ prefixes stripped). Each hunk is applied with its
// own context tolerance; a hunk that no longer matches its context lines
// fails loudly instead of silently corrupting the file.
//
// Returns a per-file report: 'Updated X with N addition(s) and M
// removal(s)', matching the style of write_file/edit_file. Relative paths
// resolve against the persistent live_shell cwd if a session is active (so
// `live_shell("cd src")` followed by a patch on `a/main.py` does the
// intuitive thing).
pub fn tool_apply_patch(patch string) string {
	if patch.trim_space() == '' {
		return 'ERROR: empty patch'
	}
	base := live_shell_cwd()

	// -- parse the patch into per-file hunks ----------------------------
	mut files := map[string]PatchFile{}
	mut order := []string{}
	mut cur := ''
	for line in split_lines(patch) {
		if (line.starts_with('--- ') || line.starts_with('+++ '))
			&& !line.starts_with('--- \t') && !line.starts_with('+++ \t') {
			mut name := line[4..].all_before('\t').trim_space()
			if name.starts_with('a/') || name.starts_with('b/') {
				name = name[2..]
			}
			if name == '/dev/null' {
				continue
			}
			if name !in files {
				files[name] = PatchFile{}
				order << name
			}
			if line.starts_with('+++ ') {
				cur = name
			}
			continue
		}
		if line.starts_with('@@') {
			if cur != '' {
				old_start, new_start := parse_hunk_header(line)
				mut f := files[cur]
				f.hunks << PatchHunk{
					old_start: old_start
					new_start: new_start
				}
				files[cur] = f
			}
			continue
		}
		if cur != '' {
			mut f := files[cur]
			if f.hunks.len > 0 {
				if line.starts_with('+') || line.starts_with('-')
					|| line.starts_with(' ') || line == '' {
					f.hunks[f.hunks.len - 1].lines << if line == '' { ' ' } else { line }
					files[cur] = f
				}
			}
		}
	}
	mut any_hunks := false
	for _, f in files {
		if f.hunks.len > 0 {
			any_hunks = true
			break
		}
	}
	if !any_hunks {
		return "ERROR: no hunks found — expected '@@' headers (unified diff format)"
	}

	// -- load old contents ----------------------------------------------
	for name in order {
		p := patch_path(name, base)
		if os.exists(p) {
			mut f := files[name]
			f.old = os.read_file(p) or { return 'ERROR: cannot read ${p}: ${err.msg()}' }
			files[name] = f
		}
	}

	// -- apply each file's hunks -----------------------------------------
	mut reports := []string{}
	for name in order {
		entry := files[name]
		if entry.hunks.len == 0 {
			continue
		}
		p := patch_path(name, base)
		old_lines := split_lines(entry.old)
		mut new_lines := old_lines.clone()

		// apply hunks bottom-up so earlier offsets stay valid
		mut ordered := entry.hunks.clone()
		ordered.sort_with_compare(fn (a &PatchHunk, b &PatchHunk) int {
			return b.old_start - a.old_start
		})
		for hunk in ordered {
			mut old_side := []string{}
			mut new_side := []string{}
			for raw in hunk.lines {
				tag := if raw.len > 0 { raw[0] } else { ` ` }
				txt := if raw.len > 1 { raw[1..] } else { '' }
				if tag == ` ` || tag == `-` {
					old_side << txt
				}
				if tag == ` ` || tag == `+` {
					new_side << txt
				}
			}
			// find where the hunk's old-side lines start in the file,
			// searching outwards from the stated position
			pos, matched := locate_hunk(old_lines, old_side, hunk.old_start - 1)
			if !matched {
				return 'ERROR: hunk context mismatch in ${name} near line ' +
					'${hunk.old_start} — file changed since the diff was made; ' +
					'regenerate the diff and retry'
			}
			// rebuild: keep everything before, splice the new-side lines,
			// keep everything after
			mut rebuilt := new_lines[..pos].clone()
			rebuilt << new_side
			if pos + old_side.len <= new_lines.len {
				rebuilt << new_lines[pos + old_side.len..]
			}
			new_lines = rebuilt.clone()
		}
		trailing := entry.old.ends_with('\n') || new_lines.len > 0
		new_text := new_lines.join('\n') + if trailing { '\n' } else { '' }
		atomic_write_text(p, new_text) or { return 'ERROR: writing ${p}: ${err.msg()}' }
		reports << edit_report(p, entry.old, new_text)
	}
	return reports.join('\n')
}

fn patch_path(name string, base string) string {
	mut p := name
	if p.starts_with('~') {
		p = os.home_dir() + p[1..]
	}
	if !os.is_abs_path(p) {
		p = os.join_path(base, p)
	}
	return os.norm_path(p)
}

// parse_hunk_header reads `@@ -old[,n] +new[,m] @@`.
fn parse_hunk_header(line string) (int, int) {
	mut old_start := 1
	mut new_start := 1
	minus := line.index('-') or { return old_start, new_start }
	plus := line.index('+') or { return old_start, new_start }
	old_field := line[minus + 1..].all_before(' ')
	new_field := line[plus + 1..].all_before(' ')
	old_start = old_field.all_before(',').int()
	new_start = new_field.all_before(',').int()
	if old_start < 1 {
		old_start = 1
	}
	if new_start < 1 {
		new_start = 1
	}
	return old_start, new_start
}

// locate_hunk searches outwards from `hint` for the position where every
// old-side line matches, so a diff still applies after unrelated edits
// shifted the file.
fn locate_hunk(old_lines []string, old_side []string, hint int) (int, bool) {
	limit := if old_lines.len > 0 { old_lines.len } else { 1 }
	for delta := 0; delta <= limit; delta++ {
		for off in [delta, -delta] {
			cand := hint + off
			if cand < 0 || cand + old_side.len > old_lines.len {
				continue
			}
			mut ok := true
			for i, want in old_side {
				if old_lines[cand + i] != want {
					ok = false
					break
				}
			}
			if ok {
				return cand, true
			}
			if delta == 0 {
				break // +0 and -0 are the same position
			}
		}
	}
	return hint, false
}

// ---------------------------------------------------------------------------
// Registry
// ---------------------------------------------------------------------------

const str_schema = {
	'type': json2.Any('string')
}

fn obj_schema(props map[string]json2.Any, required []string) map[string]json2.Any {
	mut m := {
		'type':       json2.Any('object')
		'properties': json2.Any(props)
	}
	if required.len > 0 {
		m['required'] = strs_to_any(required)
	}
	return m
}

fn arg_int(args map[string]json2.Any, key string, fallback int) int {
	if key !in args {
		return fallback
	}
	v := jint(args, key)
	return if v == 0 && jstr(args, key) !in ['0', ''] { fallback } else { v }
}

// build_registry returns the 17 tools the agent can call, keyed by name.
pub fn build_registry() map[string]Tool {
	tools := [
		Tool{
			name:        'read_file'
			description: 'Read a text file with line numbers. Use offset/limit for large files.'
			parameters:  obj_schema({
				'path':   json2.Any(str_schema)
				'offset': json2.Any({
					'type':        json2.Any('integer')
					'description': json2.Any('first line (1-based)')
				})
				'limit':  json2.Any({
					'type':        json2.Any('integer')
					'description': json2.Any('max lines (default 1000)')
				})
			}, ['path'])
			handler:     fn (a map[string]json2.Any, sink OutputSink) string {
				return tool_read_file(jstr(a, 'path'), arg_int(a, 'offset', 1),
					arg_int(a, 'limit', 1000))
			}
		},
		Tool{
			name:        'write_file'
			description: 'Create or overwrite a file with the given content. Parent dirs are created.'
			parameters:  obj_schema({
				'path':    json2.Any(str_schema)
				'content': json2.Any(str_schema)
			}, ['path', 'content'])
			handler:     fn (a map[string]json2.Any, sink OutputSink) string {
				return tool_write_file(jstr(a, 'path'), jstr(a, 'content'))
			}
			risk:        risk_confirm
		},
		Tool{
			name:        'edit_file'
			description: 'Replace an exact string in a file. old_string must match exactly ' +
				'(including indentation) and uniquely, unless replace_all=true.'
			parameters:  obj_schema({
				'path':        json2.Any(str_schema)
				'old_string':  json2.Any(str_schema)
				'new_string':  json2.Any(str_schema)
				'replace_all': json2.Any({
					'type': json2.Any('boolean')
				})
			}, ['path', 'old_string', 'new_string'])
			handler:     fn (a map[string]json2.Any, sink OutputSink) string {
				return tool_edit_file(jstr(a, 'path'), jstr(a, 'old_string'),
					jstr(a, 'new_string'), jbool(a, 'replace_all'))
			}
			risk:        risk_confirm
		},
		Tool{
			name:        'list_dir'
			description: "List a directory's contents (one level)."
			parameters:  obj_schema({
				'path': json2.Any(str_schema)
			}, [])
			handler:     fn (a map[string]json2.Any, sink OutputSink) string {
				p := jstr(a, 'path')
				return tool_list_dir(if p == '' { '.' } else { p })
			}
		},
		Tool{
			name:        'file_info'
			description: 'Show metadata (size, mtime, type) for a path.'
			parameters:  obj_schema({
				'path': json2.Any(str_schema)
			}, ['path'])
			handler:     fn (a map[string]json2.Any, sink OutputSink) string {
				return tool_file_info(jstr(a, 'path'))
			}
		},
		Tool{
			name:        'create_directory'
			description: 'Create a directory (parents included).'
			parameters:  obj_schema({
				'path': json2.Any(str_schema)
			}, ['path'])
			handler:     fn (a map[string]json2.Any, sink OutputSink) string {
				return tool_create_directory(jstr(a, 'path'))
			}
		},
		Tool{
			name:        'copy_path'
			description: 'Copy a file or directory.'
			parameters:  obj_schema({
				'src': json2.Any(str_schema)
				'dst': json2.Any(str_schema)
			}, ['src', 'dst'])
			handler:     fn (a map[string]json2.Any, sink OutputSink) string {
				return tool_copy_path(jstr(a, 'src'), jstr(a, 'dst'))
			}
			risk:        risk_confirm
		},
		Tool{
			name:        'move_path'
			description: 'Move/rename a file or directory.'
			parameters:  obj_schema({
				'src': json2.Any(str_schema)
				'dst': json2.Any(str_schema)
			}, ['src', 'dst'])
			handler:     fn (a map[string]json2.Any, sink OutputSink) string {
				return tool_move_path(jstr(a, 'src'), jstr(a, 'dst'))
			}
			risk:        risk_confirm
		},
		Tool{
			name:        'delete_path'
			description: 'Delete a file or directory permanently.'
			parameters:  obj_schema({
				'path': json2.Any(str_schema)
			}, ['path'])
			handler:     fn (a map[string]json2.Any, sink OutputSink) string {
				return tool_delete_path(jstr(a, 'path'))
			}
			risk:        risk_confirm
		},
		Tool{
			name:        'search_files'
			description: 'Regex search through file contents (ripgrep-style). ' +
				'Returns path:line:content for matches.'
			parameters:  obj_schema({
				'pattern':     json2.Any({
					'type':        json2.Any('string')
					'description': json2.Any('regex pattern')
				})
				'path':        json2.Any({
					'type':        json2.Any('string')
					'description': json2.Any('dir or file to search')
				})
				'glob_filter': json2.Any({
					'type':        json2.Any('string')
					'description': json2.Any("filename glob, e.g. '*.py'")
				})
			}, ['pattern'])
			handler:     fn (a map[string]json2.Any, sink OutputSink) string {
				p := jstr(a, 'path')
				g := jstr(a, 'glob_filter')
				return tool_search_files(jstr(a, 'pattern'), if p == '' { '.' } else { p },
					if g == '' { '*' } else { g }, 100)
			}
		},
		Tool{
			name:        'glob_files'
			description: "Find files by glob pattern, e.g. '**/*.py'."
			parameters:  obj_schema({
				'pattern': json2.Any(str_schema)
				'path':    json2.Any(str_schema)
			}, ['pattern'])
			handler:     fn (a map[string]json2.Any, sink OutputSink) string {
				p := jstr(a, 'path')
				return tool_glob_files(jstr(a, 'pattern'), if p == '' { '.' } else { p })
			}
		},
		Tool{
			name:        'run_command'
			description: 'Run a shell command via bash and return exit code, stdout, stderr. ' +
				'Use for builds, tests, git, installs, running programs.'
			parameters:  obj_schema({
				'command': json2.Any(str_schema)
				'timeout': json2.Any({
					'type':        json2.Any('integer')
					'description': json2.Any('seconds, default 120')
				})
			}, ['command'])
			handler:     fn (a map[string]json2.Any, sink OutputSink) string {
				return run_command(jstr(a, 'command'), arg_int(a, 'timeout', 120), sink)
			}
			risk:        risk_confirm
		},
		Tool{
			name:        'live_shell'
			description: 'Run a command in a PERSISTENT bash session: cd, exports and ' +
				'background jobs survive between calls. Use for live workflows ' +
				'(cd src && build, then run tests, then inspect, then fix).'
			parameters:  obj_schema({
				'command': json2.Any(str_schema)
				'timeout': json2.Any({
					'type':        json2.Any('integer')
					'description': json2.Any('seconds, default 120')
				})
			}, ['command'])
			handler:     fn (a map[string]json2.Any, sink OutputSink) string {
				return live_shell(jstr(a, 'command'), arg_int(a, 'timeout', 120), sink)
			}
			risk:        risk_confirm
		},
		Tool{
			name:        'live_shell_reset'
			description: 'Reset the persistent live-shell session back to the process ' +
				'working directory.'
			parameters:  obj_schema(map[string]json2.Any{}, [])
			handler:     fn (a map[string]json2.Any, sink OutputSink) string {
				return live_shell_reset()
			}
		},
		Tool{
			name:        'apply_patch'
			description: 'Apply a unified diff (git diff / diff -u format) to the working ' +
				'tree. Multi-file edits in one call; each hunk is context-checked ' +
				'and fails loudly on mismatch instead of corrupting files. ' +
				"Returns a per-file 'N additions / M removals' report."
			parameters:  obj_schema({
				'patch': json2.Any(str_schema)
			}, ['patch'])
			handler:     fn (a map[string]json2.Any, sink OutputSink) string {
				return tool_apply_patch(jstr(a, 'patch'))
			}
			risk:        risk_confirm
		},
		Tool{
			name:        'web_fetch'
			description: 'Fetch a URL and return its text content.'
			parameters:  obj_schema({
				'url': json2.Any(str_schema)
			}, ['url'])
			handler:     fn (a map[string]json2.Any, sink OutputSink) string {
				return tool_web_fetch(jstr(a, 'url'))
			}
		},
		Tool{
			name:        'web_search'
			description: 'Search the web (DuckDuckGo) and return top results.'
			parameters:  obj_schema({
				'query': json2.Any(str_schema)
			}, ['query'])
			handler:     fn (a map[string]json2.Any, sink OutputSink) string {
				return tool_web_search(jstr(a, 'query'))
			}
		},
	]
	mut reg := map[string]Tool{}
	for t in tools {
		reg[t.name] = t
	}
	return reg
}

// parse_tool_arguments decodes the arguments of a tool call, which arrive
// as a JSON string.
pub fn parse_tool_arguments(raw string) map[string]json2.Any {
	if raw.trim_space() == '' {
		return map[string]json2.Any{}
	}
	parsed := json2.decode[json2.Any](raw) or {
		// a model that emitted something other than JSON still deserves a
		// legible error rather than a silent empty call
		return {
			'_raw': json2.Any(raw)
		}
	}
	return match parsed {
		map[string]json2.Any { parsed }
		else { {
			'value': parsed
		} }
	}
}
