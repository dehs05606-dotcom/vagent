module model

import src.config
import src.utils

// Gateway is the agent's single handle on "the model". It owns the active
// provider, hides which dialect is in use, and keeps running token/cost totals
// so the status bar has something to show.
//
// Swapping models at runtime (`/model`) rebuilds the provider behind the same
// Gateway, so nothing above this layer holds a stale reference.
@[heap]
pub struct Gateway {
pub mut:
	cfg      config.ProviderConfig
	total    Usage
	requests int
mut:
	provider ?Provider
	log      &utils.Logger = unsafe { nil }
}

pub fn new_gateway(cfg config.ProviderConfig, mut log utils.Logger) !&Gateway {
	mut g := &Gateway{
		cfg: cfg
		log: &log
	}
	g.rebuild()!
	return g
}

fn (mut g Gateway) rebuild() ! {
	mut log := g.log
	g.provider = match g.cfg.kind {
		'anthropic' { Provider(new_anthropic(g.cfg, mut log)) }
		'openai' { Provider(new_openai(g.cfg, mut log)) }
		else { return utils.err(.config, 'unknown provider kind "${g.cfg.kind}"') }
	}
}

pub fn (g &Gateway) name() string {
	return g.cfg.name
}

pub fn (g &Gateway) model_id() string {
	return g.cfg.model
}

pub fn (g &Gateway) context_limit() int {
	return g.cfg.context_limit
}

pub fn (g &Gateway) streaming() bool {
	return g.cfg.streaming
}

// switch_model repoints the gateway at a different model on the same endpoint.
pub fn (mut g Gateway) switch_model(model_id string) ! {
	if model_id.trim_space() == '' {
		return utils.err(.config, 'model name is empty')
	}
	g.cfg.model = model_id.trim_space()
	g.rebuild()!
}

// chat runs one model turn and folds its usage into the session totals.
pub fn (mut g Gateway) chat(req Request, mut sink Sink) !Response {
	provider := g.provider or { return utils.err(.internal, 'model gateway has no provider') }
	mut r := req
	if !g.cfg.streaming {
		r.stream = false
	}
	resp := provider.chat(r, mut sink)!
	g.requests++
	if resp.usage.total_tokens > 0 || resp.usage.prompt_tokens > 0 {
		g.total = g.total.add(resp.usage)
	} else {
		// Providers that report nothing still need to move the status bar, so
		// fall back to the character estimate for this turn.
		mut est := 0
		for m in r.messages {
			est += utils.estimate_tokens(m.content)
		}
		g.total = g.total.add(Usage{
			prompt_tokens:     est
			completion_tokens: utils.estimate_tokens(resp.content)
			total_tokens:      est + utils.estimate_tokens(resp.content)
		})
	}
	return resp
}

// estimated_cost is only as good as the prices in the config; it returns 0
// when they were not set, which is the common case for self-hosted routers.
pub fn (g &Gateway) estimated_cost() f64 {
	if g.cfg.input_price == 0 && g.cfg.output_price == 0 {
		return 0
	}
	return (f64(g.total.prompt_tokens) / 1000000.0) * g.cfg.input_price +
		(f64(g.total.completion_tokens) / 1000000.0) * g.cfg.output_price
}

// set_provider installs a Provider implementation directly. This is the
// extension point for dialects that are not built in — and the seam that lets
// the agent loop be tested without a network.
pub fn (mut g Gateway) set_provider(p Provider) {
	g.provider = p
}
