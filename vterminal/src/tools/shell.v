module tools

import os
import time
import x.json2
import src.utils

// ShellTool runs a command through the platform shell. It is the highest
// authority tool in the built-in set, so it is also the one the permission
// engine scrutinises the hardest.
pub struct ShellTool {}

pub fn (t ShellTool) spec() Spec {
	return Spec{
		name:          'shell'
		description:   'Run a shell command in the project and return its combined stdout/stderr and exit code. Use it for builds, tests, linters and any CLI tool. Prefer the dedicated file tools over cat/sed/echo for reading and editing files.'
		level:         .execute
		summary_param: 'command'
		params:        [
			Param{
				name:        'command'
				description: 'The command line to run.'
				required:    true
			},
			Param{
				name:        'workdir'
				description: 'Directory to run in. Defaults to the current working directory.'
			},
			Param{
				name:        'timeout_secs'
				typ:         'integer'
				description: 'Kill the command after this many seconds. Defaults to the configured shell timeout.'
			},
		]
	}
}

pub fn (t ShellTool) execute(mut ctx Context, args map[string]json2.Any) Result {
	command := utils.jstr(args, 'command', '').trim_space()
	if command == '' {
		return fail_result('command is required')
	}
	mut workdir := ctx.workdir
	if raw := utils.jget(args, 'workdir') {
		p := ctx.resolve_path(raw.str()) or { return fail_result(err.msg()) }
		if !os.is_dir(p) {
			return fail_result('workdir is not a directory: ${ctx.rel(p)}')
		}
		workdir = p
	}
	timeout := if v := utils.jget(args, 'timeout_secs') {
		if v.int() > 0 { v.int() } else { ctx.shell_timeout }
	} else {
		ctx.shell_timeout
	}

	full := build_command(command, workdir, timeout, ctx.has_timeout_cmd)
	started := time.now()
	res := os.execute(full)
	elapsed := time.now() - started
	secs := f64(elapsed.microseconds()) / 1000000.0

	mut output := res.output.trim_right('\n')
	// GNU coreutils `timeout` reports 124 when it had to kill the child.
	if res.exit_code == 124 && ctx.has_timeout_cmd {
		return fail_result('command timed out after ${timeout}s: ${utils.first_line(command)}\n--- partial output ---\n${utils.truncate_middle(output,
			4000)}')
	}
	if output == '' {
		output = '(no output)'
	}
	body := 'exit code: ${res.exit_code}  (${secs:.2f}s)\n--- output ---\n${output}'
	if res.exit_code == 0 {
		return ok_result(body, '${utils.first_line(command)} -> ok (${secs:.1f}s)')
	}
	mut r := Result{
		ok:      false
		output:  body
		error:   'command exited with code ${res.exit_code}'
		summary: '${utils.first_line(command)} -> exit ${res.exit_code}'
	}
	r.meta['exit_code'] = res.exit_code.str()
	return r
}

// build_command wraps the user command so that it runs in the right directory
// and cannot outlive its timeout. On POSIX this leans on coreutils `timeout`
// when it is present; Windows has no equivalent, so the timeout is advisory
// there and the wrapper is skipped.
fn build_command(command string, workdir string, timeout int, has_timeout bool) string {
	$if windows {
		return 'cd /d ${workdir} && ${command}'
	}
	payload := 'cd ${sh_quote(workdir)} && ${command}'
	if timeout > 0 && has_timeout {
		return 'timeout -k 5 ${timeout} /bin/sh -c ${sh_quote(payload)} 2>&1'
	}
	return '/bin/sh -c ${sh_quote(payload)} 2>&1'
}

// sh_quote makes an arbitrary string safe as a single POSIX shell word.
fn sh_quote(s string) string {
	return "'" + s.replace("'", "'\\''") + "'"
}
