module vagent

import x.json2

// effects.v — what a call DOES, independent of which tool it used.
//
// A guard bound to a tool name is a guard bound to spelling. `write_file`
// with path "/etc/cron.d/x" and `run_command` with "echo boom >
// /etc/cron.d/x" are the same act; a rule that refuses the first and
// permits the second does not constrain the agent, it constrains its
// vocabulary. Any model — not maliciously, just by picking a different tool
// for the same job — routes straight around it.
//
// So guards must not see tool calls. They must see EFFECTS:
//
//     write   this path's bytes change (and, when known, to what)
//     delete  this path stops existing
//     exec    a process runs
//     opaque  SOMETHING happens that cannot be named ahead of time
//
// derive() reduces every tool call to that vocabulary, shell commands
// included: redirections, heredocs, rm/mv/cp/tee/dd/sed -i/truncate/ln, and
// pipelines. Two different tools producing one effect produce one identical
// Effect, so a clause written once holds across every route to it.
//
// THE OPAQUE CASE — the part that makes this airtight rather than merely
// broad. Some commands cannot be analysed before they run: `eval "$X"`,
// `bash -c "$CMD"`, `python -c …`, `curl … | sh`, a redirect whose target
// is `$DIR/f`. Their effects are unknowable, so no containment claim about
// them can be proven.
//
// An unprovable claim is not treated as a passing one. An opaque effect
// satisfies no containment clause: under a `confine_paths` or `forbid_path`
// clause it is refused, because "all writes stay under src/" is exactly the
// guarantee such a command breaks. Where the author declared no
// containment, opaque commands run normally — the boundary only ever
// refuses what its clauses actually claim.
//
// That asymmetry is deliberate. A guard that fails OPEN when it cannot see
// is decorative: it holds only for actions transparent enough not to need
// it.

// effect kinds
pub const effect_write = 'write'
pub const effect_delete = 'delete'
pub const effect_exec = 'exec'
pub const effect_opaque = 'opaque'

// interpreter forms that can perform arbitrary effects
const eval_cmds = ['eval', 'source', '.']
const shells = ['sh', 'bash', 'zsh', 'ksh', 'dash', 'fish']
const interpreters = ['python', 'python3', 'perl', 'ruby', 'node', 'php', 'lua']
// -exec / -delete reach anywhere
const arbitrary_cmds = ['xargs', 'find']

// commands whose filesystem effects are known
const deleters = ['rm', 'rmdir', 'unlink', 'shred']
const creators = ['touch', 'mkdir', 'mkfifo']

// Effect is one consequence of a call, named independently of the tool used.
pub struct Effect {
pub:
	kind    string
	path    string
	content string
	command string
	// why this effect was derived (for the citation)
	reason string
}

pub fn (e &Effect) to_json() map[string]json2.Any {
	mut d := {
		'kind': json2.Any(e.kind)
	}
	if e.path != '' {
		d['path'] = e.path
	}
	if e.content != '' {
		d['content'] = if e.content.len > 200 { e.content[..200] } else { e.content }
	}
	if e.command != '' {
		d['command'] = e.command
	}
	if e.reason != '' {
		d['reason'] = e.reason
	}
	return d
}

// ---------------------------------------------------------------------------
// Shell analysis
// ---------------------------------------------------------------------------

// shell_split is shlex.split: it honours single and double quotes and
// backslash escapes, and drops a `#` comment. The bool return is false when
// a quote never closes — a command that cannot be read cannot be shown to
// respect anything.
pub fn shell_split(s string) ([]string, bool) {
	mut out := []string{}
	mut cur := ''
	mut has_cur := false
	mut quote := u8(0)
	mut i := 0
	for i < s.len {
		c := s[i]
		if quote != 0 {
			if c == `\\` && quote == `"` && i + 1 < s.len {
				cur += s[i + 1].ascii_str()
				i += 2
				continue
			}
			if c == quote {
				quote = 0
				i++
				continue
			}
			cur += c.ascii_str()
			i++
			continue
		}
		match c {
			`'`, `"` {
				quote = c
				has_cur = true
				i++
			}
			`\\` {
				if i + 1 < s.len {
					cur += s[i + 1].ascii_str()
					has_cur = true
					i += 2
				} else {
					i++
				}
			}
			` `, `\t`, `\n`, `\r` {
				if has_cur {
					out << cur
					cur = ''
					has_cur = false
				}
				i++
			}
			`#` {
				if !has_cur {
					// a comment runs to the end of the line
					break
				}
				cur += c.ascii_str()
				i++
			}
			else {
				cur += c.ascii_str()
				has_cur = true
				i++
			}
		}
	}
	if quote != 0 {
		return out, false
	}
	if has_cur {
		out << cur
	}
	return out, true
}

fn strip_flags(tokens []string) []string {
	return tokens.filter(!it.starts_with('-'))
}

// has_dynamic reports whether a redirect target is resolved at run time.
fn has_dynamic(s string) bool {
	return s.contains('$') || s.contains('`')
}

// split_segments splits a command line on sequencing and pipes: both start
// a new simple command.
pub fn split_segments(command string) []string {
	mut out := []string{}
	mut cur := ''
	mut i := 0
	mut quote := u8(0)
	for i < command.len {
		c := command[i]
		if quote != 0 {
			cur += c.ascii_str()
			if c == quote {
				quote = 0
			}
			i++
			continue
		}
		if c == `'` || c == `"` {
			quote = c
			cur += c.ascii_str()
			i++
			continue
		}
		if c == `&` && i + 1 < command.len && command[i + 1] == `&` {
			out << cur
			cur = ''
			i += 2
			continue
		}
		if c == `|` && i + 1 < command.len && command[i + 1] == `|` {
			out << cur
			cur = ''
			i += 2
			continue
		}
		if c == `;` || c == `|` || c == `\n` {
			out << cur
			cur = ''
			i++
			continue
		}
		cur += c.ascii_str()
		i++
	}
	out << cur
	return out
}

// heredoc_bodies maps a heredoc delimiter to its body, so `cat > f <<EOF …
// EOF` is a write whose content is known and can be pattern-checked like
// any other.
fn heredoc_bodies(command string) map[string]string {
	mut out := map[string]string{}
	open_re := compile_regex(r'<<-?\s*["\x27]?([A-Za-z_][A-Za-z0-9_]*)["\x27]?') or {
		return out
	}
	for m in open_re.find_all(command) {
		delim := group_text(command, &m, 1)
		if delim in out {
			continue
		}
		// the body runs from the first newline after the opener to a line
		// that is exactly the delimiter
		start_rune := m.end
		runes := command.runes()
		mut idx := start_rune
		for idx < runes.len && runes[idx] != `\n` {
			idx++
		}
		if idx >= runes.len {
			continue
		}
		idx++ // skip the newline
		body_start := idx
		mut lines := []string{}
		mut line := ''
		for idx <= runes.len {
			if idx == runes.len || runes[idx] == `\n` {
				if line.trim_space() == delim {
					out[delim] = lines.join('\n')
					break
				}
				lines << line
				line = ''
				if idx == runes.len {
					break
				}
			} else {
				line += runes[idx].str()
			}
			idx++
		}
		_ = body_start
	}
	return out
}

// redirect_effects returns the writes implied by redirection, plus the
// segment with the redirects removed so the remaining tokens read as a
// plain command.
fn redirect_effects(segment string, heredocs map[string]string) ([]Effect, string) {
	mut effects := []Effect{}
	mut content := ''
	for delim, body in heredocs {
		if segment.contains('<<' + delim) || segment.contains('<< ' + delim)
			|| segment.contains('<<-' + delim) || segment.contains("<<'" + delim)
			|| segment.contains('<<"' + delim) {
			content = body
			break
		}
	}

	re := compile_regex(r'\d?>>?\s*([^\s;|&<>]+)') or { return effects, segment }
	mut cleaned := segment
	for m in re.find_all(segment) {
		target := group_text(segment, &m, 1)
		if has_dynamic(target) {
			effects << Effect{
				kind:    effect_opaque
				command: segment.trim_space()
				reason:  "redirect target '${target}' is resolved at run time"
			}
		} else {
			effects << Effect{
				kind:    effect_write
				path:    target.trim('"\'')
				content: content
				reason:  'shell redirection'
			}
		}
	}
	cleaned = re.replace_all(segment, ' ')
	return effects, cleaned
}

// command_effects returns the effects of one simple command (no pipes, no
// sequencing).
fn command_effects(segment string, heredocs map[string]string) []Effect {
	seg := segment.trim_space()
	if seg == '' {
		return []
	}
	mut effects, cleaned := redirect_effects(seg, heredocs)

	mut tokens, ok := shell_split(cleaned)
	if !ok {
		// unbalanced quotes — the command cannot be read, so it cannot be
		// shown to respect anything
		effects << Effect{
			kind:    effect_opaque
			command: seg
			reason:  'command could not be parsed'
		}
		return effects
	}
	// strip leading VAR=value assignments
	assign_re := compile_regex(r'^[A-Za-z_][A-Za-z0-9_]*=') or { Regex{} }
	for tokens.len > 0 && assign_re.matches(tokens[0]) {
		tokens.delete(0)
	}
	if tokens.len == 0 {
		return effects
	}

	name := tokens[0].all_after_last('/')
	rest := tokens[1..].clone()

	// `echo secret > f` writes content as surely as write_file does;
	// without this a content rule would be blind to the commonest shell
	// write.
	if name in ['echo', 'printf'] {
		mut any_content := false
		for e in effects {
			if e.content != '' {
				any_content = true
			}
		}
		if !any_content {
			said := strip_flags(rest).join(' ')
			if said != '' {
				mut updated := []Effect{}
				for e in effects {
					if e.kind == effect_write {
						updated << Effect{
							kind:    e.kind
							path:    e.path
							content: said
							command: e.command
							reason:  e.reason
						}
					} else {
						updated << e
					}
				}
				effects = updated.clone()
			}
		}
	}

	effects << Effect{
		kind:    effect_exec
		command: seg
		reason:  "runs '${name}'"
	}

	// -- forms whose effects cannot be known ahead of time ----------------
	if name in eval_cmds {
		effects << Effect{
			kind:    effect_opaque
			command: seg
			reason:  '${name} executes constructed text'
		}
		return effects
	}
	if name in shells && '-c' in rest {
		effects << Effect{
			kind:    effect_opaque
			command: seg
			reason:  '${name} -c executes constructed text'
		}
		return effects
	}
	if name in interpreters && ('-c' in rest || '-e' in rest) {
		effects << Effect{
			kind:    effect_opaque
			command: seg
			reason:  '${name} runs inline code that may write anywhere'
		}
		return effects
	}
	if name in arbitrary_cmds {
		effects << Effect{
			kind:    effect_opaque
			command: seg
			reason:  '${name} can execute further commands'
		}
		return effects
	}

	args := strip_flags(rest)

	// -- known filesystem effects -----------------------------------------
	if name in deleters {
		for a in args {
			effects << Effect{
				kind:   effect_delete
				path:   a
				reason: '${name} removes it'
			}
		}
	} else if name in creators {
		for a in args {
			effects << Effect{
				kind:   effect_write
				path:   a
				reason: '${name} creates it'
			}
		}
	} else if name == 'mv' && args.len >= 2 {
		for a in args[..args.len - 1] {
			effects << Effect{
				kind:   effect_delete
				path:   a
				reason: 'mv moves it away'
			}
		}
		effects << Effect{
			kind:   effect_write
			path:   args.last()
			reason: 'mv target'
		}
	} else if name in ['cp', 'install', 'rsync'] && args.len >= 2 {
		effects << Effect{
			kind:   effect_write
			path:   args.last()
			reason: '${name} target'
		}
	} else if name == 'ln' && args.len >= 2 {
		effects << Effect{
			kind:   effect_write
			path:   args.last()
			reason: 'ln creates it'
		}
	} else if name == 'tee' {
		for a in args {
			effects << Effect{
				kind:   effect_write
				path:   a
				reason: 'tee writes it'
			}
		}
	} else if name == 'dd' {
		for t in rest {
			if t.starts_with('of=') {
				effects << Effect{
					kind:   effect_write
					path:   t[3..]
					reason: 'dd output'
				}
			}
		}
	} else if name == 'truncate' {
		for a in args {
			effects << Effect{
				kind:   effect_write
				path:   a
				reason: 'truncate resizes it'
			}
		}
	} else if name in ['chmod', 'chown', 'chgrp'] {
		if args.len > 1 {
			for a in args[1..] {
				effects << Effect{
					kind:   effect_write
					path:   a
					reason: '${name} alters it'
				}
			}
		}
	} else if name == 'sed' {
		mut in_place := false
		for t in rest {
			if t == '-i' || t.starts_with('-i.')
				|| (t.starts_with('-') && !t.starts_with('--') && t.contains('i')) {
				in_place = true
				break
			}
		}
		// sed -i edits in place; the first non-flag arg is the script
		if in_place && args.len > 1 {
			for a in args[1..] {
				effects << Effect{
					kind:   effect_write
					path:   a
					reason: 'sed -i edits in place'
				}
			}
		}
	}
	return effects
}

// derive_command_effects lists every effect a shell command line may have.
pub fn derive_command_effects(command string) []Effect {
	heredocs := heredoc_bodies(command)
	// a heredoc body is data, not commands — remove it before splitting
	mut stripped := command
	for _, body in heredocs {
		if body != '' {
			stripped = stripped.replace(body, '')
		}
	}
	mut out := []Effect{}
	for segment in split_segments(stripped) {
		out << command_effects(segment, heredocs)
	}
	return out
}

// ---------------------------------------------------------------------------
// Tool calls -> effects
// ---------------------------------------------------------------------------

const shell_tools = ['run_command', 'bg_shell', 'shell', 'bash', 'live_shell']

// patch_effects lists the writes implied by a unified diff.
//
// apply_patch edits any number of files in one call, so without this a diff
// is a route around every path and content clause. Targets come from the
// `+++ b/path` headers and the written content from the added lines, which
// is what a content rule must be matched against.
fn patch_effects(patch string) []Effect {
	mut effects := []Effect{}
	mut target := ''
	mut added := []string{}

	for line in split_lines(patch) {
		if line.starts_with('+++ ') {
			if target != '' {
				effects << Effect{
					kind:    effect_write
					path:    target
					content: added.join('\n')
					reason:  'apply_patch hunk'
				}
			}
			mut name := line[4..].all_before('\t').trim_space()
			if name.starts_with('a/') || name.starts_with('b/') {
				name = name[2..]
			}
			target = if name == '/dev/null' { '' } else { name }
			added = []
			continue
		}
		if line.starts_with('--- ') || line.starts_with('@@') {
			continue
		}
		if line.starts_with('+') && target != '' {
			added << line[1..]
		}
		// a removal still rewrites the file it lands in, which the write
		// effect above already covers
	}
	if target != '' {
		effects << Effect{
			kind:    effect_write
			path:    target
			content: added.join('\n')
			reason:  'apply_patch hunk'
		}
	}
	return effects
}

// named_tools are the tools whose effects derive() can name. A tool outside
// this set yields no effects, so path and content clauses do not reach it —
// that limit is real, and Covenant.unnamed_tools() reports it rather than
// letting it pass for coverage. Such a tool can still be constrained by
// name (forbid_tool).
pub const named_tools = ['run_command', 'bg_shell', 'shell', 'bash', 'live_shell',
	'write_file', 'edit_file', 'create_directory', 'delete_path', 'move_path',
	'copy_path', 'apply_patch']

// derive reduces one pending tool call to its effects.
pub fn derive(tool string, args map[string]json2.Any) []Effect {
	if tool in shell_tools {
		return derive_command_effects(jstr(args, 'command'))
	}
	match tool {
		'write_file' {
			return [Effect{
				kind:    effect_write
				path:    jstr(args, 'path')
				content: jstr(args, 'content')
				reason:  'write_file'
			}]
		}
		'edit_file' {
			return [Effect{
				kind:    effect_write
				path:    jstr(args, 'path')
				content: jstr(args, 'new_string')
				reason:  'edit_file'
			}]
		}
		'create_directory' {
			return [Effect{
				kind:   effect_write
				path:   jstr(args, 'path')
				reason: 'create_directory'
			}]
		}
		'delete_path' {
			return [Effect{
				kind:   effect_delete
				path:   jstr(args, 'path')
				reason: 'delete_path'
			}]
		}
		'move_path' {
			return [
				Effect{
					kind:   effect_delete
					path:   jstr(args, 'src')
					reason: 'move_path source'
				},
				Effect{
					kind:   effect_write
					path:   jstr(args, 'dst')
					reason: 'move_path target'
				},
			]
		}
		'copy_path' {
			return [Effect{
				kind:   effect_write
				path:   jstr(args, 'dst')
				reason: 'copy_path target'
			}]
		}
		'apply_patch' {
			return patch_effects(jstr(args, 'patch'))
		}
		else {
			return []
		}
	}
}
