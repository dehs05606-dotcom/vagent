module vagent

import os
import x.json2

// cov.v — real line-coverage measurement.
//
// The Python original installed `sys.settrace` — the same CPython hook
// coverage.py is built on — around a callable, then compared the lines that
// fired against the executable lines derived from the AST:
//
//     coverage % = executed executable lines / total executable lines
//
// Neither half of that is available from V: there is no CPython frame hook
// to install and no `ast` module to walk. Reimplementing either in V would
// mean guessing at CPython's line numbering, and a coverage number that is
// quietly wrong is worse than no number at all.
//
// So this port keeps the measurement where the truth is. It writes a tracer
// harness, hands it the target and the command that exercises it, and runs
// it under the interpreter the code is written for. The harness does exactly
// what the original did — ast for the executable lines, settrace for the hits
// — and reports JSON. Everything else, the ledger and the projections, is
// here.
//
// Two consequences, both stated rather than hidden:
//   * the subject is a COMMAND, not a callable. V cannot hand Python a
//     closure, and a command is what the agent has anyway.
//   * with no usable interpreter the result is empty and a coverage.error
//     event is sealed. It never guesses a percentage.

pub struct CoverageResult {
pub mut:
	path    string
	total   int
	hit     int
	missed  []int
	percent f64
	error   string
}

pub fn (r &CoverageResult) to_json() map[string]json2.Any {
	// the original capped the missed list at 50 so one uncovered file could
	// not bloat every event after it
	capped := if r.missed.len > 50 { r.missed[..50].clone() } else { r.missed.clone() }
	mut out := {
		'path':    json2.Any(r.path)
		'total':   json2.Any(r.total)
		'hit':     json2.Any(r.hit)
		'missed':  json2.Any(capped.map(json2.Any(it)))
		'percent': json2.Any(round_to(r.percent, 1))
	}
	if r.error != '' {
		out['error'] = json2.Any(r.error)
	}
	return out
}

@[heap]
pub struct CoverageEngine {
pub mut:
	log &EventLog
}

pub fn new_coverage_engine(log &EventLog) &CoverageEngine {
	return &CoverageEngine{
		log: unsafe { log }
	}
}

// cov_harness is the tracer, verbatim in intent from the original: walk the
// AST for executable lines, record every line event whose filename resolves
// to the target, restore the previous trace whatever happens, and report.
//
// The subject is run with runpy so `python x.py` and `python -m pkg` both
// work, and a subject that raises still yields coverage — a crashing run is
// exactly when you want to know which lines it reached.
const cov_harness = "import ast, json, os, runpy, sys, shlex

target = os.path.realpath(os.path.expanduser(sys.argv[1]))
argv = shlex.split(sys.argv[2])

STMT = tuple(n for n in (
    'Assign', 'AugAssign', 'AnnAssign', 'Return', 'Delete', 'Raise',
    'Assert', 'Import', 'ImportFrom', 'If', 'For', 'While', 'Try', 'With',
    'Expr', 'Pass', 'Break', 'Continue', 'Global', 'Nonlocal',
    'FunctionDef', 'AsyncFunctionDef', 'ClassDef', 'Match')
    if hasattr(ast, n))
STMT = tuple(getattr(ast, n) for n in STMT)

try:
    with open(target, 'r', errors='replace') as fh:
        source = fh.read()
except OSError as exc:
    print(json.dumps({'error': str(exc)}))
    sys.exit(0)

try:
    tree = ast.parse(source)
except SyntaxError as exc:
    print(json.dumps({'error': 'SyntaxError: %s' % exc}))
    sys.exit(0)

exec_lines = set()
for node in ast.walk(tree):
    if isinstance(node, STMT) and hasattr(node, 'lineno'):
        exec_lines.add(node.lineno)

hit = set()

def tracer(frame, event, arg):
    if event == 'line':
        fn = frame.f_code.co_filename
        if fn == target or os.path.realpath(fn) == target:
            hit.add(frame.f_lineno)
    return tracer

old = sys.gettrace()
saved_argv = sys.argv[:]
out = sys.stdout
sys.stdout = open(os.devnull, 'w')
try:
    sys.settrace(tracer)
    try:
        sys.argv = argv
        if len(argv) >= 2 and argv[0] == '-m':
            runpy.run_module(argv[1], run_name='__main__')
        else:
            runpy.run_path(argv[0], run_name='__main__')
    except BaseException:
        pass
finally:
    sys.settrace(old)
    sys.argv = saved_argv
    sys.stdout.close()
    sys.stdout = out

executed = sorted(l for l in hit if l in exec_lines)
print(json.dumps({
    'total': len(exec_lines),
    'hit': len(executed),
    'missed': sorted(exec_lines - set(executed)),
}))
"

// measure runs `command` under the tracer and returns what it covered in
// `target_path`.
pub fn (mut c CoverageEngine) measure(target_path string, command string) CoverageResult {
	tp := os.real_path(resolve_path(target_path))
	mut res := CoverageResult{
		path: tp
	}
	if !os.is_file(tp) {
		res.error = 'not a file'
		c.log.append('coverage.error', res.to_json(), AppendOpts{ actor: 'tester' })
		return res
	}
	c.log.append('coverage.run', {
		'path':    json2.Any(tp)
		'command': json2.Any(command)
	}, AppendOpts{ actor: 'tester' })

	python := find_python() or {
		res.error = 'no python interpreter found'
		c.log.append('coverage.error', res.to_json(), AppendOpts{ actor: 'tester' })
		return res
	}
	harness := os.join_path(os.temp_dir(), 'vagent-cov-${os.getpid()}.py')
	os.write_file(harness, cov_harness) or {
		res.error = 'cannot write harness: ${err}'
		c.log.append('coverage.error', res.to_json(), AppendOpts{ actor: 'tester' })
		return res
	}
	defer {
		os.rm(harness) or {}
	}

	out := os.execute('${quote_arg(python)} ${quote_arg(harness)} ${quote_arg(tp)} ${quote_arg(command)}')
	if out.exit_code != 0 {
		res.error = 'harness failed (${out.exit_code}): ${clip(out.output.trim_space(), 300)}'
		c.log.append('coverage.error', res.to_json(), AppendOpts{ actor: 'tester' })
		return res
	}
	// the harness prints one JSON object as its last line; the subject's own
	// stdout is redirected, but a warning on stderr could still precede it
	mut payload := ''
	for line in split_lines(out.output) {
		if line.trim_space().starts_with('{') {
			payload = line.trim_space()
		}
	}
	parsed := json2.decode[json2.Any](payload) or {
		res.error = 'unreadable harness output'
		c.log.append('coverage.error', res.to_json(), AppendOpts{ actor: 'tester' })
		return res
	}
	m := parsed.as_map()
	if e := m['error'] {
		res.error = e.str()
		c.log.append('coverage.error', res.to_json(), AppendOpts{ actor: 'tester' })
		return res
	}
	res.total = jint(m, 'total')
	res.hit = jint(m, 'hit')
	for v in jarr(m, 'missed') {
		res.missed << int(v.i64())
	}
	// a file with nothing executable in it is covered, not uncovered
	res.percent = if res.total > 0 { f64(res.hit) / f64(res.total) * 100.0 } else { 100.0 }
	c.log.append('coverage.result', res.to_json(), AppendOpts{ actor: 'tester' })
	return res
}

// find_python is the interpreter the target is written for. python3 first:
// `python` is Python 2 on enough machines to matter.
pub fn find_python() ?string {
	for name in ['python3', 'python'] {
		if p := os.find_abs_path_of_executable(name) {
			return p
		}
	}
	return none
}

// -- projections -------------------------------------------------------------

pub fn (mut c CoverageEngine) results() []Rec {
	st := fold(mut c.log, c.log.branch)
	mut out := []Rec{}
	for e in st.coverage_events {
		if jstr(e, 'type') == 'coverage.result' {
			out << e
		}
	}
	return out
}

pub fn (mut c CoverageEngine) format_status() string {
	rs := c.results()
	mut lines := ['COVERAGE']
	if rs.len == 0 {
		lines << '  no runs yet'
	}
	start := max_int(0, rs.len - 6)
	for r in rs[start..] {
		path := if p := r['path'] { p.str() } else { '?' }
		lines << '  ${path}: ${jf64(r, "percent"):.0f}%  (${jint(r, "hit")}/${jint(r, "total")} lines)'
	}
	return lines.join('\n')
}
