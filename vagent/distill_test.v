module vagent

const distill_spec = '[SEC] Secrets never appear in source
Credentials and API keys live in the environment, not in files.

[PATH] Writes stay under src/ and tests/
Nothing outside those roots is ever modified by the agent.

[DEL] Nothing is ever deleted
If something must go, move it aside instead.

[TEST] Every module ships with a test
A source file without a matching test is incomplete.

[EXIT] Never claim a test passed without the exit code
Report the command and its exit status.

[NET] The agent reaches only pypi.org and github.com
No other host is contacted.

[DOC] Every public function carries a docstring

[VAGUE] Write thoughtful code that other people can maintain.

[DONE] This one already has a rule
@enforce forbid_effect: exec
'

fn distill_fixture(name string) ([]Clause, []Proposal) {
	mut cov := new_covenant(new_event_log(tmp_log_path(name), 'main', 'test'), distill_spec)
	props := distill(cov.clauses, true)
	return cov.clauses, props
}

fn props_for(props []Proposal, clause string) []Proposal {
	return props.filter(it.clause == clause)
}

fn has_line(props []Proposal, clause string, needle string) bool {
	for p in props_for(props, clause) {
		if p.line.contains(needle) {
			return true
		}
	}
	return false
}

fn test_each_reading_fires_on_the_prose_it_was_written_for() {
	_, props := distill_fixture('dis1')

	secrets := props_for(props, 'SEC')
	assert secrets.len >= 1
	assert secrets[0].line.contains('forbid_content')
	assert secrets[0].confidence == confidence_high

	assert has_line(props, 'PATH', 'confine_paths')
	mut confine := ''
	for p in props_for(props, 'PATH') {
		if p.line.contains('confine_paths') {
			confine = p.line
		}
	}
	assert confine.contains('src'), confine
	assert confine.contains('tests'), confine

	assert has_line(props, 'DEL', 'forbid_effect: delete')
	assert has_line(props, 'TEST', '@oblige')
	assert has_line(props, 'EXIT', '@output forbid')
	assert has_line(props, 'DOC', 'require_content')

	mut hosts := ''
	for p in props_for(props, 'NET') {
		if p.line.contains('allow_hosts') {
			hosts = p.line
		}
	}
	assert hosts.contains('pypi.org'), hosts
	assert hosts.contains('github.com'), hosts
}

fn test_prose_it_cannot_read_yields_nothing_rather_than_a_guess() {
	_, props := distill_fixture('dis2')
	// "Write thoughtful code that other people can maintain" implies a rule
	// to a human and nothing mechanical to this module, so it proposes none
	assert props_for(props, 'VAGUE').len == 0
}

fn test_a_clause_that_already_has_a_rule_is_left_alone() {
	_, props := distill_fixture('dis3')
	// a second, subtly different rule for one clause is how a specification
	// starts contradicting itself
	assert props_for(props, 'DONE').len == 0
}

fn test_every_proposal_carries_the_evidence_it_was_read_from() {
	_, props := distill_fixture('dis4')
	assert props.len > 0
	for p in props {
		assert p.clause != ''
		assert p.because != ''
		// the sentence really is in the specification, not a paraphrase
		assert distill_spec.contains(p.because), p.because
		assert p.confidence in [confidence_high, confidence_medium, confidence_low]
	}
}

fn test_it_proposes_and_changes_nothing() {
	mut log := new_event_log(tmp_log_path('dis5'), 'main', 'test')
	mut cov := new_covenant(log, distill_spec)
	before := cov.guards().len
	props := distill(cov.clauses, true)

	text := patch(props, confidence_low)
	assert text.contains('Nothing here is')
	assert text.contains('in force until you do')
	assert text.contains('@enforce confine_paths')

	// the specification is untouched: a second parse of the same text has
	// exactly the guards the first one had
	mut again := new_covenant(log, distill_spec)
	assert again.guards().len == before
	assert cov.guards().len == before
}

fn test_the_proposed_enforce_lines_really_parse() {
	mut log := new_event_log(tmp_log_path('dis6'), 'main', 'test')
	mut cov := new_covenant(log, distill_spec)
	props := distill(cov.clauses, true)

	mut pasted := []string{}
	for p in props {
		if p.line.starts_with('@enforce') {
			pasted << '[${p.clause}] x\n${p.line}'
		}
	}
	assert pasted.len > 0
	mut checked := new_covenant(log, pasted.join('\n'))
	assert checked.guards().len > 0, 'proposed @enforce lines did not parse'
	assert checked.errors.len == 0, checked.errors.str()
}

fn test_the_confidence_filter_narrows_the_patch() {
	_, props := distill_fixture('dis7')
	high_only := patch(props, confidence_high)
	assert high_only.contains('[high]')
	assert !high_only.contains('[medium]')
	// the unfiltered patch has both
	all := patch(props, confidence_low)
	assert all.contains('[high]')
	assert all.contains('[medium]')
}

fn test_distillation_is_deterministic() {
	mut log := new_event_log(tmp_log_path('dis8'), 'main', 'test')
	mut cov := new_covenant(log, distill_spec)
	first := distill(cov.clauses, true)
	second := distill(cov.clauses, true)
	assert first.len == second.len
	for i in 0 .. first.len {
		assert first[i].to_json().str() == second[i].to_json().str()
	}
	// strongest readings come first
	for i in 1 .. first.len {
		assert confidence_order(first[i - 1].confidence) <= confidence_order(first[i].confidence)
	}
}

fn test_the_report_counts_what_was_not_covered() {
	clauses, props := distill_fixture('dis9')
	rep := distill_report(clauses, props)
	assert rep.contains('yielded nothing')
	assert rep.contains('nothing is applied')
	assert rep.contains('carry no rule')
}

fn test_an_empty_specification_proposes_nothing() {
	mut log := new_event_log(tmp_log_path('dis10'), 'main', 'test')
	mut cov := new_covenant(log, '')
	assert distill(cov.clauses, true).len == 0
	assert patch([], confidence_low) == ''
	assert distill_report([], []) == 'distill: no specification is bound'
}

fn test_sentences_skip_the_rule_lines_and_split_on_terminators() {
	body := 'First sentence. Second one here!\n@enforce forbid_effect: delete\nThird line.'
	out := sentences(body)
	assert out == ['First sentence.', 'Second one here!', 'Third line.'], out.str()
	// a full stop with no space after it is not a sentence break
	assert sentences('version 1.2 is fine') == ['version 1.2 is fine']
}

fn test_roots_are_split_on_commas_and_the_joining_words() {
	assert split_roots('src/, tests and docs') == ['src', 'tests', 'docs']
	assert split_roots('src or lib') == ['src', 'lib']
	// a bare article is dropped, but an article attached to a root is not
	// second-guessed — "the src" is left as written for the author to read
	assert split_roots('src, the, tests') == ['src', 'tests']
	assert split_roots('the src') == ['the src']
	assert split_roots('') == []
	// a word merely containing "and" is not a separator
	assert split_roots('sandbox') == ['sandbox']
}

fn test_a_short_sentence_is_never_read_into_a_rule() {
	// eleven characters is not a specification
	assert read_sentence('C1', 'no deleting') == []
	assert read_sentence('C1', '   ') == []
}
