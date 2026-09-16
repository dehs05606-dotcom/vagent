module vagent

import x.json2

// sequence.v — the clauses about ORDER.
//
// Every rule so far is timeless. A guard asks "is this act permitted?" and a
// horizon asks "how many so far?", and neither can express the constraints
// that are entirely about when something happens relative to something else:
//
//     "read a file before rewriting it"
//     "run the tests after touching src/, before declaring done"
//     "never push before the tests have passed on the current tree"
//
// These are not permissions. Each act is individually allowed — it is the
// ORDER that is wrong, and order is invisible to a per-call check. An agent
// that rewrites a file it never read has broken a real clause without
// performing a single forbidden act.
//
// The event log is already a total order, so this is a fold over it rather
// than new bookkeeping. Two shapes cover the useful cases:
//
//     §20 A file is read before it is rewritten.
//     @sequence before write src/** require read same
//
//     §21 Touching src/ obliges a test run before done.
//     @sequence after write src/** require run pytest
//
// `before` is a PRECONDITION: checked on the pending call and refused if
// unmet, so the out-of-order act does not happen. `after` is a
// POSTCONDITION: it refuses nothing — refusing the write would make the
// clause impossible, since the write is what creates the requirement — and
// instead blocks DONE until it is satisfied.
//
// `require read same` is the case worth naming: "same" binds the requirement
// to the very path being written, so one clause covers every file.
//
// A satisfied precondition is not consumed: reading a file and then writing
// it twice is fine. It is re-armed only when the path changes in a way the
// agent did NOT author — a formatter, a build step, a redirect — because
// only then is the picture it read no longer what is on disk. Its own
// write_file carries content it supplied and cannot surprise it.

pub const seq_before = 'before'
pub const seq_after = 'after'

// tools that count as having READ a path
const read_tools = ['read_file', 'search_files', 'file_info', 'list_dir', 'glob_files']

// tools where the agent supplied the content it wrote, so the result holds
// no surprises for it
const authored_tools = ['write_file', 'edit_file', 'apply_patch', 'create_directory']

// seq_norm collapses . and .. the way PurePath does, without touching disk.
pub fn seq_norm(path string) string {
	mut parts := []string{}
	for part in path.replace('\\', '/').split('/') {
		if part == '' {
			continue
		}
		if part == '..' {
			if parts.len > 0 {
				parts.delete_last()
			}
			continue
		}
		if part == '.' {
			continue
		}
		parts << part
	}
	mut out := parts.join('/')
	if path.starts_with('/') {
		out = '/' + out
	}
	return out
}

// seq_glob is fnmatch over the normalised path, plus the ** conveniences the
// original added: a pattern of src/** also matches src itself's children
// written without the intermediate directory.
pub fn seq_glob(path string, pattern string) bool {
	norm := seq_norm(path)
	if fnmatch_name(norm, pattern) {
		return true
	}
	if pattern.contains('**') {
		flat := pattern.replace('**/', '').replace('/**', '')
		if fnmatch_name(norm, flat) {
			return true
		}
		head := pattern.all_before('**').trim_right('/')
		if head != '' && norm.starts_with(head + '/') {
			return true
		}
	}
	return false
}

pub struct SeqRule {
pub:
	clause string
	// before | after
	when string
	// write | delete
	act  string
	glob string
	// read | run
	req string
	// a path glob, "same", or a command substring
	target string
}

pub fn (r &SeqRule) to_json() map[string]json2.Any {
	return {
		'clause': json2.Any(r.clause)
		'when':   json2.Any(r.when)
		'act':    json2.Any(r.act)
		'glob':   json2.Any(r.glob)
		'req':    json2.Any(r.req)
		'target': json2.Any(r.target)
	}
}

pub fn (r &SeqRule) describe(path string) string {
	target := if r.target.to_lower() == 'same' { path } else { r.target }
	verb := if r.req == 'read' { 'read' } else { 'run' }
	subject := if path != '' { path } else { r.glob }
	if r.when == seq_before {
		return "${r.clause}: '${target}' must be ${verb} before ${r.act} to '${subject}'"
	}
	return "${r.clause}: ${r.act} to '${subject}' requires ${verb} '${target}' afterwards"
}

pub struct SeqUnmet {
pub:
	clause string
	detail string
}

pub fn (u &SeqUnmet) to_json() map[string]json2.Any {
	return {
		'clause': json2.Any(u.clause)
		'detail': json2.Any(u.detail)
	}
}

pub fn parse_sequence_rules(spec string) ([]SeqRule, []string) {
	mut rules := []SeqRule{}
	mut errors := []string{}
	mut clause := 'preamble'

	section_re := compile_regex(r'^\s{0,3}§\s*([\d.]+[a-z]?)') or { return rules, errors }
	tag_re := compile_regex(r'^\s{0,3}\[([A-Za-z0-9_.\-]+)\]') or { return rules, errors }
	head_re := compile_regex(r'(?i)^\s*@sequence\b') or { return rules, errors }
	seq_re := compile_regex(r'(?i)^\s*@sequence\s+(before|after)\s+(write|delete)\s+(\S+)\s+require\s+(read|run)\s+(.+?)\s*$') or {
		return rules, errors
	}

	for line in split_lines(spec) {
		if m := section_re.search(line) {
			clause = group_text(line, &m, 1)
			continue
		}
		if m := tag_re.search(line) {
			clause = group_text(line, &m, 1)
			continue
		}
		if _ := head_re.search(line) {
		} else {
			continue
		}
		m := seq_re.search(line) or {
			errors << "${clause}: malformed @sequence — expected " +
				"'@sequence before write src/** require read same' or " +
				"'@sequence after write src/** require run pytest'"
			continue
		}
		req := group_text(line, &m, 4).to_lower()
		target := group_text(line, &m, 5).trim_space()
		if req == 'run' && target.to_lower() == 'same' {
			errors << "${clause}: 'require run same' is meaningless — name the command"
			continue
		}
		rules << SeqRule{
			clause: clause
			when:   group_text(line, &m, 1).to_lower()
			act:    group_text(line, &m, 2).to_lower()
			glob:   group_text(line, &m, 3)
			req:    req
			target: target
		}
	}
	return rules, errors
}

@[heap]
pub struct Timeline {
pub mut:
	log     &EventLog
	rules   []SeqRule
	errors  []string
	blocked int
}

pub fn new_timeline(log &EventLog, spec string) &Timeline {
	mut t := &Timeline{
		log: unsafe { log }
	}
	t.bind(spec)
	return t
}

pub fn (mut t Timeline) bind(spec string) {
	t.rules, t.errors = parse_sequence_rules(spec)
}

// -- the fold ----------------------------------------------------------------

struct SeqRun {
	seq     int
	command string
}

struct SeqHistory {
mut:
	// path -> the seq it was last read at
	reads map[string]int
	runs  []SeqRun
	// path -> the seq it was last written or deleted at
	writes map[string]int
	// the same, but only for changes the agent did not author
	incidental map[string]int
}

// history is one pass over the log. Every question below is about the
// RELATIVE order of these, and separate folds could disagree if the log grew
// between them.
//
// Writes are split by whether the agent authored the content. A write_file
// or a patch carries content the agent supplied, so it cannot be surprised
// by the result. A file changed as a side effect of a command leaves the
// agent holding a stale picture of that path, which is the situation a
// "read before write" clause exists to prevent.
fn (mut t Timeline) history() SeqHistory {
	mut h := SeqHistory{}
	for ev in t.log.events(t.log.branch) {
		if ev.typ != 'tool.call' {
			continue
		}
		name := jstr(ev.data, 'name')
		args := jmap(ev.data, 'args')
		if name in read_tools {
			p := jstr(args, 'path')
			if p != '' {
				h.reads[seq_norm(p)] = ev.seq
			}
		}
		cmd := jstr(args, 'command')
		if cmd != '' {
			h.runs << SeqRun{
				seq:     ev.seq
				command: cmd
			}
		}
		authored := name in authored_tools
		for e in derive(name, args) {
			if (e.kind == effect_write || e.kind == effect_delete) && e.path != '' {
				p := seq_norm(e.path)
				h.writes[p] = ev.seq
				if !authored {
					h.incidental[p] = ev.seq
				}
			}
		}
	}
	return h
}

// -- preconditions -----------------------------------------------------------

// check is the `before` rules this pending call would violate.
pub fn (mut t Timeline) check(tool string, args map[string]json2.Any) []SeqUnmet {
	befores := t.rules.filter(it.when == seq_before)
	if befores.len == 0 {
		return []
	}
	h := t.history()
	mut out := []SeqUnmet{}
	for e in derive(tool, args) {
		if (e.kind != effect_write && e.kind != effect_delete) || e.path == '' {
			continue
		}
		act := if e.kind == effect_write { 'write' } else { 'delete' }
		path := seq_norm(e.path)
		for r in befores {
			if r.act != act || !seq_glob(path, r.glob) {
				continue
			}
			if r.req == 'read' {
				target := if r.target.to_lower() == 'same' { path } else { r.target }
				norm_target := seq_norm(target)
				seq := h.reads[norm_target] or {
					out << SeqUnmet{
						clause: r.clause
						detail: r.describe(path)
					}
					continue
				}
				incidental := h.incidental[norm_target] or { -1 }
				if incidental > seq {
					// read, then changed by something the agent did not
					// author: it no longer knows what it would overwrite
					out << SeqUnmet{
						clause: r.clause
						detail: "${r.clause}: '${target}' was read, then changed by a command afterwards — read it again before ${act}"
					}
				}
			} else {
				mut ran := false
				for run in h.runs {
					if run.command.contains(r.target) {
						ran = true
						break
					}
				}
				if !ran {
					out << SeqUnmet{
						clause: r.clause
						detail: r.describe(path)
					}
				}
			}
		}
	}
	return out
}

pub fn (mut t Timeline) gate(tool string, args map[string]json2.Any) string {
	unmet := t.check(tool, args)
	if unmet.len == 0 {
		return ''
	}
	t.blocked++
	t.log.append('sequence.blocked', {
		'tool':  json2.Any(tool)
		'unmet': json2.Any(unmet.map(json2.Any(it.to_json())))
	}, AppendOpts{ actor: 'kernel' })
	plural := if unmet.len > 1 { 's' } else { '' }
	mut lines := ['OutOfOrder: ${unmet.len} clause${plural} require something to happen before this call.']
	for u in unmet {
		lines << '  ${u.detail}'
	}
	return lines.join('\n')
}

// -- postconditions ----------------------------------------------------------

// outstanding is the `after` rules that have triggered and are not yet
// satisfied.
//
// Order matters: a test run BEFORE the write does not satisfy a rule that
// says the run must follow it, because it did not see the change.
pub fn (mut t Timeline) outstanding() []SeqUnmet {
	afters := t.rules.filter(it.when == seq_after)
	if afters.len == 0 {
		return []
	}
	h := t.history()
	mut out := []SeqUnmet{}
	for r in afters {
		mut last := -1
		for path, seq in h.writes {
			if seq_glob(path, r.glob) && seq > last {
				last = seq
			}
		}
		if last < 0 {
			continue
		}
		if r.req == 'run' {
			mut satisfied := false
			for run in h.runs {
				if run.seq > last && run.command.contains(r.target) {
					satisfied = true
					break
				}
			}
			if !satisfied {
				out << SeqUnmet{
					clause: r.clause
					detail: "${r.clause}: ${r.glob} changed, so '${r.target}' must run after that change and has not"
				}
			}
		} else {
			target := seq_norm(r.target)
			read_at := h.reads[target] or { -1 }
			if read_at <= last {
				out << SeqUnmet{
					clause: r.clause
					detail: r.describe('')
				}
			}
		}
	}
	return out
}

// blocker is why progress cannot be declared complete, or '' when it can.
pub fn (mut t Timeline) blocker() string {
	unmet := t.outstanding()
	if unmet.len == 0 {
		return ''
	}
	plural := if unmet.len > 1 { 's' } else { '' }
	mut lines := ['SequenceOutstanding: ${unmet.len} ordering requirement${plural} are not met yet.']
	for u in unmet {
		lines << '  ${u.detail}'
	}
	return lines.join('\n')
}

pub fn (mut t Timeline) report() string {
	if t.rules.len == 0 {
		return 'sequence: no @sequence rules in the specification'
	}
	unmet := t.outstanding()
	mut lines := ['sequence: ${t.rules.len} rule(s) · ${t.blocked} refused · ${unmet.len} outstanding']
	for r in t.rules {
		lines << '  ' + pad_width(r.clause, 10) + ' ' + pad_width(r.when, 7) +
			' ${r.act} ${r.glob} require ${r.req} ${r.target}'
	}
	for u in unmet {
		lines << '  ○ ${u.detail}'
	}
	for e in t.errors {
		lines << '  !! ${e}'
	}
	return lines.join('\n')
}
