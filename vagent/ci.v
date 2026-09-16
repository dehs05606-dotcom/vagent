module vagent

import os
import sync
import time
import x.json2

// ci.v — the continuous-integration pilot: a file-watch autopilot.
//
// A personal CI system living inside the agent:
//
//   watch    a background thread snapshots file signatures (mtime + size)
//            and polls; a change is a REAL diff, not a touch
//   map      changed files map to their tests three ways — the name
//            convention (test_x.py <-> x.py), a scan of what the test
//            files mention, and the file's own directory. The dependency
//            map grows from what the project looks like, not from a config
//            file nobody updated.
//   run      only the IMPACTED tests run, through an injected runner
//   streaks  green and red streaks are tracked and sealed; a red streak is
//            exactly the signal the healer or the main agent should react to
//
// The pilot never edits anything. It watches, maps, runs and reports. What
// to DO about a red build is the agent's job.

pub const ci_poll_seconds = 2.0

pub struct RunRecord {
pub mut:
	changed []string
	tests   []string
	passed  bool
	output  string
	ts      f64
}

struct FileSig {
	mtime i64
	size  u64
	// the content hash, but only for a file touched in the last few
	// seconds. See scan() for why.
	hash string
}

// V's stat gives whole-second mtimes, so two writes to the same file inside
// one second with the same length look identical. The original had
// sub-second resolution and did not have to care. Rather than hash the whole
// tree on every poll, a file modified within this window is hashed as well,
// which is exactly the case where the timestamp cannot decide.
const ci_hash_window = 3
const ci_hash_max_bytes = 256 * 1024

// CiRunner runs the impacted tests. Production shells out; the tests stub
// it, which is what keeps this module runnable without a test suite of the
// watched project's own.
pub type CiRunner = fn (test_files []string) !(bool, string)

@[heap]
pub struct CIPilot {
pub mut:
	log    &EventLog
	root   string
	runner CiRunner = unsafe { nil }
	poll   f64      = ci_poll_seconds

	records      []RunRecord
	streak_green int
	streak_red   int
mut:
	mu       sync.Mutex
	snapshot map[string]FileSig
	has_snap bool
	running  bool
	stop     &CancelFlag = unsafe { nil }
}

pub fn new_ci_pilot(log &EventLog, root string, runner CiRunner, poll f64) &CIPilot {
	return &CIPilot{
		log:    unsafe { log }
		root:   root
		runner: runner
		poll:   if poll > 0 { poll } else { ci_poll_seconds }
	}
}

// -- the file map ------------------------------------------------------------

fn (c &CIPilot) scan() map[string]FileSig {
	now := time.now().unix()
	mut out := map[string]FileSig{}
	for path in walk_files(c.root, 200_000) {
		rel := rel_to(c.root, path)
		if rel == '' {
			continue
		}
		parts := rel.split('/')
		if '.git' in parts || '__pycache__' in parts {
			continue
		}
		mtime := os.file_last_mod_unix(path)
		size := u64(os.file_size(path))
		mut digest := ''
		if now - mtime <= ci_hash_window && size <= ci_hash_max_bytes {
			digest = hash(read_text_or_empty(path))
		}
		out[rel] = FileSig{
			mtime: mtime
			size:  size
			hash:  digest
		}
	}
	return out
}

// changed_sig decides whether two signatures describe different content.
// The hashes only participate when BOTH were taken, so a file ageing out of
// the hash window is not reported as changed for having done so.
fn changed_sig(a FileSig, b FileSig) bool {
	if a.mtime != b.mtime || a.size != b.size {
		return true
	}
	return a.hash != '' && b.hash != '' && a.hash != b.hash
}

fn rel_to(root string, path string) string {
	r := os.real_path(root)
	p := os.real_path(path)
	if p == r {
		return ''
	}
	if !p.starts_with(r + os.path_separator) {
		return ''
	}
	return p[r.len + 1..].replace('\\', '/')
}

// impacted_tests maps changed source files to their test files: name twins,
// tests that mention the module, and same-directory tests.
pub fn (c &CIPilot) impacted_tests(changed []string) []string {
	mut tests := []string{}
	for path in walk_files(c.root, 200_000) {
		base := os.base(path)
		if base.starts_with('test_') && base.ends_with('.py') {
			rel := rel_to(c.root, path)
			if rel != '' {
				tests << rel
			}
		}
	}
	if tests.len == 0 {
		return []
	}
	mut test_text := map[string]string{}
	for t in tests {
		test_text[t] = read_text_or_empty(os.join_path(c.root, t))
	}

	mut picked := map[string]bool{}
	for raw in changed {
		path := raw.replace('\\', '/')
		base := os.base(path)
		mod := base.all_before_last('.')
		for t in tests {
			if t.ends_with('/test_${base}') || t == 'test_${mod}.py'
				|| t.ends_with('/test_${mod}.py') {
				picked[t] = true
			}
		}
		if mod != '' {
			for t, text in test_text {
				if text.contains(mod) {
					// it imports or otherwise mentions the module
					picked[t] = true
				}
			}
		}
		dirn := dir_of(path)
		for t in tests {
			if dir_of(t) == dirn {
				picked[t] = true
			}
		}
	}
	mut out := picked.keys()
	out.sort()
	return out
}

// dir_of is the posix parent of a relative path, matching Python's
// Path(p).parent — which is '.' for a bare filename.
fn dir_of(path string) string {
	idx := path.last_index('/') or { return '.' }
	if idx == 0 {
		return '/'
	}
	return path[..idx]
}

// -- one cycle ---------------------------------------------------------------

// check_once diffs the tree since the last look and runs the impacted tests.
// It returns none on the first call, which only establishes the baseline.
pub fn (mut c CIPilot) check_once() ?RunRecord {
	current := c.scan()
	c.mu.@lock()
	had := c.has_snap
	previous := c.snapshot.clone()
	c.mu.unlock()

	if !had {
		c.mu.@lock()
		c.snapshot = current.clone()
		c.has_snap = true
		c.mu.unlock()
		return none
	}

	mut changed := []string{}
	for p, sig in current {
		old := previous[p] or {
			changed << p
			continue
		}
		if changed_sig(old, sig) {
			changed << p
		}
	}
	changed.sort()
	// a file that disappeared is a change too
	mut gone := []string{}
	for p, _ in previous {
		if p !in current {
			gone << p
		}
	}
	gone.sort()
	changed << gone

	if changed.len == 0 {
		c.mu.@lock()
		c.snapshot = current.clone()
		c.mu.unlock()
		return none
	}

	tests := c.impacted_tests(changed)
	mut record := RunRecord{
		changed: changed[..min_int(50, changed.len)].clone()
		tests:   tests[..min_int(30, tests.len)].clone()
		passed:  true
		ts:      now_ts()
	}
	if record.tests.len > 0 && !isnil(c.runner) {
		ok, output := c.runner(record.tests) or {
			// a broken runner reports; it does not stop the watch
			record.passed = false
			record.output = clip_plain('runner failed: ${err.msg()}', 400)
			c.finish_cycle(mut record, current)
			return record
		}
		record.passed = ok
		record.output = clip_plain(output, 400)
	}
	c.finish_cycle(mut record, current)
	return record
}

fn (mut c CIPilot) finish_cycle(mut record RunRecord, current map[string]FileSig) {
	c.records << record
	if record.passed {
		c.streak_green++
		c.streak_red = 0
	} else {
		c.streak_red++
		c.streak_green = 0
	}
	c.log.append('ci.run', {
		'changed': json2.Any(record.changed[..min_int(10, record.changed.len)].map(json2.Any(it)))
		'tests':   json2.Any(record.tests[..min_int(10, record.tests.len)].map(json2.Any(it)))
		'passed':  json2.Any(record.passed)
	}, AppendOpts{})
	c.log.append('ci.streak', {
		'green': json2.Any(c.streak_green)
		'red':   json2.Any(c.streak_red)
	}, AppendOpts{})
	c.mu.@lock()
	c.snapshot = current.clone()
	c.mu.unlock()
}

// -- lifecycle ---------------------------------------------------------------

pub fn (mut c CIPilot) start() {
	if c.running {
		return
	}
	snap := c.scan()
	c.mu.@lock()
	c.snapshot = snap.clone()
	c.has_snap = true
	c.mu.unlock()
	c.log.append('ci.watch', {
		'root':  json2.Any(c.root)
		'files': json2.Any(snap.len)
	}, AppendOpts{ actor: 'human' })
	c.running = true
	c.stop = new_cancel_flag()
	spawn ci_loop(mut c)
}

fn ci_loop(mut c CIPilot) {
	mut stop := c.stop
	for !stop.is_set() {
		// the pilot never dies mid-watch
		c.check_once() or {}
		mut waited := 0.0
		for waited < c.poll && !stop.is_set() {
			time.sleep(50 * time.millisecond)
			waited += 0.05
		}
	}
}

pub fn (mut c CIPilot) stop_watching() {
	if !c.running {
		return
	}
	mut s := c.stop
	s.set()
	c.running = false
}

pub fn (c &CIPilot) status() string {
	state := if c.running { 'running' } else { 'stopped' }
	mut lines := [
		'CI PILOT — watching ${c.root} (${state})',
		'  streaks: ${c.streak_green} green · ${c.streak_red} red · ${c.records.len} run(s)',
	]
	if c.records.len > 0 {
		last := c.records.last()
		mark := if last.passed { '✓ green' } else { '✗ RED' }
		head := last.changed[..min_int(4, last.changed.len)]
		lines << '  last: ${mark} — changed ' + head.join(', ')
	}
	return lines.join('\n')
}
