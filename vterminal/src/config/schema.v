module config

// ProviderConfig describes one model endpoint. V-AGENT never hard-codes a
// vendor: every provider is "some OpenAI-compatible base_url plus a model
// name", and `kind` only selects the wire dialect used to talk to it.
pub struct ProviderConfig {
pub mut:
	name          string = 'custom'
	kind          string = 'openai' // openai | anthropic
	base_url      string
	api_key       string
	api_key_env   string = 'VAGENT_API_KEY'
	model         string
	headers       map[string]string
	context_limit int  = 128000
	streaming     bool = true
	temperature   f64
	top_p         f64 = 1.0
	max_tokens    int = 8192
	timeout_secs  int = 300
	// price per 1M tokens, used only for the cost readout in the status bar
	input_price  f64
	output_price f64
}

// AgentConfig bounds the agent loop. Every field here exists to stop a
// runaway loop from burning tokens or wedging the terminal.
pub struct AgentConfig {
pub mut:
	max_iterations       int  = 30
	max_tool_retries     int  = 2
	max_tool_output      int  = 30000
	max_parallel_tools   int  = 1
	shell_timeout_secs   int  = 120
	stream_tool_progress bool = true
	system_prompt_extra  string
}

// PermissionConfig is the policy half of the security engine; the interactive
// prompt is only consulted when mode is `ask` and no rule already matched.
pub struct PermissionConfig {
pub mut:
	mode              string = 'ask' // ask | allow | deny
	auto_approve_read bool   = true
	allow             []string
	deny              []string = ['rm -rf /', 'mkfs', ':(){:|:&};:', 'dd if=/dev/zero of=/dev/']
	confine_to_root   bool     = true
}

// UIConfig controls the terminal renderer.
pub struct UIConfig {
pub mut:
	color       bool = true
	unicode     bool = true
	show_tokens bool = true
	show_plan   bool = true
	stream      bool = true
	compact     bool
}

// LogConfig controls the file logger.
pub struct LogConfig {
pub mut:
	level     string = 'info'
	file      string
	to_stderr bool
}

// Config is the fully resolved configuration the rest of the program reads.
// It is produced by layering defaults, the global file, the project file,
// environment variables and CLI flags, in that order.
pub struct Config {
pub mut:
	provider     ProviderConfig
	agent        AgentConfig
	permissions  PermissionConfig
	ui           UIConfig
	log          LogConfig
	project_root string
	workdir      string
	// sources records which layers contributed, for `/status` and --debug
	sources []string
}

// validate catches the configuration mistakes that would otherwise surface as
// a confusing HTTP error on the first request.
pub fn (c &Config) validate() ! {
	if c.provider.base_url.trim_space() == '' {
		return error('provider.base_url is not set')
	}
	if c.provider.model.trim_space() == '' {
		return error('provider.model is not set')
	}
	if c.provider.api_key.trim_space() == '' {
		return error('no API key: set \$${c.provider.api_key_env}, put provider.api_key in config.json, or build a bundled binary with `make bundled`')
	}
	if c.provider.kind !in ['openai', 'anthropic'] {
		return error('provider.kind must be "openai" or "anthropic", got "${c.provider.kind}"')
	}
	if c.permissions.mode !in ['ask', 'allow', 'deny'] {
		return error('permissions.mode must be ask|allow|deny, got "${c.permissions.mode}"')
	}
	if c.agent.max_iterations < 1 {
		return error('agent.max_iterations must be >= 1')
	}
}

// redacted_api_key is what gets printed in /status and the debug dump.
pub fn (c &Config) redacted_api_key() string {
	k := c.provider.api_key
	if k == '' {
		return '(unset)'
	}
	if k.len <= 10 {
		return '***'
	}
	return '${k#[..6]}...${k#[-4..]}'
}
