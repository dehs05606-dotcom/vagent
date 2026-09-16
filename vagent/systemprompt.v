module vagent

// systemprompt.v — the ONE home of every system prompt in vagent.
//
// Every prompt the model ever sees lives here and nowhere else. The rest of
// the codebase only ever imports from this file — no inline prompt strings
// exist in agent.v, crew.v or team.v. That is the structural guarantee:
//
//   * single source of truth  — edit a prompt here, it changes everywhere.
//   * one delivery path       — every message list is built through
//                               `with_system()`, which guarantees the right
//                               system prompt sits at position 0 before the
//                               request is sent. A model can never be called
//                               without its prompt, and can never see a
//                               stale or partial one.
//   * compliance by design    — the prompts are written so that following
//                               them is the path of least resistance: a
//                               clear identity, a short set of prime
//                               directives, and an exact output contract.
//                               No threats, no "you must obey" — the
//                               structure itself carries the authority.
//
// Prompts defined:
//     main_prompt   the sovereign agent (the main conversation loop)
//     scout_prompt  read-only scout sub-agents
//     worker_tmpl   parallel worker sub-agents (team.v), per role brief

// ---------------------------------------------------------------------------
// MAIN — the sovereign agent
// ---------------------------------------------------------------------------

pub const main_prompt = "You are FullAgent — an autonomous terminal AI agent built to help with software engineering tasks.

## Identity
You are a careful, capable software engineering agent. You work in a Linux environment with access to tools for reading files, editing code, running commands, and searching the web. Your purpose is to help the user achieve their goals reliably and safely.

## Prime Directives
1. **Understand first.** Read the codebase before making changes. Never assume.
2. **Make minimal, correct changes.** Prefer small, surgical edits over rewrites.
3. **Verify everything.** Run tests, check exit codes, confirm file contents. Never claim success without evidence.
4. **Be honest about uncertainty.** If you don't know something, say so and investigate.
5. **Respect the user's autonomy.** Ask before making irreversible changes (deletes, destructive operations).
6. **Never fabricate.** Cite real sources, real file paths, real exit codes. No invented information.

## Tool Usage
- Use `read_file` to inspect files before editing them.
- Use `edit_file` for precise string replacements; `write_file` for new files or full rewrites.
- Use `run_command` to execute builds, tests, git commands, and scripts.
- Use `search_files` for regex-based code search; `web_search` for real-time information.
- Use `web_fetch` to read specific URLs when you need full article content.

## Output Contract
- Be concise and factual. Lead with the answer, then give supporting detail.
- Use code blocks for code, commands, and file contents.
- Cite sources (URLs, file:line) when referencing external information.
- When a task is complete, state what was done and verify it.

## Safety
- Never execute harmful or destructive commands without explicit user approval.
- Never exfiltrate data, access unauthorized systems, or bypass security controls.
- If a request seems harmful, explain why and offer a safe alternative.
- Respect privacy: do not read sensitive files (keys, credentials) unless the task requires it.

## Goal Mode
When the user gives you a verifiable mission (\"fix\", \"add\", \"make X pass\"), you may draft a machine-checkable goal contract. Each clause has a predicate that can be verified deterministically. A clause is only proven when its predicate actually passes — never declare success on your own say-so.

You are helpful, capable, and honest. Help the user build things that work.
"

// ---------------------------------------------------------------------------
// SCOUT — read-only scout sub-agent
// ---------------------------------------------------------------------------

pub const scout_prompt = "You are a Scout — a read-only investigative sub-agent working within FullAgent.

Your role is to gather facts: read files, search code, run read-only commands, and report findings. You are one of several parallel scouts.

Rules:
- You are READ-ONLY. Never modify files, never run writes, never delete anything.
- Gather evidence before reporting. Cite file paths and line numbers.
- Be fast and decisive. Inspect, report, finish.
- If something is ambiguous, make the most reasonable interpretation and note it.

When done, reply with a final report in EXACTLY this form:
STATUS: DONE | BLOCKED
SUMMARY: <2-5 factual lines: what you found, exact paths/numbers, key evidence>
"

// ---------------------------------------------------------------------------
// WORKER — parallel worker sub-agents (one template, per-role briefs)
// ---------------------------------------------------------------------------

pub const worker_tmpl = "You are {role_brief}

You are one of up to {max_workers} workers running IN PARALLEL on the same machine. Rules:
- Complete ONLY your assigned task; other workers handle the rest.
- Work fast and decisively: inspect, act, verify, finish.
- Use your tools to gather real evidence before claiming anything.
- If your task is ambiguous, do the most reasonable interpretation and note it.

When done, reply with a final report in EXACTLY this form:
STATUS: DONE | BLOCKED
SUMMARY: <2-5 factual lines: what you did, what you found, exact paths/numbers>"

// Role briefs slot into the worker template. Kept here (not in team.v) so
// every word the model reads is defined in this one file.
pub const role_briefs = {
	'researcher': "a RESEARCH specialist. Gather facts from the web and the codebase. Cite sources (URLs, file:line). Never modify anything."
	'coder': "a senior SOFTWARE ENGINEER. Read before you write; make minimal, correct changes; keep existing style and conventions."
	'tester': "a QA / TEST engineer. Run builds, tests and checks; report exact exit codes, failures and the minimal reproduction. Never modify source files."
	'reviewer': "a CODE REVIEWER. Inspect the code and report bugs, risks and style problems with file:line evidence. Never modify anything."
	'analyst': "a DATA / SYSTEMS analyst. Combine local evidence and live web data into numbers, comparisons and a verdict. Never modify anything."
}

// The role order the UI lists, since a V map does not preserve insertion
// order across builds.
pub const role_names = ['researcher', 'coder', 'tester', 'reviewer', 'analyst']

// ---------------------------------------------------------------------------
// SPEC — the master specification, and the ONLY place it lives
// ---------------------------------------------------------------------------
// The specification used to be read from a file: $FULLAGENT_SPEC, then
// ~/.fullagent/project.txt, then a project.txt shipped in the package. That
// is one indirection too many, and every one of those hops was a way for the
// prompt the model receives to stop being the prompt this file declares:
//
//   * a file can be swapped, truncated, or simply absent, and the agent
//     starts with 2k chars of preamble where a full specification belongs —
//     which is exactly the failure this project already hit once, silently
//   * an environment variable moves the prompt outside the repository, so
//     nothing under version control describes what the model was told
//   * three candidate paths mean the answer to "which prompt is in force?"
//     depends on the machine it is asked on
//
// So the specification is no longer data that is loaded. It is CODE that
// ships: a constant in this module, under version control, content-addressed
// by integrity.v and protected from the agent's own tool calls by sanctum.v.
// There is no file to lose, no path to resolve, and no environment in which
// a different specification can appear.
//
// TO INSTALL YOUR SPECIFICATION: paste it between the quotes below.
// Nothing else needs changing — master_prompt() is rebuilt from it.

pub const spec = ''

// spec_chars is the length of the compiled-in specification.
pub fn spec_chars() int {
	return spec.len
}

// spec_status is a one-line report of the specification compiled into this
// module.
pub fn spec_status() string {
	if spec.trim_space() == '' {
		return 'master spec is EMPTY — MASTER carries no specification.\n' +
			'  Paste it into the `spec` constant in systemprompt.v; ' +
			'there is no file to place.'
	}
	return 'master spec: ${thousands(spec.len)} chars, compiled into systemprompt.v'
}

const spec_banner_rule = '========================================================================'

// build_master is main_prompt + the specification, verbatim. The spec is
// never trimmed, summarised or sampled — a partially-delivered
// specification is worse than none, because the model cannot tell which
// half it is missing.
//
// An empty spec returns main_prompt unchanged rather than main_prompt plus
// a banner: a MASTER that announces a specification it does not carry is
// how a missing spec stayed invisible here once already.
fn build_master(s string) string {
	if s.trim_space() == '' {
		return main_prompt
	}
	return main_prompt + '\n\n' + spec_banner_rule +
		'\nFULL MASTER SPECIFICATION — the architecture you operate within. ' +
		'Treat every invariant, subsystem contract and Goal-Mode rule below ' +
		'as binding.\n' + spec_banner_rule + '\n\n' + s
}

pub const master_prompt = build_master(spec)

// ---------------------------------------------------------------------------
// Builders — the only functions the rest of the code calls
// ---------------------------------------------------------------------------

// bind_spec appends the specification to a sub-agent's prompt.
//
// The specification used to reach the sovereign agent and nothing else.
// Every sub-agent — the coder, the tester, the refactorer, the one that
// actually writes the files — received a ~640-char role brief carrying none
// of the author's rules, so the rules governed the agent that delegates and
// not one of the agents that act.
//
// That is the whole specification failing quietly. A rule about how code is
// written does not reach the thing writing the code, and the work comes back
// out of policy through a route nobody closed.
//
// The cost is real and is the right trade: every sub-agent request now
// carries the full specification. A specification cheap enough to skip for
// the workers is one the workers do not follow.
fn bind_spec(prompt string) string {
	if spec.trim_space() == '' {
		return prompt
	}
	return prompt + '\n\n' + spec_banner_rule +
		'\nFULL MASTER SPECIFICATION — binding on you exactly as it is on ' +
		'the agent that dispatched you. Every invariant and contract below ' +
		'applies to your work.\n' + spec_banner_rule + '\n\n' + spec
}

// prompt_main is the sovereign agent's system prompt.
pub fn prompt_main() string {
	return main_prompt
}

// prompt_scout is a scout sub-agent's system prompt.
pub fn prompt_scout() string {
	return bind_spec(scout_prompt)
}

// prompt_worker is a worker sub-agent's system prompt for the given role.
pub fn prompt_worker(role string, max_workers int) string {
	brief := role_briefs[role] or { role_briefs['coder'] or { '' } }
	body := worker_tmpl.replace('{role_brief}', brief).replace('{max_workers}',
		max_workers.str())
	return bind_spec(body)
}

// ---------------------------------------------------------------------------
// Message delivery
// ---------------------------------------------------------------------------

// with_system guarantees the system prompt is present and first.
//
// This is the single delivery path: every request to a model is built
// through here. If messages[0] is not already the system prompt, it is
// (re)placed — so the model always sees the full, current prompt from this
// file, and nothing upstream can accidentally drop or shadow it.
pub fn with_system(mut messages []Message, system string) []Message {
	if messages.len > 0 && messages[0].role == 'system' {
		messages[0] = Message{
			role:    'system'
			content: system
		}
	} else {
		messages.prepend(Message{
			role:    'system'
			content: system
		})
	}
	return messages
}

// ---------------------------------------------------------------------------
// Prompt registry — add more system prompts here later
// ---------------------------------------------------------------------------
// Every selectable system prompt lives in this one registry. To add another
// prompt later, either drop a new constant above and register it here, or
// call register() at runtime. prompt_get() resolves a name to its prompt,
// falling back to main so an unknown name can never leave the model
// promptless.

__global (
	prompt_registry shared map[string]string
)

// The prompts this module DECLARES. They are the single source of truth and
// cannot be replaced at runtime — see register().
pub const sovereign_prompts = ['main', 'master', 'scout']

// prompt_get resolves a prompt name to its text (falls back to main).
pub fn prompt_get(name string) string {
	rlock prompt_registry {
		if v := prompt_registry[name] {
			return v
		}
	}
	return main_prompt
}

// PromptLocked is returned when something tries to replace a sovereign
// prompt.
pub struct PromptLocked {
	Error
pub:
	name string
}

pub fn (e PromptLocked) msg() string {
	return "'${e.name}' is declared in systemprompt.v and cannot be replaced " +
		'at runtime — edit the module, which is version-controlled, ' +
		"content-addressed and protected from the agent's own writes"
}

// register adds a named system prompt at runtime.
//
// Sub-agent roles are registered here legitimately (meta.v and evolution.v
// author `worker:*` prompts), so this door has to stay open. What it must
// not be is a way to replace the sovereign prompts: if `master` could be
// overwritten at runtime, "the specification lives in systemprompt.v" would
// be true only until something called this function, and the single source
// of truth would be a convention rather than a property.
pub fn register(name string, prompt string) ! {
	if name in sovereign_prompts {
		return PromptLocked{
			name: name
		}
	}
	lock prompt_registry {
		prompt_registry[name] = prompt
	}
}

// prompt_names lists the registered prompt names, sorted.
pub fn prompt_names() []string {
	mut out := []string{}
	rlock prompt_registry {
		out = prompt_registry.keys()
	}
	out.sort()
	return out
}
