module config

import os
import src.utils

// default_config is the starting layer. The base_url and model are left empty
// on purpose: V-AGENT refuses to guess an endpoint, it asks to be configured.
pub fn default_config() Config {
	cwd := os.getwd()
	root := utils.find_project_root(cwd)
	mut c := Config{
		project_root: root
		workdir:      cwd
	}
	c.log.file = os.join_path(utils.user_config_dir(), 'logs', 'vagent.log')
	return c
}

// example_config is written by `vagent --init` and shipped in examples/.
pub fn example_config() string {
	return '{
  "provider": {
    "name": "custom",
    "kind": "openai",
    "base_url": "https://router.kiosapi.com/v1",
    "api_key_env": "VAGENT_API_KEY",
    "model": "oc/muse-spark-1.3-contributor",
    "context_limit": 128000,
    "streaming": true,
    "temperature": 0.0,
    "max_tokens": 8192
  },
  "agent": {
    "max_iterations": 30,
    "shell_timeout_secs": 120,
    "max_tool_output": 30000
  },
  "permissions": {
    "mode": "ask",
    "auto_approve_read": true,
    "allow": ["git status", "git diff", "ls", "cat"],
    "deny": ["rm -rf /", "mkfs"]
  },
  "ui": {
    "color": true,
    "unicode": true,
    "show_tokens": true
  },
  "log": {
    "level": "info"
  }
}
'
}
