module vagent

import x.json2

// daemon.v — mission control: autonomous missions that outlive a turn.
//
// A mission is a queue of steps. The daemon owns the mission record in the
// event log, advances it one TICK at a time, checkpoints after every tick,
// and can be resumed from the last checkpoint after any restart.
//
// The rules are mechanical:
//
//   * All mission state lives in the event log — daemon.mission,
//     daemon.checkpoint, daemon.tick, daemon.done. A Daemon keeps no
//     authoritative state of its own; resume() rebuilds everything from the
//     fold, so a crash loses at most one in-flight tick.
//   * A step that fails is retried up to max_retries, and then the mission
//     BLOCKS — visibly, at the step that stopped it. It is never silently
//     skipped.
//   * Self-wake is a REPORT, not a timer. wake_conditions() are
//     deterministic predicates over the fold; due() says which of them hold
//     right now, and the scheduler or a human decides whether to tick. The
//     daemon never sleeps or polls in-process.

pub const mission_states = ['RUNNING', 'BLOCKED', 'DONE', 'ABANDONED']
pub const step_states = ['PENDING', 'RUNNING', 'DONE', 'FAILED', 'SKIPPED']

// -- records ------------------------------------------------------------------

pub struct Step {
pub mut:
	id       string
	task     string
	state    string = 'PENDING'
	attempts int
	result   string
}

pub fn (s &Step) to_json() map[string]json2.Any {
	return {
		'id':       json2.Any(s.id)
		'task':     json2.Any(s.task)
		'state':    json2.Any(s.state)
		'attempts': json2.Any(s.attempts)
		'result':   json2.Any(clip_plain(s.result, 300))
	}
}

pub struct Mission {
pub mut:
	mission_id string
	statement  string
	steps      []Step
	state      string = 'RUNNING'
	// the event seq of the last checkpoint
	checkpoint_seq int = -1
	ticks          int
}

// pending is the next step waiting to run, if any.
pub fn (m &Mission) pending() ?int {
	for i, s in m.steps {
		if s.state == 'PENDING' {
			return i
		}
	}
	return none
}

pub fn (m &Mission) progress() f64 {
	if m.steps.len == 0 {
		return 1.0
	}
	done := m.steps.filter(it.state == 'DONE').len
	return f64(done) / f64(m.steps.len)
}

// -- the daemon ---------------------------------------------------------------

// StepExecutor runs one step. A result starting with 'ERROR:' counts as a
// failed attempt — the daemon reads the outcome rather than being told it.
pub type StepExecutor = fn (task string) string

@[heap]
pub struct Daemon {
pub mut:
	log         &EventLog
	executor    StepExecutor = unsafe { nil }
	max_retries int          = 2
}

pub fn new_daemon(log &EventLog, executor StepExecutor, max_retries int) &Daemon {
	return &Daemon{
		log:         unsafe { log }
		executor:    executor
		max_retries: if max_retries < 0 { 0 } else { max_retries }
	}
}

// -- mission lifecycle --------------------------------------------------------

// start seals a new mission. Step ids are M1..Mn.
//
// The id is derived from the log head rather than a clock. A millisecond
// clock collides when two missions start back to back, and everything here
// runs fast enough for that to happen; a sequence number is strictly
// monotonic and cannot.
pub fn (mut d Daemon) start(statement string, tasks []string) Mission {
	mission_id := 'mission-${d.log.head(d.log.branch) + 1}'
	mut steps := []Step{}
	for i, t in tasks {
		steps << Step{
			id:   'M${i + 1}'
			task: t
		}
	}
	d.log.append('daemon.mission', {
		'mission_id': json2.Any(mission_id)
		'statement':  json2.Any(statement)
		'steps':      json2.Any(steps.map(json2.Any(it.to_json())))
		'state':      json2.Any('RUNNING')
	}, AppendOpts{ actor: 'daemon' })
	return Mission{
		mission_id: mission_id
		statement:  statement
		steps:      steps
	}
}

// tick executes the next pending step, seals the outcome and checkpoints.
//
// A step that exhausts its retries BLOCKS the mission. It is never skipped:
// a mission that cannot finish must say where it stopped.
pub fn (mut d Daemon) tick(mission_id string) map[string]json2.Any {
	mut m := d.resume(mission_id) or {
		return {
			'mission_id': json2.Any(mission_id)
			'error':      json2.Any('no such mission')
		}
	}
	if m.state != 'RUNNING' {
		return {
			'mission_id': json2.Any(mission_id)
			'state':      json2.Any(m.state)
			'error':      json2.Any('mission is ${m.state}, not RUNNING')
		}
	}
	idx := m.pending() or {
		d.close(mut m, 'DONE')
		return {
			'mission_id': json2.Any(mission_id)
			'state':      json2.Any('DONE')
			'progress':   json2.Any(1.0)
		}
	}

	m.steps[idx].attempts++
	mut result := 'ERROR: no executor attached'
	if d.executor != unsafe { nil } {
		result = d.executor(m.steps[idx].task)
	}

	failed := result.starts_with('ERROR:')
	m.steps[idx].state = if failed { 'FAILED' } else { 'DONE' }
	m.steps[idx].result = result
	m.ticks++

	d.log.append('daemon.tick', {
		'mission_id': json2.Any(mission_id)
		'step':       json2.Any(m.steps[idx].to_json())
		'failed':     json2.Any(failed)
		'attempt':    json2.Any(m.steps[idx].attempts)
	}, AppendOpts{ actor: 'daemon' })

	if failed && m.steps[idx].attempts > d.max_retries {
		// the retries are spent — the mission blocks here, visibly
		m.steps[idx].state = 'FAILED'
		d.patch_state(mut m, 'BLOCKED')
		d.checkpoint(mut m)
		return {
			'mission_id': json2.Any(mission_id)
			'step':       json2.Any(m.steps[idx].id)
			'state':      json2.Any('BLOCKED')
			'result':     json2.Any(result)
			'progress':   json2.Any(round_to(m.progress(), 3))
		}
	}
	if failed {
		// retry on the next tick
		m.steps[idx].state = 'PENDING'
	}
	d.checkpoint(mut m)
	if !failed {
		if _ := m.pending() {
		} else {
			d.close(mut m, 'DONE')
			return {
				'mission_id': json2.Any(mission_id)
				'step':       json2.Any(m.steps[idx].id)
				'state':      json2.Any('DONE')
				'result':     json2.Any(result)
				'progress':   json2.Any(1.0)
			}
		}
	}
	return {
		'mission_id': json2.Any(mission_id)
		'step':       json2.Any(m.steps[idx].id)
		'state':      json2.Any('RUNNING')
		'result':     json2.Any(result)
		'progress':   json2.Any(round_to(m.progress(), 3))
	}
}

pub fn (mut d Daemon) abandon(mission_id string, reason string) bool {
	mut m := d.resume(mission_id) or { return false }
	if m.state == 'DONE' {
		return false
	}
	d.patch_state(mut m, 'ABANDONED')
	d.log.append('daemon.done', {
		'mission_id': json2.Any(mission_id)
		'state':      json2.Any('ABANDONED')
		'reason':     json2.Any(reason)
	}, AppendOpts{ actor: 'human' })
	return true
}

// -- checkpoints and resume ---------------------------------------------------

fn (mut d Daemon) checkpoint(mut m Mission) {
	ev := d.log.append('daemon.checkpoint', {
		'mission_id': json2.Any(m.mission_id)
		'steps':      json2.Any(m.steps.map(json2.Any(it.to_json())))
		'ticks':      json2.Any(m.ticks)
		'state':      json2.Any(m.state)
	}, AppendOpts{ actor: 'daemon' })
	m.checkpoint_seq = ev.seq
}

fn (mut d Daemon) patch_state(mut m Mission, state string) {
	m.state = state
	d.log.append('daemon.checkpoint', {
		'mission_id': json2.Any(m.mission_id)
		'steps':      json2.Any(m.steps.map(json2.Any(it.to_json())))
		'ticks':      json2.Any(m.ticks)
		'state':      json2.Any(state)
	}, AppendOpts{ actor: 'daemon' })
}

fn (mut d Daemon) close(mut m Mission, state string) {
	m.state = state
	d.log.append('daemon.done', {
		'mission_id': json2.Any(m.mission_id)
		'state':      json2.Any(state)
		'ticks':      json2.Any(m.ticks)
		'progress':   json2.Any(round_to(m.progress(), 3))
	}, AppendOpts{ actor: 'daemon' })
}

// resume rebuilds a mission purely from the fold — the daemon's crash
// recovery. The latest checkpoint wins, and the sealed order is the replay
// order.
pub fn (mut d Daemon) resume(mission_id string) ?Mission {
	st := fold(mut d.log, d.log.branch)
	evs := st.daemon_events
	mut base := map[string]json2.Any{}
	mut found := false
	for e in evs {
		if jstr(e, 'type') == 'daemon.mission' && jstr(e, 'mission_id') == mission_id {
			base = e.clone()
			found = true
		}
	}
	if !found {
		return none
	}
	mut steps := []Step{}
	for s in jarr(base, 'steps') {
		if s !is map[string]json2.Any {
			continue
		}
		obj := s.as_map()
		steps << Step{
			id:       jstr(obj, 'id')
			task:     jstr(obj, 'task')
			state:    jstr(obj, 'state')
			attempts: jint(obj, 'attempts')
			result:   jstr(obj, 'result')
		}
	}
	mut m := Mission{
		mission_id: mission_id
		statement:  jstr(base, 'statement')
		steps:      steps
		state:      'RUNNING'
	}
	for e in evs {
		if jstr(e, 'mission_id') != mission_id {
			continue
		}
		match jstr(e, 'type') {
			'daemon.checkpoint' {
				m.ticks = jint(e, 'ticks')
				if 'state' in e {
					m.state = jstr(e, 'state')
				}
				mut by_id := map[string]map[string]json2.Any{}
				for s in jarr(e, 'steps') {
					if s is map[string]json2.Any {
						by_id[jstr(s, 'id')] = s.clone()
					}
				}
				for i in 0 .. m.steps.len {
					if row := by_id[m.steps[i].id] {
						m.steps[i].state = jstr(row, 'state')
						m.steps[i].attempts = jint(row, 'attempts')
						m.steps[i].result = jstr(row, 'result')
					}
				}
			}
			'daemon.done' {
				if 'state' in e {
					m.state = jstr(e, 'state')
				}
			}
			else {}
		}
	}
	return m
}

// missions is one summary row per mission, newest first.
pub fn (mut d Daemon) missions() []map[string]json2.Any {
	st := fold(mut d.log, d.log.branch)
	mut ids := []string{}
	for e in st.daemon_events {
		if jstr(e, 'type') == 'daemon.mission' {
			mid := jstr(e, 'mission_id')
			if mid != '' && mid !in ids {
				ids << mid
			}
		}
	}
	mut rows := []map[string]json2.Any{}
	for i := ids.len - 1; i >= 0; i-- {
		m := d.resume(ids[i]) or { continue }
		rows << {
			'mission_id': json2.Any(ids[i])
			'statement':  json2.Any(m.statement)
			'state':      json2.Any(m.state)
			'ticks':      json2.Any(m.ticks)
			'progress':   json2.Any(round_to(m.progress(), 3))
			'steps':      json2.Any(m.steps.len)
		}
	}
	return rows
}

// -- self-wake ----------------------------------------------------------------

// wake_conditions are the deterministic predicates over the fold that justify
// waking the daemon for another tick. This only REPORTS what holds — the
// daemon itself never sleeps or polls.
pub fn (mut d Daemon) wake_conditions() []string {
	st := fold(mut d.log, d.log.branch)
	mut reasons := []string{}
	running := d.missions().filter(jstr(it, 'state') == 'RUNNING')
	if running.len > 0 {
		reasons << '${running.len} mission(s) RUNNING with pending steps'
	}
	failed_verdicts := st.verdicts.filter(!jbool(it, 'passed')).len
	if failed_verdicts > 0 {
		reasons << '${failed_verdicts} failed verdict(s) to react to'
	}
	if st.budget_events.len > 0 {
		reasons << 'budget event sealed — re-evaluate missions'
	}
	return reasons
}

pub fn (mut d Daemon) due() bool {
	return d.wake_conditions().len > 0
}

pub fn (mut d Daemon) format_status() string {
	rows := d.missions()
	mut lines := ['DAEMON — mission control']
	if rows.len == 0 {
		lines << '  no missions'
	}
	mut head := rows.clone()
	if head.len > 8 {
		head = head[..8].clone()
	}
	for r in head {
		progress := jf64(r, 'progress')
		bar := int(progress * 12)
		lines << '  ${jstr(r, 'mission_id')}  [' + pad_width(jstr(r, 'state'), 9) + '] ' + '█'.repeat(bar) + '░'.repeat(12 - bar) + ' ${progress * 100.0:.0f}%  ' + '${jint(r, 'ticks')} ticks  ' + clip_plain(jstr(r, 'statement'), 36)
	}
	wakes := d.wake_conditions()
	if wakes.len > 0 {
		lines << '  wake: ' + wakes.join('; ')
	}
	return lines.join('\n')
}
