module vagent

import os
import x.json2

// mutate.v — real mutation testing.
//
// Mutation testing answers the question tests alone cannot: are the tests
// actually able to catch bugs? The engine makes small, real changes to the
// source — flipping operators, negating conditions, blanking return values —
// and runs the suite against each one:
//
//   * a mutant the suite KILLS (the tests fail) means the suite caught it
//   * a mutant that SURVIVES (the tests still pass) is a real hole in it
//
// The score is killed / (killed + survived). It is the signal pitest and
// mutmut are built on, and it is the one number that measures a test suite
// rather than the code under it.
//
// Mutant generation is the ORIGINAL Python AST surgery, run through the
// interpreter rather than reimplemented here. That is deliberate: a second
// Python parser written in V would disagree with CPython somewhere, and a
// mutant that is not valid Python — or an operator site counted differently
// — turns the score into a number about the parser instead of about the
// tests. The runner, the scoring and the sealing are V; only the parse is
// borrowed.

// the per-run cap, so one large file never explodes into a run that takes an
// hour
pub const max_mutants = 40

const mutate_harness = 'import ast, copy, json, sys

MAX_MUTANTS = 40


class _OperatorFlip(ast.NodeTransformer):
    """Flip binary/comparison operators: + <-> -, * <-> /, == <-> !=, etc."""
    BIN = {ast.Add: ast.Sub, ast.Sub: ast.Add, ast.Mult: ast.Div,
           ast.Div: ast.Mult, ast.Mod: ast.Mult}
    CMP = {ast.Eq: ast.NotEq, ast.NotEq: ast.Eq, ast.Lt: ast.GtE,
           ast.GtE: ast.Lt, ast.Gt: ast.LtE, ast.LtE: ast.Gt}

    def __init__(self, only_index: int) -> None:
        self.only_index = only_index
        # SEPARATE counters per operator kind. Sharing a single `count`
        # made the third "operator site" ambiguous: a BinOp and a Compare
        # op both incremented the same variable, so requesting index #2
        # might mutate a Compare op when the caller expected a BinOp
        # (and vice versa). The mutation result was structurally wrong
        # even though the AST walked cleanly.
        self._bin_count = -1
        self._cmp_count = -1

    def visit_BinOp(self, node: ast.BinOp) -> ast.BinOp:
        self.generic_visit(node)
        repl = self.BIN.get(type(node.op))
        if repl:
            self._bin_count += 1
            if self._bin_count == self.only_index:
                node.op = repl()
        return node

    def visit_Compare(self, node: ast.Compare) -> ast.Compare:
        self.generic_visit(node)
        # _flip uses the per-Compare counter; BinOp sites do not
        # contaminate this path.
        node.ops = [self._flip(o) for o in node.ops]
        return node

    def _flip(self, op: ast.cmpop) -> ast.cmpop:
        repl = self.CMP.get(type(op))
        if repl:
            self._cmp_count += 1
            if self._cmp_count == self.only_index:
                return repl()
        return op


class _ConditionNegate(ast.NodeTransformer):
    """Negate if/while conditions: if x -> if not x."""

    def __init__(self, only_index: int) -> None:
        self.only_index = only_index
        self.count = -1

    def visit_If(self, node: ast.If) -> ast.If:
        self.generic_visit(node)
        self.count += 1
        if self.count == self.only_index:
            node.test = ast.UnaryOp(op=ast.Not(), operand=node.test)
        return node

    def visit_While(self, node: ast.While) -> ast.While:
        self.generic_visit(node)
        self.count += 1
        if self.count == self.only_index:
            node.test = ast.UnaryOp(op=ast.Not(), operand=node.test)
        return node


class _ReturnBreak(ast.NodeTransformer):
    """Break return values: return X -> return None."""

    def __init__(self, only_index: int) -> None:
        self.only_index = only_index
        self.count = -1

    def visit_Return(self, node: ast.Return) -> ast.Return:
        self.generic_visit(node)
        if node.value is not None:
            self.count += 1
            if self.count == self.only_index:
                node.value = ast.Constant(value=None)
        return node


_MUTATORS = (
    ("operator_flip", _OperatorFlip),
    ("condition_negate", _ConditionNegate),
    ("return_break", _ReturnBreak),
)


def _count_sites(tree: ast.Module, cls) -> int:
    """Walk a probe instance over a deep copy and return the number of
    mutation sites it found. Each mutator class exposes one or more
    per-kind counters (``_bin_count``, ``_cmp_count``, ...); the
    classic single ``count`` attribute is also accepted for legacy
    mutators like ``_ConditionNegate``."""
    probe = cls(only_index=-1)
    probe.visit(copy.deepcopy(tree))
    total = 0
    for attr in vars(probe):
        if not attr.endswith("_count") and attr != "count":
            continue
        v = getattr(probe, attr)
        if isinstance(v, int):
            total += v + 1
    return total


def generate_mutants(source: str,
                     max_mutants: int = MAX_MUTANTS) -> list[dict]:
    """Produce concrete mutants: [{kind, description, source}]."""
    try:
        tree = ast.parse(source)
    except SyntaxError:
        return []
    mutants: list[dict] = []
    for kind, cls in _MUTATORS:
        n = _count_sites(tree, cls)
        for i in range(n):
            if len(mutants) >= max_mutants:
                return mutants
            m = cls(only_index=i)
            mutated = m.visit(copy.deepcopy(tree))
            ast.fix_missing_locations(mutated)
            try:
                code = ast.unparse(mutated)
            except Exception:
                continue
            if code.strip() == source.strip():
                continue
            mutants.append({"kind": kind,
                            "description": f"{kind} site #{i}",
                            "source": code})
    return mutants


if __name__ == "__main__":
    source = sys.stdin.read()
    cap = int(sys.argv[1]) if len(sys.argv) > 1 else MAX_MUTANTS
    print(json.dumps({"mutants": generate_mutants(source, cap)}))
'

pub struct Mutant {
pub:
	kind        string
	description string
	source      string
}

// generate_mutants produces the concrete mutants of one source file.
pub fn generate_mutants(source string, cap int) ![]Mutant {
	python := find_python() or { return error('no python interpreter found') }
	script := os.join_path(os.temp_dir(), 'vagent-mutate-${os.getpid()}.py')
	os.write_file(script, mutate_harness) or { return error('cannot write harness: ${err}') }
	defer {
		os.rm(script) or {}
	}
	// the source goes in on stdin rather than on the command line: a file
	// large enough to be worth mutating is large enough to blow an argv limit
	src_path := os.join_path(os.temp_dir(), 'vagent-mutate-src-${os.getpid()}.py')
	os.write_file(src_path, source) or { return error('cannot stage source: ${err}') }
	defer {
		os.rm(src_path) or {}
	}
	out := os.execute('${quote_arg(python)} ${quote_arg(script)} ${cap} < ${quote_arg(src_path)}')
	if out.exit_code != 0 {
		return error('mutant generation failed (${out.exit_code}): ' + clip(out.output.trim_space(), 300))
	}
	mut payload := ''
	for line in split_lines(out.output) {
		if line.trim_space().starts_with('{') {
			payload = line.trim_space()
		}
	}
	parsed := json2.decode[json2.Any](payload) or { return error('unreadable generator output') }
	if parsed !is map[string]json2.Any {
		return error('unreadable generator output')
	}
	mut mutants := []Mutant{}
	for m in jarr(parsed.as_map(), 'mutants') {
		if m !is map[string]json2.Any {
			continue
		}
		row := m.as_map()
		mutants << Mutant{
			kind:        jstr(row, 'kind')
			description: jstr(row, 'description')
			source:      jstr(row, 'source')
		}
	}
	return mutants
}

// -- the engine -----------------------------------------------------------------

pub struct MutantResult {
pub mut:
	kind        string
	description string
	// killed | survived | error
	status string = 'pending'
	detail string
}

pub fn (r &MutantResult) to_json() map[string]json2.Any {
	return {
		'kind':        json2.Any(r.kind)
		'status':      json2.Any(r.status)
		'description': json2.Any(r.description)
	}
}

pub struct MutationReport {
pub mut:
	path     string
	total    int
	killed   int
	survived int
	errors   int
	score    f64
	results  []MutantResult
}

pub fn (r &MutationReport) to_json() map[string]json2.Any {
	return {
		'path':     json2.Any(r.path)
		'total':    json2.Any(r.total)
		'killed':   json2.Any(r.killed)
		'survived': json2.Any(r.survived)
		'errors':   json2.Any(r.errors)
		'score':    json2.Any(round_to(r.score, 3))
		'results':  json2.Any(r.results.map(json2.Any(it.to_json())))
	}
}

@[heap]
pub struct MutationTester {
pub mut:
	log           &EventLog
	suite_command string
	// where a mutant is written. Empty means the file under test itself,
	// which is restored afterwards either way.
	mutant_path string
	timeout     int = 60
}

pub fn new_mutation_tester(log &EventLog, suite_command string, mutant_path string) &MutationTester {
	return &MutationTester{
		log:           unsafe { log }
		suite_command: suite_command
		mutant_path:   mutant_path
	}
}

// run_suite returns the suite's exit code and the tail of its output. A
// non-zero code means the suite noticed something, which is how a mutant is
// killed.
fn (mut t MutationTester) run_suite() (int, string) {
	argv := resolve_shell()
	if argv.len == 0 {
		return 127, 'no POSIX shell available'
	}
	mut cmd := ''
	for part in argv {
		cmd += quote_arg(part) + ' '
	}
	cmd += quote_arg(t.suite_command)
	res := os.execute(cmd)
	if res.exit_code < 0 {
		return 127, res.output.trim_space()
	}
	out := res.output
	tail := if out.len > 300 { out[out.len - 300..] } else { out }
	return res.exit_code, tail
}

// run mutates a file, runs the suite against each mutant and scores the
// suite. The original file is always restored, including when the run fails
// part way through.
pub fn (mut t MutationTester) run(path string, cap int) MutationReport {
	p := os.expand_tilde_to_home(path)
	mut report := MutationReport{
		path: p
	}
	if !os.is_file(p) {
		return report
	}
	original := os.read_file(p) or { return report }
	mutants := generate_mutants(original, cap) or { []Mutant{} }
	report.total = mutants.len
	t.log.append('mutation.run', {
		'path':    json2.Any(p)
		'mutants': json2.Any(mutants.len)
		'suite':   json2.Any(t.suite_command)
	}, AppendOpts{ actor: 'tester' })

	target := if t.mutant_path != '' { t.mutant_path } else { p }
	for m in mutants {
		mut res := MutantResult{
			kind:        m.kind
			description: m.description
		}
		mut code := 0
		mut out := ''
		os.write_file(target, m.source) or {
			code = 127
			out = err.msg()
		}
		if code == 0 {
			code, out = t.run_suite()
		}
		if code == 127 {
			// the suite could not run at all, which says nothing about the
			// mutant — counting it as killed would inflate the score
			res.status = 'error'
			res.detail = out
			report.errors++
		} else if code != 0 {
			res.status = 'killed'
			report.killed++
		} else {
			res.status = 'survived'
			res.detail = out
			report.survived++
		}
		report.results << res
	}
	// always restore the original, whatever happened above
	os.write_file(target, original) or {}

	scored := report.killed + report.survived
	report.score = if scored > 0 { f64(report.killed) / f64(scored) } else { 0.0 }
	t.log.append('mutation.result', report.to_json(), AppendOpts{ actor: 'tester' })
	return report
}

// -- projections ------------------------------------------------------------------

pub fn (mut t MutationTester) reports() []Rec {
	st := fold(mut t.log, t.log.branch)
	return st.mutation_events.filter(jstr(it, 'type') == 'mutation.result')
}

pub fn (mut t MutationTester) format_status() string {
	reps := t.reports()
	mut lines := ['MUTATION TESTING']
	if reps.len == 0 {
		lines << '  no runs yet'
	}
	mut tail := reps.clone()
	if tail.len > 5 {
		tail = tail[tail.len - 5..].clone()
	}
	for r in tail {
		lines << '  ${jstr(r, 'path')}: score ${jf64(r, 'score') * 100.0:.0f}%  ' + 'killed ${jint(r, 'killed')}/${jint(r, 'total')}  survived ${jint(r, 'survived')}'
	}
	return lines.join('\n')
}
