module vagent

import os
import x.json2

// kgraph.v — the knowledge graph.
//
// A real graph of the project and the session: entities (modules,
// functions, classes, files, goals, episodes, facts) and typed relations
// between them (defines, calls, imports, touches, learned). Built from two
// real sources:
//
//   * CODE  an AST walk: a module DEFINES its functions and classes, a
//           function CALLS the names it invokes, a module IMPORTS the
//           modules it imports. No guessing — the AST is the ground truth.
//   * LOG   the event fold: a goal TOUCHES the files its clauses name, an
//           episode LEARNED its facts.
//
// Queries are real graph operations — BFS reachability, reverse lookups,
// impact sets — so "what calls auth()?" and "what breaks if I change X?"
// are answered by walking edges rather than by asking a model.
//
// The graph is rebuilt from its sources on demand. It is a projection,
// never authoritative state.
//
// The AST half runs through the same harness taint.v uses, and for the same
// reason: the ground truth is CPython's parse, and a second parser that
// disagreed with it would make "no guessing" false.

pub const graph_kinds = ['module', 'function', 'class', 'file', 'goal', 'episode', 'fact']

pub struct Entity {
pub:
	id   string
	kind string
	name string
	meta map[string]json2.Any
}

pub fn (e &Entity) to_json() map[string]json2.Any {
	mut d := {
		'id':   json2.Any(e.id)
		'kind': json2.Any(e.kind)
		'name': json2.Any(e.name)
	}
	for k, v in e.meta {
		d[k] = v
	}
	return d
}

pub struct Relation {
pub:
	src string
	rel string
	dst string
}

pub fn (r &Relation) to_json() map[string]json2.Any {
	return {
		'src': json2.Any(r.src)
		'rel': json2.Any(r.rel)
		'dst': json2.Any(r.dst)
	}
}

const kgraph_harness = 'import ast, json, sys
from dataclasses import dataclass, field


@dataclass
class Entity:
    id: str
    kind: str
    name: str
    meta: dict = field(default_factory=dict)

    def to_dict(self):
        return {"id": self.id, "kind": self.kind, "name": self.name, **self.meta}


@dataclass
class Relation:
    src: str
    rel: str
    dst: str

    def to_dict(self):
        return {"src": self.src, "rel": self.rel, "dst": self.dst}


def _call_name(node: ast.expr) -> str:
    if isinstance(node, ast.Name):
        return node.id
    if isinstance(node, ast.Attribute):
        parts = []
        cur = node
        while isinstance(cur, ast.Attribute):
            parts.append(cur.attr)
            cur = cur.value
        if isinstance(cur, ast.Name):
            parts.append(cur.id)
        return ".".join(reversed(parts))
    return ""


def extract_code(module_name: str, source: str) -> tuple[list[Entity],
                                                         list[Relation]]:
    """Entities + relations for one module, straight from the AST."""
    entities: list[Entity] = []
    relations: list[Relation] = []
    try:
        tree = ast.parse(source)
    except SyntaxError:
        return entities, relations

    mod_id = f"module:{module_name}"
    entities.append(Entity(mod_id, "module", module_name))

    # imports: module IMPORTS module
    for node in ast.walk(tree):
        if isinstance(node, ast.Import):
            for a in node.names:
                relations.append(Relation(mod_id, "imports",
                                          f"module:{a.name.split(\'.\')[0]}"))
        elif isinstance(node, ast.ImportFrom):
            root = (node.module or "").split(".")[0]
            if root:
                relations.append(Relation(mod_id, "imports",
                                          f"module:{root}"))

    # definitions + calls
    for node in ast.walk(tree):
        if isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef)):
            fid = f"function:{module_name}.{node.name}"
            entities.append(Entity(fid, "function", node.name,
                                   {"line": node.lineno,
                                    "module": module_name}))
            relations.append(Relation(mod_id, "defines", fid))
            # calls made inside this function
            for sub in ast.walk(node):
                if isinstance(sub, ast.Call):
                    name = _call_name(sub.func)
                    if name:
                        relations.append(Relation(fid, "calls",
                                                  f"call:{name}"))
        elif isinstance(node, ast.ClassDef):
            cid = f"class:{module_name}.{node.name}"
            entities.append(Entity(cid, "class", node.name,
                                   {"line": node.lineno,
                                    "module": module_name}))
            relations.append(Relation(mod_id, "defines", cid))
    return entities, relations




def main():
    sources = json.loads(sys.argv[1])
    entities, relations = [], []
    for name, text in sources.items():
        ents, rels = extract_code(name, text)
        entities.extend(e.to_dict() for e in ents)
        relations.extend(r.to_dict() for r in rels)
    print(json.dumps({"entities": entities, "relations": relations}))

main()
'

// extract_code returns the entities and relations of a set of modules,
// straight from the AST.
pub fn extract_code(sources map[string]string) !([]Entity, []Relation) {
	python := find_python() or { return error('no python interpreter found') }
	script := os.join_path(os.temp_dir(), 'vagent-kgraph-${os.getpid()}.py')
	os.write_file(script, kgraph_harness) or { return error('cannot write harness: ${err}') }
	defer {
		os.rm(script) or {}
	}
	mut payload_in := map[string]json2.Any{}
	for k, v in sources {
		payload_in[k] = json2.Any(v)
	}
	out := os.execute('${quote_arg(python)} ${quote_arg(script)} ${quote_arg(json2.encode(json2.Any(payload_in)))}')
	if out.exit_code != 0 {
		return error('extractor failed (${out.exit_code}): ${clip(out.output.trim_space(), 300)}')
	}
	mut payload := ''
	for line in split_lines(out.output) {
		if line.trim_space().starts_with('{') {
			payload = line.trim_space()
		}
	}
	parsed := json2.decode[json2.Any](payload) or { return error('unreadable extractor output') }
	if parsed !is map[string]json2.Any {
		return error('unreadable extractor output')
	}
	m := parsed.as_map()

	mut entities := []Entity{}
	for e in jarr(m, 'entities') {
		if e !is map[string]json2.Any {
			continue
		}
		row := e.as_map()
		mut meta := map[string]json2.Any{}
		for k, v in row {
			if k !in ['id', 'kind', 'name'] {
				meta[k] = v
			}
		}
		entities << Entity{
			id:   jstr(row, 'id')
			kind: jstr(row, 'kind')
			name: jstr(row, 'name')
			meta: meta.clone()
		}
	}
	mut relations := []Relation{}
	for r in jarr(m, 'relations') {
		if r !is map[string]json2.Any {
			continue
		}
		row := r.as_map()
		relations << Relation{
			src: jstr(row, 'src')
			rel: jstr(row, 'rel')
			dst: jstr(row, 'dst')
		}
	}
	return entities, relations
}

@[heap]
pub struct KnowledgeGraph {
pub mut:
	log &EventLog
mut:
	entities  map[string]Entity
	order     []string
	relations []Relation
	out_edges map[string][]Relation
	in_edges  map[string][]Relation
}

pub fn new_knowledge_graph(log &EventLog) &KnowledgeGraph {
	return &KnowledgeGraph{
		log: unsafe { log }
	}
}

// -- building -----------------------------------------------------------------

// index_code indexes a set of modules and returns the entity count.
pub fn (mut g KnowledgeGraph) index_code(sources map[string]string) !int {
	entities, relations := extract_code(sources)!
	for e in entities {
		g.put_entity(e)
	}
	for r in relations {
		g.add_relation(r)
	}
	g.log.append('graph.entity', {
		'entities':  json2.Any(g.entities.len)
		'relations': json2.Any(g.relations.len)
	}, AppendOpts{ actor: 'librarian' })
	return g.entities.len
}

fn (mut g KnowledgeGraph) put_entity(e Entity) {
	if e.id !in g.entities {
		g.order << e.id
	}
	g.entities[e.id] = e
}

fn (mut g KnowledgeGraph) add_relation(r Relation) {
	for existing in g.out_edges[r.src] {
		if existing.rel == r.rel && existing.dst == r.dst {
			return
		}
	}
	g.relations << r
	g.out_edges[r.src] << r
	g.in_edges[r.dst] << r
}

// index_log adds the session entities and relations from the event fold.
pub fn (mut g KnowledgeGraph) index_log() int {
	st := fold(mut g.log, g.log.branch)
	mut added := 0
	goal := st.goal or { Rec{} }
	if jstr(goal, 'statement') != '' {
		mut goal_id := jstr(goal, 'id')
		if goal_id == '' {
			goal_id = 'current'
		}
		gid := 'goal:${goal_id}'
		if gid !in g.entities {
			g.put_entity(Entity{
				id:   gid
				kind: 'goal'
				name: clip_plain(jstr(goal, 'statement'), 80)
			})
			added++
		}
		for clause in jarr(goal, 'clauses') {
			if clause !is map[string]json2.Any {
				continue
			}
			proof := jmap(clause.as_map(), 'proof')
			mut p := jstr(proof, 'path')
			if p == '' {
				p = jstr(proof, 'command')
			}
			if p == '' {
				continue
			}
			fid := 'file:${p}'
			if fid !in g.entities {
				g.put_entity(Entity{
					id:   fid
					kind: 'file'
					name: p
				})
				added++
			}
			g.add_relation(Relation{
				src: gid
				rel: 'touches'
				dst: fid
			})
		}
	}
	for i, ep in st.episodes {
		eid := 'episode:${i}'
		if eid !in g.entities {
			g.put_entity(Entity{
				id:   eid
				kind: 'episode'
				name: clip_plain(jstr(ep, 'goal'), 80)
			})
			added++
		}
		for fact in jstrs(ep, 'facts') {
			fid := 'fact:' + clip_plain(fact, 40)
			if fid !in g.entities {
				g.put_entity(Entity{
					id:   fid
					kind: 'fact'
					name: clip_plain(fact, 80)
				})
				added++
			}
			g.add_relation(Relation{
				src: eid
				rel: 'learned'
				dst: fid
			})
		}
	}
	return added
}

// -- queries -------------------------------------------------------------------

pub fn (g &KnowledgeGraph) entity(entity_id string) ?Entity {
	return g.entities[entity_id] or { return none }
}

// find is the entities whose name contains `name`, optionally of one kind.
pub fn (g &KnowledgeGraph) find(name string, kind string) []Entity {
	low := name.to_lower()
	mut out := []Entity{}
	for id in g.order {
		e := g.entities[id] or { continue }
		if e.name.to_lower().contains(low) && (kind == '' || e.kind == kind) {
			out << e
		}
	}
	return out
}

pub fn (g &KnowledgeGraph) out_of(entity_id string, rel string) []Relation {
	edges := g.out_edges[entity_id] or { return [] }
	return if rel == '' { edges } else { edges.filter(it.rel == rel) }
}

pub fn (g &KnowledgeGraph) into(entity_id string, rel string) []Relation {
	edges := g.in_edges[entity_id] or { return [] }
	return if rel == '' { edges } else { edges.filter(it.rel == rel) }
}

// callers_of is the reverse lookup: which functions call this name.
pub fn (g &KnowledgeGraph) callers_of(func_name string) []string {
	mut out := []string{}
	for r in g.relations {
		if r.rel == 'calls' && r.dst == 'call:${func_name}' {
			out << r.src
		}
	}
	out = uniq_strings(out)
	out.sort()
	return out
}

struct GraphStep {
	node  string
	depth int
}

// reachable is BFS from an entity over optionally-typed edges.
pub fn (g &KnowledgeGraph) reachable(start string, rel string, max_depth int) []string {
	mut seen := []string{}
	mut seen_set := map[string]bool{}
	seen_set[start] = true
	mut queue := [GraphStep{
		node:  start
		depth: 0
	}]
	for queue.len > 0 {
		step := queue[0]
		queue.delete(0)
		if step.depth >= max_depth {
			continue
		}
		for r in g.out_of(step.node, rel) {
			if seen_set[r.dst] {
				continue
			}
			seen_set[r.dst] = true
			seen << r.dst
			queue << GraphStep{
				node:  r.dst
				depth: step.depth + 1
			}
		}
	}
	return seen
}

// reverse_keys are the lookup keys for an entity's incoming edges.
//
// A function entity `function:<mod>.<name>` is also reached through the call
// pseudo-nodes that call sites target — both the bare `call:<name>` and the
// qualified `call:<mod>.<name>` forms.
fn reverse_keys(entity_id string) []string {
	mut keys := [entity_id]
	if entity_id.starts_with('function:') && entity_id.contains('.') {
		qual := entity_id.all_after('.')
		keys << 'call:${qual}'
		keys << 'call:' + qual.all_after_last('.')
	}
	return uniq_strings(keys)
}

// impact is reverse reachability: everything that depends on this entity.
// "What breaks if I change X?"
pub fn (g &KnowledgeGraph) impact(entity_id string) []string {
	mut seen := []string{}
	mut seen_set := map[string]bool{}
	seen_set[entity_id] = true
	mut queue := [entity_id]
	for queue.len > 0 {
		node := queue[0]
		queue.delete(0)
		for key in reverse_keys(node) {
			for r in g.in_edges[key] or { []Relation{} } {
				if seen_set[r.src] {
					continue
				}
				seen_set[r.src] = true
				seen << r.src
				queue << r.src
			}
		}
	}
	return seen
}

pub fn (g &KnowledgeGraph) stats() map[string]json2.Any {
	mut kinds := map[string]int{}
	for _, e in g.entities {
		kinds[e.kind] = kinds[e.kind] + 1
	}
	mut rels := map[string]int{}
	for r in g.relations {
		rels[r.rel] = rels[r.rel] + 1
	}
	mut kj := map[string]json2.Any{}
	for k, v in kinds {
		kj[k] = json2.Any(v)
	}
	mut rj := map[string]json2.Any{}
	for k, v in rels {
		rj[k] = json2.Any(v)
	}
	return {
		'entities':  json2.Any(g.entities.len)
		'relations': json2.Any(g.relations.len)
		'kinds':     json2.Any(kj)
		'rels':      json2.Any(rj)
	}
}

pub fn (g &KnowledgeGraph) format_status() string {
	s := g.stats()
	mut lines := ['KNOWLEDGE GRAPH',
		'  entities ${jint(s, "entities")}   relations ${jint(s, "relations")}']
	kinds := jmap(s, 'kinds')
	if kinds.len > 0 {
		mut keys := kinds.keys()
		keys.sort()
		lines << '  kinds: ' + keys.map('${it}×${jint(kinds, it)}').join('  ')
	}
	rels := jmap(s, 'rels')
	if rels.len > 0 {
		mut keys := rels.keys()
		keys.sort()
		lines << '  rels:  ' + keys.map('${it}×${jint(rels, it)}').join('  ')
	}
	return lines.join('\n')
}
