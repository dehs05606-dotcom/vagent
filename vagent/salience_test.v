module vagent

import os

const real_spec = '[SQL] Database access goes through the repository layer
Queries are never written inline in a handler; every read and write goes
through a repository class so the schema has one owner.
@enforce forbid_content: (?i)execute\\(\\s*["\\\x27]SELECT

[MIG] A schema change ships with a migration
Any change under db/schema requires a matching file in db/migrations.

[LOG] Secrets never reach the logs
Credentials, tokens and keys are redacted before any logging call.
@enforce forbid_content: (?i)log\\w*\\(.*(password|token|secret)

[UI] Buttons use the design tokens
No raw hex colours in components; use the token names.
'

fn long_spec() string {
	mut parts := []string{}
	for i in 0 .. 300 {
		parts << '§${i} Rule about subsystem ${i}\n' + 'background prose. '.repeat(24)
	}
	return parts.join('\n') + '\n' + real_spec
}

fn sal_cov(spec_text string) &Covenant {
	mut log := new_event_log(tmp_log_path('salience-${spec_text.len}.jsonl'), 'main', '')
	return new_covenant(log, spec_text)
}

fn test_relevant_clauses_beat_the_filler() {
	cov := sal_cov(long_spec())
	assert cov.clauses.len > 300

	picked := select_clauses(cov.clauses, 'add a repository method that runs a ' +
		'SELECT for the orders table and log the query', SalienceOpts{})
	ids := picked.map(it.clause_id)
	assert 'SQL' in ids, '${ids}'
	assert 'LOG' in ids, '${ids}'
	assert 'UI' !in ids, '${ids}'
	// none of the 300 filler clauses beats a genuinely relevant one
	assert ids[0] in ['SQL', 'LOG'], '${ids}'
}

fn test_the_block_is_the_authors_own_text() {
	cov := sal_cov(long_spec())
	text := salience_block(cov.clauses, 'write a SELECT in the repository',
		SalienceOpts{})
	assert text.contains('Queries are never written inline')
	assert text.contains('@enforce forbid_content'), 'the rule was stripped'
	assert text.contains('CLAUSES THIS REQUEST TOUCHES')

	// nothing invented: every non-header line comes from the specification
	spec_text := long_spec()
	for line in split_lines(text) {
		if line.trim_space() == '' {
			continue
		}
		if salience_header.contains(line.trim_space()) {
			continue
		}
		assert spec_text.contains(line), 'invented line: ${line}'
	}
}

fn test_an_unrelated_request_restates_nothing() {
	cov := sal_cov(long_spec())
	// a block saying "no rules apply here" would be a sentence this module
	// invented, and it would read as permission
	assert salience_block(cov.clauses, 'what time is it', SalienceOpts{}) == ''
	assert salience_report(cov.clauses, 'hello', SalienceOpts{})
		.contains('no clause is implicated')
}

fn test_enforceable_clauses_outrank_prose_at_equal_overlap() {
	// both clauses carry the same words, so the ONLY thing separating them
	// is that A is bound to the boundary and B is prose
	cov := sal_cov('[A] Tokens are redacted before logging\n' +
		'@enforce forbid_content: nothing_in_the_request\n\n' +
		'[B] Tokens are redacted before logging\n')
	ranked := score_clauses(cov.clauses, 'tokens redacted logging', []string{},
		map[string]f64{})
	assert ranked.len == 2, '${ranked.map(it.clause_id)}'
	assert ranked[0].clause_id == 'A', '${ranked.map(it.clause_id)}'
	assert ranked[0].score > ranked[1].score

	// and the @enforce line's own terms count as clause vocabulary, which is
	// what makes a rule mentioning `token` match a request about tokens
	mut log := new_event_log(tmp_log_path('salience-enforce.jsonl'), 'main', '')
	defer {
		log.close()
	}
	two := new_covenant(log, '[A] Tokens must be redacted\n' +
		'@enforce forbid_content: token\n\n[B] Tokens must be redacted\n')
	by_rule := score_clauses(two.clauses, 'redact the token please', []string{},
		map[string]f64{})
	assert by_rule.len == 1, '${by_rule.map(it.clause_id)}'
	assert by_rule[0].clause_id == 'A'
}

fn test_budget_bounds_the_block_without_starving_short_clauses() {
	cov := sal_cov('[BIG] a giant clause\n' + 'word '.repeat(4000) +
		'\n[SMALL] a small one about tokens\ntokens are redacted\n')
	picked := select_clauses(cov.clauses, 'tokens word', SalienceOpts{ budget: 500 })
	assert picked.map(it.clause_id) == ['SMALL'], '${picked.map(it.clause_id)}'
	assert salience_block(cov.clauses, 'tokens word', SalienceOpts{ budget: 500 }).len < 1200
}

fn test_limits_are_honoured() {
	cov := sal_cov(long_spec())
	many := select_clauses(cov.clauses, 'rule subsystem background prose',
		SalienceOpts{ limit: 3 })
	assert many.len <= 3
}

fn test_tool_names_participate_in_relevance() {
	cov := sal_cov(long_spec())
	with_tools := select_clauses(cov.clauses, 'make the change', SalienceOpts{
		tools: ['write_file', 'migrations', 'schema']
	})
	assert 'MIG' in with_tools.map(it.clause_id), '${with_tools.map(it.clause_id)}'
}

fn test_selection_is_deterministic() {
	cov := sal_cov(long_spec())
	a := select_clauses(cov.clauses, 'SELECT repository log', SalienceOpts{}).map(it.clause_id)
	b := select_clauses(cov.clauses, 'SELECT repository log', SalienceOpts{}).map(it.clause_id)
	assert a == b
}

fn test_measured_adherence_decides_the_scarce_slot() {
	cov := sal_cov('[HELD] tokens are redacted before logging\n' +
		'[MISSED] tokens are redacted before logging in handlers\n')
	req := 'redact tokens before logging'
	boosted := select_clauses(cov.clauses, req, SalienceOpts{
		limit:   1
		weights: {
			'MISSED': 2.0
			'HELD':   0.6
		}
	}).map(it.clause_id)
	assert boosted == ['MISSED'], '${boosted}'

	// a weight can never conjure a clause the request does not touch
	assert select_clauses(cov.clauses, 'what time is it', SalienceOpts{
		weights: {
			'MISSED': 99.0
		}
	}).len == 0
}

fn test_an_empty_specification_produces_nothing() {
	cov := sal_cov('')
	assert salience_block(cov.clauses, 'anything', SalienceOpts{}) == ''
}

fn test_terms_drops_stopwords_and_short_words() {
	t := terms('The repository MUST handle SELECT queries')
	assert 'repository' in t
	assert 'select' in t
	assert 'queries' in t
	assert 'the' !in t
	assert 'must' !in t
}

// -- integrity ---------------------------------------------------------------

fn integ_fixture(name string) (string, &EventLog, &Integrity) {
	dir := os.join_path(os.temp_dir(), 'vagent-integ-${os.getpid()}', name)
	os.rmdir_all(dir) or {}
	os.mkdir_all(dir) or { panic(err) }
	mut log := new_event_log(tmp_log_path('${name}.jsonl'), 'main', '')
	return dir, log, new_integrity(log)
}

const integ_spec = '§1 Writes stay under src\n@enforce confine_paths: src\n' +
	'§2 Prose only, no rule here.\n'

fn test_integrity_seal_and_agreement() {
	dir, mut log, mut integ := integ_fixture('agree')
	defer {
		log.close()
	}
	spec_file := os.join_path(dir, 'project.txt')
	os.write_file(spec_file, integ_spec) or { panic(err) }

	mut cov := new_covenant(log, integ_spec)
	sealed := integ.seal(integ_spec, spec_file, cov)
	assert sealed.clauses == 2 && sealed.enforced == 1
	assert sealed.digest.len == 64

	r := integ.verify(integ_spec, cov, spec_file)
	assert r.ok(), r.describe()
	assert r.describe().contains('agree')
}

fn test_a_file_edited_mid_session_drifts_and_is_not_repaired() {
	dir, mut log, mut integ := integ_fixture('drift')
	defer {
		log.close()
	}
	spec_file := os.join_path(dir, 'project.txt')
	os.write_file(spec_file, integ_spec) or { panic(err) }
	mut cov := new_covenant(log, integ_spec)
	integ.seal(integ_spec, spec_file, cov)

	os.write_file(spec_file, integ_spec + '§3 A new rule nobody loaded.\n') or { panic(err) }
	r := integ.verify(integ_spec, cov, spec_file)
	assert r.state == integrity_drifted, r.describe()
	assert r.describe().contains('has changed since it was loaded')
	// the loaded copy is untouched — nothing reloaded itself
	assert cov.clauses.len == 2

	// after an explicit reconcile, they agree again
	newspec := os.read_file(spec_file)!
	cov.bind(newspec)
	integ.seal(newspec, spec_file, cov)
	assert integ.verify(newspec, cov, spec_file).ok()
}

fn test_prompt_and_boundary_parsed_from_different_bytes_is_a_split() {
	dir, mut log, mut integ := integ_fixture('split')
	defer {
		log.close()
	}
	spec_file := os.join_path(dir, 'project.txt')
	os.write_file(spec_file, integ_spec) or { panic(err) }
	mut cov := new_covenant(log, integ_spec)
	integ.seal(integ_spec, spec_file, cov)

	mut other := new_covenant(log, '§9 something else entirely\n' +
		'@enforce forbid_effect: delete\n')
	r := integ.verify(integ_spec, other, spec_file)
	assert r.state == integrity_split, r.describe()
	assert r.describe().contains("not parsed from the prompt's bytes")
}

fn test_a_specification_that_binds_nothing_says_so() {
	dir, mut log, mut integ := integ_fixture('prose')
	defer {
		log.close()
	}
	prose := '§1 Be careful.\n§2 Write good code.\n'
	pf := os.join_path(dir, 'prose.txt')
	os.write_file(pf, prose) or { panic(err) }
	mut pcov := new_covenant(log, prose)
	integ.seal(prose, pf, pcov)
	r := integ.verify(prose, pcov, pf)
	assert !r.ok()
	assert r.describe().contains('prose to the boundary')
}

fn test_no_specification_at_all() {
	_, mut log, mut integ := integ_fixture('absent')
	defer {
		log.close()
	}
	mut empty := new_covenant(log, '')
	r := integ.verify('', empty, '')
	assert r.state == integrity_absent
	assert r.describe().contains('governs nothing')
}

fn test_a_missing_file_is_reported_and_the_loaded_copy_stays_in_force() {
	dir, mut log, mut integ := integ_fixture('missing')
	defer {
		log.close()
	}
	spec_file := os.join_path(dir, 'project.txt')
	os.write_file(spec_file, integ_spec) or { panic(err) }
	mut cov := new_covenant(log, integ_spec)
	integ.seal(integ_spec, spec_file, cov)

	os.rm(spec_file) or { panic(err) }
	r := integ.verify(integ_spec, cov, spec_file)
	assert r.state == integrity_drifted
	assert r.describe().contains('unreadable')
	assert cov.clauses.len == 2, 'the boundary lost clauses on an error'
}

fn test_drift_is_sealed_never_silent() {
	dir, mut log, mut integ := integ_fixture('sealed')
	defer {
		log.close()
	}
	spec_file := os.join_path(dir, 'project.txt')
	os.write_file(spec_file, integ_spec) or { panic(err) }
	mut cov := new_covenant(log, integ_spec)
	integ.seal(integ_spec, spec_file, cov)
	os.write_file(spec_file, integ_spec + '§3 more\n') or { panic(err) }
	integ.verify(integ_spec, cov, spec_file)

	mut saw_seal := false
	mut saw_drift := false
	for e in log.events('') {
		if e.typ == 'integrity.sealed' {
			saw_seal = true
		}
		if e.typ == 'integrity.drift' {
			saw_drift = true
		}
	}
	assert saw_seal && saw_drift
}
