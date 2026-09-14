module main

import os
import src.context
import src.model

fn msg(role model.Role, content string) model.Message {
	return model.Message{
		role:    role
		content: content
	}
}

fn test_estimate_grows_with_conversation() {
	m := context.Manager{}
	small := [msg(.user, 'hi')]
	big := [msg(.user, 'x'.repeat(4000))]
	assert m.estimate(big) > m.estimate(small)
	assert m.estimate([]) == 0
}

fn test_over_budget_respects_reserve() {
	m := context.Manager{
		limit:   1000
		reserve: 400
	}
	// budget is 600 tokens ~= 2400 characters
	assert !m.over_budget([msg(.user, 'x'.repeat(100))])
	assert m.over_budget([msg(.user, 'x'.repeat(20000))])
}

fn test_compaction_trims_old_tool_output_first() {
	m := context.Manager{
		limit:       2000
		reserve:     200
		keep_recent: 2
	}
	mut msgs := [
		msg(.system, 'system prompt'),
		msg(.user, 'do the thing'),
	]
	// Five bulky tool results, older than the keep_recent window.
	for i in 0 .. 5 {
		msgs << model.Message{
			role:       .assistant
			content:    ''
			tool_calls: [
				model.ToolCall{
					id:        'c${i}'
					name:      'shell'
					arguments: '{}'
				},
			]
		}
		msgs << model.Message{
			role:         .tool
			tool_call_id: 'c${i}'
			content:      'output '.repeat(400)
		}
	}
	before := m.estimate(msgs)
	out, report := m.compact(msgs)
	assert report.before_tokens == before
	assert report.after_tokens < before
	assert report.trimmed > 0
	// The system prompt and the original request always survive.
	assert out[0].role == .system
	assert out[1].content == 'do the thing'
}

fn test_compaction_never_orphans_a_tool_result() {
	m := context.Manager{
		limit:       400
		reserve:     100
		keep_recent: 2
	}
	mut msgs := [msg(.system, 'sys'), msg(.user, 'task')]
	for i in 0 .. 8 {
		msgs << model.Message{
			role:       .assistant
			tool_calls: [
				model.ToolCall{
					id:        'c${i}'
					name:      'read_file'
					arguments: '{}'
				},
			]
		}
		msgs << model.Message{
			role:         .tool
			tool_call_id: 'c${i}'
			content:      'result '.repeat(200)
		}
	}
	out, _ := m.compact(msgs)
	// Every surviving tool message must still have its originating call, or
	// the next request is a protocol error.
	mut ids := map[string]bool{}
	for msg_ in out {
		for c in msg_.tool_calls {
			ids[c.id] = true
		}
	}
	for msg_ in out {
		if msg_.role == .tool {
			assert ids[msg_.tool_call_id], 'orphaned tool result ${msg_.tool_call_id}'
		}
	}
}

fn test_collect_detects_stack_and_layout() {
	root := os.join_path(os.temp_dir(), 'vagent_ctx_${os.getpid()}')
	os.rmdir_all(root) or {}
	os.mkdir_all(os.join_path(root, 'src')) or { panic(err) }
	defer {
		os.rmdir_all(root) or {}
	}
	os.write_file(os.join_path(root, 'v.mod'), "Module { name: 'demo' }") or { panic(err) }
	os.write_file(os.join_path(root, 'README.md'), '# Demo\n\nA test project.') or { panic(err) }
	os.write_file(os.join_path(root, 'AGENTS.md'), 'Always run `v test .` before finishing.') or {
		panic(err)
	}

	snap := context.collect(root, root)
	assert 'V' in snap.languages
	assert 'v.mod' in snap.manifest_files
	assert snap.build_commands.len > 0
	assert snap.readme_excerpt.contains('A test project')
	assert snap.rules.len == 1
	assert snap.rules[0].contains('v test')

	rendered := snap.render()
	assert rendered.contains('<project>')
	assert rendered.contains('stack: V')
	assert rendered.contains('<project_rules>')
	assert rendered.contains('v test')
}
