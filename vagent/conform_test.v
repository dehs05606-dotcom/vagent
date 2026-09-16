module vagent

__global (
	conform_seen  []string
	conform_calls int
)

const conform_spec = '[OUT] Test results are reported with the exit code
@output forbid (?i)tests? (pass|fail)\\w*(?![^.]*exit)

[CITE] A described change cites file:line
@output require \\S+:\\d+   when   (?i)\\b(edited|changed|wrote|updated)\\b

[LEN] Replies stay short
@output max_chars 400
'

fn regen_unused(instruction string) !string {
	conform_calls++
	return 'should not be called'
}

fn regen_fix(instruction string) !string {
	conform_seen << instruction
	return 'pytest -q: exit 0, 41 passed.'
}

fn regen_never_fixes(instruction string) !string {
	conform_calls++
	return 'The tests pass now.'
}

fn regen_boom(instruction string) !string {
	return error('model unavailable')
}

fn regen_empty(instruction string) !string {
	return ''
}

fn regen_short(instruction string) !string {
	return 'y'.repeat(10)
}

fn test_the_spec_parses_into_exactly_its_rules() {
	rules, errors := parse_rules(conform_spec)
	assert rules.len == 3, '${rules.len}'
	assert errors.len == 0, '${errors}'
	assert rules[0].clause == 'OUT' && rules[0].kind == 'forbid'
	assert rules[1].clause == 'CITE' && rules[1].kind == 'require'
	assert rules[1].when.contains('edited')
	assert rules[2].clause == 'LEN' && rules[2].limit == 400
}

fn test_a_conforming_draft_passes_untouched() {
	conform_calls = 0
	mut c := new_conform(new_event_log(tmp_log_path('conf1'), 'main', 'test'), conform_spec,
		2)
	good := 'pytest -q: exit 0, 41 passed.'
	out := c.run(good, regen_unused)
	assert out.conformed()
	assert out.text == good
	assert out.attempts == 1
	assert c.regenerated == 0
	assert conform_calls == 0
}

fn test_a_failing_draft_goes_back_with_the_clause_it_broke() {
	conform_seen = []
	mut c := new_conform(new_event_log(tmp_log_path('conf2'), 'main', 'test'), conform_spec,
		2)
	out := c.run('The tests pass now.', regen_fix)
	assert out.conformed(), '${out.unmet.map(it.detail)}'
	assert out.attempts == 2
	assert conform_seen.len == 1

	// the instruction carries BOTH the miss and the rule
	inst := conform_seen[0]
	assert inst.contains('OUT')
	assert inst.contains('the reply contains')
	assert inst.contains('rule: OUT: the reply must not match')
	// but it never writes the answer
	assert !inst.contains('exit 0')
}

fn test_when_arms_a_rule_only_for_the_replies_it_applies_to() {
	mut c := new_conform(new_event_log(tmp_log_path('conf3'), 'main', 'test'), conform_spec,
		2)
	assert c.check('The parser looks correct as it is.').len == 0
	// `when` is a regex over the reply, so it is exactly as precise as the
	// author's pattern: "nothing was changed" trips a /changed/ condition.
	// That is a property of the rule, not of this module.
	assert c.check('Nothing was changed here.').len > 0
	unmet := c.check('I edited the parser.')
	assert unmet.len == 1
	assert unmet[0].rule.clause == 'CITE'
	assert c.check('I edited the parser at src/p.py:42.').len == 0
}

fn test_the_loop_is_bounded_and_honest_when_it_fails() {
	conform_calls = 0
	mut c := new_conform(new_event_log(tmp_log_path('conf4'), 'main', 'test'), conform_spec,
		2)
	out := c.run('The tests pass now.', regen_never_fixes)
	assert !out.conformed()
	assert conform_calls == 2, '${conform_calls}'
	// the original draft plus two retries
	assert out.attempts == 3

	shown := out.annotated()
	assert shown.starts_with('The tests pass now.')
	assert shown.contains('[conform]')
	assert shown.contains('OUT')
	assert shown.contains('does not meet')
}

fn test_a_failing_regenerator_never_loses_the_draft() {
	mut log := new_event_log(tmp_log_path('conf5'), 'main', 'test')
	mut c := new_conform(log, conform_spec, 2)
	out := c.run('The tests pass now.', regen_boom)
	assert out.text == 'The tests pass now.'
	assert !out.conformed()
	assert log.events('main').map(it.typ).contains('conform.error')

	// an empty regeneration is not progress either
	out2 := c.run('The tests pass now.', regen_empty)
	assert out2.text == 'The tests pass now.'
	assert !out2.conformed()
}

fn test_max_chars_is_a_ceiling_like_any_other_rule() {
	mut c := new_conform(new_event_log(tmp_log_path('conf6'), 'main', 'test'), '[LEN] short\n@output max_chars 20\n',
		2)
	out := c.run('x'.repeat(50), regen_short)
	assert out.conformed()
	assert out.text == 'y'.repeat(10)
}

fn test_no_rules_means_the_draft_is_never_touched() {
	conform_calls = 0
	mut c := new_conform(new_event_log(tmp_log_path('conf7'), 'main', 'test'), '', 2)
	out := c.run('anything at all', regen_unused)
	assert out.text == 'anything at all'
	assert out.conformed()
	assert conform_calls == 0
	assert c.report().contains('no @output rules')
}

fn test_zero_attempts_checks_but_never_regenerates() {
	conform_calls = 0
	mut c := new_conform(new_event_log(tmp_log_path('conf8'), 'main', 'test'), conform_spec,
		0)
	out := c.run('The tests pass now.', regen_unused)
	assert !out.conformed()
	assert out.attempts == 1
	assert conform_calls == 0
}

fn test_every_outcome_is_sealed() {
	mut log := new_event_log(tmp_log_path('conf9'), 'main', 'test')
	conform_seen = []
	conform_calls = 0
	mut c := new_conform(log, conform_spec, 2)
	c.run('pytest -q: exit 0.', regen_unused)
	c.run('The tests pass now.', regen_fix)
	c.run('The tests pass now.', regen_never_fixes)
	kinds := log.events('main').map(it.typ)
	assert 'conform.accepted' in kinds
	assert 'conform.rejected' in kinds
	assert 'conform.unmet' in kinds
}

fn test_malformed_rules_are_reported_never_guessed_at() {
	mut c := new_conform(new_event_log(tmp_log_path('conf10'), 'main', 'test'), '[A] x\n@output sideways foo\n' +
		'[B] y\n@output forbid [unclosed\n' + '[C] z\n@output max_chars nope\n' +
		'[D] w\n@output max_chars -3\n', 2)
	assert c.errors.len == 4, '${c.errors}'
	assert c.rules.len == 0
	assert c.report().contains('no @output rules')
	// each error names its own clause
	assert c.errors[0].starts_with('A:')
	assert c.errors[1].starts_with('B:')
	assert c.errors[2].starts_with('C:')
	assert c.errors[3].starts_with('D:')
}

fn test_section_markers_and_tags_both_scope_a_rule() {
	rules, _ := parse_rules('§1.2 A numbered clause\n@output max_chars 10\n')
	assert rules.len == 1
	assert rules[0].clause == '1.2'
	// and a rule before any marker belongs to the preamble
	loose, _ := parse_rules('@output max_chars 10\n')
	assert loose[0].clause == 'preamble'
}

fn test_the_report_lists_the_rules_and_the_counts() {
	conform_seen = []
	mut c := new_conform(new_event_log(tmp_log_path('conf11'), 'main', 'test'), conform_spec,
		2)
	c.run('The tests pass now.', regen_fix)
	text := c.report()
	assert text.contains('3 output rule(s)')
	assert text.contains('1 reply(ies) checked')
	assert text.contains('1 regenerated')
	assert text.contains('0 still unmet')
	assert text.contains('at most 400 chars')
}
