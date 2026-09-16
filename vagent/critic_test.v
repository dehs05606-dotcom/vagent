module vagent

import x.json2

const critic_spec = '[COMP] Prefer composition over inheritance
Deep class hierarchies are harder to change than composed parts.

[TRADE] Explain the trade-off before recommending one option
A recommendation without its cost is not a recommendation.

[ECHO] Do not restate the user\'s question back to them
Answer it.

[HASRULE] Secrets never appear in source
@enforce forbid_content: (?i)api[_-]?key
'

const critic_draft = 'You asked how to structure the parser. Subclass BaseParser and override run().'

__global (
	critic_reply  string
	critic_prompt_seen string
)

fn critic_ask(prompt string) !string {
	critic_prompt_seen = prompt
	if critic_reply == '<<boom>>' {
		return error('critic model unavailable')
	}
	return critic_reply
}

fn critic_clauses(name string) []Clause {
	mut log := new_event_log(tmp_log_path(name), 'main', 'test')
	cov := new_covenant(log, critic_spec)
	return cov.clauses
}

fn test_a_clause_with_a_machine_rule_is_never_sent_to_the_critic() {
	clauses := critic_clauses('cri0')
	prose := prose_clauses(clauses, [])
	assert 'HASRULE' !in prose.map(it.id)
	// nor is one conform.v already checks
	assert 'ECHO' !in prose_clauses(clauses, ['ECHO']).map(it.id)
	assert 'COMP' in prose.map(it.id)
}

fn test_a_well_formed_critique_is_read() {
	mut log := new_event_log(tmp_log_path('cri1'), 'main', 'test')
	mut c := new_critic(log, critic_spec)
	critic_reply = json2.encode(json2.Any({
		'findings': json2.Any([
			json2.Any({
				'clause': json2.Any('COMP')
				'quote':  json2.Any('Subclass BaseParser')
				'why':    json2.Any('it recommends inheritance where composition fits')
			}),
		])
	}))
	crit := c.review(critic_draft, critic_clauses('cri1c'), critic_ask, [], max_critic_clauses)
	assert crit.findings.len == 1
	assert !crit.clean()
	assert crit.findings[0].clause == 'COMP'
	assert crit.describe().contains('COMP')

	// the prompt carried the prose clauses and the draft, and not the rule
	assert critic_prompt_seen.contains('[COMP]')
	assert !critic_prompt_seen.contains('[HASRULE]')
	assert critic_prompt_seen.contains(critic_draft)

	note := c.instruction(&crit)
	assert note.contains('COMP')
	assert note.contains('Subclass BaseParser')
	assert note.to_lower().contains('composition')
	// it names the problem and never writes the replacement
	assert !note.contains('class Parser')
}

fn test_an_invented_clause_or_a_misquote_is_discarded() {
	mut log := new_event_log(tmp_log_path('cri2'), 'main', 'test')
	mut c := new_critic(log, critic_spec)
	clauses := critic_clauses('cri2c')

	critic_reply = json2.encode(json2.Any({
		'findings': json2.Any([
			json2.Any({
				'clause': json2.Any('NOPE')
				'quote':  json2.Any('Subclass BaseParser')
				'why':    json2.Any('made up')
			}),
		])
	}))
	invented := c.review(critic_draft, clauses, critic_ask, [], max_critic_clauses)
	assert invented.findings.len == 0
	assert invented.discarded == 1

	critic_reply = json2.encode(json2.Any({
		'findings': json2.Any([
			json2.Any({
				'clause': json2.Any('COMP')
				'quote':  json2.Any('text that never appeared')
				'why':    json2.Any('hallucinated')
			}),
		])
	}))
	misquoted := c.review(critic_draft, clauses, critic_ask, [], max_critic_clauses)
	assert misquoted.findings.len == 0
	assert misquoted.discarded == 1

	// a finding with no reason is not a finding
	critic_reply = json2.encode(json2.Any({
		'findings': json2.Any([
			json2.Any({
				'clause': json2.Any('COMP')
				'quote':  json2.Any('Subclass BaseParser')
				'why':    json2.Any('')
			}),
		])
	}))
	unreasoned := c.review(critic_draft, clauses, critic_ask, [], max_critic_clauses)
	assert unreasoned.findings.len == 0
	assert unreasoned.discarded == 1
}

fn test_junk_instead_of_json_yields_nothing_rather_than_a_crash() {
	mut log := new_event_log(tmp_log_path('cri3'), 'main', 'test')
	mut c := new_critic(log, critic_spec)
	clauses := critic_clauses('cri3c')
	for junk in ['I think the draft is fine, honestly.', '', '{', 'null',
		'{"findings": "not a list"}'] {
		critic_reply = junk
		crit := c.review(critic_draft, clauses, critic_ask, [], max_critic_clauses)
		assert crit.findings.len == 0, junk
		assert crit.error == '', junk
	}
}

fn test_a_clean_verdict_is_clean() {
	mut log := new_event_log(tmp_log_path('cri4'), 'main', 'test')
	mut c := new_critic(log, critic_spec)
	critic_reply = '{"findings": []}'
	crit := c.review(critic_draft, critic_clauses('cri4c'), critic_ask, [], max_critic_clauses)
	assert crit.clean()
	assert crit.describe().contains('breaks none of them')
}

fn test_a_failing_critic_never_takes_down_the_turn() {
	mut log := new_event_log(tmp_log_path('cri5'), 'main', 'test')
	mut c := new_critic(log, critic_spec)
	critic_reply = '<<boom>>'
	crit := c.review(critic_draft, critic_clauses('cri5c'), critic_ask, [], max_critic_clauses)
	assert crit.error != ''
	assert crit.findings.len == 0
	assert crit.describe().contains('not run')
	assert log.events('main').map(it.typ).contains('critic.error')
}

fn test_nothing_to_critique_is_not_a_critique() {
	mut log := new_event_log(tmp_log_path('cri6'), 'main', 'test')
	mut c := new_critic(log, critic_spec)
	critic_reply = '{"findings": []}'
	assert c.review('', critic_clauses('cri6c'), critic_ask, [], max_critic_clauses).considered.len == 0
	// a specification with no prose clause at all
	mut empty_log := new_event_log(tmp_log_path('cri6e'), 'main', 'test')
	empty := new_covenant(empty_log, '')
	mut c2 := new_critic(log, '')
	assert c2.review(critic_draft, empty.clauses, critic_ask, [], max_critic_clauses).considered.len == 0
}

fn test_every_review_is_sealed_and_the_report_counts_discards() {
	mut log := new_event_log(tmp_log_path('cri7'), 'main', 'test')
	mut c := new_critic(log, critic_spec)
	assert c.report() == 'critic: not run yet'
	critic_reply = '{"findings": []}'
	c.review(critic_draft, critic_clauses('cri7c'), critic_ask, [], max_critic_clauses)
	assert log.events('main').map(it.typ).contains('critic.review')
	assert c.report().contains('discarded')
	assert c.report().contains('1 review(s)')
}
