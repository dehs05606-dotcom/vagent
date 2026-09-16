module vagent

import os

// nexus.v — the code property graph (§15).
//
// What separates "an LLM with grep" from something that understands a
// codebase. This is the rung-2 source layer: symbols, call graph, import
// graph, and the killer query — impact analysis (§15.2). LSP integration
// degrades gracefully to this layer when no language server is present
// (§46 risk register).
//
// Everything is deterministic and free:
//   * index(root) scans every source file, keyed by content hash —
//     unchanged files are never re-scanned (§15.5).
//   * impact(symbol) answers "if I change this signature, what breaks?"
//     with a graph traversal: direct callers, transitive callers, test
//     coverage heuristics, public-API exposure, and a risk score.
//
// The Python original walked a real `ast`. V has no Python parser, so the
// extractor here is the same lexical scanner judge.v uses for ast_assert,
// plus a call-site and import scan. It reads what the source text says
// rather than what an interpreter would build, which is enough for every
// query below and is why the risk score is explicitly a heuristic.

pub struct Symbol {
pub:
	name      string
	kind      string // def | class | method
	path      string
	lineno    int
	params    []string
	docstring string
}

pub fn (s &Symbol) key() string {
	return '${s.path}:${s.name}'
}

// GraphIndex is the parsed view of a repo: symbols + edges.
pub struct GraphIndex {
pub mut:
	symbols map[string]Symbol // key -> Symbol
	// caller path -> callee names
	calls map[string][]string
	// path -> imported module names
	imports map[string][]string
	// path -> content hash
	file_hashes map[string]string
	// path -> parse error
	errors map[string]string
}

// Nexus is the source code graph with incremental maintenance.
@[heap]
pub struct Nexus {
pub mut:
	idx GraphIndex
}

pub fn new_nexus() &Nexus {
	return &Nexus{}
}

// -- indexing ----------------------------------------------------------------

// index scans every source file under root. Content-hash keyed: a second
// call on an unchanged repo re-scans nothing (§15.5).
pub fn (mut n Nexus) index(root string, max_files int) GraphIndex {
	base := resolve_path(root)
	mut count := 0
	for p in walk_files(base, max_files * 4) {
		if !p.ends_with('.py') {
			continue
		}
		if count >= max_files {
			break
		}
		n.index_file(p)
		count++
	}
	return n.idx
}

// index_file (re)scans one file. Returns true if it was re-scanned.
pub fn (mut n Nexus) index_file(path string) bool {
	p := resolve_path(path)
	text := os.read_file(p) or {
		n.idx.errors[p] = err.msg()
		return false
	}
	h := hash(text)[..16]
	if (n.idx.file_hashes[p] or { '' }) == h {
		return false // unchanged — never re-scanned
	}
	n.drop_file(p)
	n.idx.file_hashes[p] = h
	n.extract(p, text)
	return true
}

fn (mut n Nexus) drop_file(path string) {
	for key in n.idx.symbols.keys() {
		if key.starts_with(path + ':') {
			n.idx.symbols.delete(key)
		}
	}
	n.idx.calls.delete(path)
	n.idx.imports.delete(path)
	n.idx.errors.delete(path)
}

fn (mut n Nexus) extract(path string, text string) {
	mut calls := []string{}
	mut imports := []string{}

	for d in scan_python_defs(text) {
		// a def indented under something else is a method
		kind := if d.kind == 'class' {
			'class'
		} else if def_is_indented(text, d.line) {
			'method'
		} else {
			'def'
		}
		sym := Symbol{
			name:      d.name
			kind:      kind
			path:      path
			lineno:    d.line
			params:    d.params
			docstring: extract_docstring(text, d.line)
		}
		n.idx.symbols[sym.key()] = sym
	}

	for raw in split_lines(text) {
		line := raw.trim_space()
		if line.starts_with('import ') {
			rest := line[7..].all_before(' as ')
			for part in rest.split(',') {
				m := part.trim_space().all_before('.')
				if m != '' {
					imports << m
				}
			}
			continue
		}
		if line.starts_with('from ') {
			// a relative import (`from .auth import login`) names module
			// `auth`, so the leading dots come off before the split
			m := line[5..].all_before(' ').trim_left('.').all_before('.').trim_space()
			if m != '' && m != 'import' {
				imports << m
			}
			continue
		}
		calls << scan_call_names(raw)
	}

	n.idx.calls[path] = calls
	n.idx.imports[path] = dedup_strings(imports)
}

// def_is_indented reports whether the header at `lineno` (1-based) starts
// in a column other than 0, which is how a method is told from a function.
fn def_is_indented(text string, lineno int) bool {
	lines := split_lines(text)
	if lineno < 1 || lineno > lines.len {
		return false
	}
	raw := lines[lineno - 1]
	return raw.len > 0 && (raw[0] == ` ` || raw[0] == `\t`)
}

// extract_docstring returns the first quoted block directly beneath a
// def/class header, clipped to 200 chars.
fn extract_docstring(text string, lineno int) string {
	lines := split_lines(text)
	// skip forward past a signature that wraps across lines
	mut i := lineno // 0-based index of the line AFTER the header
	for i < lines.len {
		body := lines[i].trim_space()
		if body == '' {
			i++
			continue
		}
		for q in ['"""', "'''"] {
			if body.starts_with(q) {
				rest := body[3..]
				if e := rest.index(q) {
					return clip_plain(rest[..e].trim_space(), 200)
				}
				mut parts := [rest]
				for j := i + 1; j < lines.len; j++ {
					if e := lines[j].index(q) {
						parts << lines[j][..e]
						return clip_plain(parts.join('\n').trim_space(), 200)
					}
					parts << lines[j]
				}
			}
		}
		return ''
	}
	return ''
}

// scan_call_names finds `name(` call sites, skipping the keywords that are
// not calls and the `def`/`class` headers that are definitions.
fn scan_call_names(raw string) []string {
	line := raw.trim_space()
	if line.starts_with('def ') || line.starts_with('async def ')
		|| line.starts_with('class ') || line.starts_with('#') {
		return []
	}
	mut out := []string{}
	mut i := 0
	for i < line.len {
		if line[i] != `(` {
			i++
			continue
		}
		// walk back over the identifier (and any dotted prefix) before `(`
		mut j := i - 1
		for j >= 0 && (is_word_byte(line[j]) || line[j] == `.`) {
			j--
		}
		ident := line[j + 1..i]
		i++
		if ident == '' {
			continue
		}
		// an attribute call records the attribute, matching ast.Attribute
		name := if k := ident.last_index('.') { ident[k + 1..] } else { ident }
		if name == '' || name in python_keywords {
			continue
		}
		out << name
	}
	return out
}

const python_keywords = ['if', 'elif', 'while', 'for', 'return', 'yield',
	'assert', 'with', 'except', 'print_function', 'and', 'or', 'not', 'in',
	'is', 'lambda', 'else', 'try', 'raise', 'del', 'pass', 'import', 'from']

fn dedup_strings(items []string) []string {
	mut seen := map[string]bool{}
	mut out := []string{}
	for s in items {
		if s !in seen {
			seen[s] = true
			out << s
		}
	}
	return out
}

// -- queries -------------------------------------------------------------------

// find_symbol lists all definitions named `name` — the "which of six
// process() definitions" answer.
pub fn (n &Nexus) find_symbol(name string) []Symbol {
	mut out := []Symbol{}
	for _, s in n.idx.symbols {
		if s.name == name {
			out << s
		}
	}
	out.sort_with_compare(fn (a &Symbol, b &Symbol) int {
		return compare_strings(a.key(), b.key())
	})
	return out
}

pub struct CallSite {
pub:
	path  string
	count int
}

// callers lists the direct call sites of `name`.
pub fn (n &Nexus) callers(name string) []CallSite {
	mut out := []CallSite{}
	for path, names in n.idx.calls {
		mut count := 0
		for x in names {
			if x == name {
				count++
			}
		}
		if count > 0 {
			out << CallSite{
				path:  path
				count: count
			}
		}
	}
	out.sort_with_compare(fn (a &CallSite, b &CallSite) int {
		return compare_strings(a.path, b.path)
	})
	return out
}

// transitive_callers lists the files that call `name` directly or
// transitively (via symbols defined in the calling files).
pub fn (n &Nexus) transitive_callers(name string, max_depth int) []string {
	mut seen := map[string]bool{}
	mut frontier := []string{}
	for c in n.callers(name) {
		seen[c.path] = true
		frontier << c.path
	}
	for _ in 0 .. max_depth - 1 {
		mut next := []string{}
		for path in frontier {
			// symbols defined in this file that call into the frontier
			for _, sym in n.idx.symbols {
				if sym.path != path {
					continue
				}
				for c in n.callers(sym.name) {
					if c.path !in seen {
						seen[c.path] = true
						next << c.path
					}
				}
			}
		}
		if next.len == 0 {
			break
		}
		frontier = next.clone()
	}
	mut out := seen.keys()
	out.sort()
	return out
}

pub struct ImpactReport {
pub:
	symbol           string
	definitions      []Symbol
	direct_callers   int
	direct_files     []string
	transitive_files []string
	tests_covering   []string
	public_api       bool
	coverage_ratio   f64
	risk             string
}

// impact is the killer query (§15.2): the blast radius of changing `name`.
// A deterministic graph traversal — the planner knows the blast radius
// BEFORE it writes a line.
pub fn (n &Nexus) impact(name string) ImpactReport {
	defs := n.find_symbol(name)
	direct := n.callers(name)
	transitive := n.transitive_callers(name, 3)

	mut tests := []string{}
	for p in transitive {
		base := os.base(p).to_lower()
		if base.contains('test') || p.contains('/tests/') || p.contains('\\tests\\') {
			tests << p
		}
	}
	mut public := false
	for s in defs {
		if n.is_exported(s) {
			public = true
			break
		}
	}
	mut n_direct := 0
	for c in direct {
		n_direct += c.count
	}
	denom := if transitive.len > 0 { transitive.len } else { 1 }
	coverage := f64(tests.len) / f64(denom)
	return ImpactReport{
		symbol:           name
		definitions:      defs
		direct_callers:   n_direct
		direct_files:     direct.map(it.path)
		transitive_files: transitive
		tests_covering:   tests
		public_api:       public
		coverage_ratio:   round2(coverage)
		risk:             risk_score(public, transitive.len, coverage, defs.len)
	}
}

fn round2(v f64) f64 {
	return f64(int(v * 100.0 + 0.5)) / 100.0
}

// is_exported is a heuristic: exported via an __init__.py in the same
// package.
fn (n &Nexus) is_exported(sym Symbol) bool {
	pkg_init := os.join_path(os.dir(sym.path), '__init__.py')
	if !os.exists(pkg_init) {
		return false
	}
	text := os.read_file(pkg_init) or { return false }
	return text.contains(sym.name)
}

fn risk_score(public bool, n_transitive int, coverage f64, n_defs int) string {
	mut score := 0
	if public {
		score += 2
	}
	if n_transitive >= 10 {
		score += 2
	} else if n_transitive >= 3 {
		score++
	}
	if coverage < 0.3 {
		score += 2
	} else if coverage < 0.6 {
		score++
	}
	if n_defs > 1 {
		score++ // ambiguous: multiple same-named definitions
	}
	return match score {
		0, 1 { 'LOW' }
		2, 3 { 'MEDIUM' }
		else { 'HIGH' }
	}
}

// format_impact is the human-readable impact report for the TUI.
pub fn (n &Nexus) format_impact(name string) string {
	imp := n.impact(name)
	mut lines := ['impact(${name}) — risk ${imp.risk}',
		'  definitions     : ${imp.definitions.len}']
	for d in imp.definitions {
		lines << '    ${d.path}:${d.lineno} (${d.kind})'
	}
	lines << '  direct callers  : ${imp.direct_callers} sites across ' +
		'${imp.direct_files.len} files'
	lines << '  transitive      : ${imp.transitive_files.len} files'
	lines << '  tests covering  : ${imp.tests_covering.len}'
	lines << '  public API      : ${if imp.public_api { "yes" } else { "no" }}'
	lines << '  coverage ratio  : ${imp.coverage_ratio}'
	return lines.join('\n')
}
