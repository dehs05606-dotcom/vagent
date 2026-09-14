// A custom tool for V-AGENT.
//
// Every capability the agent has — built-in, MCP-provided, or written by you —
// is just a struct with two methods. Register it and the model can call it on
// the next turn; nothing else in the system needs to change.
//
// To use this, copy it into src/tools/, then add one line to
// `register_builtins` in src/tools/registry.v:
//
//     r.register(HttpStatusTool{})
//
module tools

import os
import x.json2
import src.utils

// HttpStatusTool reports the HTTP status of a URL. It is declared NETWORK so
// the permission engine treats it as reaching outside the machine, even though
// the implementation shells out to curl.
pub struct HttpStatusTool {}

pub fn (t HttpStatusTool) spec() Spec {
	return Spec{
		name:          'http_status'
		description:   'Fetch only the HTTP status code and content type of a URL. Use it to check whether an endpoint is reachable before writing code against it.'
		level:         .network
		summary_param: 'url'
		params:        [
			Param{
				name:        'url'
				description: 'Absolute http(s) URL.'
				required:    true
			},
			Param{
				name:        'timeout_secs'
				typ:         'integer'
				description: 'Give up after this many seconds. Defaults to 10.'
			},
		]
	}
}

pub fn (t HttpStatusTool) execute(mut ctx Context, args map[string]json2.Any) Result {
	url := utils.jstr(args, 'url', '').trim_space()
	if !url.starts_with('http://') && !url.starts_with('https://') {
		return fail_result('url must start with http:// or https://')
	}
	timeout := if v := utils.jget(args, 'timeout_secs') {
		if v.int() > 0 { v.int() } else { 10 }
	} else {
		10
	}
	if !utils.has_command('curl') {
		return fail_result('curl is not installed on this machine')
	}
	// sh_quote comes from shell.v and keeps a hostile URL from becoming a
	// second shell command.
	res := os.execute('curl -sS -o /dev/null -m ${timeout} -w "%{http_code} %{content_type}" ' +
		sh_quote(url))
	if res.exit_code != 0 {
		return fail_result('curl failed (${res.exit_code}): ${utils.first_line(res.output)}')
	}
	return ok_result('${url} -> ${res.output.trim_space()}', res.output.trim_space())
}
