module vagent

import x.json2

fn eff_args(pairs map[string]string) map[string]json2.Any {
	mut out := map[string]json2.Any{}
	for k, v in pairs {
		out[k] = json2.Any(v)
	}
	return out
}

fn writes_of(effects []Effect) []Effect {
	return effects.filter(it.kind == effect_write)
}

fn test_a_heredoc_is_a_write_whose_content_is_known() {
	// this is the case that makes a content clause reachable through the
	// shell: without the body, `cat > f <<EOF` is a write of nothing
	cmd := "cat > src/c.py <<'EOF'\nAPI_KEY = \"sk-1\"\nmore = 2\nEOF"
	writes := writes_of(derive_command_effects(cmd))
	assert writes.len == 1, '${derive_command_effects(cmd).map(it.kind)}'
	assert writes[0].path == 'src/c.py'
	assert writes[0].content.contains('API_KEY = "sk-1"')
	assert writes[0].content.contains('more = 2')

	// unquoted and dash-stripped delimiters read the same
	for opener in ['<<EOF', '<< EOF', '<<-EOF', '<<"EOF"'] {
		c := 'cat > out.txt ${opener}\nhello there\nEOF'
		w := writes_of(derive_command_effects(c))
		assert w.len == 1, opener
		assert w[0].content == 'hello there', opener
	}
}

fn test_redirection_is_a_write_and_a_dynamic_target_is_opaque() {
	plain := writes_of(derive_command_effects('echo hi > a.txt'))
	assert plain.len == 1
	assert plain[0].path == 'a.txt'

	appended := writes_of(derive_command_effects('echo hi >> a.txt'))
	assert appended.len == 1

	// a target resolved at run time cannot be judged, so it is opaque
	dynamic := derive_command_effects('echo hi > "$OUT"')
	assert dynamic.any(it.kind == effect_opaque)
	assert writes_of(dynamic).len == 0
}

fn test_deletions_and_moves_are_named() {
	rm := derive_command_effects('rm -rf build')
	assert rm.any(it.kind == effect_delete && it.path == 'build')
	mv := derive_command_effects('mv a.txt b.txt')
	assert mv.any(it.kind == effect_write && it.path == 'b.txt')
	assert mv.any(it.kind == effect_delete && it.path == 'a.txt')
}

fn test_an_unreadable_command_is_opaque_rather_than_assumed_harmless() {
	for cmd in ['eval "\$CMD"', 'bash -c "\$X"'] {
		assert derive_command_effects(cmd).any(it.kind == effect_opaque), cmd
	}
	// `sh script.sh` is not opaque: the script is named, so the guard can
	// judge the path even though it cannot read what the script will do
	assert !derive_command_effects('sh script.sh').any(it.kind == effect_opaque)
	// an unbalanced quote cannot be parsed, so it cannot be shown to respect
	// anything
	assert derive_command_effects('echo "unclosed').any(it.kind == effect_opaque)
}

fn test_the_tool_routes_produce_the_same_effects_as_the_shell_ones() {
	direct := derive('write_file', eff_args({
		'path':    'src/a.py'
		'content': 'x = 1\n'
	}))
	assert writes_of(direct).len == 1
	assert writes_of(direct)[0].content == 'x = 1\n'

	shell := derive('run_command', eff_args({
		'command': 'echo "x = 1" > src/a.py'
	}))
	assert writes_of(shell).len == 1
	assert writes_of(shell)[0].path == 'src/a.py'

	edit := derive('edit_file', eff_args({
		'path':       'src/a.py'
		'old_string': 'x'
		'new_string': 'y'
	}))
	assert writes_of(edit).len == 1
	assert writes_of(edit)[0].content == 'y'

	del := derive('delete_path', eff_args({
		'path': 'src/a.py'
	}))
	assert del.any(it.kind == effect_delete)
}

fn test_a_patch_is_a_write_per_file_with_its_added_lines() {
	patch := '--- a/one.py\n+++ b/one.py\n@@ -1 +1,2 @@\n context\n+added one\n' +
		'--- a/two.py\n+++ b/two.py\n@@ -1 +1,2 @@\n context\n+added two\n'
	writes := writes_of(derive('apply_patch', eff_args({
		'patch': patch
	})))
	assert writes.len == 2, '${writes.map(it.path)}'
	assert writes.any(it.path == 'one.py' && it.content.contains('added one'))
	assert writes.any(it.path == 'two.py' && it.content.contains('added two'))
}

fn test_a_command_that_only_reads_writes_nothing() {
	for cmd in ['ls -la', 'cat README.md', 'grep -r foo src/'] {
		assert writes_of(derive_command_effects(cmd)).len == 0, cmd
	}
}
