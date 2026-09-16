module vagent

import os
import time
import x.json2

// workflows.v — saved multi-step pipelines.
//
// A workflow is a reusable, version-controlled recipe: an ordered set of
// steps, each with a task, a role, an optional model override and an
// optional machine-checkable `expect` predicate. Steps run one at a time,
// grouped into phases that execute in order — real orchestration rather than
// a todo list.
//
// The rules are mechanical:
//
//   * Workflows are JSON files under the workflows directory: human
//     editable, git-trackable, reusable across sessions.
//   * Every run is sealed — workflow.start, workflow.step, workflow.done —
//     so a run is auditable and replayable.
//   * A step whose `expect` predicate FAILS blocks the workflow right
//     there. It is never silently skipped, and the report says which step
//     stopped and why.
//   * Step execution is injected, so the engine is fully testable without a
//     live model; the agent binds it to the crew.

const workflow_name_pattern = r'^[\w][\w.\-]{0,63}$'

pub const run_states = ['RUNNING', 'DONE', 'BLOCKED', 'ABANDONED']

// WorkflowError marks an invalid definition or an unknown workflow.
pub struct WorkflowError {
	Error
pub:
	message string
}

pub fn (e WorkflowError) msg() string {
	return e.message
}

fn workflow_error(message string) IError {
	return WorkflowError{
		message: message
	}
}

pub fn valid_workflow_name(name string) bool {
	re := compile_regex(workflow_name_pattern) or { return false }
	if _ := re.search(name) {
		return true
	}
	return false
}

// -- the definition -----------------------------------------------------------

pub struct WorkflowStep {
pub:
	task  string
	role  string = 'coder'
	model string
	phase int
	// none means the step is not machine-checked; an empty map would read
	// as "check nothing", which is a different claim
	expect ?map[string]json2.Any
}

pub fn (s &WorkflowStep) to_json() map[string]json2.Any {
	mut d := {
		'task': json2.Any(s.task)
		'role': json2.Any(s.role)
	}
	if s.model != '' {
		d['model'] = json2.Any(s.model)
	}
	if s.phase != 0 {
		d['phase'] = json2.Any(s.phase)
	}
	if e := s.expect {
		d['expect'] = json2.Any(e.clone())
	}
	return d
}

pub fn step_from_json(v json2.Any) !WorkflowStep {
	if v !is map[string]json2.Any {
		return workflow_error("every step needs a non-empty 'task'")
	}
	d := v.as_map()
	task := jstr(d, 'task').trim_space()
	if task == '' {
		return workflow_error("every step needs a non-empty 'task'")
	}
	mut expect := ?map[string]json2.Any(none)
	if raw := d['expect'] {
		if raw is map[string]json2.Any {
			expect = raw.clone()
		} else if raw !is json2.Null {
			return workflow_error("'expect' must be a predicate dict")
		}
	}
	mut phase := 0
	if raw := d['phase'] {
		phase = int_of_any(raw) or { return workflow_error("'phase' must be an integer") }
	}
	if phase < 0 {
		phase = 0
	}
	mut role := jstr(d, 'role').trim_space()
	if role == '' {
		role = 'coder'
	}
	return WorkflowStep{
		task:   task
		role:   role
		model:  jstr(d, 'model').trim_space()
		phase:  phase
		expect: expect
	}
}

pub struct Workflow {
pub:
	name        string
	description string
	steps       []WorkflowStep
}

pub fn (w &Workflow) to_json() map[string]json2.Any {
	return {
		'name':        json2.Any(w.name)
		'description': json2.Any(w.description)
		'steps':       json2.Any(w.steps.map(json2.Any(it.to_json())))
	}
}

pub fn workflow_from_json(d map[string]json2.Any) !Workflow {
	name := jstr(d, 'name').trim_space()
	if !valid_workflow_name(name) {
		return workflow_error("invalid workflow name '${name}' — use letters, digits, " + "'_', '-', '.' (max 64 chars)")
	}
	raw_steps := jarr(d, 'steps')
	if raw_steps.len == 0 {
		return workflow_error('a workflow needs at least one step')
	}
	mut steps := []WorkflowStep{}
	for s in raw_steps {
		steps << step_from_json(s)!
	}
	return Workflow{
		name:        name
		description: jstr(d, 'description').trim_space()
		steps:       steps
	}
}

// -- one step's outcome --------------------------------------------------------

pub struct StepResult {
pub mut:
	step int
	task string
	role string
	// pending | done | blocked | error
	status  string = 'pending'
	summary string
	// the expect verdict's detail
	check      string
	elapsed_ms int
}

pub fn (r &StepResult) to_json() map[string]json2.Any {
	return {
		'step':       json2.Any(r.step)
		'task':       json2.Any(clip_plain(r.task, 200))
		'role':       json2.Any(r.role)
		'status':     json2.Any(r.status)
		'summary':    json2.Any(clip_plain(r.summary, 400))
		'check':      json2.Any(clip_plain(r.check, 200))
		'elapsed_ms': json2.Any(r.elapsed_ms)
	}
}

pub struct RunReport {
pub mut:
	name       string
	state      string
	steps      []StepResult
	elapsed_ms int
}

pub fn (r &RunReport) to_json() map[string]json2.Any {
	return {
		'name':       json2.Any(r.name)
		'state':      json2.Any(r.state)
		'steps':      json2.Any(r.steps.map(json2.Any(it.to_json())))
		'elapsed_ms': json2.Any(r.elapsed_ms)
	}
}

// -- the engine ----------------------------------------------------------------

// StepExecutorFn runs ONE step and reports what happened. The agent binds it
// to the crew; a test injects a stub.
pub type StepExecutorFn = fn (step &WorkflowStep, n int) !map[string]json2.Any

@[heap]
pub struct WorkflowEngine {
pub mut:
	log      &EventLog
	dir      string
	executor StepExecutorFn = unsafe { nil }
	judge    &Judge         = unsafe { nil }
}

pub fn new_workflow_engine(log &EventLog, dir string, executor StepExecutorFn, judge &Judge) &WorkflowEngine {
	return &WorkflowEngine{
		log:      unsafe { log }
		dir:      dir
		executor: executor
		judge:    unsafe { judge }
	}
}

// -- persistence ----------------------------------------------------------------

// path_of resolves a workflow's file.
//
// The name is validated here rather than only in save(), because load,
// delete and run all take raw user text. Without this check, a name like
// '../../etc/foo' would read — or UNLINK — a JSON file outside the
// workflows directory entirely.
fn (w &WorkflowEngine) path_of(name string) !string {
	if !valid_workflow_name(name) {
		return workflow_error("invalid workflow name: '${name}'")
	}
	return os.join_path(w.dir, '${name}.json')
}

pub fn (mut w WorkflowEngine) save(wf &Workflow) !string {
	os.mkdir_all(w.dir) or { return workflow_error('cannot create ${w.dir}: ${err}') }
	path := w.path_of(wf.name)!
	atomic_write_text(path, json2.encode(json2.Any(wf.to_json()))) or {
		return workflow_error('cannot write ${path}: ${err}')
	}
	w.log.append('workflow.saved', {
		'name':  json2.Any(wf.name)
		'steps': json2.Any(wf.steps.len)
	}, AppendOpts{ actor: 'sovereign' })
	return path
}

pub fn (mut w WorkflowEngine) load(name string) !Workflow {
	path := w.path_of(name)!
	if !os.is_file(path) {
		saved := w.list()
		known := if saved.len > 0 { saved.join(', ') } else { 'none' }
		return workflow_error("unknown workflow '${name}' (saved: ${known})")
	}
	text := os.read_file(path) or { return workflow_error("workflow '${name}' is unreadable") }
	parsed := json2.decode[json2.Any](text) or {
		return workflow_error("workflow '${name}' is malformed: ${err}")
	}
	if parsed !is map[string]json2.Any {
		return workflow_error("workflow '${name}' is malformed: not an object")
	}
	return workflow_from_json(parsed.as_map()) or {
		return workflow_error("workflow '${name}' is malformed: ${err.msg()}")
	}
}

pub fn (w &WorkflowEngine) list() []string {
	if !os.is_dir(w.dir) {
		return []
	}
	mut out := []string{}
	for entry in os.ls(w.dir) or { []string{} } {
		if entry.ends_with('.json') {
			out << entry[..entry.len - 5]
		}
	}
	out.sort()
	return out
}

pub fn (mut w WorkflowEngine) delete(name string) !bool {
	path := w.path_of(name)!
	if !os.is_file(path) {
		return false
	}
	os.rm(path) or { return workflow_error('cannot delete ${path}: ${err}') }
	return true
}

// -- execution -------------------------------------------------------------------

struct PhaseGroup {
	phase int
	steps []int // indexes into the workflow's steps
}

// run executes a saved workflow: phases in order, and the steps within a
// phase one at a time. A failed expect-predicate BLOCKS the run at that step.
pub fn (mut w WorkflowEngine) run(name string, timeout f64) !RunReport {
	wf := w.load(name)!
	if w.executor == unsafe { nil } {
		return workflow_error('no executor bound — workflows cannot run')
	}

	// group the steps into phases, keeping the declared order inside each
	mut phase_numbers := []int{}
	mut by_phase := map[int][]int{}
	for i, step in wf.steps {
		if step.phase !in by_phase {
			phase_numbers << step.phase
		}
		by_phase[step.phase] << i
	}
	phase_numbers.sort()

	w.log.append('workflow.start', {
		'name':   json2.Any(wf.name)
		'steps':  json2.Any(wf.steps.len)
		'phases': json2.Any(phase_numbers.len)
	}, AppendOpts{ actor: 'sovereign' })

	mut report := RunReport{
		name:  wf.name
		state: 'RUNNING'
	}
	t0 := time.now()

	for phase in phase_numbers {
		if report.state != 'RUNNING' {
			break
		}
		for idx in by_phase[phase] {
			step := wf.steps[idx]
			n := idx + 1
			rep := w.run_step(&step, n, timeout)
			mut r := StepResult{
				step:       n
				task:       step.task
				role:       step.role
				status:     jstr(rep, 'status')
				summary:    jstr(rep, 'summary')
				elapsed_ms: jint(rep, 'elapsed_ms')
			}
			if r.status == 'done' && w.judge != unsafe { nil } {
				if predicate := step.expect {
					verdict := w.judge.check(predicate)
					r.check = verdict.detail
					if !verdict.passed {
						r.status = 'blocked'
						r.summary = (r.summary + '\nEXPECT FAILED: ${verdict.detail}').trim_space()
					}
				}
			}
			mut sealed := r.to_json()
			sealed['name'] = json2.Any(wf.name)
			sealed['phase'] = json2.Any(phase)
			w.log.append('workflow.step', sealed, AppendOpts{ actor: 'system' })
			report.steps << r
			if r.status in ['blocked', 'error'] {
				report.state = 'BLOCKED'
				break
			}
		}
	}

	if report.state == 'RUNNING' {
		report.state = 'DONE'
	}
	report.elapsed_ms = int((time.now() - t0).milliseconds())
	w.log.append('workflow.done', {
		'name':        json2.Any(wf.name)
		'state':       json2.Any(report.state)
		'steps_ok':    json2.Any(report.steps.filter(it.status == 'done').len)
		'steps_total': json2.Any(wf.steps.len)
		'elapsed_ms':  json2.Any(report.elapsed_ms)
	}, AppendOpts{ actor: 'kernel' })
	return report
}

// run_step runs ONE step through the bound executor. A failing step never
// kills the engine: the failure is the step's own report.
fn (mut w WorkflowEngine) run_step(step &WorkflowStep, n int, timeout f64) map[string]json2.Any {
	started := time.now()
	mut rep := w.executor(step, n) or {
		mut failed := map[string]json2.Any{}
		failed['status'] = json2.Any('error')
		failed['summary'] = json2.Any(err.msg())
		failed
	}
	if rep.len == 0 {
		rep['status'] = json2.Any('error')
		rep['summary'] = json2.Any('empty report')
	}
	if 'elapsed_ms' !in rep {
		rep['elapsed_ms'] = json2.Any(int((time.now() - started).milliseconds()))
	}
	if 'status' !in rep {
		rep['status'] = json2.Any('done')
	}
	if 'summary' !in rep {
		rep['summary'] = json2.Any('')
	}
	return rep
}

// -- rendering ---------------------------------------------------------------------

pub fn (mut w WorkflowEngine) format_list() string {
	names := w.list()
	if names.len == 0 {
		return 'no saved workflows — define one with /workflow define'
	}
	mut lines := ['SAVED WORKFLOWS']
	for n in names {
		wf := w.load(n) or {
			lines << '  ✗ ${n} — ${err.msg()}'
			continue
		}
		suffix := if wf.description != '' { ' — ' + clip_plain(wf.description, 60) } else { '' }
		lines << '  ◆ ${n} — ${wf.steps.len} step(s)${suffix}'
		for i, s in wf.steps {
			check := if _ := s.expect { ' ⊛expect' } else { '' }
			model := if s.model != '' { ' [${s.model}]' } else { '' }
			lines << '      ${i + 1}. (${s.role}${model}) ' + clip_plain(s.task, 70) + check
		}
	}
	return lines.join('\n')
}

pub fn (w &WorkflowEngine) format_report(report &RunReport) string {
	icon := match report.state {
		'DONE' { '✓' }
		'BLOCKED' { '⛔' }
		'RUNNING' { '…' }
		'ABANDONED' { '⊘' }
		else { '?' }
	}
	mut lines := [
		'WORKFLOW ${report.name} — ${icon} ${report.state} ' + '(${f64(report.elapsed_ms) / 1000.0:.1f}s)',
	]
	for r in report.steps {
		glyph := match r.status {
			'done' { '✓' }
			'blocked' { '⛔' }
			'error' { '✗' }
			'pending' { '·' }
			else { '?' }
		}
		lines << '  ${glyph} step ${r.step} (${r.role}) ' + clip_plain(r.task, 80)
		if r.summary != '' {
			lines << '      ' + clip_plain(r.summary, 200).replace('\n', '\n      ')
		}
		if r.check != '' {
			lines << '      expect: ' + clip_plain(r.check, 120)
		}
	}
	return lines.join('\n')
}
