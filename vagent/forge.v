module vagent

import os
import x.json2

// forge.v — environment reproducibility (§18).
//
// The most ignored failure mode in the category: the agent fixes a bug that
// only exists in its own environment. The Forge hashes everything that can
// change behaviour into an EnvironmentDigest, seals it as an event, and
// detects mid-session drift.
//
//   * digest()  — os, runtime, deps, locale, toolchain versions -> one hash.
//   * probe()   — digest + env.digest event; every observation is implicitly
//                 stamped with the environment that produced it.
//   * drift()   — compare the latest digests; any material change marks
//                 earlier evidence stale (the Judge re-runs stale proofs).

// probed_tools are the toolchains whose versions can change behaviour.
const probed_tools = ['git', 'node', 'docker', 'gcc', 'make']

fn tool_versions() map[string]string {
	mut versions := map[string]string{}
	for tool in probed_tools {
		exe := os.find_abs_path_of_executable(tool) or { continue }
		res := os.execute('${os.quoted_path(exe)} --version')
		lines := split_lines(res.output)
		if lines.len == 0 || lines[0] == '' {
			versions[tool] = '?'
			continue
		}
		first := lines[0]
		versions[tool] = if first.len > 80 { first[..80] } else { first }
	}
	return versions
}

// lockfile_hash hashes the resolved dependency tree if a lockfile exists.
fn lockfile_hash(cwd string) string {
	for name in ['v.mod', 'uv.lock', 'poetry.lock', 'requirements.txt',
		'Pipfile.lock', 'package-lock.json'] {
		p := os.join_path(cwd, name)
		if os.is_file(p) {
			content := os.read_file(p) or { return '' }
			return hash(content)[..16]
		}
	}
	return ''
}

// env_allowlist is the set of environment variables that can change
// behaviour. Hashing the whole environment would make every digest unique.
const env_allowlist = ['PATH', 'VIRTUAL_ENV', 'VMODULES', 'LANG', 'FULLAGENT_HOME']

// host_arch names the CPU architecture. A statement-level `$if` keeps the
// compile-time branch out of a struct literal, where V's codegen mangles it.
fn host_arch() string {
	$if arm64 {
		return 'arm64'
	} $else $if amd64 {
		return 'amd64'
	} $else $if i386 {
		return 'i386'
	} $else {
		return 'unknown'
	}
}

// Forge is environment digest + drift detection over the event log.
pub struct Forge {
pub mut:
	log &EventLog
	cwd string
}

pub fn new_forge(log &EventLog, cwd string) Forge {
	return Forge{
		log: unsafe { log }
		cwd: if cwd != '' { resolve_path(cwd) } else { os.getwd() }
	}
}

// digest computes the EnvironmentDigest (§18.1).
pub fn (f &Forge) digest() Rec {
	mut env := map[string]json2.Any{}
	for k in env_allowlist {
		env[k] = os.getenv(k)
	}
	mut tools := map[string]json2.Any{}
	for k, v in tool_versions() {
		tools[k] = v
	}
	mut record := Rec({
		'os':             json2.Any(os.user_os())
		'arch':           json2.Any(host_arch())
		'kernel':         json2.Any(os.uname().release)
		'runtime':        json2.Any('V ${version}')
		'implementation': json2.Any('vagent')
		'locale':         json2.Any(os.getenv('LANG'))
		'encoding':       json2.Any('utf-8')
		'cwd':            json2.Any(f.cwd)
		'lockfile_hash':  json2.Any(lockfile_hash(f.cwd))
		'env':            json2.Any(env)
		'tools':          json2.Any(tools)
		'case_sensitive': json2.Any(os.user_os() != 'windows')
	})
	record['digest'] = hash(canonical(json2.Any(record)))[..16]
	return record
}

// probe computes the digest and seals an env.digest event. Called at
// PERCEIVE and periodically by the Librarian role.
pub fn (mut f Forge) probe() Rec {
	record := f.digest()
	f.log.append('env.digest', record, AppendOpts{ actor: 'librarian' })
	return record
}

pub struct EnvDrift {
pub:
	from    string
	to      string
	changed []string
}

// drift compares the two most recent digests and returns a delta when the
// environment changed materially. Observations recorded before the change
// are stale; the Judge re-runs proofs whose evidence predates a material
// change (§18.4).
pub fn (mut f Forge) drift() ?EnvDrift {
	digests := fold(mut f.log, '').env_digests
	if digests.len < 2 {
		return none
	}
	prev := digests[digests.len - 2]
	cur := digests.last()
	if jstr(prev, 'digest') == jstr(cur, 'digest') {
		return none
	}
	mut changed := []string{}
	for k in ['os', 'runtime', 'lockfile_hash', 'cwd'] {
		if jstr(prev, k) != jstr(cur, k) {
			changed << k
		}
	}
	prev_tools := jmap(prev, 'tools')
	cur_tools := jmap(cur, 'tools')
	mut tool_names := map[string]bool{}
	for k, _ in prev_tools {
		tool_names[k] = true
	}
	for k, _ in cur_tools {
		tool_names[k] = true
	}
	mut tools_changed := []string{}
	for t, _ in tool_names {
		if jstr(prev_tools, t) != jstr(cur_tools, t) {
			tools_changed << t
		}
	}
	if tools_changed.len > 0 {
		tools_changed.sort()
		changed << 'tools:' + tools_changed.join(',')
	}
	changed.sort()
	return EnvDrift{
		from:    jstr(prev, 'digest')
		to:      jstr(cur, 'digest')
		changed: changed
	}
}
