module main

import os
import src.app
import src.config

fn tmpdir(name string) string {
	d := os.join_path(os.temp_dir(), 'vagent_cfg_${name}_${os.getpid()}')
	os.rmdir_all(d) or {}
	os.mkdir_all(d) or { panic(err) }
	return d
}

fn test_validate_rejects_incomplete_configuration() {
	mut c := config.default_config()
	if _ := c.validate() {
		assert false, 'an empty config must not validate'
	} else {
		assert err.msg().contains('base_url')
	}
	c.provider.base_url = 'https://x.test/v1'
	if _ := c.validate() {
		assert false, 'a config without a model must not validate'
	} else {
		assert err.msg().contains('model')
	}
	c.provider.model = 'm'
	if _ := c.validate() {
		assert false, 'a config without a key must not validate'
	} else {
		assert err.msg().contains('API key')
	}
	c.provider.api_key = 'k'
	c.validate() or { assert false, 'a complete config must validate: ${err.msg()}' }
}

fn test_validate_rejects_unknown_enums() {
	mut c := config.default_config()
	c.provider.base_url = 'https://x.test/v1'
	c.provider.model = 'm'
	c.provider.api_key = 'k'
	c.provider.kind = 'gemini'
	if _ := c.validate() {
		assert false, 'unknown provider kind must be rejected'
	} else {
		assert err.msg().contains('provider.kind')
	}
	c.provider.kind = 'openai'
	c.permissions.mode = 'maybe'
	if _ := c.validate() {
		assert false, 'unknown permission mode must be rejected'
	} else {
		assert err.msg().contains('permissions.mode')
	}
}

fn test_explicit_config_file_is_layered_over_defaults() {
	dir := tmpdir('layer')
	defer {
		os.rmdir_all(dir) or {}
	}
	path := os.join_path(dir, 'custom.json')
	os.write_file(path,
		'{"provider":{"base_url":"https://layer.test/v1","model":"layered","context_limit":4321},"agent":{"max_iterations":7},"ui":{"color":false}}') or {
		panic(err)
	}
	os.setenv('VAGENT_API_KEY', 'test-key', true)
	cfg := config.load(path, map[string]string{}) or { panic(err) }
	assert cfg.provider.base_url == 'https://layer.test/v1'
	assert cfg.provider.model == 'layered'
	assert cfg.provider.context_limit == 4321
	assert cfg.agent.max_iterations == 7
	assert cfg.ui.color == false
	// Untouched keys keep their defaults.
	assert cfg.provider.kind == 'openai'
	assert cfg.permissions.mode == 'ask'
	// The key comes from the environment, never from the file.
	assert cfg.provider.api_key == 'test-key'
}

fn test_flags_win_over_the_config_file() {
	dir := tmpdir('flags')
	defer {
		os.rmdir_all(dir) or {}
	}
	path := os.join_path(dir, 'c.json')
	os.write_file(path, '{"provider":{"base_url":"https://file.test/v1","model":"from-file"}}') or {
		panic(err)
	}
	os.setenv('VAGENT_API_KEY', 'test-key', true)
	cfg := config.load(path, {
		'model':           'from-flag'
		'permission-mode': 'allow'
		'no-color':        '1'
	}) or { panic(err) }
	assert cfg.provider.model == 'from-flag'
	assert cfg.permissions.mode == 'allow'
	assert cfg.ui.color == false
	assert cfg.provider.base_url == 'https://file.test/v1'
}

fn test_missing_explicit_config_is_an_error() {
	if _ := config.load('/definitely/not/here.json', map[string]string{}) {
		assert false, 'a missing --config file must fail loudly'
	} else {
		assert err.msg().contains('not found')
	}
}

fn test_redacted_key_never_leaks_the_secret() {
	mut c := config.default_config()
	c.provider.api_key = 'sk-abcdefghijklmnopqrstuvwxyz'
	out := c.redacted_api_key()
	assert out == 'sk-abc...wxyz'
	assert !out.contains('defghijklmnop')
	c.provider.api_key = ''
	assert c.redacted_api_key() == '(unset)'
	c.provider.api_key = 'short'
	assert c.redacted_api_key() == '***'
}

fn test_arg_parsing_separates_flags_from_the_prompt() {
	a := app.parse_args(['--model', 'm1', '--yes', 'fix', 'the', 'bug']) or { panic(err) }
	assert a.overrides['model'] == 'm1'
	assert a.overrides['permission-mode'] == 'allow'
	assert a.prompt == 'fix the bug'
	assert !a.show_help
}

fn test_arg_parsing_rejects_unknown_and_valueless_flags() {
	if _ := app.parse_args(['--nope']) {
		assert false, 'unknown flags must be rejected'
	} else {
		assert err.msg().contains('unknown option')
	}
	if _ := app.parse_args(['--model']) {
		assert false, 'a flag missing its value must be rejected'
	} else {
		assert err.msg().contains('requires a value')
	}
	if _ := app.parse_args(['--model', '--yes']) {
		assert false, 'a flag must not swallow the next flag as its value'
	} else {
		assert err.msg().contains('requires a value')
	}
}

fn test_example_config_is_valid_json_and_loads() {
	dir := tmpdir('example')
	defer {
		os.rmdir_all(dir) or {}
	}
	path := os.join_path(dir, 'example.json')
	config.write_example(path) or { panic(err) }
	assert os.exists(path)
	os.setenv('VAGENT_API_KEY', 'test-key', true)
	cfg := config.load(path, map[string]string{}) or { panic(err) }
	cfg.validate() or { assert false, 'the shipped example must validate: ${err.msg()}' }
	// Writing over an existing config must not silently destroy it.
	if _ := config.write_example(path) {
		assert false, 'write_example must refuse to overwrite'
	} else {
		assert err.msg().contains('already exists')
	}
}

fn test_baked_credentials_are_absent_from_an_ordinary_build() {
	// This binary is built without -d defines, so nothing may be compiled in.
	// If this ever fails, a key leaked into the source tree.
	b := config.baked()
	assert !b.present()
	assert b.api_key == ''
	assert b.base_url == ''
	assert b.model == ''
	assert b.describe() == ''
}

fn test_baked_describe_never_includes_the_key() {
	b := config.Baked{
		api_key:  'sk-secret-value'
		base_url: 'https://x.test/v1'
		model:    'm1'
	}
	out := b.describe()
	assert b.present()
	assert out.contains('m1')
	assert out.contains('https://x.test/v1')
	assert out.contains('key included')
	assert !out.contains('sk-secret-value')
}

fn test_environment_overrides_a_bundled_endpoint() {
	// A bundled binary must stay usable against a different endpoint, so the
	// built-in layer sits below the environment rather than above it.
	dir := tmpdir('overrides')
	defer {
		os.rmdir_all(dir) or {}
	}
	path := os.join_path(dir, 'c.json')
	os.write_file(path, '{"provider":{"base_url":"https://file.test/v1","model":"from-file"}}') or {
		panic(err)
	}
	os.setenv('VAGENT_API_KEY', 'env-key', true)
	os.setenv('VAGENT_MODEL', 'from-env', true)
	defer {
		os.unsetenv('VAGENT_MODEL')
	}
	cfg := config.load(path, map[string]string{}) or { panic(err) }
	assert cfg.provider.model == 'from-env'
	assert cfg.provider.api_key == 'env-key'
	assert cfg.provider.base_url == 'https://file.test/v1'
}
