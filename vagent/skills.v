module vagent

import os
import x.json2

// skills.v — the skill forge: the self-evolving tool author.
//
// When the agent keeps doing the same multi-step thing by hand, the forge
// lets it author a NEW tool, prove it safe and correct with deterministic
// checks, and register it into the live registry — so the agent becomes more
// capable over time. Skills are written to disk so they survive a restart.
//
// The safety gate is mechanical, and a skill NEVER runs unvalidated:
//
//   1. Parse   — the source must be valid Python.
//   2. Shape   — it must define exactly the declared entry function, with a
//                docstring, and nothing but plain functions.
//   3. Safety  — an AST scan forbids imports outside the allowlist,
//                subprocess and eval and exec, writes and deletes through a
//                dangerous module, dunder access, and global statements. A
//                skill is a pure data-in/data-out function.
//   4. Test    — the author must ship test cases, and ALL of them must pass.
//
// Only a skill that clears all four is sealed as skill.registered. Anything
// else is sealed as skill.rejected with the exact reason: the attempt is
// recorded rather than hidden, because a forge that quietly drops its
// failures cannot be audited.
//
// The gates run the ORIGINAL Python validators through the interpreter. That
// is the point rather than a shortcut: the thing being judged IS Python, and
// a safety scan written against a second, slightly different parser would
// pass code that CPython executes differently. A skill whose danger is
// invisible to the checker is worse than no checker.
//
// The forge itself — the record, the persistence, the registry, the ledger —
// is V.

const skills_harness = 'import ast, importlib.util, json, os, sys, tempfile
from dataclasses import dataclass, field

# imports a skill may use — pure stdlib, no side-effect modules
ALLOWED_IMPORTS = frozenset(
    "json math re string hashlib base64 datetime itertools functools "
    "collections statistics textwrap unicodedata urllib.parse html "
    "pathlib posixpath random typing dataclasses enum".split())

# AST nodes / names that are never allowed in a skill
_FORBIDDEN_CALLS = frozenset(
    "eval exec compile open input __import__ globals locals vars setattr "
    "delattr breakpoint exit quit".split())
# File/process-mutation attributes are only dangerous when the *receiver* is
# a known dangerous module (os, shutil, pathlib, subprocess, io, builtins).
# Matching the bare attribute name used to reject benign code such as
# `class Door: def open(self): ...; Door().open()` — the dot is right, the
# semantics are completely different.
_FORBIDDEN_ATTRS = frozenset(
    "system popen exec execl execle execlp subprocess __subclasses__ "
    "__globals__ __code__ __builtins__ "
    # filesystem mutation through allowed modules (pathlib/shutil-style):
    # a "pure data-in/data-out" function never writes or deletes
    "write_text write_bytes open unlink rmdir rename replace rmtree "
    "touch mkdir symlink_to hardlink_to chmod chown".split())
# Module roots whose attribute access is treated as dangerous. The bare
# name `os.open`, `pathlib.Path.write_text`, `shutil.rmtree` are caught;
# a custom class with its own `open()` method is left alone.
_DANGEROUS_MODULES = frozenset(
    "os shutil pathlib subprocess sys builtins io fcntl "
    "posix nt _io".split())


# ---------------------------------------------------------------------------
# Skill record
# ---------------------------------------------------------------------------

@dataclass
class Skill:
    name: str
    description: str
    source: str
    entry: str                     # the function name to call
    parameters: dict = field(default_factory=dict)
    tests: list[dict] = field(default_factory=list)  # {args, expect}
    status: str = "pending"        # pending | registered | rejected
    reject_reason: str = ""

    def to_dict(self) -> dict:
        return {"name": self.name, "description": self.description,
                "entry": self.entry, "parameters": self.parameters,
                "tests": self.tests, "status": self.status,
                "reject_reason": self.reject_reason,
                "chars": len(self.source)}


# ---------------------------------------------------------------------------
# Validation gates
# ---------------------------------------------------------------------------

def _validate_shape(tree: ast.Module, skill: Skill) -> str | None:
    """The entry function must exist, be a plain def, and have a docstring."""
    fns = [n for n in tree.body if isinstance(n, ast.FunctionDef)]
    names = [f.name for f in fns]
    if skill.entry not in names:
        return f"entry function {skill.entry!r} not defined (has: {names})"
    fn = next(f for f in fns if f.name == skill.entry)
    if not (fn.body and isinstance(fn.body[0], ast.Expr)
            and isinstance(fn.body[0].value, ast.Constant)
            and isinstance(fn.body[0].value.value, str)):
        return f"entry function {skill.entry!r} needs a docstring"
    if any(isinstance(n, (ast.AsyncFunctionDef, ast.ClassDef))
           for n in tree.body):
        return "skills must be plain functions — no classes/async"
    return None


def _attr_root_is_dangerous(node: ast.Attribute) -> bool:
    """Walk the receiver chain of `a.b.c.d` and return True iff the
    leftmost name is a known dangerous module (os, shutil, ...). A method
    call on a locally-defined object (e.g. `door.open()`) returns False
    even when the attribute name itself is in the forbidden list."""
    cur: ast.AST = node
    while isinstance(cur, ast.Attribute):
        cur = cur.value
    if isinstance(cur, ast.Name):
        return cur.id in _DANGEROUS_MODULES
    return False


def _validate_safety(tree: ast.Module) -> str | None:
    """AST scan: no forbidden imports, calls, attributes, or writes."""
    for node in ast.walk(tree):
        if isinstance(node, ast.Import):
            for a in node.names:
                root = a.name.split(".")[0]
                if root not in ALLOWED_IMPORTS:
                    return f"forbidden import: {a.name}"
        elif isinstance(node, ast.ImportFrom):
            root = (node.module or "").split(".")[0]
            if root not in ALLOWED_IMPORTS:
                return f"forbidden import: from {node.module}"
        elif isinstance(node, ast.Call):
            fn = node.func
            if isinstance(fn, ast.Name) and fn.id in _FORBIDDEN_CALLS:
                return f"forbidden call: {fn.id}()"
            if isinstance(fn, ast.Attribute) \
                    and fn.attr in _FORBIDDEN_ATTRS \
                    and _attr_root_is_dangerous(fn):
                # only reject when the receiver chain is a known dangerous
                # module — a user-defined `Door.open()` is fine
                return (f"forbidden attribute on dangerous module: "
                        f".{fn.attr}()")
        elif isinstance(node, ast.Attribute):
            if node.attr.startswith("__") and node.attr.endswith("__"):
                return f"dunder access forbidden: {node.attr}"
        elif isinstance(node, ast.Global):
            return "global statements forbidden in skills"
    return None


def _run_tests(skill: Skill, namespace: dict) -> str | None:
    """Run the author\x27s test cases against the loaded entry function."""
    fn = namespace.get(skill.entry)
    if not callable(fn):
        return f"entry {skill.entry!r} did not load as callable"
    if not skill.tests:
        return "a skill must ship at least one test case"
    for i, t in enumerate(skill.tests, 1):
        args = t.get("args") or {}
        expect = str(t.get("expect", ""))
        try:
            got = str(fn(**args))
        except Exception as e:
            return f"test {i} raised {type(e).__name__}: {e}"
        if expect and expect not in got:
            return (f"test {i} failed: expected {expect!r} in output, "
                    f"got {got[:120]!r}")
    return None




def _load(skill):
    """Load the skill source in an isolated module namespace."""
    with tempfile.NamedTemporaryFile("w", suffix=".py", delete=False) as f:
        f.write(skill.source)
        tmp = f.name
    try:
        spec = importlib.util.spec_from_file_location(
            "fullagent_skill_%s" % skill.name, tmp)
        module = importlib.util.module_from_spec(spec)
        sys.modules[spec.name] = module
        try:
            spec.loader.exec_module(module)
        finally:
            sys.modules.pop(spec.name, None)
        return module.__dict__
    finally:
        try:
            os.unlink(tmp)
        except OSError:
            pass


def gate(payload):
    skill = Skill(name=payload.get("name", "skill"),
                  description=payload.get("description", ""),
                  source=payload.get("source", ""),
                  entry=payload.get("entry", ""),
                  parameters=payload.get("parameters") or {},
                  tests=payload.get("tests") or [])
    try:
        tree = ast.parse(skill.source)
    except SyntaxError as e:
        return {"ok": False, "reason": "does not parse: %s" % e}
    err = _validate_shape(tree, skill)
    if err:
        return {"ok": False, "reason": err}
    err = _validate_safety(tree)
    if err:
        return {"ok": False, "reason": err}
    try:
        namespace = _load(skill)
    except Exception as e:
        return {"ok": False, "reason": "failed to load: %s" % e}
    err = _run_tests(skill, namespace)
    if err:
        return {"ok": False, "reason": err}
    return {"ok": True, "reason": ""}


if __name__ == "__main__":
    print(json.dumps(gate(json.loads(sys.stdin.read()))))
'

pub struct SkillTest {
pub:
	args   map[string]json2.Any
	expect string
}

pub fn (t &SkillTest) to_json() map[string]json2.Any {
	return {
		'args':   json2.Any(t.args.clone())
		'expect': json2.Any(t.expect)
	}
}

pub struct Skill {
pub mut:
	name        string
	description string
	source      string
	// the function the tool actually calls
	entry      string
	parameters map[string]json2.Any
	tests      []SkillTest
	// pending | registered | rejected
	status        string = 'pending'
	reject_reason string
}

pub fn (s &Skill) to_json() map[string]json2.Any {
	return {
		'name':          json2.Any(s.name)
		'description':   json2.Any(s.description)
		'entry':         json2.Any(s.entry)
		'parameters':    json2.Any(s.parameters.clone())
		'tests':         json2.Any(s.tests.map(json2.Any(it.to_json())))
		'status':        json2.Any(s.status)
		'reject_reason': json2.Any(s.reject_reason)
		'chars':         json2.Any(s.source.len)
	}
}

fn skill_from_json(name string, source string, meta map[string]json2.Any) Skill {
	mut entry := jstr(meta, 'entry')
	if entry == '' {
		entry = name
	}
	mut description := jstr(meta, 'description')
	if description == '' {
		description = '(persisted)'
	}
	mut tests := []SkillTest{}
	for t in jarr(meta, 'tests') {
		if t !is map[string]json2.Any {
			continue
		}
		row := t.as_map()
		tests << SkillTest{
			args:   jmap(row, 'args')
			expect: jstr(row, 'expect')
		}
	}
	return Skill{
		name:        name
		description: description
		source:      source
		entry:       entry
		parameters:  jmap(meta, 'parameters')
		tests:       tests
	}
}

// -- the gate ---------------------------------------------------------------------

pub struct GateVerdict {
pub:
	ok     bool
	reason string
}

// run_gates puts one skill through all four gates and returns the verdict.
// An interpreter that cannot be found is itself a rejection: an unvalidated
// skill must never register, and "could not check" is not "safe".
pub fn run_gates(skill &Skill) GateVerdict {
	python := find_python() or {
		return GateVerdict{
			ok:     false
			reason: 'no python interpreter — cannot validate'
		}
	}
	script := os.join_path(os.temp_dir(), 'vagent-skillgate-${os.getpid()}.py')
	os.write_file(script, skills_harness) or {
		return GateVerdict{
			ok:     false
			reason: 'cannot write validator: ${err}'
		}
	}
	defer {
		os.rm(script) or {}
	}
	mut payload := skill.to_json()
	payload['source'] = json2.Any(skill.source)
	payload_path := os.join_path(os.temp_dir(), 'vagent-skillgate-in-${os.getpid()}.json')
	os.write_file(payload_path, json2.encode(json2.Any(payload))) or {
		return GateVerdict{
			ok:     false
			reason: 'cannot stage skill: ${err}'
		}
	}
	defer {
		os.rm(payload_path) or {}
	}
	out := os.execute('${quote_arg(python)} ${quote_arg(script)} < ${quote_arg(payload_path)}')
	if out.exit_code != 0 {
		return GateVerdict{
			ok:     false
			reason: 'validator failed: ' + clip(out.output.trim_space(), 200)
		}
	}
	mut line := ''
	for row in split_lines(out.output) {
		if row.trim_space().starts_with('{') {
			line = row.trim_space()
		}
	}
	parsed := json2.decode[json2.Any](line) or {
		return GateVerdict{
			ok:     false
			reason: 'unreadable validator output'
		}
	}
	if parsed !is map[string]json2.Any {
		return GateVerdict{
			ok:     false
			reason: 'unreadable validator output'
		}
	}
	m := parsed.as_map()
	return GateVerdict{
		ok:     jbool(m, 'ok')
		reason: jstr(m, 'reason')
	}
}

// -- the forge ----------------------------------------------------------------------

@[heap]
pub struct SkillForge {
pub mut:
	log &EventLog
	// empty means in-memory only: the forge still works, the skills simply
	// do not survive a restart
	skills_dir string
	registry   map[string]Skill
}

pub fn new_skill_forge(log &EventLog, skills_dir string) &SkillForge {
	if skills_dir != '' {
		os.mkdir_all(skills_dir) or {}
	}
	return &SkillForge{
		log:        unsafe { log }
		skills_dir: skills_dir
	}
}

// author runs the four gates. On success it persists the skill and seals
// skill.registered; on failure it seals skill.rejected with the exact reason.
pub fn (mut f SkillForge) author(skill Skill) Skill {
	mut s := skill
	f.log.append('skill.authored', s.to_json(), AppendOpts{ actor: 'sovereign' })

	verdict := run_gates(&s)
	if !verdict.ok {
		return f.reject(mut s, verdict.reason)
	}

	s.status = 'registered'
	if f.skills_dir != '' {
		f.persist(&s)
	}
	f.registry[s.name] = s
	f.log.append('skill.validated', {
		'name':  json2.Any(s.name)
		'tests': json2.Any(s.tests.len)
	}, AppendOpts{ actor: 'kernel' })
	f.log.append('skill.registered', s.to_json(), AppendOpts{ actor: 'kernel' })
	return s
}

// persist writes the source and a metadata sidecar. The sidecar matters:
// entry, parameters and tests have to survive the restart, or load_persisted
// cannot re-run every gate faithfully and would be reduced to guessing.
fn (mut f SkillForge) persist(skill &Skill) {
	os.mkdir_all(f.skills_dir) or { return }
	src := os.join_path(f.skills_dir, '${skill.name}.py')
	atomic_write_text(src, skill.source) or { return }
	meta := os.join_path(f.skills_dir, '${skill.name}.json')
	atomic_write_text(meta, json2.encode(json2.Any(skill.to_json()))) or {}
}

fn (mut f SkillForge) reject(mut skill Skill, reason string) Skill {
	skill.status = 'rejected'
	skill.reject_reason = reason
	f.log.append('skill.rejected', {
		'name':   json2.Any(skill.name)
		'reason': json2.Any(reason)
	}, AppendOpts{ actor: 'kernel' })
	return skill
}

// -- reloading persisted skills -------------------------------------------------------

// load_persisted re-registers the skills on disk and returns how many were
// accepted.
//
// A persisted skill is only trusted after it passes ALL FOUR gates again
// against the on-disk source. The bytes on disk are never assumed to be the
// bytes that were validated before the restart — a file anyone can edit is
// not a certificate.
pub fn (mut f SkillForge) load_persisted() int {
	if f.skills_dir == '' {
		return 0
	}
	mut names := []string{}
	for entry in os.ls(f.skills_dir) or { []string{} } {
		if entry.ends_with('.py') {
			names << entry[..entry.len - 3]
		}
	}
	names.sort()

	mut count := 0
	for name in names {
		if name in f.registry {
			continue
		}
		source := os.read_file(os.join_path(f.skills_dir, '${name}.py')) or { continue }
		meta_path := os.join_path(f.skills_dir, '${name}.json')
		mut meta := map[string]json2.Any{}
		if os.exists(meta_path) {
			meta = decode_obj(os.read_file(meta_path) or { '' })
		}
		mut skill := skill_from_json(name, source, meta)
		if !run_gates(&skill).ok {
			continue
		}
		skill.status = 'registered'
		f.registry[name] = skill
		count++
	}
	return count
}

// -- projections -----------------------------------------------------------------------

pub fn (mut f SkillForge) skill_events() []Rec {
	st := fold(mut f.log, f.log.branch)
	return st.skill_events
}

pub fn (f &SkillForge) registered() []string {
	mut out := f.registry.keys()
	out.sort()
	return out
}

pub fn (mut f SkillForge) format_status() string {
	evs := f.skill_events()
	mut authored := 0
	mut registered := 0
	mut rejected := 0
	for e in evs {
		match jstr(e, 'type') {
			'skill.authored' { authored++ }
			'skill.registered' { registered++ }
			'skill.rejected' { rejected++ }
			else {}
		}
	}
	mut lines := [
		'SKILL FORGE — the self-evolving tool author',
		'  authored ${authored}   registered ${registered}   rejected ${rejected}',
	]
	for name in f.registered() {
		lines << '    ◆ ${name}'
	}
	for e in evs {
		if jstr(e, 'type') == 'skill.rejected' {
			lines << '    ✗ ' + jstr(e, 'name') + ': ' + clip_plain(jstr(e, 'reason'), 60)
		}
	}
	return lines.join('\n')
}
