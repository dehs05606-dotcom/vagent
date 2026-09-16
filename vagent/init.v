module vagent

import os

// init.v — the module's single startup hook.
//
// V allows one `init()` per module, so every piece of process-wide state
// that cannot be a plain const is seeded here: the prompt registry, whose
// sovereign entries must exist before anything resolves a prompt, and the
// tokenizer calibration, which is a heap struct because a `shared map`
// cannot be cloned out of a lock without tripping V's codegen.

fn init() {
	lock prompt_registry {
		prompt_registry['main'] = main_prompt
		prompt_registry['master'] = master_prompt
	}
	calibration = &Calibration{}
}

// os_join is os.join_path under a short name, so the const-initialisation
// order in client.v does not depend on importing os there.
fn os_join(parts ...string) string {
	return os.join_path(parts[0], ...parts[1..])
}
