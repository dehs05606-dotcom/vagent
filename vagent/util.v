module vagent

import crypto.sha256
import os
import strings
import time
import x.json2

// ---------------------------------------------------------------------------
// Hashing / canonical JSON
// ---------------------------------------------------------------------------

// canonical renders `v` as JSON with map keys sorted, so the same logical
// value always produces the same bytes. The event log hashes this output,
// so key order drifting between runs would break every content address.
pub fn canonical(v json2.Any) string {
	mut sb := strings.new_builder(256)
	canonical_into(mut sb, v)
	return sb.str()
}

fn canonical_into(mut sb strings.Builder, v json2.Any) {
	match v {
		map[string]json2.Any {
			mut keys := v.keys()
			keys.sort()
			sb.write_string('{')
			for i, k in keys {
				if i > 0 {
					sb.write_string(',')
				}
				sb.write_string(json2.Any(k).json_str())
				sb.write_string(':')
				canonical_into(mut sb, v[k] or { json2.null })
			}
			sb.write_string('}')
		}
		[]json2.Any {
			sb.write_string('[')
			for i, item in v {
				if i > 0 {
					sb.write_string(',')
				}
				canonical_into(mut sb, item)
			}
			sb.write_string(']')
		}
		else {
			sb.write_string(v.json_str())
		}
	}
}

// hash is the one content-address function used across the package.
pub fn hash(text string) string {
	return sha256.hexhash(text)
}

// short_hash is `hash` clipped to the 12 chars the UI shows.
pub fn short_hash(text string) string {
	return hash(text)[..12]
}

// ---------------------------------------------------------------------------
// Text helpers
// ---------------------------------------------------------------------------

// clip truncates `text` to `limit` runes and appends a truncation note that
// says how much was dropped, matching the Python `_clip` helpers.
pub fn clip(text string, limit int) string {
	r := text.runes()
	if r.len <= limit {
		return text
	}
	dropped := r.len - limit
	return r[..limit].string() + '\n… [truncated ${dropped} chars]'
}

// clip_plain truncates without the note — used for single-line previews.
pub fn clip_plain(text string, limit int) string {
	r := text.runes()
	if r.len <= limit {
		return text
	}
	if limit <= 1 {
		return r[..limit].string()
	}
	return r[..limit - 1].string() + '…'
}

// one_line collapses every run of whitespace into single spaces so a value
// can be shown on one row of the TUI.
pub fn one_line(text string) string {
	mut sb := strings.new_builder(text.len)
	mut in_space := false
	for ch in text.runes() {
		if ch == ` ` || ch == `\t` || ch == `\n` || ch == `\r` {
			in_space = true
			continue
		}
		if in_space && sb.len > 0 {
			sb.write_rune(` `)
		}
		in_space = false
		sb.write_rune(ch)
	}
	return sb.str()
}

// indent prefixes every line of `text` with `pad`.
pub fn indent(text string, pad string) string {
	return text.split('\n').map(pad + it).join('\n')
}

// plural returns "1 file" / "3 files".
pub fn plural(n int, word string) string {
	return if n == 1 { '${n} ${word}' } else { '${n} ${word}s' }
}

// ---------------------------------------------------------------------------
// Filesystem helpers
// ---------------------------------------------------------------------------

// atomic_write_text writes through a temp file in the same directory and
// renames it into place, so a crash mid-write can never leave a truncated
// file where a whole one used to be.
pub fn atomic_write_text(path string, text string) ! {
	dir := os.dir(path)
	if dir != '' && !os.exists(dir) {
		os.mkdir_all(dir)!
	}
	tmp := '${path}.tmp-${os.getpid()}'
	os.write_file(tmp, text)!
	os.mv(tmp, path) or {
		os.rm(tmp) or {}
		return err
	}
}

// append_line appends one line to a file, creating it if needed.
pub fn append_line(path string, line string) ! {
	dir := os.dir(path)
	if dir != '' && !os.exists(dir) {
		os.mkdir_all(dir)!
	}
	mut f := os.open_append(path)!
	defer {
		f.close()
	}
	f.write_string(line + '\n')!
}

// read_text returns a file's contents, or `` when it cannot be read. Used
// on every path where a missing file is an empty state, not an error.
pub fn read_text_or_empty(path string) string {
	return os.read_file(path) or { '' }
}

// ---------------------------------------------------------------------------
// Time helpers
// ---------------------------------------------------------------------------

// now_ts is the float seconds-since-epoch the Python code stores in events.
pub fn now_ts() f64 {
	return f64(time.now().unix_milli()) / 1000.0
}

// fmt_duration renders seconds the way the status bar does: 1.2s, 3m 04s.
pub fn fmt_duration(seconds f64) string {
	if seconds < 60.0 {
		return '${seconds:.1f}s'
	}
	mins := int(seconds) / 60
	secs := int(seconds) % 60
	if mins < 60 {
		return '${mins}m ${secs:02}s'
	}
	hours := mins / 60
	rem := mins % 60
	return '${hours}h ${rem:02}m'
}

// fmt_clock renders a unix timestamp as HH:MM:SS local time.
pub fn fmt_clock(ts f64) string {
	t := time.unix(i64(ts))
	return '${t.hour:02}:${t.minute:02}:${t.second:02}'
}

// ---------------------------------------------------------------------------
// json2 conveniences
// ---------------------------------------------------------------------------

// jget returns a map member or json2.null, so callers never have to write
// the `or {}` dance on every lookup.
pub fn jget(m map[string]json2.Any, key string) json2.Any {
	return m[key] or { json2.null }
}

// jstr reads a string member, defaulting to ``.
pub fn jstr(m map[string]json2.Any, key string) string {
	v := m[key] or { return '' }
	return match v {
		string { v }
		json2.Null { '' }
		else { v.str() }
	}
}

// jint reads an integer member, defaulting to 0.
pub fn jint(m map[string]json2.Any, key string) int {
	v := m[key] or { return 0 }
	return match v {
		i64 { int(v) }
		f64 { int(v) }
		int { v }
		string { v.int() }
		bool { if v { 1 } else { 0 } }
		else { 0 }
	}
}

// jf64 reads a float member, defaulting to 0.0.
pub fn jf64(m map[string]json2.Any, key string) f64 {
	v := m[key] or { return 0.0 }
	return match v {
		f64 { v }
		i64 { f64(v) }
		int { f64(v) }
		string { v.f64() }
		else { 0.0 }
	}
}

// jbool reads a boolean member, defaulting to false. Only a real JSON
// boolean counts — a drifted `"false"` string must not read as true, which
// is exactly the safety-gate bug config.py guards against.
pub fn jbool(m map[string]json2.Any, key string) bool {
	v := m[key] or { return false }
	return match v {
		bool { v }
		else { false }
	}
}

// jarr reads an array member, defaulting to empty.
pub fn jarr(m map[string]json2.Any, key string) []json2.Any {
	v := m[key] or { return []json2.Any{} }
	return match v {
		[]json2.Any { v }
		else { []json2.Any{} }
	}
}

// jmap reads an object member, defaulting to empty.
pub fn jmap(m map[string]json2.Any, key string) map[string]json2.Any {
	v := m[key] or { return map[string]json2.Any{} }
	return match v {
		map[string]json2.Any { v }
		else { map[string]json2.Any{} }
	}
}

// jstrs reads an array-of-strings member.
pub fn jstrs(m map[string]json2.Any, key string) []string {
	mut out := []string{}
	for item in jarr(m, key) {
		out << match item {
			string { item }
			else { item.str() }
		}
	}
	return out
}

// decode_obj parses JSON text into an object, returning empty on any error.
pub fn decode_obj(text string) map[string]json2.Any {
	v := json2.decode[json2.Any](text) or { return map[string]json2.Any{} }
	return match v {
		map[string]json2.Any { v }
		else { map[string]json2.Any{} }
	}
}

// to_any lifts a string map into a json2 map.
pub fn to_any(m map[string]string) map[string]json2.Any {
	mut out := map[string]json2.Any{}
	for k, v in m {
		out[k] = json2.Any(v)
	}
	return out
}

// strs_to_any lifts a string list into a json2 array.
pub fn strs_to_any(items []string) []json2.Any {
	return items.map(json2.Any(it))
}

// thousands renders an integer with comma separators, matching Python's
// `{n:,}` formatting used throughout the status lines.
pub fn thousands(n int) string {
	neg := n < 0
	mut digits := if neg { (-i64(n)).str() } else { n.str() }
	mut out := []string{}
	mut i := digits.len
	for i > 3 {
		out.prepend(digits[i - 3..i])
		i -= 3
	}
	out.prepend(digits[..i])
	return if neg { '-' + out.join(',') } else { out.join(',') }
}

// thousands64 is `thousands` for 64-bit counts.
pub fn thousands64(n i64) string {
	neg := n < 0
	digits := if neg { (-n).str() } else { n.str() }
	mut out := []string{}
	mut i := digits.len
	for i > 3 {
		out.prepend(digits[i - 3..i])
		i -= 3
	}
	out.prepend(digits[..i])
	return if neg { '-' + out.join(',') } else { out.join(',') }
}

// round_to rounds to `places` decimals, which is what Python's round() does
// for the event payloads — a percentage recorded as 83.33333333333333 makes
// every diff of the log noisy for no gain.
pub fn round_to(x f64, places int) f64 {
	mut scale := 1.0
	for _ in 0 .. places {
		scale *= 10.0
	}
	return math_round(x * scale) / scale
}

fn math_round(x f64) f64 {
	return if x < 0 { -f64(u64(-x + 0.5)) } else { f64(u64(x + 0.5)) }
}

// quote_arg wraps a value so a shell passes it through as ONE argument,
// whatever whitespace or metacharacters it holds.
pub fn quote_arg(s string) string {
	return "'" + s.replace("'", "'\\''") + "'"
}

// jf64_or is jf64 with a caller-supplied default for an absent key, so a
// record written before a field existed reads as that field's prior rather
// than as zero.
pub fn jf64_or(m map[string]json2.Any, key string, fallback f64) f64 {
	v := m[key] or { return fallback }
	if v is json2.Null {
		return fallback
	}
	return v.f64()
}
