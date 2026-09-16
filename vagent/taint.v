module vagent

import os
import x.json2

// taint.v — real static analysis over the AST.
//
// Not regex, not guessing. Three genuine analyses:
//
//   * TAINT TRACKING     dataflow from declared SOURCES (user input, env,
//                        network, file reads) to declared SINKS (eval,
//                        exec, subprocess, os.system, sql, file writes).
//                        A variable assigned from a source is tainted;
//                        taint propagates through assignments. A tainted
//                        value reaching a sink is a finding with its exact
//                        propagation path.
//   * COMPLEXITY         cyclomatic complexity per function — branches
//                        plus one — with line and argument counts.
//   * DEPENDENCY CYCLES  the module import graph; A imports B imports A is
//                        a real structural smell, found by iterative DFS.
//
// All three are computed FROM THE PYTHON AST, and V has no Python parser.
// Reimplementing one would be a second parser to keep in step with
// CPython's, and a taint path derived from a slightly different parse is
// worse than no taint path. So the analysis runs where the parser lives:
// the harness below is the original module's own code, handed the files and
// asked for JSON. Everything else — the ledger, the projections, the report
// — is here.
//
// With no usable interpreter the result carries an error rather than an
// empty finding list, because "no findings" and "not analysed" must not
// print the same way.

pub struct TaintFinding {
pub:
	sink        string
	line        int
	source      string
	source_line int
	path        []string
}

pub fn (f &TaintFinding) to_json() map[string]json2.Any {
	return {
		'sink':        json2.Any(f.sink)
		'line':        json2.Any(f.line)
		'source':      json2.Any(f.source)
		'source_line': json2.Any(f.source_line)
		'path':        json2.Any(f.path.map(json2.Any(it)))
	}
}

pub struct Complexity {
pub:
	name       string
	line       int
	complexity int
	lines      int
	args       int
}

pub fn (c &Complexity) to_json() map[string]json2.Any {
	return {
		'name':       json2.Any(c.name)
		'line':       json2.Any(c.line)
		'complexity': json2.Any(c.complexity)
		'lines':      json2.Any(c.lines)
		'args':       json2.Any(c.args)
	}
}

pub struct Hotspot {
pub:
	file     string
	function string
}

pub struct AnalysisResult {
pub mut:
	error      string
	files      int
	taint      []TaintFinding
	complexity []Complexity
	hotspots   []Hotspot
	cycles     [][]string
}

// a function at or above this complexity is a hotspot
pub const hotspot_complexity = 10

const taint_harness = 'import ast, json, sys
from dataclasses import dataclass, field

DEFAULT_SOURCES = frozenset(
    "input raw_input request.get request.form request.args request.json "
    "os.environ os.getenv sys.argv open read readline readlines recv "
    "recvfrom urlopen fetch".split())

# Sinks: calls that are dangerous when fed tainted data.
DEFAULT_SINKS = frozenset(
    "eval exec compile os.system os.popen subprocess.run subprocess.call "
    "subprocess.Popen pickle.loads yaml.load cursor.execute execute "
    "open write send sendall render_template".split())


# ---------------------------------------------------------------------------
# Records
# ---------------------------------------------------------------------------

@dataclass
class TaintFinding:
    sink: str
    line: int
    source: str
    source_line: int
    path: list[str] = field(default_factory=list)

    def to_dict(self) -> dict:
        return {"sink": self.sink, "line": self.line,
                "source": self.source, "source_line": self.source_line,
                "path": self.path}


@dataclass
class Complexity:
    name: str
    line: int
    complexity: int
    lines: int
    args: int

    def to_dict(self) -> dict:
        return {"name": self.name, "line": self.line,
                "complexity": self.complexity, "lines": self.lines,
                "args": self.args}


# ---------------------------------------------------------------------------
# Taint analysis
# ---------------------------------------------------------------------------

def _call_name(node: ast.Call) -> str:
    """Best-effort dotted name of a call: eval / os.system / request.get."""
    fn = node.func
    if isinstance(fn, ast.Name):
        return fn.id
    if isinstance(fn, ast.Attribute):
        parts = []
        cur = fn
        while isinstance(cur, ast.Attribute):
            parts.append(cur.attr)
            cur = cur.value
        if isinstance(cur, ast.Name):
            parts.append(cur.id)
        return ".".join(reversed(parts))
    return ""


class TaintAnalyzer:
    """Intra-procedural taint dataflow over one module\'s AST."""

    def __init__(self, sources: frozenset = DEFAULT_SOURCES,
                 sinks: frozenset = DEFAULT_SINKS) -> None:
        self.sources = sources
        self.sinks = sinks

    def analyze(self, source: str) -> list[TaintFinding]:
        try:
            tree = ast.parse(source)
        except SyntaxError:
            return []
        # name -> (source_name, source_line, path)
        tainted: dict[str, tuple[str, int, list[str]]] = {}
        findings: list[TaintFinding] = []

        def is_source_call(node: ast.expr) -> tuple[bool, str, int]:
            for sub in ast.walk(node):
                if isinstance(sub, ast.Call):
                    name = _call_name(sub)
                    if name in self.sources or any(
                            name.endswith("." + s) for s in self.sources) \\
                            or any(s.endswith(name) for s in self.sources
                                   if "." in s):
                        return True, name, getattr(sub, "lineno", 0)
            return False, "", 0

        def tainted_names(node: ast.expr) -> list[str]:
            return [n.id for n in ast.walk(node)
                    if isinstance(n, ast.Name) and n.id in tainted]

        # walk in SOURCE order, not BFS order: ast.walk visits nodes
        # level-by-level, so a later re-assignment would be processed
        # before an earlier sink call and report flows that never happen
        stmts = sorted((n for n in ast.walk(tree)
                        if isinstance(n, (ast.Assign, ast.Call))),
                       key=lambda n: (getattr(n, "lineno", 0),
                                      getattr(n, "col_offset", 0)))
        for node in stmts:
            if isinstance(node, ast.Assign):
                ok, sname, sline = is_source_call(node.value)
                if ok:
                    for tgt in node.targets:
                        if isinstance(tgt, ast.Name):
                            tainted[tgt.id] = (sname, sline,
                                               [f"{sname}@{sline}",
                                                tgt.id])
                else:
                    # propagate: RHS uses a tainted name
                    used = tainted_names(node.value)
                    if used:
                        base = tainted[used[0]]
                        for tgt in node.targets:
                            if isinstance(tgt, ast.Name):
                                tainted[tgt.id] = (
                                    base[0], base[1],
                                    base[2] + [tgt.id])
            elif isinstance(node, ast.Call):
                name = _call_name(node)
                if name in self.sinks:
                    for arg in list(node.args) + \\
                            [kw.value for kw in node.keywords]:
                        for tn in tainted_names(arg):
                            src, sline, path = tainted[tn]
                            findings.append(TaintFinding(
                                sink=name,
                                line=getattr(node, "lineno", 0),
                                source=src, source_line=sline,
                                path=path + [f"{name}()"]))
                            break
        return findings


# ---------------------------------------------------------------------------
# Complexity
# ---------------------------------------------------------------------------

_BRANCHES = (ast.If, ast.For, ast.While, ast.ExceptHandler, ast.With,
             ast.BoolOp, ast.IfExp, ast.comprehension, ast.Assert)
_BRANCHES += (ast.Match,) if hasattr(ast, "Match") else ()  # py3.10+


def _own_nodes(fn: ast.AST):
    """Walk a function\'s body WITHOUT descending into nested defs —
    an inner function\'s branches belong to the inner function\'s score,
    not to every enclosing one."""
    from collections import deque
    todo = deque(ast.iter_child_nodes(fn))
    while todo:
        node = todo.popleft()
        if isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef)):
            continue
        yield node
        todo.extend(ast.iter_child_nodes(node))


def cyclomatic(source: str) -> list[Complexity]:
    """Cyclomatic complexity per function: 1 + number of branch nodes."""
    try:
        tree = ast.parse(source)
    except SyntaxError:
        return []
    out: list[Complexity] = []
    for node in ast.walk(tree):
        if isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef)):
            branches = sum(1 for n in _own_nodes(node)
                           if isinstance(n, _BRANCHES))
            end = getattr(node, "end_lineno", node.lineno)
            nargs = len(node.args.args) + len(node.args.kwonlyargs)
            out.append(Complexity(node.name, node.lineno,
                                  1 + branches, end - node.lineno + 1,
                                  nargs))
    return out


# ---------------------------------------------------------------------------
# Import cycles
# ---------------------------------------------------------------------------

def import_cycles(sources: dict[str, str]) -> list[list[str]]:
    """Detect cycles in the module import graph.

    `sources` maps module name -> source text. Returns a list of cycles,
    each a list of module names forming the loop (deduplicated)."""
    graph: dict[str, set[str]] = {}
    known = set(sources)
    for mod, src in sources.items():
        deps: set[str] = set()
        try:
            tree = ast.parse(src)
        except SyntaxError:
            continue
        for node in ast.walk(tree):
            if isinstance(node, ast.Import):
                for a in node.names:
                    root = a.name.split(".")[0]
                    if root in known:
                        deps.add(root)
            elif isinstance(node, ast.ImportFrom):
                root = (node.module or "").split(".")[0]
                if root in known:
                    deps.add(root)
        graph[mod] = deps

    cycles: list[list[str]] = []
    seen_cycles: set[tuple[str, ...]] = set()
    WHITE, GRAY, BLACK = 0, 1, 2
    color = {m: WHITE for m in graph}
    stack: list[str] = []

    def dfs(u: str) -> None:
        color[u] = GRAY
        stack.append(u)
        for v in sorted(graph.get(u, ())):
            if color.get(v, BLACK) == GRAY:
                # found a cycle: slice the stack from v
                idx = stack.index(v)
                cyc = tuple(sorted(stack[idx:]))
                if cyc not in seen_cycles:
                    seen_cycles.add(cyc)
                    cycles.append(list(stack[idx:]))
            elif color.get(v, BLACK) == WHITE:
                dfs(v)
        stack.pop()
        color[u] = BLACK

    for m in sorted(graph):
        if color[m] == WHITE:
            dfs(m)
    return cycles




def main():
    mode = sys.argv[1]
    paths = json.loads(sys.argv[2])
    analyzer = TaintAnalyzer()
    files = {}
    out_files = []
    for p in paths:
        try:
            with open(p, \'r\', errors=\'replace\') as fh:
                text = fh.read()
        except OSError as exc:
            out_files.append({\'path\': p, \'error\': str(exc)})
            continue
        files[p] = text
        out_files.append({
            \'path\': p,
            \'taint\': [f.to_dict() for f in analyzer.analyze(text)],
            \'complexity\': [c.to_dict() for c in cyclomatic(text)],
        })
    result = {\'files\': out_files}
    if mode == \'tree\':
        import os.path
        stems = {}
        for p, text in files.items():
            stems[os.path.splitext(os.path.basename(p))[0]] = text
        result[\'cycles\'] = import_cycles(stems)
    print(json.dumps(result))

main()
'

@[heap]
pub struct StaticAnalyzer {
pub mut:
	log &EventLog
}

pub fn new_static_analyzer(log &EventLog) &StaticAnalyzer {
	return &StaticAnalyzer{
		log: unsafe { log }
	}
}

// run_harness hands the files to the analyser and reads back its JSON.
fn run_harness(mode string, paths []string) !map[string]json2.Any {
	python := find_python() or { return error('no python interpreter found') }
	script := os.join_path(os.temp_dir(), 'vagent-taint-${os.getpid()}.py')
	os.write_file(script, taint_harness) or { return error('cannot write harness: ${err}') }
	defer {
		os.rm(script) or {}
	}
	arg := json2.encode(json2.Any(paths.map(json2.Any(it))))
	out := os.execute('${quote_arg(python)} ${quote_arg(script)} ${quote_arg(mode)} ${quote_arg(arg)}')
	if out.exit_code != 0 {
		return error('analyser failed (${out.exit_code}): ${clip(out.output.trim_space(), 300)}')
	}
	mut payload := ''
	for line in split_lines(out.output) {
		if line.trim_space().starts_with('{') {
			payload = line.trim_space()
		}
	}
	parsed := json2.decode[json2.Any](payload) or { return error('unreadable analyser output') }
	if parsed !is map[string]json2.Any {
		return error('unreadable analyser output')
	}
	return parsed.as_map()
}

fn read_file_result(row map[string]json2.Any) ([]TaintFinding, []Complexity) {
	mut taint := []TaintFinding{}
	for t in jarr(row, 'taint') {
		if t !is map[string]json2.Any {
			continue
		}
		m := t.as_map()
		taint << TaintFinding{
			sink:        jstr(m, 'sink')
			line:        jint(m, 'line')
			source:      jstr(m, 'source')
			source_line: jint(m, 'source_line')
			path:        jstrs(m, 'path')
		}
	}
	mut comp := []Complexity{}
	for c in jarr(row, 'complexity') {
		if c !is map[string]json2.Any {
			continue
		}
		m := c.as_map()
		comp << Complexity{
			name:       jstr(m, 'name')
			line:       jint(m, 'line')
			complexity: jint(m, 'complexity')
			lines:      jint(m, 'lines')
			args:       jint(m, 'args')
		}
	}
	return taint, comp
}

// analyze_file runs all three analyses over one file and seals what it found.
pub fn (mut a StaticAnalyzer) analyze_file(path string) AnalysisResult {
	p := resolve_path(path)
	if !os.is_file(p) {
		return AnalysisResult{
			error: 'not a file: ${p}'
		}
	}
	parsed := run_harness('file', [p]) or {
		return AnalysisResult{
			error: err.msg()
		}
	}
	rows := jarr(parsed, 'files')
	if rows.len == 0 {
		return AnalysisResult{
			error: 'the analyser returned nothing for ${p}'
		}
	}
	row := rows[0].as_map()
	if e := row['error'] {
		return AnalysisResult{
			error: e.str()
		}
	}
	taint, comp := read_file_result(row)
	mut res := AnalysisResult{
		files:      1
		taint:      taint
		complexity: comp
	}
	for c in comp {
		if c.complexity >= hotspot_complexity {
			res.hotspots << Hotspot{
				file:     p
				function: c.name
			}
		}
	}
	if taint.len > 0 {
		a.log.append('analysis.taint', {
			'path':     json2.Any(p)
			'findings': json2.Any(taint.map(json2.Any(it.to_json())))
		}, AppendOpts{ actor: 'analyst' })
	}
	if comp.len > 0 {
		a.log.append('analysis.complexity', {
			'path':      json2.Any(p)
			'functions': json2.Any(comp.map(json2.Any(it.to_json())))
			'hotspots':  json2.Any(res.hotspots.map(json2.Any(it.function)))
		}, AppendOpts{ actor: 'analyst' })
	}
	return res
}

// analyze_tree runs the same analyses over a directory, and adds the import
// cycles, which only exist between files.
pub fn (mut a StaticAnalyzer) analyze_tree(root string, pattern string, max_files int) AnalysisResult {
	rp := resolve_path(root)
	mut files := []string{}
	if os.is_dir(rp) {
		entries := os.ls(rp) or { []string{} }
		mut matched := []string{}
		for e in entries {
			full := os.join_path(rp, e)
			if os.is_file(full) && fnmatch_name(e, pattern) {
				matched << full
			}
		}
		matched.sort()
		files = matched[..min_int(max_files, matched.len)].clone()
	} else if os.is_file(rp) {
		files = [rp]
	}
	if files.len == 0 {
		return AnalysisResult{
			error: 'nothing to analyse under ${rp}'
		}
	}

	parsed := run_harness('tree', files) or {
		return AnalysisResult{
			error: err.msg()
		}
	}
	mut res := AnalysisResult{
		files: files.len
	}
	for entry in jarr(parsed, 'files') {
		if entry !is map[string]json2.Any {
			continue
		}
		row := entry.as_map()
		if _ := row['error'] {
			continue
		}
		path := jstr(row, 'path')
		taint, comp := read_file_result(row)
		res.taint << taint
		res.complexity << comp
		for c in comp {
			if c.complexity >= hotspot_complexity {
				res.hotspots << Hotspot{
					file:     path
					function: c.name
				}
			}
		}
		if taint.len > 0 {
			a.log.append('analysis.taint', {
				'path':     json2.Any(path)
				'findings': json2.Any(taint.map(json2.Any(it.to_json())))
			}, AppendOpts{ actor: 'analyst' })
		}
		if comp.len > 0 {
			a.log.append('analysis.complexity', {
				'path':      json2.Any(path)
				'functions': json2.Any(comp.map(json2.Any(it.to_json())))
				'hotspots':  json2.Any(comp.filter(it.complexity >= hotspot_complexity).map(json2.Any(it.name)))
			}, AppendOpts{ actor: 'analyst' })
		}
	}
	for cyc in jarr(parsed, 'cycles') {
		mut names := []string{}
		for n in cyc.as_array() {
			names << n.str()
		}
		if names.len > 0 {
			res.cycles << names
		}
	}
	if res.cycles.len > 0 {
		a.log.append('analysis.cycles', {
			'root':   json2.Any(rp)
			'cycles': json2.Any(res.cycles.map(json2.Any(it.map(json2.Any(it)))))
		}, AppendOpts{ actor: 'analyst' })
	}
	return res
}

pub fn (a &StaticAnalyzer) format_report(result &AnalysisResult) string {
	if result.error != '' {
		return 'STATIC ANALYSIS — ${result.error}'
	}
	mut lines := ['STATIC ANALYSIS', '  files scanned: ${result.files}',
		'  taint findings: ${result.taint.len}']
	for f in result.taint[..min_int(10, result.taint.len)] {
		lines << '    ⚠ ${f.source}@${f.source_line} → ${f.sink}@${f.line}  (${f.path.join(" → ")})'
	}
	if result.hotspots.len > 0 {
		lines << '  complexity hotspots: ${result.hotspots.len}'
		for h in result.hotspots[..min_int(10, result.hotspots.len)] {
			lines << '    ${h.file}::${h.function}'
		}
	}
	if result.cycles.len > 0 {
		lines << '  import cycles: ${result.cycles.len}'
		for c in result.cycles[..min_int(5, result.cycles.len)] {
			lines << '    ' + c.join(' → ') + ' → ' + c[0]
		}
	}
	return lines.join('\n')
}
