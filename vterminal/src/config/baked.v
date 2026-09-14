module config

// Credentials can be compiled into the binary, so a build can be handed to
// someone (or dropped on a box) that just runs, with nothing to export first.
//
// The values arrive through V's compile-time defines, never through a literal
// in this file, so a key is only ever present in a binary somebody explicitly
// built that way — it is not in the source and cannot be committed by accident:
//
//   v -d vagent_api_key='sk-...' \
//     -d vagent_base_url='https://router.example.com/v1' \
//     -d vagent_model='some-model' \
//     -o bin/vagent cmd/vagent.v
//
// `make bundled` does exactly that, reading the values from the build
// environment.
//
// A baked value is the lowest-priority layer above the defaults: a config file,
// an environment variable or a flag still overrides it, so a bundled binary
// stays usable against a different endpoint.
//
// This is convenience, not secrecy. A string compiled into an executable is
// recoverable with `strings`; a bundled binary should be treated as the
// credential itself.
pub struct Baked {
pub:
	api_key  string
	base_url string
	model    string
	kind     string
}

// baked returns whatever was compiled in. All fields are empty in an ordinary
// build.
pub fn baked() Baked {
	return Baked{
		api_key:  $d('vagent_api_key', '')
		base_url: $d('vagent_base_url', '')
		model:    $d('vagent_model', '')
		kind:     $d('vagent_provider_kind', '')
	}
}

// present reports whether this binary carries any compiled-in configuration.
pub fn (b Baked) present() bool {
	return b.api_key != '' || b.base_url != '' || b.model != ''
}

// describe is what `--version` and `/status` show. It never includes the key.
pub fn (b Baked) describe() string {
	if !b.present() {
		return ''
	}
	mut out := if b.model != '' { b.model } else { 'no model' }
	if b.base_url != '' {
		out += ' @ ${b.base_url}'
	}
	out += if b.api_key != '' { ', key included' } else { ', no key' }
	return out
}
