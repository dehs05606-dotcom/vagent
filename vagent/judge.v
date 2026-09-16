module vagent

import os
import x.json2

// judge.v — deterministic verification subsystem.
//
// A node cannot enter PASSED on the model's own testimony. Every claim is
// checked against reality with deterministic predicates — real exit codes,
// real file checks, real regex matches — and each result is sealed into the
// event log as a 'judge.verdict' event. No LLM judging here: verification is
// 100% deterministic.
//
// Predicates understood by Judge.check():
//     {"type": "exit_code", "command": "pytest -q", "expect": 0, "timeout": 120}
//     {"type": "file_exists", "path": "src/x.py"}
//     {"type": "file_contains", "path": "src/x.py", "text": "def foo"}
//     {"type": "file_matches", "path": "src/x.py", "pattern": "def \\w+\\("}
//     {"type": "command_output_contains", "command": "python -V", "text": "Python"}
//     {"type": "ast_assert", "path": "src/x.py", "symbol": "verify_token",
//      "has_parameter": "leeway", "kind": "def"}
//     {"type": "diff_assert", "path": "src/x.py", "forbid": ["print\\(", "TODO"]}
//     {"type": "file_unchanged", "path": "uv.lock", "baseline_hash": "…"}
//     {"type": "tool_delta", "command": "mypy src", "delta": 0}

// evidence_limit is the max chars of evidence kept per verdict.
pub const evidence_limit = 300

// Verdict is the sealed outcome of one deterministic predicate check.
pub struct Verdict {
pub:
	passed bool
	kind   string // predicate type that was checked
	detail string // human-readable one-line result
	// minimal excerpt proving pass/fail
	evidence string
}

pub fn (v &Verdict) to_json() map[string]json2.Any {
	return {
		'passed':   json2.Any(v.passed)
		'kind':     json2.Any(v.kind)
		'detail':   json2.Any(v.detail)
		'evidence': json2.Any(v.evidence)
	}
}

// ---------------------------------------------------------------------------
// Internal helpers
// ---------------------------------------------------------------------------

// clip_evidence trims evidence down to a bounded excerpt.
fn clip_evidence(text string) string {
	t := text.trim_space()
	if t.len <= evidence_limit {
		return t
	}
	return t[..evidence_limit - 1].trim_right(' \t\n') + '…'
}

// line_around returns the line of text containing the byte at idx.
fn line_around(text string, idx int) string {
	mut start := 0
	if i := text[..idx].last_index('\n') {
		start = i + 1
	}
	mut end := text.len
	if j := text[idx..].index('\n') {
		end = idx + j
	}
	return text[start..end].trim_space()
}

// line_number is the 1-based line containing the byte at idx.
fn line_number(text string, idx int) int {
	return text[..idx].count('\n') + 1
}

fn as_timeout(v json2.Any) int {
	t := match v {
		i64 { int(v) }
		int { v }
		f64 { int(v) }
		string { v.int() }
		else { 0 }
	}
	return if t > 0 { t } else { 120 }
}

// run_predicate_shell runs a predicate command in the resolved shell and
// returns (exit code, combined output, ok). ok=false means no shell exists.
fn run_predicate_shell(command string, timeout int) (int, string, bool) {
	argv := resolve_shell()
	if argv.len == 0 {
		return 0, '', false
	}
	mut p := spawn_shell(command, os.getwd(), map[string]string{}) or {
		return 0, err.msg(), false
	}
	res := pump_process(mut p, f64(timeout), no_sink)
	if res.timed_out {
		return -1, 'timed out after ${timeout}s', true
	}
	return res.exit_code, res.stdout + res.stderr, true
}

// ---------------------------------------------------------------------------
// Deterministic checkers
// ---------------------------------------------------------------------------

// check_exit_code runs a command via bash and compares its exit code
// against `expect`.
pub fn check_exit_code(command string, expect int, timeout int) Verdict {
	rc, output, ok := run_predicate_shell(command, timeout)
	if !ok {
		return Verdict{
			passed: false
			kind:   'exit_code'
			detail: 'no POSIX shell available — install Git Bash (windows) or bash (posix)'
		}
	}
	if rc == -1 && output.starts_with('timed out') {
		return Verdict{
			passed: false
			kind:   'exit_code'
			detail: 'timed out after ${timeout}s: ${command}'
		}
	}
	return Verdict{
		passed:   rc == expect
		kind:     'exit_code'
		detail:   "'${command}' exited ${rc}, expected ${expect}"
		evidence: clip_evidence(output)
	}
}

// check_file_exists passes iff path exists on disk.
pub fn check_file_exists(path string) Verdict {
	p := resolve_path(path)
	if os.exists(p) {
		kind := if os.is_dir(p) { 'directory' } else { 'file' }
		return Verdict{
			passed:   true
			kind:     'file_exists'
			detail:   '${kind} exists: ${p}'
			evidence: p
		}
	}
	return Verdict{
		passed:   false
		kind:     'file_exists'
		detail:   'not found: ${p}'
		evidence: p
	}
}

// check_file_contains passes iff literal text appears in the file at path.
pub fn check_file_contains(path string, text string) Verdict {
	p := resolve_path(path)
	if !os.is_file(p) {
		return Verdict{
			passed: false
			kind:   'file_contains'
			detail: 'file not found: ${p}'
		}
	}
	content := os.read_file(p) or {
		return Verdict{
			passed: false
			kind:   'file_contains'
			detail: 'cannot read ${p}: ${err.msg()}'
		}
	}
	idx := content.index(text) or {
		return Verdict{
			passed: false
			kind:   'file_contains'
			detail: "'${text}' not found in ${p}"
		}
	}
	return Verdict{
		passed:   true
		kind:     'file_contains'
		detail:   "'${text}' found at ${p}:${line_number(content, idx)}"
		evidence: clip_evidence(line_around(content, idx))
	}
}

// check_file_matches passes iff a regex matches anywhere in the file
// (MULTILINE, so ^ and $ match line boundaries).
pub fn check_file_matches(path string, pattern string) Verdict {
	re := compile_regex_flags(pattern, RxFlags{ multiline: true }) or {
		return Verdict{
			passed: false
			kind:   'file_matches'
			detail: "invalid pattern '${pattern}': ${err.msg()}"
		}
	}
	p := resolve_path(path)
	if !os.is_file(p) {
		return Verdict{
			passed: false
			kind:   'file_matches'
			detail: 'file not found: ${p}'
		}
	}
	content := os.read_file(p) or {
		return Verdict{
			passed: false
			kind:   'file_matches'
			detail: 'cannot read ${p}: ${err.msg()}'
		}
	}
	m := re.search(content) or {
		return Verdict{
			passed: false
			kind:   'file_matches'
			detail: "pattern '${pattern}' not found in ${p}"
		}
	}
	// Match offsets are rune indices; the evidence helpers work in bytes.
	byte_idx := content.runes()[..m.start].string().len
	return Verdict{
		passed:   true
		kind:     'file_matches'
		detail:   'pattern matched at ${p}:${line_number(content, byte_idx)}'
		evidence: clip_evidence(line_around(content, byte_idx))
	}
}

// check_command_output_contains runs a command via bash and passes iff text
// appears in its combined stdout+stderr output.
pub fn check_command_output_contains(command string, text string, timeout int) Verdict {
	rc, output, ok := run_predicate_shell(command, timeout)
	if !ok {
		return Verdict{
			passed: false
			kind:   'command_output_contains'
			detail: 'no POSIX shell available'
		}
	}
	if rc == -1 && output.starts_with('timed out') {
		return Verdict{
			passed: false
			kind:   'command_output_contains'
			detail: 'timed out after ${timeout}s: ${command}'
		}
	}
	idx := output.index(text) or {
		return Verdict{
			passed:   false
			kind:     'command_output_contains'
			detail:   "'${text}' not in output of '${command}' (exit ${rc})"
			evidence: clip_evidence(output)
		}
	}
	return Verdict{
		passed:   true
		kind:     'command_output_contains'
		detail:   "'${text}' found in output of '${command}'"
		evidence: clip_evidence(line_around(output, idx))
	}
}

// PyDef is one `def`/`class` found by the lexical scanner below.
struct PyDef {
	name   string
	kind   string
	line   int
	params []string
}

// scan_python_defs finds top-level and nested `def`/`class` declarations.
//
// The Python original used the real `ast` module. V has no Python parser,
// so this is a lexical scan: it recognises a `def name(params)` or
// `class Name` header, joins a parameter list that spans lines, and strips
// defaults, annotations and the `*`/`**` markers to recover parameter
// names. That covers every predicate shape this project actually writes —
// what it does NOT do is understand code that only a parser could resolve
// (a def produced by a decorator, or one inside a string), so it reports
// what the source text says rather than what the interpreter would build.
fn scan_python_defs(source string) []PyDef {
	mut out := []PyDef{}
	lines := split_lines(source)
	for i, raw in lines {
		line := raw.trim_space()
		mut kind := ''
		mut rest := ''
		if line.starts_with('def ') {
			kind = 'def'
			rest = line[4..]
		} else if line.starts_with('async def ') {
			kind = 'def'
			rest = line[10..]
		} else if line.starts_with('class ') {
			kind = 'class'
			rest = line[6..]
		} else {
			continue
		}
		mut name := ''
		for ch in rest {
			if ch.is_letter() || ch.is_digit() || ch == `_` {
				name += ch.ascii_str()
				continue
			}
			break
		}
		if name == '' {
			continue
		}
		mut params := []string{}
		if kind == 'def' {
			// the parameter list can span lines; collect until brackets balance
			mut buf := ''
			mut depth := 0
			mut started := false
			for j := i; j < lines.len; j++ {
				for ch in lines[j] {
					if ch == `(` {
						depth++
						started = true
						if depth == 1 {
							continue
						}
					} else if ch == `)` {
						depth--
						if depth == 0 {
							break
						}
					}
					if started && depth >= 1 {
						buf += ch.ascii_str()
					}
				}
				if started && depth == 0 {
					break
				}
			}
			params = parse_param_names(buf)
		}
		out << PyDef{
			name:   name
			kind:   kind
			line:   i + 1
			params: params
		}
	}
	return out
}

// parse_param_names splits a parameter list on top-level commas and strips
// defaults, annotations and `*`/`**`.
fn parse_param_names(buf string) []string {
	mut parts := []string{}
	mut depth := 0
	mut cur := ''
	for ch in buf {
		match ch {
			`(`, `[`, `{` { depth++ }
			`)`, `]`, `}` { depth-- }
			else {}
		}
		if ch == `,` && depth == 0 {
			parts << cur
			cur = ''
			continue
		}
		cur += ch.ascii_str()
	}
	if cur.trim_space() != '' {
		parts << cur
	}
	mut names := []string{}
	for part in parts {
		mut p := part.trim_space()
		p = p.all_before('=').all_before(':').trim_space()
		p = p.trim_left('*').trim_space()
		// a bare `*` or `/` is a marker, not a parameter
		if p == '' || p == '/' {
			continue
		}
		names << p
	}
	return names
}

// check_ast_assert passes iff the source of `path` defines `symbol`
// (def/class) — optionally with a parameter named has_parameter.
pub fn check_ast_assert(path string, symbol string, kind string, has_parameter string) Verdict {
	p := resolve_path(path)
	if !os.is_file(p) {
		return Verdict{
			passed: false
			kind:   'ast_assert'
			detail: 'file not found: ${p}'
		}
	}
	source := os.read_file(p) or {
		return Verdict{
			passed: false
			kind:   'ast_assert'
			detail: 'cannot read ${p}: ${err.msg()}'
		}
	}
	want_kind := if kind == 'class' { 'class' } else { 'def' }
	mut found := PyDef{}
	mut ok := false
	for d in scan_python_defs(source) {
		if d.kind == want_kind && d.name == symbol {
			found = d
			ok = true
			break
		}
	}
	if !ok {
		return Verdict{
			passed: false
			kind:   'ast_assert'
			detail: "${want_kind} '${symbol}' not found in ${p}"
		}
	}
	if has_parameter != '' {
		if want_kind == 'class' {
			return Verdict{
				passed: false
				kind:   'ast_assert'
				detail: "has_parameter is not supported for kind='class' " + "('${symbol}' is a class)"
			}
		}
		if has_parameter !in found.params {
			return Verdict{
				passed:   false
				kind:     'ast_assert'
				detail:   "${symbol}() has no parameter '${has_parameter}' " + '(has: ${found.params.join(', ')})'
				evidence: 'line ${found.line}'
			}
		}
	}
	suffix := if has_parameter != '' { " with parameter '${has_parameter}'" } else { '' }
	return Verdict{
		passed:   true
		kind:     'ast_assert'
		detail:   "${want_kind} '${symbol}' found at ${p}:${found.line}${suffix}"
		evidence: 'line ${found.line}'
	}
}

// check_diff_assert passes iff the file contains NONE of the forbid
// patterns and ALL of the require patterns (each a regex). Used for
// anti-clauses like 'no print( or TODO introduced'.
pub fn check_diff_assert(path string, forbid []string, require []string) Verdict {
	p := resolve_path(path)
	if !os.is_file(p) {
		return Verdict{
			passed: false
			kind:   'diff_assert'
			detail: 'file not found: ${p}'
		}
	}
	content := os.read_file(p) or {
		return Verdict{
			passed: false
			kind:   'diff_assert'
			detail: 'cannot read ${p}: ${err.msg()}'
		}
	}
	for pat in forbid {
		re := compile_regex_flags(pat, RxFlags{ multiline: true }) or {
			return Verdict{
				passed: false
				kind:   'diff_assert'
				detail: "invalid forbid pattern '${pat}': ${err.msg()}"
			}
		}
		if m := re.search(content) {
			byte_idx := content.runes()[..m.start].string().len
			return Verdict{
				passed:   false
				kind:     'diff_assert'
				detail:   "forbidden pattern '${pat}' found at ${p}:${line_number(content, byte_idx)}"
				evidence: clip_evidence(line_around(content, byte_idx))
			}
		}
	}
	for pat in require {
		re := compile_regex_flags(pat, RxFlags{ multiline: true }) or {
			return Verdict{
				passed: false
				kind:   'diff_assert'
				detail: "invalid require pattern '${pat}': ${err.msg()}"
			}
		}
		if !re.matches(content) {
			return Verdict{
				passed: false
				kind:   'diff_assert'
				detail: "required pattern '${pat}' absent from ${p}"
			}
		}
	}
	return Verdict{
		passed: true
		kind:   'diff_assert'
		detail: '${p}: no forbidden patterns, all required present'
	}
}

// check_file_unchanged passes iff the file's sha256 still equals
// baseline_hash — the anti-clause 'no new dependency' check against a
// lockfile.
pub fn check_file_unchanged(path string, baseline_hash string) Verdict {
	p := resolve_path(path)
	if !os.is_file(p) {
		return Verdict{
			passed: false
			kind:   'file_unchanged'
			detail: 'file not found: ${p}'
		}
	}
	content := os.read_file(p) or {
		return Verdict{
			passed: false
			kind:   'file_unchanged'
			detail: 'cannot read ${p}: ${err.msg()}'
		}
	}
	actual := hash(content)
	if actual != baseline_hash {
		want := if baseline_hash.len >= 12 { baseline_hash[..12] } else { baseline_hash }
		return Verdict{
			passed: false
			kind:   'file_unchanged'
			detail: '${p} changed: ${actual[..12]} != ${want}'
		}
	}
	return Verdict{
		passed: true
		kind:   'file_unchanged'
		detail: '${p} unchanged (${actual[..12]})'
	}
}

// check_tool_delta runs a checker (mypy, ruff, …) and passes iff its
// error-line count is <= delta. 'No NEW type errors' = delta 0 against a
// clean baseline.
pub fn check_tool_delta(command string, delta int, timeout int) Verdict {
	rc, output, ok := run_predicate_shell(command, timeout)
	if !ok {
		return Verdict{
			passed: false
			kind:   'tool_delta'
			detail: 'no POSIX shell available'
		}
	}
	if rc == -1 && output.starts_with('timed out') {
		return Verdict{
			passed: false
			kind:   'tool_delta'
			detail: 'timed out after ${timeout}s: ${command}'
		}
	}
	// count error-ish lines: "file:line: error" or "file:line:col: E501"
	re := compile_regex(r':\d+(:\d+)?:\s*(error|E\d{3}|F\d{3})') or {
		return Verdict{
			passed: false
			kind:   'tool_delta'
			detail: 'internal: error pattern failed to compile'
		}
	}
	mut errors := []string{}
	for ln in split_lines(output) {
		if re.matches(ln) {
			errors << ln
		}
	}
	allowed := if delta > 0 { delta } else { 0 }
	if errors.len > allowed {
		head := if errors.len > 5 { errors[..5] } else { errors }
		return Verdict{
			passed:   false
			kind:     'tool_delta'
			detail:   "'${command}' reports ${errors.len} errors (allowed ${allowed})"
			evidence: clip_evidence(head.join('\n'))
		}
	}
	return Verdict{
		passed: true
		kind:   'tool_delta'
		detail: "'${command}' reports ${errors.len} errors (allowed ${allowed})"
	}
}

// ---------------------------------------------------------------------------
// Judge — dispatch, emit, query
// ---------------------------------------------------------------------------

// Judge is deterministic verification over the event log.
//
// Every predicate is checked against reality and the verdict is sealed as a
// 'judge.verdict' event; state is recovered by folding the log.
// The judge is a heap type, and new_judge hands back a reference.
//
// It holds nothing but a log pointer, so it is tempting to pass it around by
// value — but several subsystems STORE a `&Judge` (the goal contract, the
// workflow engine). A value returned onto a caller's stack and then pointed
// at from a longer-lived struct is a dangling pointer the moment that caller
// returns, and the failure is not a crash: it is a hang, in whatever runs
// next. Making the type heap-allocated removes the footgun rather than
// documenting it.
@[heap]
pub struct Judge {
pub mut:
	log &EventLog
}

pub fn new_judge(log &EventLog) &Judge {
	return &Judge{
		log: unsafe { log }
	}
}

// check dispatches a predicate to the right deterministic checker, runs it,
// seals a 'judge.verdict' event, and returns the verdict. It never raises.
pub fn (mut j Judge) check(predicate map[string]json2.Any) Verdict {
	verdict := j.evaluate(predicate)
	j.log.append('judge.verdict', verdict.to_json(), AppendOpts{})
	return verdict
}

// check_all runs every predicate and returns (all_passed, verdicts).
pub fn (mut j Judge) check_all(predicates []map[string]json2.Any) (bool, []Verdict) {
	mut verdicts := []Verdict{}
	mut all := true
	for p in predicates {
		v := j.check(p)
		if !v.passed {
			all = false
		}
		verdicts << v
	}
	return all, verdicts
}

// recent_verdicts lists the last n verdicts from the fold, newest first.
pub fn (mut j Judge) recent_verdicts(n int) []Rec {
	if n <= 0 {
		return []
	}
	verdicts := fold(mut j.log, '').verdicts
	start := if verdicts.len > n { verdicts.len - n } else { 0 }
	mut out := verdicts[start..].clone()
	out.reverse_in_place()
	return out
}

// failure turns a failed verdict into a STRUCTURED failure — never a raw
// traceback dumped into the prompt. This is the difference between an agent
// that debugs and an agent that flails (§19.2).
pub fn (j &Judge) failure(verdict Verdict, context string) map[string]json2.Any {
	mut location := ''
	if re := compile_regex(r'([^\s:]+):(\d+)') {
		if m := re.search(verdict.detail) {
			location = '${group_text(verdict.detail, &m, 1)}:${group_text(verdict.detail, &m, 2)}'
		}
	}
	ev := if verdict.evidence.len > evidence_limit {
		verdict.evidence[..evidence_limit]
	} else {
		verdict.evidence
	}
	return {
		'kind':           json2.Any(if verdict.kind != 'exit_code' {
			'ASSERTION'
		} else {
			'EXCEPTION'
		})
		'predicate':      json2.Any(verdict.kind)
		'evidence':       json2.Any(ev)
		'location':       json2.Any(location)
		'detail':         json2.Any(verdict.detail)
		'context':        json2.Any(context)
		'suggested_next': json2.Any('inspect the evidence, then change the ' + 'approach — do not retry the identical action')
	}
}

// check_with_retry re-runs a failing test before believing it. If it passes
// on any retry it is a FLAKE: recorded as a project fact and excluded from
// pass criteria with a visible warning. Agents that treat flakes as real
// bugs waste enormous money chasing ghosts (§19.3).
pub fn (mut j Judge) check_with_retry(predicate map[string]json2.Any, runs int) Verdict {
	first := j.check(predicate)
	if first.passed {
		return first
	}
	extra := if runs - 1 > 0 { runs - 1 } else { 0 }
	for _ in 0 .. extra {
		retry := j.check(predicate)
		if retry.passed {
			mut subject := jstr(predicate, 'command')
			if subject == '' {
				subject = jstr(predicate, 'path')
			}
			j.log.append('fact.learned', {
				'fact': json2.Any('FLAKE: ${jstr(predicate, 'type')} ${subject} ' + 'fails intermittently')
				'kind': json2.Any('flake')
			}, AppendOpts{ actor: 'judge' })
			return Verdict{
				passed:   true
				kind:     'flake'
				detail:   'FLAKE detected (failed then passed): ${first.detail}'
				evidence: first.evidence
			}
		}
	}
	return first
}

// evaluate routes one predicate to its checker. It never raises.
fn (j &Judge) evaluate(predicate map[string]json2.Any) Verdict {
	ptype := jstr(predicate, 'type')
	if ptype == '' {
		return Verdict{
			passed: false
			kind:   'invalid'
			detail: "predicate missing 'type'"
		}
	}
	match ptype {
		'exit_code' {
			command := jstr(predicate, 'command')
			if command.trim_space() == '' {
				return missing(ptype, 'command')
			}
			return check_exit_code(command, jint(predicate, 'expect'), as_timeout(jget(predicate, 'timeout')))
		}
		'file_exists' {
			path := jstr(predicate, 'path')
			if path == '' {
				return missing(ptype, 'path')
			}
			return check_file_exists(path)
		}
		'file_contains' {
			path := jstr(predicate, 'path')
			if path == '' {
				return missing(ptype, 'path')
			}
			if 'text' !in predicate {
				return missing(ptype, 'text')
			}
			text := jstr(predicate, 'text')
			// an empty search string vacuously matches at position 0 of ANY
			// content, so a clause with an empty `text` would prove itself
			if text == '' {
				return Verdict{
					passed: false
					kind:   ptype
					detail: "predicate 'text' is empty — it would match any file"
				}
			}
			return check_file_contains(path, text)
		}
		'file_matches' {
			path := jstr(predicate, 'path')
			if path == '' {
				return missing(ptype, 'path')
			}
			pattern := jstr(predicate, 'pattern')
			if pattern == '' {
				return missing(ptype, 'pattern')
			}
			return check_file_matches(path, pattern)
		}
		'command_output_contains' {
			command := jstr(predicate, 'command')
			if command.trim_space() == '' {
				return missing(ptype, 'command')
			}
			if 'text' !in predicate {
				return missing(ptype, 'text')
			}
			text := jstr(predicate, 'text')
			if text == '' {
				return Verdict{
					passed: false
					kind:   ptype
					detail: "predicate 'text' is empty — it would match any output"
				}
			}
			return check_command_output_contains(command, text, as_timeout(jget(predicate, 'timeout')))
		}
		'ast_assert' {
			path := jstr(predicate, 'path')
			if path == '' {
				return missing(ptype, 'path')
			}
			symbol := jstr(predicate, 'symbol')
			if symbol == '' {
				return missing(ptype, 'symbol')
			}
			kind := if k := predicate['kind'] { k.str() } else { 'def' }
			return check_ast_assert(path, symbol, kind, jstr(predicate, 'has_parameter'))
		}
		'diff_assert' {
			path := jstr(predicate, 'path')
			if path == '' {
				return missing(ptype, 'path')
			}
			return check_diff_assert(path, jstrs(predicate, 'forbid'), jstrs(predicate, 'require'))
		}
		'file_unchanged' {
			path := jstr(predicate, 'path')
			if path == '' {
				return missing(ptype, 'path')
			}
			baseline := jstr(predicate, 'baseline_hash')
			if baseline == '' {
				return missing(ptype, 'baseline_hash')
			}
			return check_file_unchanged(path, baseline)
		}
		'tool_delta' {
			command := jstr(predicate, 'command')
			if command.trim_space() == '' {
				return missing(ptype, 'command')
			}
			return check_tool_delta(command, jint(predicate, 'delta'), as_timeout(jget(predicate, 'timeout')))
		}
		else {
			return Verdict{
				passed: false
				kind:   ptype
				detail: "unknown predicate type '${ptype}'"
			}
		}
	}
}

fn missing(ptype string, field string) Verdict {
	return Verdict{
		passed: false
		kind:   ptype
		detail: "predicate missing '${field}'"
	}
}
