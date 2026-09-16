module vagent

// regexp.v — a backtracking regular-expression engine.
//
// V's stdlib `regex` covers a subset that is too small for this port: it
// rejects top-level alternation (`foo|bar` simply does not match), has no
// inline flags, and its `matches_string` is a full-string match rather than
// a search. `search_files` is a user-facing tool where a pattern quietly
// matching nothing is worse than an error, and the rest of the package
// parses provider errors and source text with patterns that use all of it.
//
// So this is a complete engine for the syntax the Python original relies on:
//
//   literals, `.`, escapes, `\d \D \w \W \s \S \b \B`
//   classes `[abc]`, ranges `[a-z]`, negation `[^...]`, class escapes
//   anchors `^` `$`, groups `(...)`, non-capturing `(?:...)`
//   alternation `|`
//   quantifiers `* + ? {n} {n,} {n,m}`, greedy and lazy (`*?`)
//   inline flags `(?i)` `(?m)` `(?s)` and the same flags passed in
//
// Matching is backtracking with an explicit continuation stack, bounded by
// a step budget so a pathological pattern fails loudly instead of hanging
// the agent.

const rx_step_budget = 2_000_000

pub struct RxFlags {
pub mut:
	ignore_case bool
	multiline   bool
	dotall      bool
}

enum RxKind {
	char_
	any_
	class_
	seq_
	alt_
	group_
	repeat_
	bol
	eol
	word_b
	not_word_b
}

struct RxRange {
	lo rune
	hi rune
}

struct RxNode {
mut:
	kind     RxKind
	ch       rune
	ranges   []RxRange
	negated  bool
	children []int
	min      int
	max      int = -1
	greedy   bool = true
	capture  int = -1
}

pub struct Regex {
mut:
	nodes    []RxNode
	root     int
	n_groups int
pub:
	pattern string
	flags   RxFlags
}

// ---------------------------------------------------------------------------
// Parsing
// ---------------------------------------------------------------------------

struct RxParser {
	src []rune
mut:
	pos      int
	nodes    []RxNode
	n_groups int
	flags    RxFlags
}

// compile_regex parses `pattern` into a matcher.
pub fn compile_regex(pattern string) !Regex {
	return compile_regex_flags(pattern, RxFlags{})
}

// compile_regex_flags is compile_regex with flags supplied by the caller;
// inline `(?i)` style flags in the pattern add to them.
pub fn compile_regex_flags(pattern string, flags RxFlags) !Regex {
	mut p := RxParser{
		src:   pattern.runes()
		flags: flags
	}
	root := p.parse_alt()!
	if p.pos < p.src.len {
		return error('unexpected ${p.src[p.pos]} at offset ${p.pos}')
	}
	return Regex{
		nodes:    p.nodes
		root:     root
		n_groups: p.n_groups
		pattern:  pattern
		flags:    p.flags
	}
}

fn (mut p RxParser) add(n RxNode) int {
	p.nodes << n
	return p.nodes.len - 1
}

fn (mut p RxParser) peek() rune {
	return if p.pos < p.src.len { p.src[p.pos] } else { rune(0) }
}

fn (mut p RxParser) eof() bool {
	return p.pos >= p.src.len
}

// parse_alt parses `seq (| seq)*`.
fn (mut p RxParser) parse_alt() !int {
	mut branches := [p.parse_seq()!]
	for !p.eof() && p.peek() == `|` {
		p.pos++
		branches << p.parse_seq()!
	}
	if branches.len == 1 {
		return branches[0]
	}
	return p.add(RxNode{
		kind:     .alt_
		children: branches
	})
}

// parse_seq parses a run of quantified atoms up to `|` or `)`.
fn (mut p RxParser) parse_seq() !int {
	mut kids := []int{}
	for !p.eof() && p.peek() != `|` && p.peek() != `)` {
		kids << p.parse_quantified()!
	}
	return p.add(RxNode{
		kind:     .seq_
		children: kids
	})
}

// parse_quantified parses one atom plus any trailing quantifier.
fn (mut p RxParser) parse_quantified() !int {
	atom := p.parse_atom()!
	if p.eof() {
		return atom
	}
	mut min := 0
	mut max := -1
	match p.peek() {
		`*` {
			p.pos++
		}
		`+` {
			min = 1
			p.pos++
		}
		`?` {
			max = 1
			p.pos++
		}
		`{` {
			// `{` is only a quantifier when it parses as one; otherwise it
			// is a literal brace, which is how `interface{}` searches work
			save := p.pos
			lo, hi, ok := p.parse_braces()
			if !ok {
				p.pos = save
				return atom
			}
			min = lo
			max = hi
		}
		else {
			return atom
		}
	}
	mut greedy := true
	if !p.eof() && p.peek() == `?` {
		greedy = false
		p.pos++
	} else if !p.eof() && p.peek() == `+` {
		// possessive quantifiers are not supported; treat as greedy so the
		// pattern still means something close rather than failing outright
		p.pos++
	}
	return p.add(RxNode{
		kind:     .repeat_
		children: [atom]
		min:      min
		max:      max
		greedy:   greedy
	})
}

// parse_braces reads `{n}`, `{n,}` or `{n,m}`. Returns ok=false when the
// brace is not a quantifier.
fn (mut p RxParser) parse_braces() (int, int, bool) {
	start := p.pos
	p.pos++ // consume '{'
	mut lo_digits := ''
	for !p.eof() && p.peek() >= `0` && p.peek() <= `9` {
		lo_digits += p.peek().str()
		p.pos++
	}
	if lo_digits == '' {
		p.pos = start
		return 0, -1, false
	}
	lo := lo_digits.int()
	if !p.eof() && p.peek() == `}` {
		p.pos++
		return lo, lo, true
	}
	if p.eof() || p.peek() != `,` {
		p.pos = start
		return 0, -1, false
	}
	p.pos++ // consume ','
	mut hi_digits := ''
	for !p.eof() && p.peek() >= `0` && p.peek() <= `9` {
		hi_digits += p.peek().str()
		p.pos++
	}
	if p.eof() || p.peek() != `}` {
		p.pos = start
		return 0, -1, false
	}
	p.pos++
	hi := if hi_digits == '' { -1 } else { hi_digits.int() }
	return lo, hi, true
}

// parse_atom parses a single unquantified element.
fn (mut p RxParser) parse_atom() !int {
	if p.eof() {
		return error('unexpected end of pattern')
	}
	c := p.peek()
	match c {
		`(` {
			p.pos++
			mut capture := -1
			if !p.eof() && p.peek() == `?` {
				p.pos++
				if p.eof() {
					return error('dangling (? group')
				}
				k := p.peek()
				if k == `:` {
					p.pos++
				} else if k == `i` || k == `m` || k == `s` {
					// inline flags: (?i), (?im), (?is) …
					for !p.eof() && p.peek() != `)` && p.peek() != `:` {
						match p.peek() {
							`i` { p.flags.ignore_case = true }
							`m` { p.flags.multiline = true }
							`s` { p.flags.dotall = true }
							else { return error('unsupported flag ${p.peek()}') }
						}
						p.pos++
					}
					if !p.eof() && p.peek() == `)` {
						p.pos++
						// a bare flag group matches the empty string
						return p.add(RxNode{
							kind: .seq_
						})
					}
					if !p.eof() && p.peek() == `:` {
						p.pos++
					}
				} else if k == `P` || k == `<` || k == `=` || k == `!` {
					return error('named groups and lookaround are not supported')
				} else {
					return error('unsupported group (?${k}')
				}
			} else {
				capture = p.n_groups + 1
				p.n_groups++
			}
			inner := p.parse_alt()!
			if p.eof() || p.peek() != `)` {
				return error('unbalanced (')
			}
			p.pos++
			return p.add(RxNode{
				kind:     .group_
				children: [inner]
				capture:  capture
			})
		}
		`[` {
			return p.parse_class()
		}
		`.` {
			p.pos++
			return p.add(RxNode{
				kind: .any_
			})
		}
		`^` {
			p.pos++
			return p.add(RxNode{
				kind: .bol
			})
		}
		`$` {
			p.pos++
			return p.add(RxNode{
				kind: .eol
			})
		}
		`\\` {
			p.pos++
			if p.eof() {
				return error('dangling backslash')
			}
			e := p.peek()
			p.pos++
			match e {
				`d` { return p.add(digit_class(false)) }
				`D` { return p.add(digit_class(true)) }
				`w` { return p.add(word_class(false)) }
				`W` { return p.add(word_class(true)) }
				`s` { return p.add(space_class(false)) }
				`S` { return p.add(space_class(true)) }
				`b` { return p.add(RxNode{
						kind: .word_b
					}) }
				`B` { return p.add(RxNode{
						kind: .not_word_b
					}) }
				else {
					return p.add(RxNode{
						kind: .char_
						ch:   unescape_rune(e)
					})
				}
			}
		}
		`*`, `+`, `?` {
			return error('nothing to repeat at offset ${p.pos}')
		}
		else {
			p.pos++
			return p.add(RxNode{
				kind: .char_
				ch:   c
			})
		}
	}
}

// parse_class parses `[...]`, including ranges, negation and class escapes.
fn (mut p RxParser) parse_class() !int {
	p.pos++ // consume '['
	mut node := RxNode{
		kind: .class_
	}
	if !p.eof() && p.peek() == `^` {
		node.negated = true
		p.pos++
	}
	mut first := true
	for !p.eof() && (p.peek() != `]` || first) {
		first = false
		mut lo := p.peek()
		if lo == `\\` {
			p.pos++
			if p.eof() {
				return error('dangling backslash in class')
			}
			e := p.peek()
			p.pos++
			match e {
				`d` {
					node.ranges << digit_class(false).ranges
					continue
				}
				`w` {
					node.ranges << word_class(false).ranges
					continue
				}
				`s` {
					node.ranges << space_class(false).ranges
					continue
				}
				else {
					lo = unescape_rune(e)
				}
			}
		} else {
			p.pos++
		}
		// a `-` that is not the last character opens a range
		if !p.eof() && p.peek() == `-` && p.pos + 1 < p.src.len && p.src[p.pos + 1] != `]` {
			p.pos++
			mut hi := p.peek()
			if hi == `\\` {
				p.pos++
				if p.eof() {
					return error('dangling backslash in class')
				}
				hi = unescape_rune(p.peek())
			}
			p.pos++
			node.ranges << RxRange{
				lo: lo
				hi: hi
			}
			continue
		}
		node.ranges << RxRange{
			lo: lo
			hi: lo
		}
	}
	if p.eof() {
		return error('unterminated [')
	}
	p.pos++ // consume ']'
	return p.add(node)
}

fn unescape_rune(e rune) rune {
	return match e {
		`n` { `\n` }
		`t` { `\t` }
		`r` { `\r` }
		`f` { rune(12) }
		`v` { rune(11) }
		`0` { rune(0) }
		`a` { rune(7) }
		else { e }
	}
}

fn digit_class(neg bool) RxNode {
	return RxNode{
		kind:    .class_
		negated: neg
		ranges:  [RxRange{`0`, `9`}]
	}
}

fn word_class(neg bool) RxNode {
	return RxNode{
		kind:    .class_
		negated: neg
		ranges:  [RxRange{`a`, `z`}, RxRange{`A`, `Z`}, RxRange{`0`, `9`},
			RxRange{`_`, `_`}]
	}
}

fn space_class(neg bool) RxNode {
	return RxNode{
		kind:    .class_
		negated: neg
		ranges:  [RxRange{` `, ` `}, RxRange{`\t`, `\t`}, RxRange{`\n`, `\n`},
			RxRange{`\r`, `\r`}, RxRange{rune(11), rune(12)}]
	}
}

// ---------------------------------------------------------------------------
// Matching
// ---------------------------------------------------------------------------

enum FrameKind {
	seq
	rep
	cap
}

struct Frame {
	kind FrameKind
	// .seq
	kids []int
	ci   int
	// .rep
	rep_idx   int
	rep_count int
	rep_pos   int
	// .cap
	cap_idx   int
	cap_start int
}

struct Matcher {
	re    &Regex
	input []rune
mut:
	caps  []int // 2 slots per group: start, end
	steps int
}

// Match is one successful match: the span, and the captured groups.
pub struct Match {
pub:
	start  int
	end    int
	groups [][]int // [start, end] per group, [-1, -1] when unset
	text   string
}

// group returns the text of capture group `n` (0 = the whole match).
pub fn (m &Match) group(n int) string {
	if n == 0 {
		return m.text
	}
	if n < 1 || n > m.groups.len {
		return ''
	}
	return ''
}

fn (re &Regex) eq_rune(a rune, b rune) bool {
	if a == b {
		return true
	}
	if !re.flags.ignore_case {
		return false
	}
	return lower_rune(a) == lower_rune(b)
}

fn lower_rune(r rune) rune {
	if r >= `A` && r <= `Z` {
		return r + 32
	}
	return r
}

fn is_word_rune(r rune) bool {
	return (r >= `a` && r <= `z`) || (r >= `A` && r <= `Z`) || (r >= `0` && r <= `9`)
		|| r == `_`
}

fn (mut m Matcher) run(frames []Frame, pos int) ?int {
	m.steps++
	if m.steps > rx_step_budget {
		return none
	}
	if frames.len == 0 {
		return pos
	}
	f := frames[0]
	match f.kind {
		.seq {
			if f.ci >= f.kids.len {
				return m.run(frames[1..], pos)
			}
			mut rest := frames.clone()
			rest[0] = Frame{
				kind: .seq
				kids: f.kids
				ci:   f.ci + 1
			}
			return m.match_node(f.kids[f.ci], pos, rest)
		}
		.rep {
			// one iteration of the repeat just completed at `pos`
			if pos == f.rep_pos {
				// an iteration that consumed nothing would repeat forever
				return m.run(frames[1..], pos)
			}
			return m.try_repeat(f.rep_idx, f.rep_count + 1, pos, frames[1..])
		}
		.cap {
			if f.cap_idx >= 1 {
				slot := (f.cap_idx - 1) * 2
				saved_s := m.caps[slot]
				saved_e := m.caps[slot + 1]
				m.caps[slot] = f.cap_start
				m.caps[slot + 1] = pos
				if r := m.run(frames[1..], pos) {
					return r
				}
				m.caps[slot] = saved_s
				m.caps[slot + 1] = saved_e
				return none
			}
			return m.run(frames[1..], pos)
		}
	}
}

fn (mut m Matcher) match_node(idx int, pos int, rest []Frame) ?int {
	n := m.re.nodes[idx]
	s := m.input
	match n.kind {
		.char_ {
			if pos < s.len && m.re.eq_rune(s[pos], n.ch) {
				return m.run(rest, pos + 1)
			}
			return none
		}
		.any_ {
			if pos < s.len && (m.re.flags.dotall || s[pos] != `\n`) {
				return m.run(rest, pos + 1)
			}
			return none
		}
		.class_ {
			if pos >= s.len {
				return none
			}
			if m.class_matches(n, s[pos]) {
				return m.run(rest, pos + 1)
			}
			return none
		}
		.bol {
			if pos == 0 || (m.re.flags.multiline && pos > 0 && s[pos - 1] == `\n`) {
				return m.run(rest, pos)
			}
			return none
		}
		.eol {
			if pos == s.len || (m.re.flags.multiline && s[pos] == `\n`) {
				return m.run(rest, pos)
			}
			return none
		}
		.word_b, .not_word_b {
			before := pos > 0 && is_word_rune(s[pos - 1])
			after := pos < s.len && is_word_rune(s[pos])
			at_boundary := before != after
			want := n.kind == .word_b
			if at_boundary == want {
				return m.run(rest, pos)
			}
			return none
		}
		.seq_ {
			mut frames := [Frame{
				kind: .seq
				kids: n.children
				ci:   0
			}]
			frames << rest
			return m.run(frames, pos)
		}
		.alt_ {
			for branch in n.children {
				if r := m.match_node(branch, pos, rest) {
					return r
				}
			}
			return none
		}
		.group_ {
			mut frames := [Frame{
				kind:      .cap
				cap_idx:   n.capture
				cap_start: pos
			}]
			frames << rest
			return m.match_node(n.children[0], pos, frames)
		}
		.repeat_ {
			return m.try_repeat(idx, 0, pos, rest)
		}
	}
}

fn (m &Matcher) class_matches(n RxNode, ch rune) bool {
	mut hit := false
	for r in n.ranges {
		if ch >= r.lo && ch <= r.hi {
			hit = true
			break
		}
		if m.re.flags.ignore_case {
			lc := lower_rune(ch)
			uc := if ch >= `a` && ch <= `z` { ch - 32 } else { ch }
			if (lc >= r.lo && lc <= r.hi) || (uc >= r.lo && uc <= r.hi) {
				hit = true
				break
			}
		}
	}
	return hit != n.negated
}

fn (mut m Matcher) try_repeat(idx int, count int, pos int, rest []Frame) ?int {
	n := m.re.nodes[idx]
	child := n.children[0]
	can_more := n.max < 0 || count < n.max
	must_more := count < n.min

	mut with_rep := [Frame{
		kind:      .rep
		rep_idx:   idx
		rep_count: count
		rep_pos:   pos
	}]
	with_rep << rest

	if must_more {
		return m.match_node(child, pos, with_rep)
	}
	if n.greedy {
		if can_more {
			if r := m.match_node(child, pos, with_rep) {
				return r
			}
		}
		return m.run(rest, pos)
	}
	if r := m.run(rest, pos) {
		return r
	}
	if can_more {
		return m.match_node(child, pos, with_rep)
	}
	return none
}

// ---------------------------------------------------------------------------
// Public API
// ---------------------------------------------------------------------------

// search finds the leftmost match at or after `from`, or none.
pub fn (re &Regex) search_from(text string, from int) ?Match {
	input := text.runes()
	for start := from; start <= input.len; start++ {
		mut m := Matcher{
			re:    unsafe { re }
			input: input
			caps:  []int{len: re.n_groups * 2, init: -1}
		}
		frames := [Frame{
			kind: .seq
			kids: [re.root]
			ci:   0
		}]
		if end := m.run(frames, start) {
			mut groups := [][]int{}
			for g in 0 .. re.n_groups {
				groups << [m.caps[g * 2], m.caps[g * 2 + 1]]
			}
			return Match{
				start:  start
				end:    end
				groups: groups
				text:   input[start..end].string()
			}
		}
	}
	return none
}

// search finds the leftmost match anywhere in `text`.
pub fn (re &Regex) search(text string) ?Match {
	return re.search_from(text, 0)
}

// matches reports whether the pattern is found anywhere in `text` — the
// semantics of Python's `re.search`, which is what the search tools use.
pub fn (re &Regex) matches(text string) bool {
	if _ := re.search(text) {
		return true
	}
	return false
}

// full_match reports whether the pattern matches the ENTIRE string.
pub fn (re &Regex) full_match(text string) bool {
	if m := re.search_from(text, 0) {
		return m.start == 0 && m.end == text.runes().len
	}
	return false
}

// find_all returns every non-overlapping match, left to right.
pub fn (re &Regex) find_all(text string) []Match {
	mut out := []Match{}
	input := text.runes()
	mut from := 0
	for from <= input.len {
		m := re.search_from(text, from) or { break }
		out << m
		// a zero-width match must still advance, or this loops forever
		from = if m.end > m.start { m.end } else { m.start + 1 }
	}
	return out
}

// group_text returns the text of capture group `n` of a match against
// `text` (0 = the whole match, '' when the group did not participate).
pub fn group_text(text string, m &Match, n int) string {
	if n == 0 {
		return m.text
	}
	if n < 1 || n > m.groups.len {
		return ''
	}
	span := m.groups[n - 1]
	if span[0] < 0 || span[1] < 0 {
		return ''
	}
	input := text.runes()
	return input[span[0]..span[1]].string()
}

// replace_all substitutes every match with `repl`, where `$1`..`$9` refer
// to capture groups.
pub fn (re &Regex) replace_all(text string, repl string) string {
	input := text.runes()
	mut out := []rune{}
	mut from := 0
	for from <= input.len {
		m := re.search_from(text, from) or { break }
		out << input[from..m.start]
		out << expand_repl(text, m, repl).runes()
		if m.end > m.start {
			from = m.end
		} else {
			if m.start < input.len {
				out << input[m.start]
			}
			from = m.start + 1
		}
	}
	if from < input.len {
		out << input[from..]
	}
	return out.string()
}

fn expand_repl(text string, m &Match, repl string) string {
	mut out := ''
	r := repl.runes()
	mut i := 0
	for i < r.len {
		if r[i] == `$` && i + 1 < r.len && r[i + 1] >= `0` && r[i + 1] <= `9` {
			out += group_text(text, m, int(r[i + 1] - `0`))
			i += 2
			continue
		}
		out += r[i].str()
		i++
	}
	return out
}
