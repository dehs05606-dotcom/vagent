module vagent

import x.json2

const kg_auth_src = 'def login(user):
    return check(user)


def check(user):
    return True
'

const kg_main_src = "import auth


def run():
    return auth.login('x')
"

fn kg_fixture(name string) &KnowledgeGraph {
	mut g := new_knowledge_graph(new_event_log(tmp_log_path(name), 'main', 'test'))
	g.index_code({
		'auth': kg_auth_src
		'main': kg_main_src
	}) or { panic(err) }
	return g
}

fn test_indexing_code_names_every_module_and_function() {
	mut g := kg_fixture('kg1')
	for id in ['module:auth', 'function:auth.login', 'function:auth.check', 'function:main.run'] {
		if _ := g.entity(id) {
		} else {
			assert false, 'missing entity ${id}'
		}
	}
	// a name that was never indexed is absent rather than invented
	if _ := g.entity('function:auth.logout') {
		assert false, 'invented an entity'
	}
}

fn test_a_module_defines_its_functions_and_imports_its_dependencies() {
	mut g := kg_fixture('kg2')
	defs := g.out_of('module:auth', 'defines').map(it.dst)
	assert 'function:auth.login' in defs, defs.str()
	assert 'function:auth.check' in defs, defs.str()

	imports := g.out_of('module:main', 'imports').map(it.dst)
	assert 'module:auth' in imports, imports.str()

	// the reverse index agrees with the forward one
	defined_by := g.into('function:auth.login', 'defines').map(it.src)
	assert defined_by == ['module:auth'], defined_by.str()
}

fn test_a_call_is_found_from_the_callee_side() {
	mut g := kg_fixture('kg3')
	callers := g.callers_of('check')
	assert 'function:auth.login' in callers, callers.str()
	// a call is indexed under the text of the call site, so `auth.login('x')`
	// is `call:auth.login` and NOT `call:login` — the graph never guesses that
	// the attribute resolves to the module of the same name
	assert g.callers_of('auth.login') == ['function:main.run'], g.callers_of('auth.login').str()
	assert g.callers_of('login').len == 0
	assert g.callers_of('nonexistent').len == 0
}

fn test_reachability_follows_calls_across_modules() {
	mut g := kg_fixture('kg4')
	reach := g.reachable('function:main.run', 'calls', 6)
	mut hit := false
	for r in reach {
		if r.contains('auth.login') {
			hit = true
		}
	}
	assert hit, reach.str()
}

fn test_impact_is_reachability_run_backwards() {
	mut g := kg_fixture('kg5')
	// changing check() breaks login(), which calls it
	impact := g.impact('function:auth.check')
	assert 'function:auth.login' in impact, impact.str()
}

fn test_find_matches_by_name_within_a_kind() {
	mut g := kg_fixture('kg6')
	hits := g.find('login', 'function')
	assert hits.len == 1, hits.len.str()
	assert hits[0].name == 'login'
	// the same name under the wrong kind matches nothing
	assert g.find('login', 'module').len == 0
}

fn test_the_event_log_contributes_goals_episodes_and_files() {
	mut log := new_event_log(tmp_log_path('kg7'), 'main', 'test')
	mut g := new_knowledge_graph(log)
	g.index_code({
		'auth': kg_auth_src
		'main': kg_main_src
	}) or { panic(err) }

	clause := {
		'id':    json2.Any('C1')
		'proof': json2.Any({
			'type': json2.Any('file_exists')
			'path': json2.Any('p.py')
		})
	}
	log.append('goal.set', {
		'id':        json2.Any('g1')
		'statement': json2.Any('ship parser')
		'clauses':   json2.Any([json2.Any(clause)])
	}, AppendOpts{ actor: 'test' })
	log.append('memory.episode', {
		'goal':    json2.Any('fix parser')
		'outcome': json2.Any('success')
		'facts':   json2.Any([json2.Any('tokenizer is line-based')])
	}, AppendOpts{ actor: 'test' })

	added := g.index_log()
	assert added >= 2, added.str()
	if _ := g.entity('goal:g1') {
	} else {
		assert false, 'the goal never became an entity'
	}
	// the clause proof names a file, so the goal touches it
	touches := g.out_of('goal:g1', 'touches').map(it.dst)
	assert 'file:p.py' in touches, touches.str()

	s := g.stats()
	assert (s['entities'] or { json2.Any(0) }).int() > 5, s.str()
	assert (s['relations'] or { json2.Any(0) }).int() > 5, s.str()
	assert g.format_status().contains('KNOWLEDGE GRAPH')

	// every index is sealed into the log, so the fold can see it happened
	st := fold(mut log, 'main')
	assert st.graph_events.len > 0
}
