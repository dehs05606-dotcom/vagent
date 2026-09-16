module vagent

fn apply_ops(a []string, ops []DiffOp) []string {
	mut out := []string{}
	for op in ops {
		match op.kind {
			.equal, .insert { out << op.text }
			.delete {}
		}
	}
	return out
}

fn test_split_lines_matches_python_splitlines() {
	assert split_lines('') == []
	assert split_lines('a') == ['a']
	assert split_lines('a\n') == ['a']
	assert split_lines('a\nb\n') == ['a', 'b']
	assert split_lines('a\n\nb') == ['a', '', 'b']
	assert split_lines('a\r\nb\r\n') == ['a', 'b']
	assert split_lines('\n') == ['']
}

fn test_diff_is_minimal_and_reconstructs() {
	a := ['a', 'b', 'c']
	b := ['a', 'B', 'c']
	ops := diff_lines(a, b)
	assert apply_ops(a, ops) == b
	mut adds := 0
	mut dels := 0
	for op in ops {
		if op.kind == .insert {
			adds++
		}
		if op.kind == .delete {
			dels++
		}
	}
	assert adds == 1 && dels == 1
}

fn test_diff_summary_counts() {
	adds1, rem1 := diff_summary('a\nb\nc\n', 'a\nB\nc\n')
	assert adds1 == 1 && rem1 == 1

	adds2, rem2 := diff_summary('', 'x\ny\n')
	assert adds2 == 2 && rem2 == 0

	adds3, rem3 := diff_summary('x\ny\n', '')
	assert adds3 == 0 && rem3 == 2

	adds4, rem4 := diff_summary('same\n', 'same\n')
	assert adds4 == 0 && rem4 == 0

	// pure insertion in the middle keeps removals at zero
	adds5, rem5 := diff_summary('a\nc\n', 'a\nb\nc\n')
	assert adds5 == 1 && rem5 == 0
}

fn test_diff_reconstructs_larger_inputs() {
	mut a := []string{}
	for i in 0 .. 400 {
		a << 'line ${i}'
	}
	mut b := a.clone()
	b[10] = 'CHANGED'
	b.delete(200)
	b.insert(300, 'INSERTED')
	ops := diff_lines(a, b)
	assert apply_ops(a, ops) == b
}

fn test_unified_diff_renders_hunks() {
	out := unified_diff('a\nb\nc\nd\n', 'a\nB\nc\nd\n', 'a/f.txt', 'b/f.txt', 1)
	assert out.contains('--- a/f.txt')
	assert out.contains('+++ b/f.txt')
	assert out.contains('@@')
	assert out.contains('-b')
	assert out.contains('+B')
	// no change at all renders nothing
	assert unified_diff('a\n', 'a\n', 'x', 'y', 3) == ''
}

fn test_unified_hunks_merge_nearby_changes() {
	a := ['1', '2', '3', '4', '5', '6', '7', '8', '9']
	mut b := a.clone()
	b[1] = 'two'
	b[3] = 'four'
	// with 3 lines of context the two edits fall into one hunk
	merged := unified_hunks(a, b, 3)
	assert merged.len == 1
	// with no context they stay separate
	split := unified_hunks(a, b, 0)
	assert split.len == 2
}
