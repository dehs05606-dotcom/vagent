module vagent

import os
import x.json2

// pyfn.v — calling one function inside a Python file.
//
// Two tools need it: the fuzzer, which must actually invoke the function it
// is throwing inputs at, and anything else that wants to poke a subject
// without importing it into this process. The generation, the boundary bias
// and the shrinking all stay in V; Python is used only for the one thing
// only Python can do, which is run the function.
//
// Each call re-imports the file. That is slower than holding the module open
// and it is the right trade: a fuzz run that mutated module state between
// iterations would report crashes that depend on the order inputs happened
// to arrive in, which is the least reproducible bug report there is.

const pyfn_harness = 'import importlib.util, json, sys


def _load(path, name):
    spec = importlib.util.spec_from_file_location(name, path)
    if spec is None or spec.loader is None:
        raise ImportError("cannot import %s" % path)
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    try:
        spec.loader.exec_module(module)
    finally:
        sys.modules.pop(spec.name, None)
    return module


def call(payload):
    path = payload.get("path") or ""
    function = payload.get("function") or ""
    try:
        module = _load(path, "vagent_probe_%s" % abs(hash(path)))
    except Exception as e:
        return {"ok": False, "error": "import failed: %s: %s"
                % (type(e).__name__, e)}
    fn = getattr(module, function, None)
    if not callable(fn):
        return {"ok": False, "error": "no callable %r in %s"
                % (function, path)}
    args = payload.get("args") or []
    try:
        got = fn(*args)
    except Exception as e:
        return {"ok": False, "error": "%s: %s" % (type(e).__name__, e)}
    return {"ok": True, "result": repr(got)}


if __name__ == "__main__":
    print(json.dumps(call(json.loads(sys.stdin.read()))))
'

pub struct PyCallResult {
pub:
	ok     bool
	result string
	error  string
}

// call_python_function invokes `function` in the file at `path` with the
// given positional arguments.
pub fn call_python_function(path string, function string, args []json2.Any) PyCallResult {
	python := find_python() or {
		return PyCallResult{
			error: 'no python interpreter found'
		}
	}
	script := os.join_path(os.temp_dir(), 'vagent-pyfn-${os.getpid()}.py')
	os.write_file(script, pyfn_harness) or {
		return PyCallResult{
			error: 'cannot write harness: ${err}'
		}
	}
	defer {
		os.rm(script) or {}
	}
	payload := json2.encode(json2.Any({
		'path':     json2.Any(path)
		'function': json2.Any(function)
		'args':     json2.Any(args.clone())
	}))
	payload_path := os.join_path(os.temp_dir(), 'vagent-pyfn-in-${os.getpid()}.json')
	os.write_file(payload_path, payload) or {
		return PyCallResult{
			error: 'cannot stage payload: ${err}'
		}
	}
	defer {
		os.rm(payload_path) or {}
	}
	out := os.execute('${quote_arg(python)} ${quote_arg(script)} < ${quote_arg(payload_path)}')
	if out.exit_code != 0 {
		return PyCallResult{
			error: 'call failed: ' + clip(out.output.trim_space(), 200)
		}
	}
	mut line := ''
	for row in split_lines(out.output) {
		if row.trim_space().starts_with('{') {
			line = row.trim_space()
		}
	}
	parsed := json2.decode[json2.Any](line) or {
		return PyCallResult{
			error: 'unreadable harness output'
		}
	}
	if parsed !is map[string]json2.Any {
		return PyCallResult{
			error: 'unreadable harness output'
		}
	}
	m := parsed.as_map()
	return PyCallResult{
		ok:     jbool(m, 'ok')
		result: jstr(m, 'result')
		error:  jstr(m, 'error')
	}
}

// fuzz_value_to_json renders a generated value as the JSON the harness will
// turn back into a Python argument. A byte string has no JSON form, so it
// travels as its decoded text — the fuzzer's blob cases still exercise the
// function, they simply arrive as `str` rather than `bytes`.
pub fn fuzz_value_to_json(v FuzzValue) json2.Any {
	match v {
		FuzzNone { return json2.null }
		bool { return json2.Any(v) }
		i64 { return json2.Any(v) }
		f64 { return json2.Any(v) }
		string { return json2.Any(v) }
		FuzzBlob { return json2.Any(v.data.bytestr()) }
		[]FuzzValue { return json2.Any(v.map(fuzz_value_to_json(it))) }
		map[string]FuzzValue {
			mut out := map[string]json2.Any{}
			for k, item in v {
				out[k] = fuzz_value_to_json(item)
			}
			return json2.Any(out)
		}
	}
}
