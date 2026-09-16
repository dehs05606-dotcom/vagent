module vagent

// diff.v — line diffing, the V stand-in for Python's `difflib`.
//
// Two things in this package need a real diff, not an approximation:
//
//   * every write/edit tool returns an "N addition(s), M removal(s)"
//     receipt, so the counts have to be the ones a reviewer would get from
//     `diff -u`, not a heuristic;
//   * the TUI renders the actual changed lines of an edit inline, so it
//     needs the edit script itself, not just the totals.
//
// This is Myers' O((N+M)D) algorithm with a recorded trace, which gives a
// minimal edit script. `max_diff_d` bounds the search: two files that share
// almost nothing produce a D on the order of their combined length, and
// walking that is neither fast nor useful to read. Past the bound the diff
// degrades to "everything replaced", which is both true and cheap.

const max_diff_d = 4000

pub enum DiffKind {
	equal
	insert
	delete
}

pub struct DiffOp {
pub:
	kind DiffKind
	// index into the old array for equal/delete, -1 for insert
	old_index int = -1
	// index into the new array for equal/insert, -1 for delete
	new_index int = -1
	text      string
}

// diff_lines returns a minimal edit script turning `a` into `b`.
pub fn diff_lines(a []string, b []string) []DiffOp {
	n := a.len
	m := b.len
	if n == 0 && m == 0 {
		return []
	}
	if n == 0 {
		return []DiffOp{len: m, init: DiffOp{
			kind:      .insert
			new_index: index
			text:      b[index]
		}}
	}
	if m == 0 {
		return []DiffOp{len: n, init: DiffOp{
			kind:      .delete
			old_index: index
			text:      a[index]
		}}
	}

	max_d := if n + m < max_diff_d { n + m } else { max_diff_d }
	offset := max_d
	size := 2 * max_d + 1
	mut v := []int{len: size}
	mut trace := [][]int{}

	mut found_d := -1
	for d := 0; d <= max_d; d++ {
		trace << v.clone()
		for k := -d; k <= d; k += 2 {
			idx := k + offset
			if idx < 0 || idx >= size {
				continue
			}
			mut x := 0
			// take the better of "down" (insert) and "right" (delete)
			down := k == -d || (k != d && idx - 1 >= 0 && idx + 1 < size
				&& v[idx - 1] < v[idx + 1])
			if down {
				x = if idx + 1 < size { v[idx + 1] } else { 0 }
			} else {
				x = if idx - 1 >= 0 { v[idx - 1] + 1 } else { 1 }
			}
			mut y := x - k
			// slide down the diagonal through every equal line
			for x < n && y < m && a[x] == b[y] {
				x++
				y++
			}
			v[idx] = x
			if x >= n && y >= m {
				found_d = d
				break
			}
		}
		if found_d >= 0 {
			break
		}
	}

	if found_d < 0 {
		// beyond the bound: report it as a wholesale replacement rather
		// than spending the time to prove a minimal script nobody reads
		mut out := []DiffOp{cap: n + m}
		for i, line in a {
			out << DiffOp{
				kind:      .delete
				old_index: i
				text:      line
			}
		}
		for i, line in b {
			out << DiffOp{
				kind:      .insert
				new_index: i
				text:      line
			}
		}
		return out
	}

	// backtrack through the recorded trace to recover the script
	mut ops := []DiffOp{}
	mut x := n
	mut y := m
	for d := found_d; d > 0; d-- {
		vp := trace[d]
		k := x - y
		idx := k + offset
		down := k == -d || (k != d && idx - 1 >= 0 && idx + 1 < size
			&& vp[idx - 1] < vp[idx + 1])
		prev_k := if down { k + 1 } else { k - 1 }
		prev_idx := prev_k + offset
		prev_x := if prev_idx >= 0 && prev_idx < size { vp[prev_idx] } else { 0 }
		prev_y := prev_x - prev_k
		// the diagonal slide first (equal lines), walked backwards
		for x > prev_x && y > prev_y {
			x--
			y--
			ops << DiffOp{
				kind:      .equal
				old_index: x
				new_index: y
				text:      a[x]
			}
		}
		if down {
			y--
			ops << DiffOp{
				kind:      .insert
				new_index: y
				text:      b[y]
			}
		} else {
			x--
			ops << DiffOp{
				kind:      .delete
				old_index: x
				text:      a[x]
			}
		}
	}
	// whatever is left at d == 0 is a pure equal run back to the origin
	for x > 0 && y > 0 {
		x--
		y--
		ops << DiffOp{
			kind:      .equal
			old_index: x
			new_index: y
			text:      a[x]
		}
	}
	ops.reverse_in_place()
	return ops
}

// split_lines matches Python's str.splitlines(): a trailing newline does
// NOT produce a final empty element, and an empty string yields no lines.
pub fn split_lines(text string) []string {
	if text == '' {
		return []
	}
	mut body := text.replace('\r\n', '\n').replace('\r', '\n')
	if body.ends_with('\n') {
		body = body#[..-1]
	}
	return body.split('\n')
}

// diff_summary returns (additions, removals) line counts between two
// versions — the numbers every write/edit receipt quotes.
pub fn diff_summary(old string, new string) (int, int) {
	a := split_lines(old)
	b := split_lines(new)
	mut adds := 0
	mut removes := 0
	for op in diff_lines(a, b) {
		match op.kind {
			.insert { adds++ }
			.delete { removes++ }
			.equal {}
		}
	}
	return adds, removes
}

// Hunk is one contiguous region of change with its surrounding context.
pub struct Hunk {
pub mut:
	old_start int // 1-based
	old_count int
	new_start int // 1-based
	new_count int
	ops       []DiffOp
}

// unified_hunks groups an edit script into `diff -u` style hunks with
// `context` lines of surrounding equality.
pub fn unified_hunks(a []string, b []string, context int) []Hunk {
	ops := diff_lines(a, b)
	mut changed := []int{}
	for i, op in ops {
		if op.kind != .equal {
			changed << i
		}
	}
	if changed.len == 0 {
		return []
	}
	mut hunks := []Hunk{}
	mut i := 0
	for i < changed.len {
		start := if changed[i] - context > 0 { changed[i] - context } else { 0 }
		mut j := i
		// absorb the next change when its context window touches this one
		for j + 1 < changed.len && changed[j + 1] - changed[j] <= 2 * context + 1 {
			j++
		}
		mut end := changed[j] + context
		if end >= ops.len {
			end = ops.len - 1
		}
		mut h := Hunk{}
		mut first_old := -1
		mut first_new := -1
		for k := start; k <= end; k++ {
			op := ops[k]
			if op.old_index >= 0 && first_old < 0 {
				first_old = op.old_index
			}
			if op.new_index >= 0 && first_new < 0 {
				first_new = op.new_index
			}
			if op.kind != .insert {
				h.old_count++
			}
			if op.kind != .delete {
				h.new_count++
			}
			h.ops << op
		}
		h.old_start = if first_old >= 0 { first_old + 1 } else { 1 }
		h.new_start = if first_new >= 0 { first_new + 1 } else { 1 }
		hunks << h
		i = j + 1
	}
	return hunks
}

// unified_diff renders a full `diff -u` text, used by the report exporter.
pub fn unified_diff(old string, new string, from_file string, to_file string, context int) string {
	a := split_lines(old)
	b := split_lines(new)
	hunks := unified_hunks(a, b, context)
	if hunks.len == 0 {
		return ''
	}
	mut out := ['--- ${from_file}', '+++ ${to_file}']
	for h in hunks {
		out << '@@ -${h.old_start},${h.old_count} +${h.new_start},${h.new_count} @@'
		for op in h.ops {
			match op.kind {
				.equal { out << ' ${op.text}' }
				.insert { out << '+${op.text}' }
				.delete { out << '-${op.text}' }
			}
		}
	}
	return out.join('\n')
}
