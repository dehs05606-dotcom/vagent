module vagent

import sync

// roster.v — the roster is not fixed.
//
// team.v and systemprompt.v declare the roles the agent ships with, as
// consts, because that is where they are authored and they must be readable
// in one place. But meta.v forges NEW specialists at runtime and evolution.v
// rewrites briefs, so the set of roles the system actually has is larger
// than the set it was compiled with.
//
// This is that set. It starts as an exact copy of the consts and grows; a
// role is only ever ADDED or its brief replaced, never removed, so a worker
// prompt resolved earlier in a session stays resolvable later.
//
// It is a heap struct behind a mutex rather than a `shared map` because a
// shared map cannot be cloned out of its lock without tripping V's codegen,
// and every reader here wants a copy.

@[heap]
pub struct RoleRegistry {
mut:
	mu     sync.Mutex
	specs  map[string]RoleSpec
	briefs map[string]string
	// insertion order, so the UI lists roles the same way twice
	order []string
}

__global (
	role_registry &RoleRegistry
)

fn new_role_registry() &RoleRegistry {
	mut r := &RoleRegistry{}
	for name in role_names {
		if spec := roles[name] {
			r.specs[name] = spec
		}
		if brief := role_briefs[name] {
			r.briefs[name] = brief
		}
		r.order << name
	}
	// the advanced specialists in team.v are not in role_names, which lists
	// only what the UI shows; they are still real roles
	mut extra := []string{}
	for name, _ in roles {
		if name !in r.specs {
			extra << name
		}
	}
	extra.sort()
	for name in extra {
		if spec := roles[name] {
			r.specs[name] = spec
		}
		r.order << name
	}
	return r
}

// has reports whether a role exists — the gate meta.v uses to refuse a
// draft that would shadow one.
pub fn (mut r RoleRegistry) has(name string) bool {
	r.mu.@lock()
	defer {
		r.mu.unlock()
	}
	return name in r.specs
}

pub fn (mut r RoleRegistry) spec(name string) ?RoleSpec {
	r.mu.@lock()
	defer {
		r.mu.unlock()
	}
	return r.specs[name] or { return none }
}

pub fn (mut r RoleRegistry) brief(name string) ?string {
	r.mu.@lock()
	defer {
		r.mu.unlock()
	}
	return r.briefs[name] or { return none }
}

// names is every role, in the order they joined the roster.
pub fn (mut r RoleRegistry) names() []string {
	r.mu.@lock()
	defer {
		r.mu.unlock()
	}
	return r.order.clone()
}

// sorted_names is the roster alphabetically, which is what the reports show.
pub fn (mut r RoleRegistry) sorted_names() []string {
	mut out := r.names()
	out.sort()
	return out
}

// add installs a role. An existing name has its spec and brief replaced —
// evolution.v rewrites briefs in place — and keeps its position.
pub fn (mut r RoleRegistry) add(name string, spec RoleSpec, brief string) {
	r.mu.@lock()
	defer {
		r.mu.unlock()
	}
	if name !in r.specs {
		r.order << name
	}
	r.specs[name] = spec
	if brief != '' {
		r.briefs[name] = brief
	}
}

// set_brief replaces only the words, leaving the tool whitelist alone.
pub fn (mut r RoleRegistry) set_brief(name string, brief string) {
	r.mu.@lock()
	defer {
		r.mu.unlock()
	}
	r.briefs[name] = brief
}
