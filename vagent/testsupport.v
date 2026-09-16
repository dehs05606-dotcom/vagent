module vagent

import os

// testsupport.v — helpers shared by the module's _test.v files.
//
// V compiles each _test.v file as its own program, so a helper defined in
// one test file is not visible from another. These two live in a regular
// module file so every test can use them.

// tmp_log_path returns a fresh, empty path under the system temp dir for a
// throwaway event log.
pub fn tmp_log_path(name string) string {
	dir := os.join_path(os.temp_dir(), 'vagent-selftest-${os.getpid()}')
	os.mkdir_all(dir) or {}
	p := os.join_path(dir, name)
	os.rm(p) or {}
	return p
}

// texts_of extracts the `text` field of every user.message event.
pub fn texts_of(evs []Event) []string {
	mut out := []string{}
	for e in evs {
		if e.typ == 'user.message' {
			out << jstr(e.data, 'text')
		}
	}
	return out
}

// LineCollector captures streamed tool output for assertions.
//
// V closures capture `mut` locals by value: state mutated inside the
// closure persists across ITS OWN calls, but never propagates back to the
// enclosing scope. Capturing a pointer to a heap struct is what actually
// carries the lines out, so every streaming sink in this package — tests
// and TUI alike — hands the closure a `&` receiver rather than a `mut`
// local.
@[heap]
pub struct LineCollector {
pub mut:
	lines   []string
	tagged  []string
}

pub fn (c &LineCollector) sink() OutputSink {
	return OutputSink(fn [c] (line string, stream string) {
		unsafe {
			c.lines << line
			c.tagged << '${stream}:${line}'
		}
	})
}
