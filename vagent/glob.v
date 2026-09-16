module vagent

import os

// glob.v — filename matching, the V stand-in for Python's `fnmatch` and
// `pathlib.Path.glob`.
//
// Two different matchers live here because the Python original uses two:
//
//   * fnmatch_name  — `*` matches anything at all, including a separator.
//     search_files() uses it to filter bare filenames against '*.py'.
//   * glob_match    — a path matcher where `*` stops at a separator and
//     `**` spans directories, which is what '**/*.py' means to Path.glob.
//
// Collapsing them into one matcher would quietly change which files each
// tool sees, so they stay distinct.

// fnmatch_name reports whether `name` matches a shell-style pattern.
// Supports *, ?, [seq] and [!seq]. `*` crosses separators.
pub fn fnmatch_name(name string, pattern string) bool {
	return match_at(name.runes(), 0, pattern.runes(), 0, true)
}

// glob_match reports whether a slash-separated `path` matches a glob
// pattern in which `*` and `?` never cross a separator, while `**` does.
pub fn glob_match(path string, pattern string) bool {
	return match_at(path.runes(), 0, pattern.runes(), 0, false)
}

// match_at matches `p[pi..]` against `s[si..]`.
//
// `stars_cross_sep` is the one behavioural switch between fnmatch and glob
// semantics: when false, a single `*` and a `?` stop at a `/`, and only a
// `**` may span directories.
fn match_at(s []rune, si_in int, p []rune, pi_in int, stars_cross_sep bool) bool {
	mut si := si_in
	mut pi := pi_in
	for pi < p.len {
		c := p[pi]
		match c {
			`*` {
				// decide the star's reach before consuming it
				mut next_pi := pi + 1
				mut unrestricted := stars_cross_sep
				if !stars_cross_sep && next_pi < p.len && p[next_pi] == `*` {
					unrestricted = true
					next_pi++
					// `**/` also matches zero directories, so try skipping
					// the separator outright before letting the star eat
					if next_pi < p.len && p[next_pi] == `/` {
						if match_at(s, si, p, next_pi + 1, stars_cross_sep) {
							return true
						}
					}
				}
				// try every split point, shortest first
				mut k := si
				for {
					if match_at(s, k, p, next_pi, stars_cross_sep) {
						return true
					}
					if k >= s.len {
						return false
					}
					if !unrestricted && s[k] == `/` {
						return false
					}
					k++
				}
				return false
			}
			`?` {
				if si >= s.len {
					return false
				}
				if !stars_cross_sep && s[si] == `/` {
					return false
				}
				si++
				pi++
			}
			`[` {
				if si >= s.len {
					return false
				}
				matched, after := match_class(s[si], p, pi)
				if after == pi {
					// unterminated or empty class — '[' is a literal
					if s[si] != `[` {
						return false
					}
					si++
					pi++
					continue
				}
				if !matched {
					return false
				}
				si++
				pi = after
			}
			`\\` {
				// an escaped metacharacter matches itself
				if pi + 1 >= p.len {
					if si >= s.len || s[si] != `\\` {
						return false
					}
					si++
					pi++
					continue
				}
				if si >= s.len || s[si] != p[pi + 1] {
					return false
				}
				si++
				pi += 2
			}
			else {
				if si >= s.len || s[si] != c {
					return false
				}
				si++
				pi++
			}
		}
	}
	return si == s.len
}

// match_class matches a [seq] / [!seq] character class, returning whether
// the rune matched and the pattern index just past the class. When the
// class is malformed the returned index equals `pi`, telling the caller to
// treat '[' as a literal — which is what fnmatch does.
fn match_class(ch rune, p []rune, pi int) (bool, int) {
	mut i := pi + 1
	if i >= p.len {
		return false, pi
	}
	mut negated := false
	if p[i] == `!` || p[i] == `^` {
		negated = true
		i++
	}
	mut matched := false
	mut first := true
	for i < p.len && (p[i] != `]` || first) {
		first = false
		if i + 2 < p.len && p[i + 1] == `-` && p[i + 2] != `]` {
			if ch >= p[i] && ch <= p[i + 2] {
				matched = true
			}
			i += 3
			continue
		}
		if p[i] == ch {
			matched = true
		}
		i++
	}
	if i >= p.len {
		return false, pi // unterminated class
	}
	return matched != negated, i + 1
}

// ---------------------------------------------------------------------------
// Directory walking
// ---------------------------------------------------------------------------

// skip_dirs are the directories no search ever descends into. Walking them
// turns a one-second search into a minute of reading caches and vendored
// trees nobody asked about.
pub const skip_dirs = ['.git', 'node_modules', '__pycache__', '.venv', 'venv',
	'dist', 'build', '.tox', '.mypy_cache', '.ruff_cache']

// walk_files lists files under `root`, skipping the ignore dirs, stopping
// once `limit` paths have been collected (limit <= 0 means no cap).
pub fn walk_files(root string, limit int) []string {
	mut out := []string{}
	mut stack := [root]
	for stack.len > 0 {
		dir := stack.pop()
		entries := os.ls(dir) or { continue }
		mut names := entries.clone()
		names.sort()
		for name in names {
			full := os.join_path(dir, name)
			if os.is_dir(full) {
				if name in skip_dirs {
					continue
				}
				// a symlinked directory can point back up the tree, and the
				// walk would then never terminate
				if os.is_link(full) {
					continue
				}
				stack << full
				continue
			}
			out << full
			if limit > 0 && out.len >= limit {
				return out
			}
		}
	}
	return out
}

// glob_paths resolves a glob pattern relative to `root`, returning matching
// FILE paths, sorted. `**` spans directories.
pub fn glob_paths(root string, pattern string) []string {
	// the walk cap keeps a glob over `/` from hanging the agent
	all := walk_files(root, 20000)
	mut out := []string{}
	prefix := if root.ends_with('/') { root } else { root + '/' }
	for f in all {
		rel := if f.starts_with(prefix) { f[prefix.len..] } else { f }
		if glob_match(rel.replace('\\', '/'), pattern) {
			out << f
		}
	}
	out.sort()
	return out
}
