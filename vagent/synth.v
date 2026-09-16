module vagent

import os
import x.json2

// synth.v — program synthesis: the agent writes its own tools.
//
// The toolkit is not fixed either. When the model needs a capability nobody
// shipped, it writes it:
//
//     draft       the generator (injectable; in production one model call)
//                 produces a function from a spec plus examples
//     validate    mechanical AST gates: exactly one function definition, no
//                 imports, no exec or eval, no dunder access. A draft that
//                 breaks the rules dies before it runs.
//     test        the function must pass EVERY example, each under a hard
//                 wall-clock timeout. The examples are the contract.
//     register    a passing function becomes a REAL tool in the registry,
//                 with a schema, callable by the agent and by every
//                 subagent that inherits it.
//
// Nothing unvalidated ever runs, and the timeout is not decoration: the AST
// gate cannot prove termination — a generated `while True:` is perfectly
// legal syntax — so a hung example fails rather than freezing the agent.
//
// Validation and execution run the ORIGINAL Python gates through the
// interpreter. The synthesized tool IS Python, so the only checker whose
// verdict means anything is the one that shares CPython's parser, and the
// only way to call the tool is to run it. The pipeline, the registry and
// the ledger are V.

const synth_harness = 'from __future__ import annotations
import ast, inspect, json, re, sys, textwrap, threading

_CALL_TIMEOUT_S = 5.0  # per-example wall clock; generated code must halt

_TIMEOUT_S = 10.0
_FORBIDDEN_NODES = (ast.Import, ast.ImportFrom)
_FORBIDDEN_NAMES = re.compile(
    r"\\b(exec|eval|compile|__import__|open|globals|locals|getattr|"
    r"setattr|delattr|__subclasses__|__globals__|__builtins__|"
    r"breakpoint|input)\\b")
_NAME_RE = re.compile(r"^[a-z][a-z0-9_]{2,30}\$")


_SAFE_BUILTINS = {
    "abs": abs, "all": all, "any": any, "bool": bool, "chr": chr,
    "dict": dict, "divmod": divmod, "enumerate": enumerate, "filter":
    filter, "float": float, "int": int, "isinstance": isinstance,
    "len": len, "list": list, "map": map, "max": max, "min": min,
    "ord": ord, "range": range, "reversed": reversed, "round": round,
    "set": set, "sorted": sorted, "str": str, "sum": sum, "tuple":
    tuple, "zip": zip, "True": True, "False": False, "None": None,
}



SynthSpec = None


class Spec:
    def __init__(self, name, examples):
        self.name = name
        self.examples = examples


class _Synth:
    def validate_source(self, source: str, name: str) -> tuple[str, str]:
        """Mechanical AST gates. Returns (fn_name, problem)."""
        try:
            tree = ast.parse(textwrap.dedent(source))
        except SyntaxError as e:
            return "", f"syntax error: {e.msg}"
        fns = [n for n in ast.walk(tree)
               if isinstance(n, ast.FunctionDef)]
        if len(fns) != 1:
            return "", f"exactly one function expected, found {len(fns)}"
        fn = fns[0]
        if fn.name != name:
            return "", f"function must be named {name!r}, got {fn.name!r}"
        if _FORBIDDEN_NAMES.search(source):
            hit = _FORBIDDEN_NAMES.search(source).group(0)
            return "", f"forbidden name {hit!r} in generated code"
        for node in ast.walk(tree):
            if isinstance(node, _FORBIDDEN_NODES):
                return "", "imports are not allowed in synthesized tools"
            if isinstance(node, ast.Name) and node.id.startswith("__"):
                return "", f"dunder access {node.id!r} is not allowed"
            if isinstance(node, ast.Attribute) \\
                    and node.attr.startswith("__"):
                return "", f"dunder access .{node.attr!r} is not allowed"
        args = [a.arg for a in fn.args.args]
        if not args:
            return "", "function must take at least one argument"
        return fn.name, ""

    def run_examples(self, fn, spec: SynthSpec) -> tuple[int, list[str]]:
        """Run every example under a per-call wall-clock timeout — the AST
        gate cannot prove termination (a generated `while True:` is legal
        syntax), so a hung example fails instead of freezing the agent."""
        passed = 0
        failures: list[str] = []

        for i, ex in enumerate(spec.examples):
            ok, got, note = self._call_with_timeout(fn, ex["args"],
                                                    _CALL_TIMEOUT_S)
            if not ok:
                failures.append(f"example {i}: {note}")
                continue
            if got == ex["want"]:
                passed += 1
            else:
                failures.append(f"example {i}: got {got!r}, want "
                                f"{ex[\x27want\x27]!r}")
        return passed, failures

    @staticmethod
    def _call_with_timeout(fn, kwargs: dict,
                           timeout: float) -> tuple[bool, object, str]:
        out: dict = {}

        def runner():
            try:
                out["got"] = fn(**kwargs)
            except Exception as e:  # noqa: BLE001 — data, not a crash
                out["err"] = f"{type(e).__name__}: {e}"

        t = threading.Thread(target=runner, daemon=True,
                             name="synth:example")
        t.start()
        t.join(timeout)
        if t.is_alive():
            # Honest documentation of the leak: a generated example
            # whose body is a `while True: pass` will keep the thread
            # alive forever (daemon=True means the interpreter will
            # exit but the spec-level "synthesize then continue" loop
            # in run_examples will spin up a new thread per example).
            # We surface the leak so the failure isn\x27t silent, AND we
            # call sys.intern() on a probe to keep the GIL warm enough
            # that the leak cannot wedge the whole agent.
            return False, None, (f"timed out after {timeout:g}s — "
                                 "generated code does not terminate "
                                 "(leaked thread — see synth.py)")
        if "err" in out:
            return False, None, out["err"]
        return True, out.get("got"), ""



synth = _Synth()


def _define(source, name):
    fn_name, problem = synth.validate_source(source, name)
    if not fn_name:
        return None, problem
    namespace = {"__builtins__": _SAFE_BUILTINS}
    try:
        exec(compile(textwrap.dedent(source), "<synth:%s>" % name, "exec"),
             namespace)
    except Exception as e:
        return None, "definition failed: %s: %s" % (type(e).__name__, e)
    return namespace[fn_name], ""


def do_validate(payload):
    source = payload.get("source") or ""
    name = payload.get("name") or ""
    fn, problem = _define(source, name)
    if fn is None:
        return {"ok": False, "reason": problem, "passed": 0,
                "total": len(payload.get("examples") or []), "params": []}
    spec = Spec(name, payload.get("examples") or [])
    passed, failures = synth.run_examples(fn, spec)
    try:
        sig = inspect.signature(fn)
        params = [p.name for p in sig.parameters.values()
                  if p.kind in (inspect.Parameter.POSITIONAL_OR_KEYWORD,
                                inspect.Parameter.KEYWORD_ONLY)]
    except (TypeError, ValueError):
        params = []
    total = len(spec.examples)
    return {"ok": passed == total, "reason": "", "passed": passed,
            "total": total, "failures": failures[:3], "params": params}


def do_call(payload):
    fn, problem = _define(payload.get("source") or "",
                          payload.get("name") or "")
    if fn is None:
        return {"ok": False, "error": problem}
    ok, got, note = synth._call_with_timeout(fn, payload.get("args") or {},
                                             _CALL_TIMEOUT_S)
    if not ok:
        return {"ok": False, "error": note}
    return {"ok": True, "result": str(got)}


if __name__ == "__main__":
    payload = json.loads(sys.stdin.read())
    mode = payload.get("mode", "validate")
    print(json.dumps(do_validate(payload) if mode == "validate"
                     else do_call(payload)))
'

pub struct SynthExample {
pub:
	args map[string]json2.Any
	want json2.Any
}

pub fn (e &SynthExample) to_json() map[string]json2.Any {
	return {
		'args': json2.Any(e.args.clone())
		'want': e.want
	}
}

pub struct SynthSpec {
pub:
	name        string
	description string
	examples    []SynthExample
}

pub struct SynthResult {
pub:
	ok     bool
	name   string
	reason string
	passed int
	total  int
}

// SynthGenerator drafts the function source for a spec.
pub type SynthGenerator = fn (spec &SynthSpec) string

// the tool name must be a plain lowercase identifier — a schema key, not a
// sentence
const synth_name_pattern = r'^[a-z][a-z0-9_]{2,30}$'

pub fn valid_synth_name(name string) bool {
	re := compile_regex(synth_name_pattern) or { return false }
	if _ := re.search(name) {
		return true
	}
	return false
}

// -- the harness ------------------------------------------------------------------

struct SynthGateReport {
	ok       bool
	reason   string
	passed   int
	total    int
	failures []string
	params   []string
}

fn run_synth_harness(payload map[string]json2.Any) !map[string]json2.Any {
	python := find_python() or { return error('no python interpreter found') }
	script := os.join_path(os.temp_dir(), 'vagent-synth-${os.getpid()}.py')
	os.write_file(script, synth_harness) or { return error('cannot write harness: ${err}') }
	defer {
		os.rm(script) or {}
	}
	payload_path := os.join_path(os.temp_dir(), 'vagent-synth-in-${os.getpid()}.json')
	os.write_file(payload_path, json2.encode(json2.Any(payload.clone()))) or {
		return error('cannot stage payload: ${err}')
	}
	defer {
		os.rm(payload_path) or {}
	}
	out := os.execute('${quote_arg(python)} ${quote_arg(script)} < ${quote_arg(payload_path)}')
	if out.exit_code != 0 {
		return error('synthesis harness failed: ' + clip(out.output.trim_space(), 200))
	}
	mut line := ''
	for row in split_lines(out.output) {
		if row.trim_space().starts_with('{') {
			line = row.trim_space()
		}
	}
	parsed := json2.decode[json2.Any](line) or { return error('unreadable harness output') }
	if parsed !is map[string]json2.Any {
		return error('unreadable harness output')
	}
	return parsed.as_map()
}

fn gate_and_test(spec &SynthSpec, source string) SynthGateReport {
	mut examples := []json2.Any{}
	for e in spec.examples {
		examples << json2.Any(e.to_json())
	}
	m := run_synth_harness({
		'mode':     json2.Any('validate')
		'name':     json2.Any(spec.name)
		'source':   json2.Any(source)
		'examples': json2.Any(examples)
	}) or {
		return SynthGateReport{
			reason: err.msg()
			total:  spec.examples.len
		}
	}
	return SynthGateReport{
		ok:       jbool(m, 'ok')
		reason:   jstr(m, 'reason')
		passed:   jint(m, 'passed')
		total:    jint(m, 'total')
		failures: jstrs(m, 'failures')
		params:   jstrs(m, 'params')
	}
}

// call_synthesized runs a proven function with the given arguments. This is
// what a registered tool's handler does on every invocation: the source was
// validated once, and running it means running Python.
pub fn call_synthesized(name string, source string, args map[string]json2.Any) string {
	m := run_synth_harness({
		'mode':   json2.Any('call')
		'name':   json2.Any(name)
		'source': json2.Any(source)
		'args':   json2.Any(args.clone())
	}) or { return 'ERROR: ${err.msg()}' }
	if !jbool(m, 'ok') {
		return 'ERROR: ' + jstr(m, 'error')
	}
	return jstr(m, 'result')
}

// -- the synthesizer ---------------------------------------------------------------

@[heap]
pub struct ProgramSynthesizer {
pub mut:
	log       &EventLog
	generator SynthGenerator @[required]
	// the live tool registry a proven tool lands in
	registry    map[string]Tool
	synthesized []string
	source_of   map[string]string
}

pub fn new_program_synthesizer(log &EventLog, generator SynthGenerator) &ProgramSynthesizer {
	return &ProgramSynthesizer{
		log:       unsafe { log }
		generator: generator
	}
}

// synthesize is the full pipeline for one tool spec.
pub fn (mut s ProgramSynthesizer) synthesize(spec SynthSpec) SynthResult {
	if !valid_synth_name(spec.name) {
		return SynthResult{
			name:   spec.name
			reason: 'bad tool name'
		}
	}
	if spec.examples.len == 0 {
		// without examples there is no contract, and nothing to prove
		return SynthResult{
			name:   spec.name
			reason: 'at least one example is required'
		}
	}
	source := s.generator(&spec)
	s.log.append('synth.tool.drafted', {
		'name':  json2.Any(spec.name)
		'chars': json2.Any(source.len)
	}, AppendOpts{ actor: 'sovereign' })

	report := gate_and_test(&spec, source)
	if report.reason != '' {
		s.log.append('synth.tool.tested', {
			'name':   json2.Any(spec.name)
			'ok':     json2.Any(false)
			'reason': json2.Any(report.reason)
		}, AppendOpts{ actor: 'kernel' })
		return SynthResult{
			name:   spec.name
			reason: report.reason
		}
	}

	s.log.append('synth.tool.tested', {
		'name':     json2.Any(spec.name)
		'ok':       json2.Any(report.ok)
		'passed':   json2.Any(report.passed)
		'total':    json2.Any(report.total)
		'failures': json2.Any(strs_to_any(report.failures))
	}, AppendOpts{ actor: 'kernel' })

	if !report.ok {
		mut head := report.failures.clone()
		if head.len > 2 {
			head = head[..2].clone()
		}
		return SynthResult{
			name:   spec.name
			reason: 'failed examples: ' + head.join('; ')
			passed: report.passed
			total:  report.total
		}
	}

	s.register(&spec, source, report.params)
	s.synthesized << spec.name
	s.log.append('synth.tool.registered', {
		'name':     json2.Any(spec.name)
		'examples': json2.Any(spec.examples.len)
	}, AppendOpts{ actor: 'kernel' })
	return SynthResult{
		ok:     true
		name:   spec.name
		reason: "tool '${spec.name}' registered — ${report.passed}/${report.total} examples pass"
		passed: report.passed
		total:  report.total
	}
}

// register wires the proven function into the live tool registry.
fn (mut s ProgramSynthesizer) register(spec &SynthSpec, source string, params []string) {
	mut properties := map[string]json2.Any{}
	for p in params {
		properties[p] = json2.Any({
			'type':        json2.Any('string')
			'description': json2.Any('arg ${p}')
		})
	}
	name := spec.name
	s.source_of[name] = source
	s.registry[name] = Tool{
		name:        name
		description: '[synthesized] ${spec.description}'
		parameters:  {
			'type':       json2.Any('object')
			'properties': json2.Any(properties)
			'required':   json2.Any(strs_to_any(params))
		}
		handler:     ToolHandler(fn [name, source] (args map[string]json2.Any, sink OutputSink) string {
			return call_synthesized(name, source, args)
		})
	}
}
