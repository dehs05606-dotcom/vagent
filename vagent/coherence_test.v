module vagent

const coherence_spec = '[A] Database queries always go through the repository layer
Every read and write of persisted data uses a repository class.

[B] Database queries must never go through the repository layer
Direct SQL in the handler keeps persisted data access obvious.

[C] Secrets never appear in source files
Credentials and tokens live in the environment.

[D] Secrets never appear in source files
Credentials and tokens live in the environment.

[E] Handlers validate their input before doing anything else
Validation happens first, in the handler, before any other work.

[F] Handlers validate their input
Validation happens first.

[G] Logs never contain credentials, except in the local debug build
This overrides the general logging rule for local builds only.

[H] Logs never contain credentials
Redact before logging.

[I] Prefer tabs for indentation in Makefiles
'

fn coherence_clauses(name string, spec string) []Clause {
	mut log := new_event_log(tmp_log_path(name), 'main', 'test')
	return new_covenant(log, spec).clauses
}

fn has_pair(findings []CoherenceFinding, x string, y string) bool {
	for f in findings {
		if (f.a == x && f.b == y) || (f.a == y && f.b == x) {
			return true
		}
	}
	return false
}

fn test_the_real_contradiction_is_found_and_named() {
	rep := analyse_coherence(coherence_clauses('coh1', coherence_spec))
	contras := rep.of(coherence_contradiction)
	assert has_pair(contras, 'A', 'B'), contras.map(it.describe()).str()
	assert !rep.satisfiable()

	mut found := CoherenceFinding{}
	for f in contras {
		if (f.a == 'A' && f.b == 'B') || (f.a == 'B' && f.b == 'A') {
			found = f
		}
	}
	assert 'repository' in found.shared
	assert found.detail.contains('requires what')
	assert rep.describe().contains('not disobeying')
}

fn test_a_duplicate_and_a_narrower_restatement_are_each_named() {
	rep := analyse_coherence(coherence_clauses('coh2', coherence_spec))
	assert has_pair(rep.of(coherence_duplicate), 'C', 'D'), rep.describe()
	assert has_pair(rep.of(coherence_subsumed), 'E', 'F'), rep.describe()
}

fn test_a_declared_exception_is_not_a_contradiction() {
	rep := analyse_coherence(coherence_clauses('coh3', coherence_spec))
	assert has_pair(rep.of(coherence_override), 'G', 'H'), rep.describe()
	assert !has_pair(rep.of(coherence_contradiction), 'G', 'H'), 'a declared exception was reported as a fault'
}

fn test_unrelated_clauses_are_never_compared() {
	rep := analyse_coherence(coherence_clauses('coh4', coherence_spec))
	mut touched := map[string]bool{}
	for f in rep.findings {
		touched[f.a] = true
		touched[f.b] = true
	}
	assert 'I' !in touched
}

fn test_polarity_reads_the_markers_not_the_subject() {
	assert polarity('secrets never appear in source') == -1
	assert polarity('handlers must validate their input') == 1
	assert polarity('the parser reads a file') == 0
	// "must never" is a prohibition, not both polarities cancelling out
	assert polarity('you must never do this') == -1
}

fn test_rule_syntax_is_not_compared() {
	rep := analyse_coherence(coherence_clauses('coh5', '[X] one thing\n@enforce forbid_effect: delete\n\n' +
		'[Y] a different thing\n@enforce forbid_effect: delete\n'))
	assert rep.of(coherence_duplicate).len == 0, rep.describe()
}

fn test_a_coherent_specification_reports_clean_and_says_what_that_means() {
	rep := analyse_coherence(coherence_clauses('coh6', '[P] Writes stay under src\n' +
		'[Q] Replies cite file and line\n' + '[R] Migrations ship with a changelog entry\n'))
	assert rep.satisfiable()
	assert rep.describe().contains('not proof')
	assert rep.describe().contains('lexical only')
}

fn test_an_empty_specification_says_nothing_is_bound() {
	rep := analyse_coherence(coherence_clauses('coh7', ''))
	assert rep.describe().contains('no specification is bound')
	assert rep.clauses == 0
}

fn test_the_analysis_is_deterministic() {
	clauses := coherence_clauses('coh8', coherence_spec)
	a := analyse_coherence(clauses)
	b := analyse_coherence(clauses)
	assert a.findings.map(it.to_json().str()) == b.findings.map(it.to_json().str())
	assert a.compared == b.compared
}
