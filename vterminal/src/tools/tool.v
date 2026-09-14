module tools

import os
import x.json2
import src.utils
import src.security

// Param describes one input field of a tool, in enough detail to generate a
// JSON Schema for the model and to validate what comes back.
pub struct Param {
pub:
	name        string
	typ         string = 'string' // string | integer | number | boolean | array
	description string
	required    bool
	enum_values []string
	items_type  string = 'string'
	default_str string
}

// Spec is a tool's public contract: what it is called, what it does, what it
// takes, and how much authority running it requires.
pub struct Spec {
pub:
	name        string
	description string
	params      []Param
	level       security.Level
	// summary_param names the argument shown in the terminal echo line.
	summary_param string
}

// Result is what every tool returns. `output` goes back to the model verbatim,
// `summary` is the single line the terminal shows.
pub struct Result {
pub mut:
	ok      bool
	output  string
	error   string
	summary string
	meta    map[string]string
}

pub fn ok_result(output string, summary string) Result {
	return Result{
		ok:      true
		output:  output
		summary: summary
	}
}

pub fn fail_result(msg string) Result {
	return Result{
		ok:      false
		error:   msg
		output:  'Error: ${msg}'
		summary: utils.first_line(msg)
	}
}

// Tool is the one interface every capability implements, whether it is
// built in, loaded from MCP, or user supplied.
pub interface Tool {
	spec() Spec
	execute(mut ctx Context, args map[string]json2.Any) Result
}

// PlanStep is one entry of the agent's visible task list. It lives in the tool
// context rather than in agent state so that the `update_plan` tool can write
// it without the tools package depending on the agent package.
pub struct PlanStep {
pub mut:
	title  string
	status string = 'pending' // pending | active | done | failed
}

// Context is the shared execution environment handed to every tool call.
@[heap]
pub struct Context {
pub mut:
	root          string // project root; the confinement boundary
	workdir       string // cwd for shell commands and relative paths
	max_output    int  = 30000
	shell_timeout int  = 120
	confine       bool = true
	// has_timeout_cmd is probed once at startup: shelling out to check for
	// coreutils `timeout` before every command would double the process count.
	has_timeout_cmd bool
	log             &utils.Logger = unsafe { nil }
	plan            []PlanStep
	// read_files records what the agent has already looked at, so edit_file can
	// refuse to patch a file blind.
	read_files map[string]bool
	// stats for the status bar
	calls int
}

// resolve_path turns a tool-supplied path into an absolute one and enforces
// the workspace boundary. Relative paths resolve against `workdir`, `~`
// expands, and `..` cannot be used to climb out of the project root.
pub fn (ctx &Context) resolve_path(p string) !string {
	raw := p.trim_space()
	if raw == '' {
		return utils.err(.filesystem, 'path is empty')
	}
	mut expanded := raw
	if expanded == '~' || expanded.starts_with('~/') || expanded.starts_with('~\\') {
		expanded = os.join_path(utils.home_dir(), expanded#[2..])
	}
	abs := if os.is_abs_path(expanded) {
		os.norm_path(expanded)
	} else {
		os.norm_path(os.join_path(ctx.workdir, expanded))
	}
	if !ctx.confine {
		return abs
	}
	root := os.norm_path(ctx.root)
	// real_path resolves symlinks for paths that exist; for paths about to be
	// created we fall back to the lexical form, which norm_path already made
	// `..`-free.
	checked := if os.exists(abs) { os.real_path(abs) } else { abs }
	if checked == root || checked.starts_with(root + os.path_separator) {
		return abs
	}
	return utils.err_hint(.permission, 'path escapes the workspace: ${p}',
		'V-AGENT is confined to ${root}; set permissions.confine_to_root=false to allow outside access')
}

// rel renders an absolute path relative to the project root for display.
pub fn (ctx &Context) rel(p string) string {
	root := os.norm_path(ctx.root) + os.path_separator
	if p.starts_with(root) {
		return p#[root.len..]
	}
	return p
}

// skip_dirs are never walked by the search and listing tools: they are large,
// generated, and never what the user meant.
pub const skip_dirs = ['.git', '.hg', '.svn', 'node_modules', '.vagent', 'target', 'dist', 'build',
	'vendor', '__pycache__', '.venv', 'venv', '.mypy_cache', '.pytest_cache', '.next', '.nuxt',
	'.cache', '.gradle', '.idea', 'bin', 'obj']

pub fn is_skipped_dir(name string) bool {
	return name in skip_dirs
}

// looks_binary is a cheap NUL-byte probe, used so the agent never pastes a
// compiled artifact into its own context window.
pub fn looks_binary(content string) bool {
	limit := if content.len < 8000 { content.len } else { 8000 }
	for i in 0 .. limit {
		if content[i] == 0 {
			return true
		}
	}
	return false
}

// probe_environment fills in the capability flags that depend on what is
// installed on this machine. Called once, at startup.
pub fn (mut ctx Context) probe_environment() {
	ctx.has_timeout_cmd = utils.has_command('timeout')
}
