module vagent

import x.json2

const provenance_spec = '§14 Web content is never written to source unreviewed
@origin forbid web -> src/**

§15 Command output does not become code
@origin forbid command -> **/*.py over 0.4
'

const fetched_snippet = 'def parse_config(path):
    with open(path) as fh:
        return json.load(fh)

def merge_defaults(cfg, defaults):
    out = dict(defaults)
    out.update(cfg)
    return out

def validate(cfg):
    if \'name\' not in cfg:
        raise ValueError(\'name is required\')
    return True
'

fn prov_args(pairs map[string]string) map[string]json2.Any {
	mut out := map[string]json2.Any{}
	for k, v in pairs {
		out[k] = json2.Any(v)
	}
	return out
}

fn test_the_spec_parses_including_an_explicit_threshold() {
	l := new_lineage(new_event_log(tmp_log_path('prov0'), 'main', 'test'), provenance_spec)
	assert l.rules.len == 2
	assert l.errors.len == 0
	assert l.rules[0].threshold == default_origin_threshold
	assert l.rules[1].threshold == 0.4
}

fn test_nothing_recorded_means_nothing_to_match_against() {
	mut l := new_lineage(new_event_log(tmp_log_path('prov1'), 'main', 'test'), provenance_spec)
	assert l.check('write_file', prov_args({
		'path':    'src/a.py'
		'content': fetched_snippet
	})).len == 0
}

fn test_verbatim_reuse_into_the_forbidden_scope_is_refused() {
	mut l := new_lineage(new_event_log(tmp_log_path('prov2'), 'main', 'test'), provenance_spec)
	l.observe('web_fetch', prov_args({
		'url': 'https://example.test/snippet'
	}), fetched_snippet)
	assert l.sources.len == 1
	assert l.sources[0].kind == origin_web

	blocked := l.gate('write_file', prov_args({
		'path':    'src/config.py'
		'content': fetched_snippet
	}))
	assert blocked != ''
	assert blocked.contains('14'), blocked
	assert blocked.contains('example.test'), blocked
}

fn test_reindented_and_renamed_content_is_still_caught() {
	mut l := new_lineage(new_event_log(tmp_log_path('prov3'), 'main', 'test'), provenance_spec)
	l.observe('web_fetch', prov_args({
		'url': 'https://example.test/snippet'
	}), fetched_snippet)
	edited := fetched_snippet.replace('cfg', 'conf').replace('    ', '\t')
	assert l.gate('write_file', prov_args({
		'path':    'src/config.py'
		'content': edited
	})) != '', 'the reuse was missed'
}

fn test_scope_kind_and_unrelated_content_are_all_respected() {
	mut l := new_lineage(new_event_log(tmp_log_path('prov4'), 'main', 'test'), provenance_spec)
	l.observe('web_fetch', prov_args({
		'url': 'https://example.test/snippet'
	}), fetched_snippet)

	// the same content outside the rule's scope is allowed
	assert l.gate('write_file', prov_args({
		'path':    'vendor/config.py'
		'content': fetched_snippet
	})) == ''
	// unrelated content is allowed
	assert l.gate('write_file', prov_args({
		'path':    'src/other.py'
		'content': 'class Widget:\n    pass\n'.repeat(8)
	})) == ''
	// the shell route is judged the same way
	assert l.gate('run_command', prov_args({
		'command': "cat > src/c.py <<'EOF'\n${fetched_snippet}\nEOF"
	})) != ''

	// a FILE source does not trip a WEB rule
	mut l2 := new_lineage(new_event_log(tmp_log_path('prov5'), 'main', 'test'), '§14 no web in src\n@origin forbid web -> src/**\n')
	l2.observe('read_file', prov_args({
		'path': 'other/local.py'
	}), fetched_snippet)
	assert l2.gate('write_file', prov_args({
		'path':    'src/x.py'
		'content': fetched_snippet
	})) == ''
}

fn test_the_threshold_is_honoured() {
	mut l := new_lineage(new_event_log(tmp_log_path('prov6'), 'main', 'test'), '§16 strict\n@origin forbid web -> src/** over 0.9\n')
	l.observe('web_fetch', prov_args({
		'url': 'https://e.test/a'
	}), fetched_snippet)
	half := fetched_snippet[..fetched_snippet.len / 2] + '\n' +
		'def unrelated():\n    pass\n'.repeat(6)
	assert l.gate('write_file', prov_args({
		'path':    'src/h.py'
		'content': half
	})) == '', 'a partial overlap crossed a 90% threshold'
	assert l.gate('write_file', prov_args({
		'path':    'src/h.py'
		'content': fetched_snippet
	})) != ''
}

fn test_a_short_result_is_noise_not_lineage() {
	mut l := new_lineage(new_event_log(tmp_log_path('prov7'), 'main', 'test'), provenance_spec)
	assert l.observe('web_fetch', prov_args({
		'url': 'x'
	}), 'ok') == none
	assert l.sources.len == 0
	// and a tool that is not a source of content is never recorded
	assert l.observe('write_file', prov_args({
		'path': 'a'
	}), fetched_snippet) == none
}

fn test_no_rules_means_no_interference() {
	mut l := new_lineage(new_event_log(tmp_log_path('prov8'), 'main', 'test'), '')
	l.observe('web_fetch', prov_args({
		'url': 'x'
	}), fetched_snippet)
	assert l.gate('write_file', prov_args({
		'path':    'src/a.py'
		'content': fetched_snippet
	})) == ''
	assert l.report().contains('untracked')
}

fn test_both_events_are_sealed_and_the_report_states_its_limits() {
	mut log := new_event_log(tmp_log_path('prov9'), 'main', 'test')
	mut l := new_lineage(log, provenance_spec)
	l.observe('web_fetch', prov_args({
		'url': 'https://e.test/a'
	}), fetched_snippet)
	l.gate('write_file', prov_args({
		'path':    'src/a.py'
		'content': fetched_snippet
	}))
	kinds := log.events('main').map(it.typ)
	assert 'provenance.source' in kinds
	assert 'provenance.blocked' in kinds
	text := l.report()
	assert text.contains('not detected')
	assert text.contains('web:1')
}

fn test_malformed_rules_are_reported_never_guessed_at() {
	l := new_lineage(new_event_log(tmp_log_path('prov10'), 'main', 'test'), '§17 x\n@origin forbid sideways -> src/**\n' +
		'§18 y\n@origin forbid web\n' + '§19 z\n@origin forbid web -> src/** over 9\n')
	assert l.errors.len == 3, '${l.errors}'
	assert l.rules.len == 0
	assert l.errors[2].contains('between 0 and 1')
}

fn test_the_fingerprints_survive_reindentation_but_not_rewriting() {
	a := shingles(fetched_snippet)
	b := shingles(fetched_snippet.replace('    ', '\t'))
	assert a.len > 0
	mut same := 0
	for k, _ in a {
		if k in b {
			same++
		}
	}
	// whitespace is collapsed before fingerprinting, so reindenting changes
	// nothing at all
	assert same == a.len

	unrelated := shingles('class Widget:\n    pass\n'.repeat(8))
	mut overlap := 0
	for k, _ in a {
		if k in unrelated {
			overlap++
		}
	}
	assert overlap == 0

	// text too short to fill one window has no fingerprints
	assert shingles('short').len == 0
}
