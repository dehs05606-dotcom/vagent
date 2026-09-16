module vagent

import rand
import time
import x.json2

// team.v — the shared worker-subagent substrate.
//
// The parallel fan-out machinery is gone: every subagent runs through the
// persistent CREW (crew.v), which is the ONLY way to execute a worker. This
// file keeps the pieces the whole system shares:
//
//     roles               role -> tool whitelist + write permission
//     WorkerReport        the compact structured report a worker collapses
//                         into
//     parse_worker_final  split a worker's final STATUS/SUMMARY reply
//     chat_with_retry     rate-limit-hardened model call (crew + evaluators)
//     write_lock          ONE global write lock — the Crew's agents can
//                         never mutate the world at the same time
//                         (invariant I7)
//
// Nothing a worker does pollutes the main conversation: each worker
// collapses into a compact structured WorkerReport, and its lifecycle is
// sealed as crew.* events in the log.

pub const max_worker_steps = 96 // tool-loop budget per worker
pub const max_workers = 8 // roster ceiling; baked into worker prompts
pub const max_summary_chars = 1800
pub const rate_limit_retries = 8 // retries when the provider rate-limits
pub const rate_limit_base_wait = 2.0 // seconds; doubles each retry (+ jitter)

// One global write lock: writes serialise across ALL subagents (§16.1).
__global (
	write_lock shared []bool
)

// acquire_write_lock blocks until no other subagent holds the write lock.
pub fn acquire_write_lock() {
	for {
		mut got := false
		lock write_lock {
			if write_lock.len == 0 {
				write_lock = [true]
				got = true
			}
		}
		if got {
			return
		}
		time.sleep(2 * time.millisecond)
	}
}

pub fn release_write_lock() {
	lock write_lock {
		write_lock = []
	}
}

pub struct RoleSpec {
pub:
	tools  []string
	writes bool
}

// roles maps a role to its tool whitelist and write permission. Reads fan
// out freely; only builder roles get write tools, and those go through the
// write lock. The role BRIEFS — the words the model actually reads — live
// in systemprompt.v, so every prompt is defined in one file.
pub const roles = {
	'researcher': RoleSpec{
		tools:  ['read_file', 'list_dir', 'file_info', 'search_files', 'glob_files',
			'web_search', 'web_fetch']
		writes: false
	}
	'coder':      RoleSpec{
		tools:  ['read_file', 'list_dir', 'file_info', 'search_files', 'glob_files',
			'write_file', 'edit_file', 'create_directory']
		writes: true
	}
	'tester':     RoleSpec{
		tools:  ['read_file', 'list_dir', 'file_info', 'search_files', 'glob_files',
			'run_command']
		writes: false
	}
	'reviewer':   RoleSpec{
		tools:  ['read_file', 'list_dir', 'file_info', 'search_files', 'glob_files']
		writes: false
	}
	'analyst':    RoleSpec{
		tools:  ['read_file', 'list_dir', 'file_info', 'search_files', 'glob_files',
			'web_search', 'web_fetch', 'run_command']
		writes: false
	}
	// -- advanced specialists (big-project grade) -------------------------
	'architect':  RoleSpec{
		tools:  ['read_file', 'list_dir', 'file_info', 'search_files', 'glob_files',
			'write_file', 'create_directory']
		writes: true
	}
	'debugger':   RoleSpec{
		tools:  ['read_file', 'list_dir', 'file_info', 'search_files', 'glob_files',
			'run_command']
		writes: false
	}
	'optimizer':  RoleSpec{
		tools:  ['read_file', 'list_dir', 'file_info', 'search_files', 'glob_files',
			'run_command']
		writes: false
	}
	'refactorer': RoleSpec{
		tools:  ['read_file', 'list_dir', 'file_info', 'search_files', 'glob_files',
			'write_file', 'edit_file', 'create_directory']
		writes: true
	}
	'documenter': RoleSpec{
		tools:  ['read_file', 'list_dir', 'file_info', 'search_files', 'glob_files',
			'write_file', 'edit_file', 'create_directory']
		writes: true
	}
	'devops':     RoleSpec{
		tools:  ['read_file', 'list_dir', 'file_info', 'search_files', 'glob_files',
			'write_file', 'edit_file', 'create_directory', 'run_command']
		writes: true
	}
	'integrator': RoleSpec{
		tools:  ['read_file', 'list_dir', 'file_info', 'search_files', 'glob_files',
			'write_file', 'edit_file', 'create_directory', 'run_command']
		writes: true
	}
	'planner':    RoleSpec{
		tools:  ['read_file', 'list_dir', 'file_info', 'search_files', 'glob_files']
		writes: false
	}
}

pub const default_role = 'coder'

// role_spec resolves a role, falling back to the default.
pub fn role_spec(role string) RoleSpec {
	return roles[role] or { roles[default_role] or { RoleSpec{} } }
}

pub struct WorkerReport {
pub mut:
	task          string
	role          string
	summary       string
	status        string = 'running' // done | blocked | error
	files_touched []string
	tool_calls    int
	tokens_in     int
	tokens_out    int
	error         string
	elapsed_ms    int
}

pub fn (r &WorkerReport) to_json() map[string]json2.Any {
	return {
		'task':          json2.Any(r.task)
		'role':          json2.Any(r.role)
		'summary':       json2.Any(r.summary)
		'status':        json2.Any(r.status)
		'files_touched': json2.Any(strs_to_any(r.files_touched))
		'tool_calls':    json2.Any(r.tool_calls)
		'tokens_in':     json2.Any(r.tokens_in)
		'tokens_out':    json2.Any(r.tokens_out)
		'error':         json2.Any(r.error)
		'elapsed_ms':    json2.Any(r.elapsed_ms)
	}
}

// parse_worker_final splits a worker's final reply into (status, summary).
// Shared by the persistent Crew and every subsystem that reads worker
// reports.
//
// Status taxonomy: a worker says `STATUS: DONE|BLOCKED|ERROR`. Recognising
// only BLOCKED would silently swallow every other failure label (ERROR,
// FAILED, TIMEOUT, …) as `done` — a worker that timed out would be marked
// successful, the contract would close, and the dead-end would be lost. So
// anything that is neither DONE nor BLOCKED reads as `error`, and genuine
// failures stay visible.
pub fn parse_worker_final(text string) (string, string) {
	mut status := 'done'
	mut summary_lines := []string{}
	for line in split_lines(text.trim_space()) {
		low := line.trim_space().to_upper()
		if low.starts_with('STATUS:') {
			val := line.all_after_first(':').trim_space().to_upper()
			if val == '' || val.starts_with('DONE') {
				status = 'done'
			} else if val.starts_with('BLOCK') {
				status = 'blocked'
			} else {
				// an explicit ERROR / FAILED / TIMEOUT / anything unknown:
				// surface it as error so callers (Crew, Healer) can act
				status = 'error'
			}
		} else if low.starts_with('SUMMARY:') {
			summary_lines << line.all_after_first(':').trim_space()
		} else if summary_lines.len > 0 {
			summary_lines << line.trim_space()
		}
	}
	mut summary := summary_lines.filter(it != '').join('\n').trim_space()
	if summary == '' {
		// the model ignored the format — keep the whole reply
		summary = text.trim_space()
	}
	return status, summary
}

// chat_with_retry is chat_blocking with rate-limit retry + exponential
// backoff.
//
// Shared by the persistent Crew and every blocking subsystem evaluator.
// Free-tier APIs rate-limit; a worker must wait and retry, not die. Backoff
// doubles each attempt with jitter.
//
// It also carries context-overflow protection: if a worker's own tool loop
// bloats its context past the window, the oldest tool results are truncated
// and the call retried — a worker never dies with a context-length error.
pub fn chat_with_retry(provider Provider, model Model, effort Effort, mut messages []Message, schemas []json2.Any, timeout f64) !StreamResult {
	// The overflow callback has to shrink the SAME conversation the call is
	// sending. V will not let a closure capture a reference to a stack
	// slice, so the messages live in a heap box for the duration of the
	// call and are copied back out at the end.
	mut box := &MessageBox{
		items: messages.clone()
	}
	cb := StreamCallbacks{
		on_overflow: OverflowFn(fn [box] () bool {
			unsafe {
				mut b := box
				return shrink_tool_outputs(mut b.items, 1, 400)
			}
		})
	}
	mut last_err := api_error('no attempt made', 0)
	for attempt in 0 .. rate_limit_retries {
		result := chat_blocking(provider, model, effort, mut box.items, schemas,
			cb, timeout) or {
			if err is TurnCancelled {
				return err
			}
			msg := err.msg().to_lower()
			status := if err is APIError { err.status } else { 0 }
			rate_limited := status == 429 || msg.contains('rate limit')
				|| msg.contains('too many requests')
			if !rate_limited {
				return err
			}
			last_err = err
			if attempt >= rate_limit_retries - 1 {
				break // the last attempt — no point sleeping after the verdict
			}
			wait := rate_limit_base_wait * f64(1 << u32(attempt)) + rand.f64n(1.5) or { 0.0 }
			time.sleep(i64(wait * f64(time.second)))
			continue
		}
		messages = box.items.clone()
		return result
	}
	messages = box.items.clone()
	return last_err
}
