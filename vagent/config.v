module vagent

import os
import x.json2

pub const app_name = 'FullAgent'
pub const version = '3.1.0'

pub const default_timeout = 300.0
pub const max_tool_iterations = 80
pub const max_tool_output_chars = 24_000

// One output ceiling for every effort level: 200k tokens.
pub const max_tokens = 200_000

// Backends reject a request when input + max_tokens exceeds the model's
// context window. Every request's max_tokens is clamped to fit (client.v).
pub const default_context_window = 262_144

// ---------------------------------------------------------------------------
// Paths
// ---------------------------------------------------------------------------

// pick_app_dir chooses a WRITABLE home for app state — never a crash path.
//
// Order: $FULLAGENT_HOME, ~/.fullagent, <tmp>/fullagent-<uid>.
// Each candidate is probed with a real write; the first one that actually
// works wins, so a read-only home dir degrades gracefully instead of
// killing the app at startup (an error on the event log).
fn pick_app_dir() string {
	uid := os.getuid().str()
	mut candidates := []string{}
	env := os.getenv('FULLAGENT_HOME')
	if env != '' {
		candidates << env
	}
	candidates << os.join_path(os.home_dir(), '.fullagent')
	fallback := os.join_path(os.temp_dir(), 'fullagent-${uid}')
	candidates << fallback

	for c in candidates {
		probe := os.join_path(c, '.write-probe')
		os.mkdir_all(c) or { continue }
		os.write_file(probe, 'ok') or { continue }
		os.rm(probe) or {}
		return c
	}
	// last resort: per-user tmp subdir so two users on the same box don't
	// clobber each other's config / event log / sessions
	os.mkdir_all(fallback) or { return os.temp_dir() }
	return fallback
}

pub const app_dir = pick_app_dir()
pub const config_file = os.join_path(app_dir, 'config.json')
pub const history_file = os.join_path(app_dir, 'history')
pub const sessions_dir = os.join_path(app_dir, 'sessions')
pub const event_log_file = os.join_path(app_dir, 'eventlog.jsonl')

// ensure_dirs creates every directory the app writes into. Called at
// startup AND before individual writes, so a deleted home dir heals itself.
pub fn ensure_dirs() {
	for d in [app_dir, sessions_dir, os.join_path(app_dir, 'memory'),
		os.join_path(app_dir, 'skills'), os.join_path(app_dir, 'store')] {
		os.mkdir_all(d) or {}
	}
}

// ---------------------------------------------------------------------------
// Providers
// ---------------------------------------------------------------------------

pub struct Provider {
pub:
	key      string
	name     string
	base_url string
	api_key  string
	color    string
}

fn env_or(name string, fallback string) string {
	v := os.getenv(name)
	return if v != '' { v } else { fallback }
}

fn build_providers() map[string]Provider {
	opencode_key := env_or('OPENCODE_API_KEY', 'sk-h11yU0O2sQxGL9CC0Y5bHQxtdWQSqXAi1mRUG7TSLpA7EvFAzYBpyAJ7NQ6xhDvm')
	return {
		'zen':         Provider{
			key:      'zen'
			name:     'OpenCode Zen'
			base_url: 'https://opencode.ai/zen/v1'
			api_key:  opencode_key
			color:    '#8be9fd'
		}
		'opencode':    Provider{
			key:      'opencode'
			name:     'OpenCode'
			base_url: 'https://opencode.ai/zen/v1'
			api_key:  opencode_key
			color:    '#bd93f9'
		}
		'tokenrouter': Provider{
			key:      'tokenrouter'
			name:     'TokenRouter'
			base_url: 'https://api.tokenrouter.com/v1'
			api_key:  env_or('TOKENROUTER_API_KEY', 'sk-cTiHfKWRCDK6EO64AuloBS09hQGu06careTB2oQ9OETBe2wK')
			color:    '#ffb86c'
		}
		'agnes':       Provider{
			key:      'agnes'
			name:     'Agnes'
			base_url: 'https://apihub.agnes-ai.com/v1'
			api_key:  env_or('AGNES_API_KEY', 'sk-fKLLAlhfkYdwCMrznXi1rKlh3ZQXgNtucHrpPatC7MQCHYVi')
			color:    '#50fa7b'
		}
		'zenmux':      Provider{
			key:      'zenmux'
			name:     'ZenMux'
			base_url: 'https://zenmux.ai/api/v1'
			api_key:  env_or('ZENMUX_API_KEY', 'sk-ai-v1-9424a61af5fea4355a34de00530e189d1972da4d4f8324815be47b8d5a6280eb')
			color:    '#f1fa8c'
		}
		'nvidia':      Provider{
			key:      'nvidia'
			name:     'NVIDIA NIM'
			base_url: 'https://integrate.api.nvidia.com/v1'
			api_key:  env_or('NVIDIA_API_KEY', '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')
			color:    '#76b900'
		}
		// Kios Router. base_url is fixed here (not env-driven by default)
		// because the endpoint is known; KIOS_API_KEY still overrides the
		// built-in key.
		'kios':        Provider{
			key:      'kios'
			name:     'Kios Router'
			base_url: env_or('KIOS_BASE_URL', 'https://router.kiosapi.com/v1')
			api_key:  env_or('KIOS_API_KEY', 'sk-cFXQ576lsIctpudkYD5lPniF5UgHGLy1nKeXDscCEvK1LMZV')
			color:    '#ff79c6'
		}
	}
}

pub const providers = build_providers()

pub fn provider_by_key(key string) ?Provider {
	return providers[key] or { return none }
}

// ---------------------------------------------------------------------------
// Models
// ---------------------------------------------------------------------------

pub struct Model {
pub:
	id        string
	provider  string
	label     string
	tag       string
	tag_color string = 'grey62'
	// supports_tools=false means the backend cannot act, only answer.
	supports_tools bool = true
	// supports_reasoning=true means the backend understands a reasoning
	// switch — the client uses it to send an EXPLICIT "none" (thinking off
	// globally), not to turn thinking on.
	supports_reasoning bool
	// Total context window (input + output tokens). Used to clamp
	// max_tokens at send time so a request is never rejected for
	// exceeding the window.
	context_window int = default_context_window
}

pub const models = [
	Model{
		id:             'mimo-v2.5-free'
		provider:       'zen'
		label:          'MiMo v2.5'
		tag:            'FREE'
		tag_color:      'green'
		supports_tools: false
	},
	Model{
		id:        'big-pickle'
		provider:  'zen'
		label:     'Big Pickle'
		tag:       'FREE'
		tag_color: 'green'
	},
	Model{
		id:        'grok-code-fast-1'
		provider:  'zen'
		label:     'Grok Code Fast'
		tag:       'FAST'
		tag_color: 'cyan'
	},
	Model{
		id:             'claude-sonnet-4-5'
		provider:       'zen'
		label:          'Claude Sonnet 4.5'
		context_window: 200_000
	},
	Model{
		id:             'claude-opus-4-6'
		provider:       'zen'
		label:          'Claude Opus 4.6'
		context_window: 200_000
	},
	Model{
		id:             'gemini-3.1-pro'
		provider:       'zen'
		label:          'Gemini 3.1 Pro'
		context_window: 1_048_576
	},
	Model{
		id:             'gpt-5.2'
		provider:       'zen'
		label:          'GPT-5.2'
		context_window: 400_000
	},
	Model{
		id:                 'muse-spark-1.2-contributor-free'
		provider:           'opencode'
		label:              'Muse Spark 1.2'
		tag:                'FREE'
		tag_color:          'green'
		supports_tools:     true
		supports_reasoning: true
	},
	Model{
		id:                 'opencode/muse-spark-1.2-contributor-free'
		provider:           'opencode'
		label:              'Muse Spark 1.2'
		tag:                'FREE'
		tag_color:          'green'
		supports_tools:     true
		supports_reasoning: true
	},
	Model{
		id:                 'qwen/qwen3.8-max-free'
		provider:           'tokenrouter'
		label:              'Qwen3.8 Max'
		tag:                'FREE'
		tag_color:          'green'
		supports_reasoning: true
	},
	Model{
		id:                 'deepseek-ai/DeepSeek-V3.2'
		provider:           'tokenrouter'
		label:              'DeepSeek V3.2'
		supports_reasoning: false
		context_window:     131_072
	},
	Model{
		id:                 'deepseek/deepseek-v4-pro-0813-free'
		provider:           'tokenrouter'
		label:              'DeepSeek V4 Pro 0813'
		tag:                'FREE'
		tag_color:          'green'
		supports_tools:     true
		supports_reasoning: true
		context_window:     131_072
	},
	Model{
		id:             'moonshotai/Kimi-K2-Instruct'
		provider:       'tokenrouter'
		label:          'Kimi K2'
		context_window: 131_072
	},
	Model{
		id:                 'agnes-2.5-flash'
		provider:           'agnes'
		label:              'Agnes 2.5 Flash'
		tag:                'FAST'
		tag_color:          'green'
		supports_tools:     true
		supports_reasoning: true
	},
	Model{
		id:                 'dots-studio/dots3-note-prev'
		provider:           'zenmux'
		label:              'Dots.OCR Note Prev'
		tag:                'NEW'
		tag_color:          'yellow'
		supports_tools:     true
		supports_reasoning: true
	},
	Model{
		id:                 'deepseek-ai/deepseek-v4-pro-0813'
		provider:           'nvidia'
		label:              'DeepSeek V4 Pro 0813'
		tag:                'NIM'
		tag_color:          'green'
		supports_tools:     true
		supports_reasoning: true
		context_window:     1_048_576
	},
	// Kios router (OpenAI-compatible, Bearer key via $KIOS_API_KEY).
	// supports_reasoning=false ON PURPOSE: sending reasoning_effort makes
	// this router reject some models outright, so no thinking switch is
	// ever sent — the models think on their own and answer as long as
	// max_tokens has headroom (it does: 200k ceiling).
	Model{
		id:                 'oc/muse-spark-1.3-contributor'
		provider:           'kios'
		label:              'Muse Spark 1.3'
		tag:                'KIOS'
		tag_color:          'magenta'
		supports_tools:     true
		supports_reasoning: false
	},
	Model{
		id:                 'agnes-3.0-flash'
		provider:           'kios'
		label:              'Agnes 3.0 Flash'
		tag:                'KIOS'
		tag_color:          'magenta'
		supports_tools:     true
		supports_reasoning: false
		context_window:     65_536
	},
	Model{
		id:                 'deepseek-v4-flash'
		provider:           'kios'
		label:              'DeepSeek V4 Flash'
		tag:                'KIOS'
		tag_color:          'magenta'
		supports_tools:     true
		supports_reasoning: false
	},
	Model{
		id:                 'glm-5.3'
		provider:           'kios'
		label:              'GLM 5.3'
		tag:                'KIOS'
		tag_color:          'magenta'
		supports_tools:     true
		supports_reasoning: false
		context_window:     131_072
	},
	Model{
		id:                 'qwen3.8-flash'
		provider:           'kios'
		label:              'Qwen3.8 Flash'
		tag:                'KIOS'
		tag_color:          'magenta'
		supports_tools:     true
		supports_reasoning: false
	},
	// Flags below are measured against the live router, not assumed: each
	// model was sent a tool schema and a reasoning_effort switch.
	// muse-spark-1.2 rejects the switch outright — the router answers 400
	// `"effort" does not support "none"` — so it must stay false, exactly
	// like its 1.3 sibling above. ling-3.0 and hy3 accept it and answer
	// normally, so they keep it. All three called the test tool. Context
	// windows stay at the package default: /v1/models publishes no limits,
	// and an invented window would make client.v clamp max_tokens against
	// a number nobody measured.
	Model{
		id:                 'oc/muse-spark-1.2-contributor'
		provider:           'kios'
		label:              'Muse Spark 1.2'
		tag:                'KIOS'
		tag_color:          'magenta'
		supports_tools:     true
		supports_reasoning: false
	},
	Model{
		id:                 'ling-3.0-flash-fin'
		provider:           'kios'
		label:              'Ling 3.0 Flash Fin'
		tag:                'KIOS'
		tag_color:          'magenta'
		supports_tools:     true
		supports_reasoning: true
	},
	Model{
		id:                 'hy3'
		provider:           'kios'
		label:              'HY3'
		tag:                'KIOS'
		tag_color:          'magenta'
		supports_tools:     true
		supports_reasoning: true
	},
]

// The default has to be a model that actually answers. mimo-v2.5-free was
// the default and could not be used at all: the provider rejects it with
// "OpenCode's free tier can only be used in OpenCode", so every request
// failed before the model saw a single token. It also declares
// supports_tools=false, so even had it answered, the agent could not act.
//
// An agent whose default model never replies presents exactly as "the model
// ignores my system prompt", which is the symptom this cost a long time to
// trace. Measured against every configured model, these two answered:
//
//   deepseek-ai/deepseek-v4-pro-0813  nvidia   1,048,576 window, tools, ok
//   dots-studio/dots3-note-prev       zenmux     262,144 window, tools, ok
//
// The rest fail on payment, free-tier lock-in, or an unsupported id. The
// larger window is the default because a long specification needs the room.
pub const default_model_id = 'deepseek-ai/deepseek-v4-pro-0813'

pub fn model_by_id(model_id string) ?Model {
	for m in models {
		if m.id == model_id {
			return m
		}
	}
	return none
}

// ---------------------------------------------------------------------------
// Effort levels
// ---------------------------------------------------------------------------

pub struct Effort {
pub:
	key              string
	label            string
	color            string
	max_tokens       int
	temperature      f64
	reasoning_effort string
	description      string
}

pub const efforts = [
	Effort{
		key:         'low'
		label:       'LOW'
		color:       '#6272a4'
		max_tokens:  max_tokens
		temperature: 0.2
		description: 'short answers, minimal tokens'
	},
	Effort{
		key:         'medium'
		label:       'MEDIUM'
		color:       '#8be9fd'
		max_tokens:  max_tokens
		temperature: 0.4
		description: 'balanced length and speed'
	},
	Effort{
		key:         'high'
		label:       'HIGH'
		color:       '#50fa7b'
		max_tokens:  max_tokens
		temperature: 0.6
		description: 'thorough, detailed answers'
	},
	Effort{
		key:         'extrahigh'
		label:       'EXTRA HIGH'
		color:       '#ffb86c'
		max_tokens:  max_tokens
		temperature: 0.7
		description: 'deep work, long outputs'
	},
	Effort{
		key:         'ultrahigh'
		label:       'ULTRA HIGH'
		color:       '#ff5555'
		max_tokens:  max_tokens
		temperature: 0.8
		description: 'maximum depth, exhaustive work'
	},
]

pub const default_effort = 'high'

pub fn effort_by_key(key string) ?Effort {
	for e in efforts {
		if e.key == key {
			return e
		}
	}
	return none
}

// ---------------------------------------------------------------------------
// Config
// ---------------------------------------------------------------------------

const config_known_keys = ['model_id', 'effort', 'auto_approve', 'show_reasoning',
	'theme', 'prompt']

pub struct Config {
pub mut:
	model_id       string = default_model_id
	effort         string = default_effort
	auto_approve   bool
	show_reasoning bool
	theme          string = 'dracula'
	// which system prompt to send: "main" (compact) or "master" (130k+)
	prompt string = 'main'
	extra  map[string]json2.Any
}

pub fn load_config() Config {
	mut cfg := Config{}
	raw := os.read_file(config_file) or { '' }
	data := decode_obj(raw)

	for k in config_known_keys {
		if k !in data {
			continue
		}
		match k {
			'model_id' { cfg.model_id = jstr(data, k) }
			'effort' { cfg.effort = jstr(data, k) }
			'theme' { cfg.theme = jstr(data, k) }
			'prompt' { cfg.prompt = jstr(data, k) }
			// safety gates must be real booleans — a drifted config with
			// "auto_approve": "false" (a truthy string in Python) would
			// silently disable the approval prompt. jbool only accepts a
			// real JSON boolean.
			'auto_approve' { cfg.auto_approve = jbool(data, k) }
			'show_reasoning' { cfg.show_reasoning = jbool(data, k) }
			else {}
		}
	}
	for k, v in data {
		if k !in config_known_keys {
			cfg.extra[k] = v
		}
	}

	if model_by_id(cfg.model_id) == none {
		cfg.model_id = default_model_id
	}
	if effort_by_key(cfg.effort) == none {
		cfg.effort = default_effort
	}
	if cfg.prompt == '' {
		cfg.prompt = 'main'
	}
	// A user who installed a master spec wants it used — shipping their
	// specification and then sending the 2k compact prompt is the same bug
	// as not loading it at all. An explicit "prompt" in the config always
	// wins; this only fills the unset default.
	if 'prompt' !in data && spec_chars() > 0 {
		cfg.prompt = 'master'
	}
	return cfg
}

pub fn (c &Config) save() {
	ensure_dirs()
	mut data := map[string]json2.Any{}
	data['model_id'] = c.model_id
	data['effort'] = c.effort
	data['auto_approve'] = c.auto_approve
	data['show_reasoning'] = c.show_reasoning
	data['theme'] = c.theme
	data['prompt'] = c.prompt
	for k, v in c.extra {
		data[k] = v
	}
	// atomic write: a crash mid-write must never leave truncated JSON that
	// would reset the whole config on next load. Config persistence is a
	// convenience, never a crash path, so errors are swallowed.
	atomic_write_text(config_file, json2.encode(json2.Any(data), prettify: true, indent_string: '  ')) or {}
}

// model returns the configured model, falling back to the default when the
// id has drifted out of the catalog.
pub fn (c &Config) model() Model {
	return model_by_id(c.model_id) or { model_by_id(default_model_id) or { models[0] } }
}

// effort_level returns the configured effort, falling back to the default.
pub fn (c &Config) effort_level() Effort {
	return effort_by_key(c.effort) or { effort_by_key(default_effort) or { efforts[0] } }
}

// provider returns the provider backing the configured model.
pub fn (c &Config) provider() Provider {
	m := c.model()
	return providers[m.provider] or { providers['zen'] or { Provider{} } }
}
