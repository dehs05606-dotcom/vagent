module vagent

import os
import time

// shell.v — process execution with LIVE output.
//
// Every shell tool streams its output line by line as the process produces
// it, which is what lets the TUI render a running build the way a real
// terminal does. V's os.Process.pipe_read is non-blocking, so this polls
// both pipes, splits on newlines, and relays each completed line the moment
// it lands — the equivalent of the Python original's reader threads feeding
// a queue.

// OutputSink receives one completed line and the pipe it came from
// ("out" or "err").
//
// This is a plain function type rather than an optional one, and callers
// that want no streaming pass `no_sink`. An `?OutputSink` reads better at
// the call sites but V's codegen mishandles an optional function value
// captured by a closure, which is exactly what live_shell's relay does.
pub type OutputSink = fn (line string, stream string)

// no_sink is the "do not stream" sink.
pub fn no_sink(line string, stream string) {}

// poll_interval is how long the pump sleeps when neither pipe has data.
// Short enough that output feels live, long enough not to spin a core.
const poll_interval = 5 * time.millisecond

// ---------------------------------------------------------------------------
// Shell resolution
// ---------------------------------------------------------------------------

__global (
	shell_cache shared []string
)

// resolve_shell resolves a working POSIX shell, once.
//
// On Windows, System32\bash.exe is the WSL stub — it fails with 'no
// installed distributions' when WSL has no distro, silently breaking every
// shell predicate. Candidates (Git Bash first, then PATH bash/sh) are
// probed with a real `exit 0`; the first that works is cached. On POSIX
// it's just bash. Returns an empty list when nothing runnable exists.
pub fn resolve_shell() []string {
	// one lock, not two nested: the cached value and the "is cached" flag
	// live in the same array, where an empty array means "not resolved yet"
	// and a [''] sentinel means "resolved to nothing runnable"
	rlock shell_cache {
		if shell_cache.len > 0 {
			return if shell_cache[0] == '' { []string{} } else { shell_cache.clone() }
		}
	}
	mut candidates := []string{}
	$if windows {
		if git := os.find_abs_path_of_executable('git') {
			gdir := os.dir(os.dir(git))
			for rel in ['bin/bash.exe', 'usr/bin/bash.exe', 'bin/sh.exe',
				'usr/bin/sh.exe'] {
				candidates << os.join_path(gdir, rel)
			}
		}
		for name in ['bash.exe', 'sh.exe'] {
			if found := os.find_abs_path_of_executable(name) {
				candidates << found
			}
		}
	} $else {
		candidates << 'bash'
	}
	mut resolved := []string{}
	for cand in candidates {
		probe := os.execute('${os.quoted_path(cand)} -c "exit 0"')
		if probe.exit_code == 0 {
			resolved = [cand, '-lc']
			break
		}
	}
	lock shell_cache {
		shell_cache = if resolved.len > 0 { resolved.clone() } else { [''] }
	}
	return resolved
}

// ---------------------------------------------------------------------------
// Process pumping
// ---------------------------------------------------------------------------

pub struct PumpResult {
pub:
	stdout    string
	stderr    string
	exit_code int
	timed_out bool
}

struct LineBuffer {
mut:
	pending string
}

// feed appends a chunk and relays every COMPLETE line to the sink. A
// partial trailing line is held back until its newline arrives, so a
// progress bar written without a newline never gets split mid-token.
fn (mut b LineBuffer) feed(chunk string, tag string, sink OutputSink) string {
	b.pending += chunk
	mut emitted := ''
	for {
		idx := b.pending.index('\n') or { break }
		line := b.pending[..idx]
		emitted += line + '\n'
		b.pending = b.pending[idx + 1..]
		sink(line.trim_right('\r'), tag)
	}
	return emitted
}

// flush relays whatever is left without a trailing newline.
fn (mut b LineBuffer) flush(tag string, sink OutputSink) string {
	if b.pending == '' {
		return ''
	}
	rest := b.pending
	b.pending = ''
	sink(rest.trim_right('\r'), tag)
	return rest
}

// pump_process reads stdout/stderr of `p` until it exits or the timeout
// elapses. Every line is relayed to `sink` the moment it is produced.
fn pump_process(mut p os.Process, timeout f64, sink OutputSink) PumpResult {
	mut out := []string{}
	mut err := []string{}
	mut out_buf := LineBuffer{}
	mut err_buf := LineBuffer{}
	deadline := time.now().unix_milli() + i64(timeout * 1000)

	for {
		mut got_any := false
		if chunk := p.pipe_read(.stdout) {
			out << out_buf.feed(chunk, 'out', sink)
			got_any = true
		}
		if chunk := p.pipe_read(.stderr) {
			err << err_buf.feed(chunk, 'err', sink)
			got_any = true
		}
		if !p.is_alive() {
			// drain whatever the pipes still hold after exit
			for {
				mut drained := false
				if chunk := p.pipe_read(.stdout) {
					out << out_buf.feed(chunk, 'out', sink)
					drained = true
				}
				if chunk := p.pipe_read(.stderr) {
					err << err_buf.feed(chunk, 'err', sink)
					drained = true
				}
				if !drained {
					break
				}
			}
			break
		}
		if time.now().unix_milli() > deadline {
			p.signal_kill()
			p.wait()
			return PumpResult{
				stdout:    out.join('') + out_buf.flush('out', sink)
				stderr:    err.join('') + err_buf.flush('err', sink)
				exit_code: -1
				timed_out: true
			}
		}
		if !got_any {
			time.sleep(poll_interval)
		}
	}
	out << out_buf.flush('out', sink)
	err << err_buf.flush('err', sink)
	p.wait()
	code := p.code
	p.close()
	return PumpResult{
		stdout:    out.join('')
		stderr:    err.join('')
		exit_code: code
	}
}

// spawn_shell starts `command` in the resolved shell with both pipes
// redirected.
fn spawn_shell(command string, cwd string, env map[string]string) !&os.Process {
	argv := resolve_shell()
	if argv.len == 0 {
		return error('no POSIX shell available — install Git Bash (windows) or bash (posix)')
	}
	mut p := os.new_process(argv[0])
	mut args := argv[1..].clone()
	args << command
	p.set_args(args)
	if cwd != '' && os.is_dir(cwd) {
		p.set_work_folder(cwd)
	}
	if env.len > 0 {
		p.set_environment(env)
	}
	p.set_redirect_stdio()
	p.run()
	return p
}

// ---------------------------------------------------------------------------
// run_command — a fresh shell per call
// ---------------------------------------------------------------------------

// run_command runs a shell command via bash and returns exit code + output.
//
// The shell is resolved once (resolve_shell): on Windows, System32\bash.exe
// is the WSL stub and fails when no distro is installed, so Git Bash is
// probed and preferred. If `sink` is provided, each output line is streamed
// to it live as it appears.
pub fn run_command(command string, timeout int, sink OutputSink) string {
	mut p := spawn_shell(command, os.getwd(), map[string]string{}) or {
		return 'ERROR: ${err.msg()}'
	}
	res := pump_process(mut p, f64(timeout), sink)
	if res.timed_out {
		return 'ERROR: command timed out after ${timeout}s'
	}
	mut out := ['exit code: ${res.exit_code}']
	if res.stdout != '' {
		out << '--- stdout ---\n' + res.stdout
	}
	if res.stderr != '' {
		out << '--- stderr ---\n' + res.stderr
	}
	return clip_tool_output(out.join('\n'))
}

// ---------------------------------------------------------------------------
// live_shell — a PERSISTENT session (cd/env/exports survive between calls)
// ---------------------------------------------------------------------------

// The live session's sticky state. V globals are zero-initialised and
// `shared` gives them a lock, so the session needs no lazy construction and
// two callers can never interleave their commands into it.
//
// live_cwd holds zero or one element: empty means "the process cwd", which
// keeps the reset path from having to invent a value.
// live_env is stored as flat `k=v` entries rather than a map: V's codegen
// mishandles cloning a `shared map` out of an rlock, and `env` prints the
// same flat form anyway, so no information is lost.
__global (
	live_cwd shared []string
	live_env shared []string
)

const cwd_marker = '__FA_CWD__'
const env_marker = '__FA_ENV__'

fn session_cwd() string {
	rlock live_cwd {
		if live_cwd.len > 0 && live_cwd[0] != '' {
			return live_cwd[0]
		}
	}
	return os.getwd()
}

fn session_env() map[string]string {
	mut pairs := []string{}
	rlock live_env {
		pairs = live_env.clone()
	}
	mut out := map[string]string{}
	for pair in pairs {
		if eq := pair.index('=') {
			out[pair[..eq]] = pair[eq + 1..]
		}
	}
	return out
}

fn set_session_env(env map[string]string) {
	mut pairs := []string{cap: env.len}
	for k, v in env {
		pairs << '${k}=${v}'
	}
	lock live_env {
		live_env = pairs.clone()
	}
}

// live_shell runs a command inside a persistent bash session.
//
// Unlike `run_command` (which spawns a fresh shell per call), this one keeps
// state across calls: a `cd src` in one call is still in effect in the next,
// and exported variables persist. Use it for live workflows: cd -> build ->
// test -> inspect -> fix.
//
// State is shared process-wide and guarded by a lock so two callers can
// never interleave their commands into the same session. If `sink` is
// provided, each output line is streamed to it live as it appears.
pub fn live_shell(command string, timeout int, sink OutputSink) string {
	start_cwd := session_cwd()
	start_env := session_env()

	// Wrap so the command's own exit code survives, and the FINAL cwd +
	// environment are reported back on marker lines we strip before
	// returning. Replaying the env on the next call is what makes
	// `export FOO=...` stick across calls despite fresh processes.
	wrapped := command + '\n' + '__fa_rc=\$?\n' +
		'printf "\\n${cwd_marker}%s" "\$PWD"\n' + 'printf "\\n${env_marker}"\n' +
		'env\n' + 'exit \$__fa_rc\n'

	// Live-stream filter: the marker line and everything after it (the env
	// blob) is bookkeeping, not real output — never show it. The wrapper's
	// leading newline can arrive as one last blank line, so trailing blanks
	// are held back until the next real line proves they are genuine output.
	mut cutoff := false
	mut pending_blanks := 0
	relay := fn [sink, mut cutoff, mut pending_blanks] (line string, stream string) {
		mut text := line
		if stream == 'out' {
			if text.contains(cwd_marker) {
				pre := text.all_before(cwd_marker)
				cutoff = true
				pending_blanks = 0
				if pre == '' {
					return
				}
				text = pre // stream the real output before the marker
			}
			if cutoff {
				return
			}
			if text == '' {
				pending_blanks++
				return
			}
			for pending_blanks > 0 {
				pending_blanks--
				sink('', 'out')
			}
		}
		sink(text, stream)
	}

	mut p := spawn_shell(wrapped, start_cwd, start_env) or {
		return 'ERROR: ${err.msg()}'
	}
	res := pump_process(mut p, f64(timeout), OutputSink(relay))
	if res.timed_out {
		return 'ERROR: command timed out after ${timeout}s (cwd=${start_cwd})'
	}

	mut stdout := res.stdout
	mut new_cwd := start_cwd
	mut new_env := start_env.clone()

	if idx := stdout.last_index(env_marker) {
		blob := stdout[idx + env_marker.len..]
		mut env_map := map[string]string{}
		for pair in blob.split('\n') {
			if pair == '' {
				continue
			}
			if eq := pair.index('=') {
				env_map[pair[..eq]] = pair[eq + 1..]
			}
		}
		if env_map.len > 0 {
			new_env = env_map.clone()
		}
		stdout = stdout[..idx].trim_right('\n')
	}
	if j := stdout.last_index(cwd_marker) {
		cand := stdout[j + cwd_marker.len..].trim_space()
		if cand != '' {
			new_cwd = cand
		}
		stdout = stdout[..j].trim_right('\n')
	}

	if os.is_dir(new_cwd) {
		lock live_cwd {
			live_cwd = [new_cwd]
		}
	}
	if new_env.len > 0 {
		set_session_env(new_env)
	}
	reported_cwd := session_cwd()

	mut parts := ['cwd: ${reported_cwd}', 'exit code: ${res.exit_code}']
	if stdout != '' {
		parts << '--- stdout ---\n' + stdout
	}
	if res.stderr != '' {
		parts << '--- stderr ---\n' + res.stderr
	}
	return clip_tool_output(parts.join('\n'))
}

// live_shell_reset resets the persistent shell session back to the process
// cwd/env.
pub fn live_shell_reset() string {
	prev := session_cwd()
	lock live_cwd {
		live_cwd = []
	}
	lock live_env {
		live_env = []string{}
	}
	return 'OK: session reset (${prev} -> ${os.getwd()})'
}

// live_shell_cwd is the session's sticky working directory, which
// apply_patch resolves relative paths against.
pub fn live_shell_cwd() string {
	return session_cwd()
}
