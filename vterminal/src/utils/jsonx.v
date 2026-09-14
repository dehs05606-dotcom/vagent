module utils

import x.json2

// The helpers below wrap json2 so the rest of the codebase never has to deal
// with missing-key errors or with an `Any` that turned out to be the wrong
// variant. Every getter takes a default and never fails, because a model can
// and will send back a payload that does not match the schema it was given.

pub fn jget(m map[string]json2.Any, key string) ?json2.Any {
	v := m[key] or { return none }
	if v is json2.Null {
		return none
	}
	return v
}

pub fn jstr(m map[string]json2.Any, key string, def string) string {
	v := jget(m, key) or { return def }
	if v is string {
		return v
	}
	return v.str()
}

// jint reads an integer field, coercing numeric strings and floats.
pub fn jint(m map[string]json2.Any, key string, def int) int {
	v := jget(m, key) or { return def }
	if v is bool {
		return def
	}
	return v.int()
}

// jbool reads a boolean field, accepting the "true"/1 spellings models emit.
pub fn jbool(m map[string]json2.Any, key string, def bool) bool {
	v := jget(m, key) or { return def }
	if v is string {
		return v.to_lower() in ['true', '1', 'yes', 'y', 'on']
	}
	return v.bool()
}

// jf64 reads a floating point field.
pub fn jf64(m map[string]json2.Any, key string, def f64) f64 {
	v := jget(m, key) or { return def }
	if v is bool {
		return def
	}
	return v.f64()
}

pub fn jmap(m map[string]json2.Any, key string) map[string]json2.Any {
	v := jget(m, key) or { return map[string]json2.Any{} }
	if v is map[string]json2.Any {
		return v
	}
	return map[string]json2.Any{}
}

pub fn jarr(m map[string]json2.Any, key string) []json2.Any {
	v := jget(m, key) or { return []json2.Any{} }
	if v is []json2.Any {
		return v
	}
	return []json2.Any{}
}

pub fn jstrings(m map[string]json2.Any, key string) []string {
	mut out := []string{}
	for item in jarr(m, key) {
		if item is string {
			out << item
		} else {
			out << item.str()
		}
	}
	return out
}

// parse_object decodes a JSON object, tolerating the empty string (which
// models frequently send as tool arguments for zero-argument tools).
pub fn parse_object(raw string) !map[string]json2.Any {
	trimmed := raw.trim_space()
	if trimmed == '' || trimmed == 'null' {
		return map[string]json2.Any{}
	}
	decoded := json2.decode[json2.Any](trimmed) or {
		return err_hint(.protocol, 'invalid JSON object', err.msg())
	}
	if decoded is map[string]json2.Any {
		return decoded
	}
	return err(.protocol, 'expected a JSON object, got ${type_name_of(decoded)}')
}

pub fn type_name_of(a json2.Any) string {
	return match a {
		string { 'string' }
		bool { 'boolean' }
		json2.Null { 'null' }
		[]json2.Any { 'array' }
		map[string]json2.Any { 'object' }
		f32, f64 { 'number' }
		else { 'integer' }
	}
}

// any_to_display renders a value the way a human wants to read it in a tool
// echo line: bare strings without quotes, everything else as compact JSON.
pub fn any_to_display(a json2.Any) string {
	if a is string {
		return a
	}
	return a.json_str()
}
