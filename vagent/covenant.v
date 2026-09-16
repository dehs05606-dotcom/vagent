module vagent

import os
import x.json2

// covenant.v — the specification as an enforced boundary, not as advice.
//
// A system prompt cannot make a model comply. Text is probabilistic: every
// "you MUST", every restated rule, every reminder re-injected into context
// is a request the model is free to lose under load, length or distraction.
// The longer the specification, the weaker each individual line's pull — a
// 150k spec is exactly the case where prompt-level compliance fails worst.
//
// So compliance is not asked for here. It is made structural:
//
//     a clause the agent can violate in its output is advice.
//     a clause the agent cannot violate in its EFFECT is a boundary.
//
// This module moves the specification from the first category to the
// second. Nothing here writes a single character into the prompt. The model
// is never told to obey, never reminded, never nagged — the specification's
// text is delivered once, verbatim, by systemprompt.v, and that is all.
// What this module does is make non-compliant ACTIONS fail to commit.
//
// Three mechanisms, all deterministic, none textual:
//
//   1. ADDRESSING — the specification stops being a wall of text and
//      becomes a namespace. parse_clauses() splits it into stable,
//      content-hashed clauses with ids (§4.2, "no-secrets", …). A clause
//      can now be cited, counted, and bound to.
//
//   2. BINDING — a clause becomes enforceable when it carries a
//      machine-checkable rule, authored by the human in their own
//      specification, next to the prose it enforces:
//
//          §4.2 Secrets never live in source.
//          @enforce forbid_content: (?i)api[_-]?key\s*=\s*["'][A-Za-z0-9]
//
//      Nothing is inferred from the prose and nothing is invented: a clause
//      with no @enforce is unenforced, and says so, rather than being
//      silently approximated.
//
//   3. THE BOUNDARY — guards are evaluated against the PENDING tool call,
//      before it runs. A violation returns a block reason, so the call
//      never executes: no snapshot, no write, no side effect. The agent
//      learns the rule from a real gate refusing a real action, not from a
//      sentence added to its prompt.
//
// Every evaluation is sealed to the event log ('covenant.blocked',
// 'covenant.cleared'), so adherence per clause is an auditable number
// rather than an impression.
//
// Guards bind to EFFECTS, not to tool names (see effects.v). Where a
// command's effects cannot be determined before it runs, a containment
// clause refuses it rather than assuming the best: an unprovable claim is
// not a passing one.

const effect_kinds = [effect_write, effect_delete, effect_exec, effect_opaque]

const guard_kinds = ['forbid_tool', 'forbid_path', 'confine_paths',
	'forbid_content', 'require_content', 'forbid_command', 'forbid_effect']

// Guard is one deterministic constraint on a pending tool call.
pub struct Guard {
pub:
	clause string // the clause id this guard belongs to
	kind   string
	value  string   // regex / glob / tool name, per kind
	roots  []string // confine_paths
	globs  []string // forbid_path
	where  string   // require_content scope (a path glob)
}

pub fn (g &Guard) to_json() map[string]json2.Any {
	mut d := {
		'clause': json2.Any(g.clause)
		'kind':   json2.Any(g.kind)
	}
	if g.value != '' {
		d['value'] = g.value
	}
	if g.roots.len > 0 {
		d['roots'] = strs_to_any(g.roots)
	}
	if g.globs.len > 0 {
		d['globs'] = strs_to_any(g.globs)
	}
	if g.where != '' {
		d['where'] = g.where
	}
	return d
}

// Clause is one addressable unit of the specification.
pub struct Clause {
pub mut:
	id     string
	title  string
	body   string
	line   int
	guards []Guard
}

// fingerprint is the content address — it changes the moment the clause's
// text changes.
pub fn (c &Clause) fingerprint() string {
	return hash('${c.id}\x00${c.title}\x00${c.body}')[..16]
}

pub fn (c &Clause) enforced() bool {
	return c.guards.len > 0
}

// Violation is a pending call's collision with one clause.
pub struct Violation {
pub:
	clause string
	kind   string
	detail string
	// the effect's path, when the guard judged one
	path string
}

pub fn (v &Violation) to_json() map[string]json2.Any {
	mut d := {
		'clause': json2.Any(v.clause)
		'kind':   json2.Any(v.kind)
		'detail': json2.Any(v.detail)
	}
	if v.path != '' {
		d['path'] = v.path
	}
	return d
}

// ---------------------------------------------------------------------------
// Parsing — specification text -> addressable clauses
// ---------------------------------------------------------------------------

// parse_guard parses one @enforce line and returns (guard, error). A
// malformed rule is reported, never guessed at and never silently dropped —
// an enforcement rule that quietly does nothing is worse than no rule,
// because the author believes they are covered.
fn parse_guard(clause_id string, rest_in string) (?Guard, string) {
	rest := rest_in.trim_space()
	mut kind := ''
	mut value := ''
	mut roots := []string{}
	mut globs := []string{}
	mut where := ''

	if rest.starts_with('{') {
		spec_obj := json2.decode[json2.Any](rest) or {
			return none, '${clause_id}: malformed @enforce JSON (${err.msg()})'
		}
		obj := match spec_obj {
			map[string]json2.Any { spec_obj }
			else { return none, '${clause_id}: @enforce JSON must be an object' }
		}
		kind = jstr(obj, 'kind').trim_space()
		value = jstr(obj, 'value').trim_space()
		if value == '' {
			value = jstr(obj, 'pattern').trim_space()
		}
		roots = jstrs(obj, 'roots').clone()
		globs = jstrs(obj, 'globs').clone()
		where = jstr(obj, 'where').trim_space()
	} else {
		head := rest.all_before(':')
		tail := if rest.contains(':') { rest.all_after_first(':') } else { '' }
		kind = head.trim_space()
		value = tail.trim_space()
		if kind == 'confine_paths' || kind == 'forbid_path' {
			parts := value.split(',').map(it.trim_space()).filter(it != '')
			if kind == 'confine_paths' {
				roots = parts.clone()
			} else {
				globs = parts.clone()
			}
			value = ''
		}
	}

	if kind !in guard_kinds {
		mut known := guard_kinds.clone()
		known.sort()
		return none, "${clause_id}: unknown @enforce kind '${kind}' — known: ${known.join(', ')}"
	}
	if kind in ['forbid_content', 'require_content', 'forbid_command'] {
		if value == '' {
			return none, '${clause_id}: ${kind} needs a regex'
		}
		compile_regex(value) or {
			return none, '${clause_id}: ${kind} regex is invalid (${err.msg()})'
		}
	}
	if kind == 'require_content' && where == '' {
		// an unscoped require_content would block every unrelated write
		return none, '${clause_id}: require_content needs `where` (a path glob) ' +
			'so it scopes to the files it means'
	}
	if kind == 'forbid_tool' && value == '' {
		return none, '${clause_id}: forbid_tool needs a tool name'
	}
	if kind == 'forbid_effect' && value !in effect_kinds {
		mut known := effect_kinds.clone()
		known.sort()
		return none, '${clause_id}: forbid_effect must be one of ${known.join(", ")}'
	}
	if kind == 'confine_paths' && roots.len == 0 {
		return none, '${clause_id}: confine_paths needs at least one root'
	}
	if kind == 'forbid_path' && globs.len == 0 {
		return none, '${clause_id}: forbid_path needs at least one glob'
	}
	return Guard{
		clause: clause_id
		kind:   kind
		value:  value
		roots:  roots
		globs:  globs
		where:  where
	}, ''
}

struct ClauseHeader {
	id    string
	title string
	ok    bool
}

// match_clause_header recognises "§4.2 Title", "[no-secrets] Title" and
// "## Title" at up to three spaces of indentation.
fn match_clause_header(line string) ClauseHeader {
	mut s := line
	mut lead := 0
	for lead < 3 && lead < s.len && s[lead] == ` ` {
		lead++
	}
	if lead < s.len && s[lead] == `\t` {
		return ClauseHeader{}
	}
	s = s[lead..]
	if s.starts_with('§') {
		rest := s['§'.len..].trim_left(' ')
		mut n := 0
		for n < rest.len && (rest[n].is_digit() || rest[n] == `.`) {
			n++
		}
		if n < rest.len && rest[n] >= `a` && rest[n] <= `z`
			&& (n + 1 >= rest.len || rest[n + 1] == ` `) {
			n++
		}
		if n == 0 {
			return ClauseHeader{}
		}
		return ClauseHeader{
			id:    rest[..n]
			title: rest[n..].trim_space()
			ok:    true
		}
	}
	if s.starts_with('[') {
		close := s.index(']') or { return ClauseHeader{} }
		tag := s[1..close]
		if tag == '' {
			return ClauseHeader{}
		}
		for c in tag {
			if !is_word_byte(c) && c != `.` && c != `-` {
				return ClauseHeader{}
			}
		}
		return ClauseHeader{
			id:    tag
			title: s[close + 1..].trim_space()
			ok:    true
		}
	}
	if s.starts_with('#') {
		mut n := 0
		for n < s.len && s[n] == `#` && n < 6 {
			n++
		}
		if n == 0 || n >= s.len || s[n] != ` ` {
			return ClauseHeader{}
		}
		title := s[n..].trim_space()
		if title == '' {
			return ClauseHeader{}
		}
		return ClauseHeader{
			id:    '' // a markdown heading is slugified by the caller
			title: title
			ok:    true
		}
	}
	return ClauseHeader{}
}

fn slugify(title string) string {
	mut out := ''
	mut prev_dash := false
	for c in title.to_lower() {
		if (c >= `a` && c <= `z`) || (c >= `0` && c <= `9`) {
			out += c.ascii_str()
			prev_dash = false
		} else if !prev_dash {
			out += '-'
			prev_dash = true
		}
	}
	return out.trim('-')
}

fn match_enforce(line string) ?string {
	s := line.trim_left(' \t')
	if s.len < 9 {
		return none
	}
	if s[..8].to_lower() != '@enforce' {
		return none
	}
	rest := s[8..]
	if rest.len == 0 || (rest[0] != ` ` && rest[0] != `\t`) {
		return none
	}
	body := rest.trim_space()
	return if body == '' { none } else { body }
}

// parse_clauses splits a specification into addressable clauses and returns
// (clauses, errors). Text before the first header becomes the preamble
// clause, so no byte of the specification is unaddressable.
pub fn parse_clauses(spec string) ([]Clause, []string) {
	mut clauses := []Clause{}
	mut errors := []string{}
	mut cur := Clause{}
	mut have_cur := false
	mut buf := []string{}
	mut seen := map[string]int{}

	lines := split_lines(spec)
	mut n := 0
	for n < lines.len {
		line := lines[n]
		n++
		h := match_clause_header(line)
		if h.ok {
			if have_cur {
				cur.body = buf.join('\n').trim_space()
				clauses << cur
			}
			mut raw := h.id
			if raw == '' {
				// a markdown heading: slugify its title into an id
				raw = slugify(h.title)
				if raw == '' {
					raw = 'clause-${n}'
				}
			}
			// ids must be unique to be citable
			if count := seen[raw] {
				seen[raw] = count + 1
				raw = '${raw}#${count + 1}'
			} else {
				seen[raw] = 1
			}
			cur = Clause{
				id:    raw
				title: h.title
				line:  n
			}
			have_cur = true
			buf = []
			continue
		}
		if !have_cur {
			cur = Clause{
				id:    'preamble'
				title: 'preamble'
				line:  1
			}
			seen['preamble'] = 1
			have_cur = true
			buf = []
		}
		buf << line
		mut rest := match_enforce(line) or { continue }
		// a JSON rule may span lines — long regexes need the room. Consume
		// until the braces balance (or the clause ends), so an unterminated
		// block reports as malformed instead of eating the rest of the
		// specification.
		if rest.starts_with('{') && rest.count('{') > rest.count('}') {
			for n < lines.len {
				nxt := lines[n]
				if match_clause_header(nxt).ok {
					break
				}
				if _ := match_enforce(nxt) {
					break
				}
				n++
				buf << nxt
				rest += '\n' + nxt.trim_space()
				if rest.count('{') <= rest.count('}') {
					break
				}
			}
		}
		guard, err_msg := parse_guard(cur.id, rest)
		if g := guard {
			cur.guards << g
		} else {
			errors << err_msg
		}
	}
	if have_cur {
		cur.body = buf.join('\n').trim_space()
		clauses << cur
	}
	return clauses, errors
}

// ---------------------------------------------------------------------------
// Evaluation — guards against a pending call
// ---------------------------------------------------------------------------

// norm_path is a posix-normalised path for glob matching. It keeps matching
// stable across platforms and collapses '..' so a traversal cannot slip a
// confine_paths root.
fn norm_path(path string) string {
	mut p := path
	if p.starts_with('~') {
		p = os.home_dir() + p[1..]
	}
	mut parts := []string{}
	for part in p.replace('\\', '/').split('/') {
		if part == '..' {
			if parts.len > 0 {
				parts.delete_last()
			}
			continue
		}
		if part == '.' || part == '' {
			continue
		}
		parts << part
	}
	return parts.join('/')
}

fn matches_glob(path string, pattern string) bool {
	norm := norm_path(path)
	pat := pattern.trim_right('/')
	if fnmatch_name(norm, pat) || fnmatch_name(norm, pat + '/*') {
		return true
	}
	// a bare directory name confines/forbids everything beneath it
	for seg in norm.split('/') {
		if fnmatch_name(seg, pat) {
			return true
		}
	}
	return false
}

fn under_root(path string, root string) bool {
	r := norm_path(root).trim_right('/')
	if r == '' {
		return true
	}
	norm := norm_path(path)
	return norm == r || norm.starts_with(r + '/')
}

// via names how an effect was reached, so a refusal on a shell route reads
// as clearly as one on a direct call.
fn via(e &Effect) string {
	return if e.reason != '' { ' (via ${e.reason})' } else { '' }
}

// evaluate lists every guard this pending call collides with.
//
// Guards are matched against the call's EFFECTS, not its tool name, so the
// same act is judged identically however it is spelled. Pure and
// deterministic: same call, same guards, same verdict — always.
pub fn evaluate(guards []Guard, tool string, args map[string]json2.Any) []Violation {
	return evaluate_effects(guards, derive(tool, args), tool, jstr(args, 'command'))
}

// evaluate_effects judges effects directly.
//
// evaluate() derives effects from a pending call — an intention. Effects
// can also be observed AFTER the fact, from what actually changed on disk
// (see sentinel.v), and the same clauses must judge both. Keeping the rule
// in one place is what makes an intended write and a realised one
// impossible to judge differently.
pub fn evaluate_effects(guards []Guard, effects []Effect, tool string, command string) []Violation {
	mut out := []Violation{}
	mutations := effects.filter(it.kind == effect_write || it.kind == effect_delete)
	opaque := effects.filter(it.kind == effect_opaque)

	for g in guards {
		match g.kind {
			'forbid_tool' {
				if tool == g.value {
					out << Violation{
						clause: g.clause
						kind:   g.kind
						detail: "tool '${tool}' is forbidden"
					}
				}
			}
			'forbid_effect' {
				for e in effects {
					if e.kind == g.value {
						where := if e.path != '' { " on '${e.path}'" } else { '' }
						out << Violation{
							clause: g.clause
							kind:   g.kind
							detail: '${e.kind} effect${where} is forbidden${via(&e)}'
							path:   e.path
						}
					}
				}
			}
			'forbid_path' {
				for e in mutations {
					if e.path == '' {
						continue
					}
					for x in g.globs {
						if matches_glob(e.path, x) {
							out << Violation{
								clause: g.clause
								kind:   g.kind
								detail: "${e.kind} to '${e.path}' matches forbidden " +
									"pattern '${x}'${via(&e)}"
								path:   e.path
							}
							break
						}
					}
				}
				for e in opaque {
					out << Violation{
						clause: g.clause
						kind:   g.kind
						detail: 'effects cannot be determined before running, so ' +
							'this call cannot be shown to avoid ${g.globs} — ${e.reason}'
					}
				}
			}
			'confine_paths' {
				for e in mutations {
					if e.path == '' {
						continue
					}
					mut inside := false
					for r in g.roots {
						if under_root(e.path, r) {
							inside = true
							break
						}
					}
					if !inside {
						out << Violation{
							clause: g.clause
							kind:   g.kind
							detail: "${e.kind} to '${e.path}' is outside the permitted " +
								'roots ${g.roots}${via(&e)}'
							path:   e.path
						}
					}
				}
				for e in opaque {
					out << Violation{
						clause: g.clause
						kind:   g.kind
						detail: 'effects cannot be determined before running, so ' +
							'this call cannot be shown to stay under ${g.roots} — ${e.reason}'
					}
				}
			}
			'forbid_content' {
				re := compile_regex(g.value) or { continue }
				for e in mutations {
					if e.content == '' {
						continue
					}
					if m := re.search(e.content) {
						out << Violation{
							clause: g.clause
							kind:   g.kind
							detail: "content written to '${e.path}' matches forbidden " +
								"pattern: '${clip_plain(m.text, 60)}'${via(&e)}"
							path:   e.path
						}
					}
				}
			}
			'require_content' {
				re := compile_regex(g.value) or { continue }
				for e in mutations {
					if e.kind != effect_write || e.content == '' || e.path == '' {
						continue
					}
					if matches_glob(e.path, g.where) && !re.matches(e.content) {
						out << Violation{
							clause: g.clause
							kind:   g.kind
							detail: "'${e.path}' must contain a match for " +
								"'${g.value}' and does not${via(&e)}"
							path:   e.path
						}
					}
				}
			}
			'forbid_command' {
				if command == '' {
					continue
				}
				re := compile_regex(g.value) or { continue }
				if m := re.search(command) {
					out << Violation{
						clause: g.clause
						kind:   g.kind
						detail: "command matches forbidden pattern: '${clip_plain(m.text,
							60)}'"
					}
				}
			}
			else {}
		}
	}
	return out
}

// ---------------------------------------------------------------------------
// Covenant — the bound specification
// ---------------------------------------------------------------------------

// Covenant is the specification, parsed into clauses and bound to the
// action boundary. It holds no prompt text and never contributes any.
@[heap]
pub struct Covenant {
pub mut:
	log     &EventLog
	clauses []Clause
	errors  []string
	blocked int
	cleared int
mut:
	hits  map[string]int
	by_id map[string]int // clause id -> index into clauses
}

pub fn new_covenant(log &EventLog, spec string) &Covenant {
	mut c := &Covenant{
		log: unsafe { log }
	}
	c.bind(spec)
	return c
}

// bind (re)parses a specification. Safe to call on every reload.
pub fn (mut c Covenant) bind(spec string) {
	c.clauses, c.errors = parse_clauses(spec)
	c.by_id = map[string]int{}
	for i, cl in c.clauses {
		c.by_id[cl.id] = i
	}
}

pub fn (c &Covenant) guards() []Guard {
	mut out := []Guard{}
	for cl in c.clauses {
		out << cl.guards
	}
	return out
}

pub fn (c &Covenant) enforced_clauses() []Clause {
	return c.clauses.filter(it.enforced())
}

// -- the boundary ------------------------------------------------------------

// check evaluates the pending call and returns the violations; the caller
// (the agent's gate) turns a non-empty list into a refusal.
pub fn (c &Covenant) check(tool string, args map[string]json2.Any) []Violation {
	return evaluate(c.guards(), tool, args)
}

// check_effects evaluates effects observed rather than intended — the same
// clauses, applied to what actually happened.
pub fn (c &Covenant) check_effects(effects []Effect) []Violation {
	return evaluate_effects(c.guards(), effects, '', '')
}

// cite renders the refusal text — every clause that refused, by id and
// title.
pub fn (c &Covenant) cite(violations []Violation) string {
	plural_s := if violations.len > 1 { 's' } else { '' }
	mut lines := ['CovenantViolation: this action is refused by the ' +
		'specification (${violations.len} clause${plural_s}).']
	for v in violations {
		mut title := ''
		if idx := c.by_id[v.clause] {
			t := c.clauses[idx].title
			if t != '' {
				title = ' — ${t}'
			}
		}
		lines << '  ${v.clause}${title}: ${v.detail}'
	}
	return lines.join('\n')
}

fn (mut c Covenant) record(event string, tool string, violations []Violation) {
	c.blocked++
	for v in violations {
		c.hits[v.clause] = (c.hits[v.clause] or { 0 }) + 1
	}
	c.log.append(event, {
		'tool':       json2.Any(tool)
		'violations': json2.Any(violations.map(json2.Any(it.to_json())))
	}, AppendOpts{ actor: 'kernel' })
}

// gate returns the block reason for a pending call, or '' to let it
// proceed.
//
// A returned string blocks the call before it executes — no snapshot, no
// write, no side effect. The citation names the clause so the refusal is
// traceable to the specification rather than to a rule invented here.
pub fn (mut c Covenant) gate(tool string, args map[string]json2.Any) string {
	violations := c.check(tool, args)
	if violations.len == 0 {
		if c.guards().len > 0 {
			c.cleared++
		}
		return ''
	}
	c.record('covenant.blocked', tool, violations)
	return c.cite(violations)
}

// -- arming: the boundary as the only route to a handler --------------------

__global (
	// The armed registry's boundary. Arming replaces a tool's handler with
	// a wrapper, and a V closure cannot capture a `&Covenant` that a caller
	// might move, so the live boundary is reached through this global. One
	// agent owns one covenant per process, which is the same lifetime the
	// Python original's bound method had.
	armed_covenant &Covenant
)

// arm returns `registry` with every handler wrapped in the boundary.
//
// Calling the gate from each tool loop is a convention, and a convention is
// only as good as every future executor remembering it — crew.v runs its
// subagents' tools directly, so the specification would bind the sovereign
// agent and nothing else.
//
// Arming removes the thing that has to be remembered: the unguarded handler
// is no longer reachable from the registry, so any executor — this one, a
// subagent, one written later — passes the boundary because there is no
// other way to invoke the tool.
//
// A call refused here ALSO seals 'covenant.bypassed', because reaching this
// wrapper without having been refused by gate() means some executor skipped
// the gate. The backstop holds the line and reports the gap rather than
// hiding it.
pub fn (mut c Covenant) arm(registry map[string]Tool) map[string]Tool {
	armed_covenant = unsafe { &c }
	mut armed := map[string]Tool{}
	for name, tool in registry {
		armed[name] = c.arm_one(name, tool)
	}
	return armed
}

// arm_one wraps a single tool. Idempotent — an armed tool is returned as
// is.
pub fn (mut c Covenant) arm_one(name string, tool Tool) Tool {
	if tool.guarded {
		return tool
	}
	armed_covenant = unsafe { &c }
	inner := tool.handler
	return Tool{
		name:        tool.name
		description: tool.description
		parameters:  tool.parameters
		risk:        tool.risk
		guarded:     true
		handler:     ToolHandler(fn [name, inner] (args map[string]json2.Any, sink OutputSink) string {
			mut cov := armed_covenant
			if cov == unsafe { nil } {
				return inner(args, sink)
			}
			violations := cov.check(name, args)
			if violations.len == 0 {
				return inner(args, sink)
			}
			cov.record('covenant.bypassed', name, violations)
			return 'ERROR: ' + cov.cite(violations)
		})
	}
}

// -- observation --------------------------------------------------------------

// unnamed_tools lists the armed tools whose effects derive() cannot name.
//
// Arming routes every tool through the boundary, but a path or content
// clause can only judge effects it can read. A tool outside the effect
// vocabulary passes those clauses because nothing was derived to test — not
// because it was found compliant.
//
// That gap is reported instead of being left to look like coverage, so the
// author can see exactly which tools their containment clauses do not reach
// and name them directly with forbid_tool if they must.
pub fn unnamed_tools(registry map[string]Tool) []string {
	mut out := []string{}
	for name, _ in registry {
		if name !in named_tools {
			out << name
		}
	}
	out.sort()
	return out
}

pub struct CovenantStats {
pub:
	clauses  int
	enforced int
	guards   int
	errors   int
	blocked  int
	cleared  int
}

pub fn (c &Covenant) stats() CovenantStats {
	return CovenantStats{
		clauses:  c.clauses.len
		enforced: c.enforced_clauses().len
		guards:   c.guards().len
		errors:   c.errors.len
		blocked:  c.blocked
		cleared:  c.cleared
	}
}

// report is the human-readable adherence report — what is bound, what is
// not, and which clauses actually caught something.
pub fn (c &Covenant) report() string {
	s := c.stats()
	if c.clauses.len == 0 {
		return 'covenant: no specification bound'
	}
	mut lines := ['covenant: ${thousands(s.clauses)} clauses · ${s.enforced} enforced ' +
		'· ${s.guards} guards · ${s.blocked} blocked / ${s.cleared} cleared']
	for cl in c.enforced_clauses() {
		hits := c.hits[cl.id] or { 0 }
		mut kinds := []string{}
		for g in cl.guards {
			if g.kind !in kinds {
				kinds << g.kind
			}
		}
		kinds.sort()
		mark := if hits > 0 { '●' } else { '○' }
		plural_s := if hits == 1 { '' } else { 's' }
		lines << '  ${mark} ${pad_right(cl.id, 16)} ${pad_right(kinds.join(","), 32)} ' +
			'${hits} block${plural_s}'
	}
	unenforced := c.clauses.len - s.enforced
	if unenforced > 0 {
		lines << '  ${thousands(unenforced)} clause(s) carry no @enforce rule ' +
			'— prose only, not bound to the boundary'
	}
	for e in c.errors {
		lines << '  !! ${e}'
	}
	return lines.join('\n')
}
