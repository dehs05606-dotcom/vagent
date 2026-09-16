module vagent

import x.json2

// healer.v — the self-healing root-cause engine.
//
// When a command or a check fails, the healer does not merely report the
// error. It runs a closed loop: CAPTURE the error, CLASSIFY it against a
// root-cause taxonomy, propose a deterministic FIX, apply it, RETRY the
// original check for proof, and seal the LESSON so the same failure is
// recognised instantly next time.
//
// The rules are mechanical — there is no model anywhere in this loop:
//
//   * Classification is a pattern table over the error text. An unknown
//     error is classified 'unknown' and the healer says so. It never
//     guesses, because a confident wrong root cause sends the next hour of
//     work in the wrong direction.
//   * A fix is only ever applied through a caller-supplied fixer. The healer
//     itself never writes a file. With no fixer it classifies and records
//     the lesson, and nothing else.
//   * Proof, not promise: after a fix, the ORIGINAL failing check is re-run,
//     and only a green re-run seals the lesson as healed.
//   * Every stage is an event — heal.captured, heal.hypothesis, heal.patch,
//     heal.retry, heal.lesson — so the healing history replays like
//     everything else.

// TaxonomyEntry is one root cause: the pattern that recognises it and the
// deterministic suggestion that follows from it.
struct TaxonomyEntry {
	pattern    string
	root_cause string
	suggestion string
}

// The taxonomy is ordered and the first match wins, so the patterns are kept
// cheap and specific. A broad pattern placed early would swallow the precise
// ones below it and report a root cause that is technically true and useless.
const heal_taxonomy = [
	TaxonomyEntry{r'(?i)ModuleNotFoundError|No module named', 'missing_module', 'install the missing module or fix the import path'},
	TaxonomyEntry{r'(?i)FileNotFoundError|No such file or directory', 'missing_file', 'create the file or fix the path'},
	TaxonomyEntry{r'(?i)PermissionError', 'permission_denied', 'check file permissions / run with appropriate access'},
	TaxonomyEntry{r'(?i)ConnectionError|Connection refused|Name or service not known|getaddrinfo', 'network_unreachable', 'check network / target host availability'},
	TaxonomyEntry{r'(?i)TimeoutError|timed out', 'timeout', 'raise the timeout or optimise the slow step'},
	TaxonomyEntry{r'(?i)SyntaxError', 'syntax_error', 'fix the syntax at the reported line'},
	TaxonomyEntry{r'(?i)IndentationError', 'indentation_error', 'fix the indentation at the reported line'},
	TaxonomyEntry{r'(?i)NameError', 'undefined_name', 'define or import the missing name'},
	TaxonomyEntry{r'(?i)TypeError', 'type_mismatch', 'fix the argument types / signature'},
	TaxonomyEntry{r'(?i)KeyError', 'missing_key', 'use a checked lookup or ensure the key exists'},
	TaxonomyEntry{r'(?i)AttributeError', 'missing_attribute', 'check the object type / attribute name'},
	TaxonomyEntry{r'(?i)ZeroDivisionError', 'division_by_zero', 'guard the divisor against zero'},
	TaxonomyEntry{r'(?i)AssertionError', 'assertion_failed', 'the behaviour under test is wrong — inspect the assertion'},
	TaxonomyEntry{r'(?i)command not found|not recognized', 'missing_binary', 'install the tool or fix PATH'},
	TaxonomyEntry{r'(?i)out of memory|MemoryError|Cannot allocate', 'out_of_memory', 'reduce memory use or raise the limit'},
	TaxonomyEntry{r'(?i)rate limit|429|too many requests', 'rate_limited', 'back off and retry with delay'},
]

pub struct Diagnosis {
pub:
	root_cause string
	suggestion string
	// the pattern text that matched
	matched string
	// the excerpt of the error the match was read from
	evidence string
}

pub fn (d &Diagnosis) to_json() map[string]json2.Any {
	return {
		'root_cause': json2.Any(d.root_cause)
		'suggestion': json2.Any(d.suggestion)
		'matched':    json2.Any(d.matched)
		'evidence':   json2.Any(clip_plain(d.evidence, 300))
	}
}

// classify_error matches an error against the taxonomy. The first match wins,
// and no match is an honest 'unknown' rather than the nearest guess.
//
// The patterns are compiled on each call. The table is sixteen entries long
// and this only runs on a failure path, so a cache would buy nothing and
// would have to be invalidated when the taxonomy grows.
pub fn classify_error(error_text string) Diagnosis {
	text := error_text
	for entry in heal_taxonomy {
		re := compile_regex(entry.pattern) or { continue }
		m := re.search(text) or { continue }
		mut lo := m.start - 40
		if lo < 0 {
			lo = 0
		}
		mut hi := m.end + 80
		if hi > text.len {
			hi = text.len
		}
		return Diagnosis{
			root_cause: entry.root_cause
			suggestion: entry.suggestion
			matched:    entry.pattern
			evidence:   text[lo..hi]
		}
	}
	return Diagnosis{
		root_cause: 'unknown'
		suggestion: 'no known pattern — inspect the error manually'
		evidence:   clip_plain(text, 200)
	}
}

// -- the healer ---------------------------------------------------------------

pub struct HealReport {
pub mut:
	error       string
	diagnosis   Diagnosis
	fix_applied bool
	fix_result  string
	retried     bool
	healed      bool
	lesson      string
}

pub fn (r &HealReport) to_json() map[string]json2.Any {
	mut d := r.diagnosis.to_json()
	d['error'] = json2.Any(clip_plain(r.error, 300))
	d['fix_applied'] = json2.Any(r.fix_applied)
	d['fix_result'] = json2.Any(clip_plain(r.fix_result, 200))
	d['retried'] = json2.Any(r.retried)
	d['healed'] = json2.Any(r.healed)
	d['lesson'] = json2.Any(clip_plain(r.lesson, 200))
	return d
}

// Fixer applies a suggested fix. It is caller-supplied, so the healer itself
// never mutates anything.
pub type Fixer = fn (diagnosis &Diagnosis, context string) !string

// Recheck re-runs the ORIGINAL failing check and reports (ok, error text).
pub type Recheck = fn () !(bool, string)

@[heap]
pub struct Healer {
pub mut:
	log     &EventLog
	fixer   Fixer   = unsafe { nil }
	recheck Recheck = unsafe { nil }
}

pub fn new_healer(log &EventLog, fixer Fixer, recheck Recheck) &Healer {
	return &Healer{
		log:     unsafe { log }
		fixer:   fixer
		recheck: recheck
	}
}

// new_observing_healer classifies and records, and fixes nothing.
pub fn new_observing_healer(log &EventLog) &Healer {
	return &Healer{
		log: unsafe { log }
	}
}

// heal runs the full capture → classify → fix → retry → lesson loop.
pub fn (mut h Healer) heal(error_text string, context string) HealReport {
	diag := classify_error(error_text)
	mut captured := diag.to_json()
	captured['error'] = json2.Any(clip_plain(error_text, 300))
	captured['context'] = json2.Any(clip_plain(context, 200))
	h.log.append('heal.captured', captured, AppendOpts{ actor: 'healer' })

	mut report := HealReport{
		error:     error_text
		diagnosis: diag
	}
	h.log.append('heal.hypothesis', {
		'root_cause': json2.Any(diag.root_cause)
		'suggestion': json2.Any(diag.suggestion)
	}, AppendOpts{ actor: 'healer' })

	// A fix is applied only when one is available AND the cause is known.
	// Applying the "fix" for an unknown cause would be acting on a guess,
	// which is the one thing this engine exists not to do.
	if h.fixer != unsafe { nil } && diag.root_cause != 'unknown' {
		fix_result := h.fixer(&diag, context) or { 'ERROR: ${err.msg()}' }
		report.fix_applied = true
		report.fix_result = fix_result
		h.log.append('heal.patch', {
			'root_cause': json2.Any(diag.root_cause)
			'result':     json2.Any(clip_plain(fix_result, 200))
		}, AppendOpts{ actor: 'healer' })

		// proof: re-run the original check
		if h.recheck != unsafe { nil } {
			ok, retry_err := h.recheck() or { false, err.msg() }
			report.retried = true
			report.healed = ok
			h.log.append('heal.retry', {
				'ok':    json2.Any(ok)
				'error': json2.Any(clip_plain(retry_err, 200))
			}, AppendOpts{ actor: 'healer' })
		}
	}

	report.lesson = heal_lesson(&report)
	h.log.append('heal.lesson', {
		'root_cause': json2.Any(diag.root_cause)
		'healed':     json2.Any(report.healed)
		'lesson':     json2.Any(report.lesson)
	}, AppendOpts{ actor: 'healer' })
	return report
}

fn heal_lesson(report &HealReport) string {
	d := report.diagnosis
	if report.healed {
		return "${d.root_cause}: auto-healed via '${d.suggestion}'"
	}
	if report.fix_applied {
		return '${d.root_cause}: fix attempted but check still fails — ' + 'needs a different approach'
	}
	return '${d.root_cause}: ${d.suggestion}'
}

// -- projections --------------------------------------------------------------

pub fn (mut h Healer) lessons() []Rec {
	st := fold(mut h.log, h.log.branch)
	return st.heal_events.filter(jstr(it, 'type') == 'heal.lesson')
}

// known_cause reports whether this root cause has been seen AND healed
// before — instant recognition from the lesson ledger.
pub fn (mut h Healer) known_cause(error_text string) bool {
	cause := classify_error(error_text).root_cause
	for l in h.lessons() {
		if jstr(l, 'root_cause') == cause && jbool(l, 'healed') {
			return true
		}
	}
	return false
}

pub struct HealStats {
pub mut:
	captured int
	healed   int
	by_cause map[string]int
}

pub fn (mut h Healer) stats() HealStats {
	st := fold(mut h.log, h.log.branch)
	mut out := HealStats{}
	for e in st.heal_events {
		match jstr(e, 'type') {
			'heal.captured' {
				out.captured++
				mut cause := jstr(e, 'root_cause')
				if cause == '' {
					cause = 'unknown'
				}
				out.by_cause[cause] = out.by_cause[cause] + 1
			}
			'heal.lesson' {
				if jbool(e, 'healed') {
					out.healed++
				}
			}
			else {}
		}
	}
	return out
}

pub fn (mut h Healer) format_status() string {
	s := h.stats()
	mut lines := [
		'HEALER — self-healing root-cause engine',
		'  captured ${s.captured}   healed ${s.healed}',
	]
	// most frequent first; an alphabetical tiebreak keeps two runs over one
	// ledger reporting the same order
	mut causes := s.by_cause.keys()
	causes.sort()
	causes.sort_with_compare(fn [s] (a &string, b &string) int {
		na := s.by_cause[*a] or { 0 }
		nb := s.by_cause[*b] or { 0 }
		if na != nb {
			return nb - na
		}
		return if *a < *b {
			-1
		} else if *a > *b { 1 } else { 0 }
	})
	mut head := causes.clone()
	if head.len > 8 {
		head = head[..8].clone()
	}
	for cause in head {
		lines << '    ' + pad_width(cause, 22) + ' ×${s.by_cause[cause]}'
	}
	return lines.join('\n')
}
