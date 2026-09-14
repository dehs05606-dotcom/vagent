module tools

import os
import x.json2
import src.utils

// The git tools are thin, deliberately read-heavy wrappers. They exist instead
// of "just use the shell tool" for two reasons: the model gets a stable,
// documented interface, and the permission engine can grant READ on repository
// inspection without granting EXECUTE on the whole shell.

// run_git executes a git subcommand in `dir` and returns (output, exit_code).
fn run_git(dir string, argv []string) (string, int) {
	mut parts := ['git', '-C', sh_quote(dir)]
	for a in argv {
		parts << sh_quote(a)
	}
	res := os.execute(parts.join(' ') + ' 2>&1')
	return res.output.trim_right('\n'), res.exit_code
}

fn ensure_repo(dir string) ?string {
	out, code := run_git(dir, ['rev-parse', '--show-toplevel'])
	if code != 0 {
		return none
	}
	return out.trim_space()
}

// ---------------------------------------------------------------- git_status

pub struct GitStatusTool {}

pub fn (t GitStatusTool) spec() Spec {
	return Spec{
		name:        'git_status'
		description: 'Show the working tree status: current branch, staged, unstaged and untracked files.'
		level:       .read
		params:      []
	}
}

pub fn (t GitStatusTool) execute(mut ctx Context, args map[string]json2.Any) Result {
	root := ensure_repo(ctx.workdir) or {
		return fail_result('${ctx.rel(ctx.workdir)} is not inside a git repository')
	}
	branch, _ := run_git(ctx.workdir, ['rev-parse', '--abbrev-ref', 'HEAD'])
	status, code := run_git(ctx.workdir, ['status', '--porcelain=v1', '--branch'])
	if code != 0 {
		return fail_result('git status failed: ${status}')
	}
	body := 'repository: ${root}\nbranch: ${branch}\n\n${if status == '' {
		'(clean working tree)'
	} else {
		status
	}}'
	changed := status.split('\n').filter(it.trim_space() != '' && !it.starts_with('##')).len
	return ok_result(body, '${branch}, ${changed} change(s)')
}

// ------------------------------------------------------------------ git_diff

pub struct GitDiffTool {}

pub fn (t GitDiffTool) spec() Spec {
	return Spec{
		name:          'git_diff'
		description:   'Show a unified diff of the working tree. Use staged=true for the index, or pass a path to narrow it. Read this before committing.'
		level:         .read
		summary_param: 'path'
		params:        [
			Param{
				name:        'path'
				description: 'Limit the diff to this path.'
			},
			Param{
				name:        'staged'
				typ:         'boolean'
				description: 'Diff the staged changes instead of the unstaged ones.'
			},
			Param{
				name:        'stat'
				typ:         'boolean'
				description: 'Show only the summary of changed files.'
			},
		]
	}
}

pub fn (t GitDiffTool) execute(mut ctx Context, args map[string]json2.Any) Result {
	ensure_repo(ctx.workdir) or {
		return fail_result('${ctx.rel(ctx.workdir)} is not inside a git repository')
	}
	mut argv := ['diff']
	if utils.jbool(args, 'staged', false) {
		argv << '--cached'
	}
	if utils.jbool(args, 'stat', false) {
		argv << '--stat'
	}
	if p := utils.jget(args, 'path') {
		argv << '--'
		argv << p.str()
	}
	out, code := run_git(ctx.workdir, argv)
	if code != 0 {
		return fail_result('git diff failed: ${out}')
	}
	if out.trim_space() == '' {
		return ok_result('(no changes)', 'no changes')
	}
	return ok_result(out, '${utils.count_lines(out)} diff lines')
}

// ------------------------------------------------------------------- git_log

pub struct GitLogTool {}

pub fn (t GitLogTool) spec() Spec {
	return Spec{
		name:        'git_log'
		description: 'Show recent commits, newest first, one per line.'
		level:       .read
		params:      [
			Param{
				name:        'limit'
				typ:         'integer'
				description: 'How many commits to show. Defaults to 20.'
			},
			Param{
				name:        'path'
				description: 'Only commits touching this path.'
			},
		]
	}
}

pub fn (t GitLogTool) execute(mut ctx Context, args map[string]json2.Any) Result {
	ensure_repo(ctx.workdir) or {
		return fail_result('${ctx.rel(ctx.workdir)} is not inside a git repository')
	}
	limit := if l := utils.jget(args, 'limit') { l.int() } else { 20 }
	mut argv := ['log', '--max-count=${if limit > 0 { limit } else { 20 }}',
		'--pretty=format:%h %ad %an: %s', '--date=short']
	if p := utils.jget(args, 'path') {
		argv << '--'
		argv << p.str()
	}
	out, code := run_git(ctx.workdir, argv)
	if code != 0 {
		return fail_result('git log failed: ${out}')
	}
	return ok_result(out, '${utils.count_lines(out)} commits')
}

// ---------------------------------------------------------------- git_commit

pub struct GitCommitTool {}

pub fn (t GitCommitTool) spec() Spec {
	return Spec{
		name:          'git_commit'
		description:   'Stage the given paths (or all modified tracked files) and create a commit. Never runs push. Review git_diff first.'
		level:         .write
		summary_param: 'message'
		params:        [
			Param{
				name:        'message'
				description: 'Commit message. First line is the subject.'
				required:    true
			},
			Param{
				name:        'paths'
				typ:         'array'
				items_type:  'string'
				description: 'Paths to stage. Omit to stage all modified tracked files.'
			},
		]
	}
}

pub fn (t GitCommitTool) execute(mut ctx Context, args map[string]json2.Any) Result {
	ensure_repo(ctx.workdir) or {
		return fail_result('${ctx.rel(ctx.workdir)} is not inside a git repository')
	}
	message := utils.jstr(args, 'message', '').trim_space()
	if message == '' {
		return fail_result('message is required')
	}
	paths := utils.jstrings(args, 'paths')
	if paths.len > 0 {
		mut argv := ['add', '--']
		argv << paths
		out, code := run_git(ctx.workdir, argv)
		if code != 0 {
			return fail_result('git add failed: ${out}')
		}
	} else {
		out, code := run_git(ctx.workdir, ['add', '--update'])
		if code != 0 {
			return fail_result('git add --update failed: ${out}')
		}
	}
	staged, _ := run_git(ctx.workdir, ['diff', '--cached', '--name-only'])
	if staged.trim_space() == '' {
		return fail_result('nothing staged to commit')
	}
	out, code := run_git(ctx.workdir, ['commit', '-m', message])
	if code != 0 {
		return fail_result('git commit failed: ${out}')
	}
	sha, _ := run_git(ctx.workdir, ['rev-parse', '--short', 'HEAD'])
	files := staged.split('\n').filter(it.trim_space() != '').len
	return ok_result('${out}\n\ncommit ${sha} (${files} file(s))',
		'commit ${sha}: ${utils.first_line(message)}')
}
