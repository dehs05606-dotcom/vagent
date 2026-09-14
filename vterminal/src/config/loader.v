module config

import os
import x.json2
import src.utils

// load builds the effective configuration by layering, in increasing order of
// precedence: defaults, ~/.vagent/config.json, <project>/.vagent/config.json,
// an explicit --config file, environment variables, and CLI flags.
//
// `flag_overrides` holds only the flags the user actually typed, so an unset
// flag never clobbers a configured value.
pub fn load(explicit_path string, flag_overrides map[string]string) !Config {
	mut c := default_config()
	c.sources << 'defaults'

	// Values compiled into this binary sit just above the defaults, so a file,
	// an environment variable or a flag still overrides them.
	b := baked()
	if b.present() {
		apply_baked(mut c, b)
		c.sources << 'built-in'
	}

	global := os.join_path(utils.user_config_dir(), 'config.json')
	if os.exists(global) {
		apply_file(mut c, global)!
		c.sources << global
	}

	project := os.join_path(utils.project_config_dir(c.project_root), 'config.json')
	if os.exists(project) && project != global {
		apply_file(mut c, project)!
		c.sources << project
	}

	if explicit_path != '' {
		if !os.exists(explicit_path) {
			return utils.err_hint(.config, 'config file not found: ${explicit_path}',
				'check the path passed to --config')
		}
		apply_file(mut c, explicit_path)!
		c.sources << explicit_path
	}

	apply_env(mut c)
	apply_flags(mut c, flag_overrides)
	resolve_api_key(mut c)
	return c
}

fn apply_baked(mut c Config, b Baked) {
	if b.base_url != '' {
		c.provider.base_url = b.base_url
	}
	if b.model != '' {
		c.provider.model = b.model
	}
	if b.kind != '' {
		c.provider.kind = b.kind
	}
	if b.api_key != '' {
		c.provider.api_key = b.api_key
	}
}

fn apply_file(mut c Config, path string) ! {
	raw := os.read_file(path) or {
		return utils.err_hint(.config, 'cannot read ${path}', err.msg())
	}
	obj := utils.parse_object(raw) or {
		return utils.err_hint(.config, 'invalid JSON in ${path}', err.msg())
	}
	apply_object(mut c, obj)
	c.sources << path
}

// apply_object merges one decoded config layer into `c`. Only keys that are
// present are touched, which is what makes layering work.
fn apply_object(mut c Config, obj map[string]json2.Any) {
	if p := utils.jget(obj, 'provider') {
		if p is map[string]json2.Any {
			apply_provider(mut c.provider, p)
		}
	}
	if a := utils.jget(obj, 'agent') {
		if a is map[string]json2.Any {
			c.agent.max_iterations = utils.jint(a, 'max_iterations', c.agent.max_iterations)
			c.agent.max_tool_retries = utils.jint(a, 'max_tool_retries', c.agent.max_tool_retries)
			c.agent.max_tool_output = utils.jint(a, 'max_tool_output', c.agent.max_tool_output)
			c.agent.max_parallel_tools = utils.jint(a, 'max_parallel_tools',
				c.agent.max_parallel_tools)
			c.agent.shell_timeout_secs = utils.jint(a, 'shell_timeout_secs',
				c.agent.shell_timeout_secs)
			c.agent.stream_tool_progress = utils.jbool(a, 'stream_tool_progress',
				c.agent.stream_tool_progress)
			c.agent.system_prompt_extra = utils.jstr(a, 'system_prompt_extra',
				c.agent.system_prompt_extra)
		}
	}
	if p := utils.jget(obj, 'permissions') {
		if p is map[string]json2.Any {
			c.permissions.mode = utils.jstr(p, 'mode', c.permissions.mode)
			c.permissions.auto_approve_read = utils.jbool(p, 'auto_approve_read',
				c.permissions.auto_approve_read)
			c.permissions.confine_to_root = utils.jbool(p, 'confine_to_root',
				c.permissions.confine_to_root)
			if _ := utils.jget(p, 'allow') {
				c.permissions.allow << utils.jstrings(p, 'allow')
			}
			if _ := utils.jget(p, 'deny') {
				c.permissions.deny << utils.jstrings(p, 'deny')
			}
		}
	}
	if u := utils.jget(obj, 'ui') {
		if u is map[string]json2.Any {
			c.ui.color = utils.jbool(u, 'color', c.ui.color)
			c.ui.unicode = utils.jbool(u, 'unicode', c.ui.unicode)
			c.ui.show_tokens = utils.jbool(u, 'show_tokens', c.ui.show_tokens)
			c.ui.show_plan = utils.jbool(u, 'show_plan', c.ui.show_plan)
			c.ui.stream = utils.jbool(u, 'stream', c.ui.stream)
			c.ui.compact = utils.jbool(u, 'compact', c.ui.compact)
		}
	}
	if l := utils.jget(obj, 'log') {
		if l is map[string]json2.Any {
			c.log.level = utils.jstr(l, 'level', c.log.level)
			c.log.file = utils.jstr(l, 'file', c.log.file)
			c.log.to_stderr = utils.jbool(l, 'to_stderr', c.log.to_stderr)
		}
	}
}

fn apply_provider(mut p ProviderConfig, obj map[string]json2.Any) {
	p.name = utils.jstr(obj, 'name', p.name)
	p.kind = utils.jstr(obj, 'kind', p.kind)
	p.base_url = utils.jstr(obj, 'base_url', p.base_url)
	p.api_key = utils.jstr(obj, 'api_key', p.api_key)
	p.api_key_env = utils.jstr(obj, 'api_key_env', p.api_key_env)
	p.model = utils.jstr(obj, 'model', p.model)
	p.context_limit = utils.jint(obj, 'context_limit', p.context_limit)
	p.streaming = utils.jbool(obj, 'streaming', p.streaming)
	p.temperature = utils.jf64(obj, 'temperature', p.temperature)
	p.top_p = utils.jf64(obj, 'top_p', p.top_p)
	p.max_tokens = utils.jint(obj, 'max_tokens', p.max_tokens)
	p.timeout_secs = utils.jint(obj, 'timeout_secs', p.timeout_secs)
	p.input_price = utils.jf64(obj, 'input_price', p.input_price)
	p.output_price = utils.jf64(obj, 'output_price', p.output_price)
	for k, v in utils.jmap(obj, 'headers') {
		p.headers[k] = utils.any_to_display(v)
	}
}

fn apply_env(mut c Config) {
	mut touched := false
	if v := os.getenv_opt('VAGENT_BASE_URL') {
		c.provider.base_url = v
		touched = true
	}
	if v := os.getenv_opt('VAGENT_MODEL') {
		c.provider.model = v
		touched = true
	}
	if v := os.getenv_opt('VAGENT_PROVIDER_KIND') {
		c.provider.kind = v
		touched = true
	}
	if v := os.getenv_opt('VAGENT_LOG_LEVEL') {
		c.log.level = v
		touched = true
	}
	if v := os.getenv_opt('VAGENT_PERMISSION_MODE') {
		c.permissions.mode = v
		touched = true
	}
	if os.getenv('NO_COLOR') != '' {
		c.ui.color = false
		touched = true
	}
	if touched {
		c.sources << 'environment'
	}
}

fn apply_flags(mut c Config, f map[string]string) {
	if f.len == 0 {
		return
	}
	if v := f['model'] {
		c.provider.model = v
	}
	if v := f['provider'] {
		c.provider.name = v
	}
	if v := f['base-url'] {
		c.provider.base_url = v
	}
	if v := f['permission-mode'] {
		c.permissions.mode = v
	}
	if _ := f['debug'] {
		c.log.level = 'debug'
		c.log.to_stderr = true
	}
	if _ := f['no-color'] {
		c.ui.color = false
	}
	if _ := f['no-stream'] {
		c.ui.stream = false
		c.provider.streaming = false
	}
	c.sources << 'cli flags'
}

// resolve_api_key prefers the environment over the config file, so a key never
// has to be written to disk to be used.
fn resolve_api_key(mut c Config) {
	env_name := if c.provider.api_key_env != '' { c.provider.api_key_env } else { 'VAGENT_API_KEY' }
	if v := os.getenv_opt(env_name) {
		if v.trim_space() != '' {
			c.provider.api_key = v.trim_space()
			return
		}
	}
	// A generic fallback so an existing OPENAI_API_KEY just works.
	if c.provider.api_key.trim_space() == '' {
		if v := os.getenv_opt('OPENAI_API_KEY') {
			if v.trim_space() != '' {
				c.provider.api_key = v.trim_space()
			}
		}
	}
}

// write_example creates a starter config.json, refusing to clobber an existing
// one so a stray `--init` cannot destroy a working setup.
pub fn write_example(path string) ! {
	if os.exists(path) {
		return utils.err_hint(.config, '${path} already exists',
			'delete it first, or pass a different path')
	}
	utils.ensure_dir(os.dir(path))!
	os.write_file(path, example_config()) or {
		return utils.err_hint(.config, 'cannot write ${path}', err.msg())
	}
}
