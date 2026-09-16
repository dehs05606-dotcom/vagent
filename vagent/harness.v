module vagent

// harness.v — the Python harnesses, and the guarantee that they survive.
//
// Several analyses in this package borrow CPython rather than reimplement
// it: coverage needs sys.settrace, the taint and graph and mutation passes
// need the real `ast`, and the skill and synthesis gates have to judge Python
// with Python's own parser. Each of those modules embeds its analyser as a V
// string constant and writes it to a temp script at call time.
//
// That embedding is the fragile step, and it failed silently once. A V string
// literal processes escapes, so a `\b` inside a borrowed regex — a word
// boundary, in `\b(exec|eval|...)\b` — became an actual backspace byte, and
// the pattern quietly stopped matching anything. The gate still ran, still
// reported, and caught nothing. Nothing crashed; the check simply evaporated.
//
// So the harnesses are listed here and checked as a set: a control character
// that has no business in source code is a corrupted literal, and a harness
// that no longer parses as Python is a harness that will never judge
// anything. Both are caught by a test rather than by the next person to
// wonder why a safety gate never fires.

// embedded_pages is every large verbatim text this package carries that is
// NOT Python — today, the control tower's dashboard. It is checked for the
// same corruption, because a mangled escape in a script tag is just as
// invisible as one in a regex.
pub fn embedded_pages() map[string]string {
	return {
		'tower_page': tower_page
	}
}

// embedded_harnesses is every Python analyser this package carries, by name.
pub fn embedded_harnesses() map[string]string {
	return {
		'cov':    cov_harness
		'taint':  taint_harness
		'kgraph': kgraph_harness
		'mutate': mutate_harness
		'skills': skills_harness
		'synth':  synth_harness
		'pyfn':   pyfn_harness
	}
}

// harness_control_bytes is the offsets of any control character in a harness
// other than tab and newline. Source code has none; a literal that picked one
// up was mangled on its way into the binary.
pub fn harness_control_bytes(text string) []int {
	mut out := []int{}
	for i, c in text.bytes() {
		if c < 0x20 && c != `\n` && c != `\t` {
			out << i
		}
	}
	return out
}
