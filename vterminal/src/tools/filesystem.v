module tools

import os
import strings
import x.json2
import src.utils
import src.security

// ---------------------------------------------------------------- read_file

pub struct ReadFileTool {}

pub fn (t ReadFileTool) spec() Spec {
	return Spec{
		name:          'read_file'
		description:   'Read a text file from the workspace. Output is line-numbered so that line references in later edits are accurate. Use offset/limit to page through a large file instead of reading it whole.'
		level:         .read
		summary_param: 'path'
		params:        [
			Param{
				name:        'path'
				description: 'File path, absolute or relative to the working directory.'
				required:    true
			},
			Param{
				name:        'offset'
				typ:         'integer'
				description: '1-based line number to start from. Defaults to 1.'
			},
			Param{
				name:        'limit'
				typ:         'integer'
				description: 'Maximum number of lines to return. Defaults to 2000.'
			},
		]
	}
}

pub fn (t ReadFileTool) execute(mut ctx Context, args map[string]json2.Any) Result {
	path := ctx.resolve_path(utils.jstr(args, 'path', '')) or { return fail_result(err.msg()) }
	if !os.exists(path) {
		return fail_result('file not found: ${ctx.rel(path)}')
	}
	if os.is_dir(path) {
		return fail_result('${ctx.rel(path)} is a directory; use list_directory instead')
	}
	content := os.read_file(path) or {
		return fail_result('cannot read ${ctx.rel(path)}: ${err.msg()}')
	}
	if looks_binary(content) {
		return fail_result('${ctx.rel(path)} looks like a binary file (${utils.human_bytes(i64(content.len))}); refusing to read it as text')
	}
	offset := if o := utils.jget(args, 'offset') { o.int() } else { 1 }
	limit := if l := utils.jget(args, 'limit') { l.int() } else { 2000 }
	start := if offset > 0 { offset - 1 } else { 0 }
	lines := content.split('\n')
	// A trailing newline produces a final empty element that is not a line.
	total := if lines.len > 0 && lines.last() == '' { lines.len - 1 } else { lines.len }
	if start >= total && total > 0 {
		return fail_result('offset ${offset} is past the end of ${ctx.rel(path)} (${total} lines)')
	}
	mut end := start + if limit > 0 { limit } else { 2000 }
	if end > total {
		end = total
	}
	mut sb := strings.new_builder(4096)
	for i in start .. end {
		sb.write_string('${i + 1:6} | ${lines[i]}\n')
	}
	ctx.read_files[path] = true
	mut note := ''
	if end < total {
		note = '\n[showing lines ${start + 1}-${end} of ${total}; call read_file again with offset=${
			end + 1} for more]'
	}
	return ok_result('${sb.str()}${note}', '${ctx.rel(path)} (${end - start} lines)')
}

// --------------------------------------------------------------- write_file

pub struct WriteFileTool {}

pub fn (t WriteFileTool) spec() Spec {
	return Spec{
		name:          'write_file'
		description:   'Create a file or replace its entire contents. Parent directories are created as needed. To change part of an existing file prefer edit_file, which is safer.'
		level:         .write
		summary_param: 'path'
		params:        [
			Param{
				name:        'path'
				description: 'File path to write.'
				required:    true
			},
			Param{
				name:        'content'
				description: 'The full new contents of the file.'
				required:    true
			},
		]
	}
}

pub fn (t WriteFileTool) execute(mut ctx Context, args map[string]json2.Any) Result {
	path := ctx.resolve_path(utils.jstr(args, 'path', '')) or { return fail_result(err.msg()) }
	content := utils.jstr(args, 'content', '')
	if os.is_dir(path) {
		return fail_result('${ctx.rel(path)} is a directory')
	}
	existed := os.exists(path)
	utils.ensure_dir(os.dir(path)) or { return fail_result(err.msg()) }
	os.write_file(path, content) or {
		return fail_result('cannot write ${ctx.rel(path)}: ${err.msg()}')
	}
	ctx.read_files[path] = true
	verb := if existed { 'overwrote' } else { 'created' }
	n := utils.count_lines(content)
	return ok_result('${verb} ${ctx.rel(path)} (${n} lines, ${content.len} bytes)',
		'${verb} ${ctx.rel(path)} (${n} lines)')
}

// ---------------------------------------------------------------- edit_file

pub struct EditFileTool {}

pub fn (t EditFileTool) spec() Spec {
	return Spec{
		name:          'edit_file'
		description:   'Replace an exact string in a file. old_string must appear exactly once unless replace_all is true, so include enough surrounding context to make it unique. Read the file first.'
		level:         .write
		summary_param: 'path'
		params:        [
			Param{
				name:        'path'
				description: 'File to edit.'
				required:    true
			},
			Param{
				name:        'old_string'
				description: 'Exact text to replace, including indentation.'
				required:    true
			},
			Param{
				name:        'new_string'
				description: 'Replacement text. Use an empty string to delete.'
				required:    true
			},
			Param{
				name:        'replace_all'
				typ:         'boolean'
				description: 'Replace every occurrence instead of requiring a unique match.'
			},
		]
	}
}

pub fn (t EditFileTool) execute(mut ctx Context, args map[string]json2.Any) Result {
	path := ctx.resolve_path(utils.jstr(args, 'path', '')) or { return fail_result(err.msg()) }
	if !os.exists(path) {
		return fail_result('file not found: ${ctx.rel(path)}')
	}
	old_s := utils.jstr(args, 'old_string', '')
	new_s := utils.jstr(args, 'new_string', '')
	if old_s == '' {
		return fail_result('old_string is empty; use write_file to create a file')
	}
	if old_s == new_s {
		return fail_result('old_string and new_string are identical, nothing to do')
	}
	content := os.read_file(path) or {
		return fail_result('cannot read ${ctx.rel(path)}: ${err.msg()}')
	}
	if looks_binary(content) {
		return fail_result('${ctx.rel(path)} is a binary file')
	}
	occurrences := content.count(old_s)
	if occurrences == 0 {
		return fail_result('old_string not found in ${ctx.rel(path)}. Read the file again: it may have changed, or the whitespace may differ.')
	}
	replace_all := utils.jbool(args, 'replace_all', false)
	if occurrences > 1 && !replace_all {
		return fail_result('old_string appears ${occurrences} times in ${ctx.rel(path)}. Add surrounding context to make it unique, or pass replace_all=true.')
	}
	updated := if replace_all {
		content.replace(old_s, new_s)
	} else {
		content.replace_once(old_s, new_s)
	}
	os.write_file(path, updated) or {
		return fail_result('cannot write ${ctx.rel(path)}: ${err.msg()}')
	}
	line_no := line_of_offset(content, content.index(old_s) or { 0 })
	n := if replace_all { occurrences } else { 1 }
	return ok_result('edited ${ctx.rel(path)}: ${n} replacement(s), first at line ${line_no}',
		'${ctx.rel(path)}:${line_no} (${n} edit)')
}

fn line_of_offset(s string, off int) int {
	mut n := 1
	for i in 0 .. off {
		if s[i] == `\n` {
			n++
		}
	}
	return n
}

// -------------------------------------------------------------- delete_file

pub struct DeleteFileTool {}

pub fn (t DeleteFileTool) spec() Spec {
	return Spec{
		name:          'delete_file'
		description:   'Delete a file, or a directory when recursive is true. Irreversible.'
		level:         .write
		summary_param: 'path'
		params:        [
			Param{
				name:        'path'
				description: 'Path to delete.'
				required:    true
			},
			Param{
				name:        'recursive'
				typ:         'boolean'
				description: 'Required to delete a non-empty directory.'
			},
		]
	}
}

pub fn (t DeleteFileTool) execute(mut ctx Context, args map[string]json2.Any) Result {
	path := ctx.resolve_path(utils.jstr(args, 'path', '')) or { return fail_result(err.msg()) }
	if !os.exists(path) {
		return fail_result('nothing to delete at ${ctx.rel(path)}')
	}
	if os.norm_path(path) == os.norm_path(ctx.root) {
		return fail_result('refusing to delete the project root')
	}
	if os.is_dir(path) {
		if !utils.jbool(args, 'recursive', false) {
			return fail_result('${ctx.rel(path)} is a directory; pass recursive=true to delete it')
		}
		os.rmdir_all(path) or { return fail_result('cannot delete: ${err.msg()}') }
		return ok_result('deleted directory ${ctx.rel(path)}', 'deleted ${ctx.rel(path)}/')
	}
	os.rm(path) or { return fail_result('cannot delete: ${err.msg()}') }
	return ok_result('deleted ${ctx.rel(path)}', 'deleted ${ctx.rel(path)}')
}

// ----------------------------------------------------------- list_directory

pub struct ListDirectoryTool {}

pub fn (t ListDirectoryTool) spec() Spec {
	return Spec{
		name:          'list_directory'
		description:   'List directory contents as a tree. Build and VCS directories such as .git and node_modules are skipped.'
		level:         .read
		summary_param: 'path'
		params:        [
			Param{
				name:        'path'
				description: 'Directory to list. Defaults to the working directory.'
			},
			Param{
				name:        'depth'
				typ:         'integer'
				description: 'How many levels to descend. Defaults to 2.'
			},
			Param{
				name:        'show_hidden'
				typ:         'boolean'
				description: 'Include dotfiles.'
			},
		]
	}
}

pub fn (t ListDirectoryTool) execute(mut ctx Context, args map[string]json2.Any) Result {
	target := utils.jstr(args, 'path', '.')
	path := ctx.resolve_path(target) or { return fail_result(err.msg()) }
	if !os.exists(path) {
		return fail_result('no such directory: ${ctx.rel(path)}')
	}
	if !os.is_dir(path) {
		return fail_result('${ctx.rel(path)} is a file, not a directory')
	}
	depth := if d := utils.jget(args, 'depth') { d.int() } else { 2 }
	show_hidden := utils.jbool(args, 'show_hidden', false)
	mut w := TreeWalk{
		sb:          strings.new_builder(2048)
		show_hidden: show_hidden
	}
	w.sb.write_string('${ctx.rel(path)}/\n')
	w.walk(path, '', if depth > 0 { depth } else { 2 })
	return ok_result(w.sb.str(), '${ctx.rel(path)}/ (${w.counted} entries)')
}

// TreeWalk carries the recursion state for list_directory; the entry cap keeps
// a `list_directory` on a huge tree from flooding the context window.
struct TreeWalk {
mut:
	sb          strings.Builder
	counted     int
	show_hidden bool
}

const max_tree_entries = 800

fn (mut w TreeWalk) walk(dir string, prefix string, depth int) {
	if depth <= 0 || w.counted > max_tree_entries {
		return
	}
	mut entries := os.ls(dir) or { return }
	entries.sort()
	mut visible := []string{}
	for e in entries {
		if !w.show_hidden && e.starts_with('.') {
			continue
		}
		if is_skipped_dir(e) {
			continue
		}
		visible << e
	}
	for i, e in visible {
		full := os.join_path(dir, e)
		last := i == visible.len - 1
		branch := if last { '`-- ' } else { '|-- ' }
		if os.is_dir(full) {
			w.sb.write_string('${prefix}${branch}${e}/\n')
			w.counted++
			child_prefix := prefix + if last { '    ' } else { '|   ' }
			w.walk(full, child_prefix, depth - 1)
		} else {
			size := os.file_size(full)
			w.sb.write_string('${prefix}${branch}${e}  (${utils.human_bytes(i64(size))})\n')
			w.counted++
		}
		if w.counted > max_tree_entries {
			w.sb.write_string('${prefix}... [listing truncated at ${max_tree_entries} entries]\n')
			return
		}
	}
}

// -------------------------------------------------------------- update_plan

// UpdatePlanTool lets the model maintain the visible task list. It is the one
// built-in tool with no side effect outside the terminal, which is why it
// needs no more than READ authority.
pub struct UpdatePlanTool {}

pub fn (t UpdatePlanTool) spec() Spec {
	return Spec{
		name:        'update_plan'
		description: 'Record or update the step-by-step plan shown to the user. Call it once when you start a multi-step task and again whenever a step completes. Keep steps short and in execution order. When the whole task is finished, call it one last time with active set past the last step so every step shows as done.'
		level:       .read
		params:      [
			Param{
				name:        'steps'
				typ:         'array'
				items_type:  'string'
				description: 'The full ordered list of step titles. Send the whole list every time, not a delta.'
				required:    true
			},
			Param{
				name:        'active'
				typ:         'integer'
				description: '1-based index of the step currently in progress; steps before it are marked done. Pass a value greater than the number of steps to mark them all done.'
			},
		]
	}
}

pub fn (t UpdatePlanTool) execute(mut ctx Context, args map[string]json2.Any) Result {
	titles := utils.jstrings(args, 'steps')
	if titles.len == 0 {
		return fail_result('steps must be a non-empty array of strings')
	}
	active := if a := utils.jget(args, 'active') { a.int() } else { 1 }
	mut steps := []PlanStep{}
	for i, title in titles {
		status := if i + 1 < active {
			'done'
		} else if i + 1 == active {
			'active'
		} else {
			'pending'
		}
		steps << PlanStep{
			title:  title
			status: status
		}
	}
	ctx.plan = steps
	mut sb := strings.new_builder(256)
	for i, s in steps {
		sb.write_string('${i + 1}. [${s.status}] ${s.title}\n')
	}
	position := if active > steps.len { 'all done' } else { 'on step ${active}' }
	return ok_result('plan updated:\n${sb.str()}', '${steps.len} steps, ${position}')
}

// permission_level_of is used by /tools to show what each tool can do.
pub fn permission_level_of(s Spec) security.Level {
	return s.level
}
