module utils

import os
import time

pub enum LogLevel {
	error
	warn
	info
	debug
	trace
}

pub fn level_from_string(s string) LogLevel {
	return match s.to_lower() {
		'error' { LogLevel.error }
		'warn', 'warning' { LogLevel.warn }
		'debug' { LogLevel.debug }
		'trace' { LogLevel.trace }
		else { LogLevel.info }
	}
}

pub fn (l LogLevel) str() string {
	return match l {
		.error { 'ERROR' }
		.warn { 'WARN ' }
		.info { 'INFO ' }
		.debug { 'DEBUG' }
		.trace { 'TRACE' }
	}
}

// Logger writes structured-ish lines to a file and, when `to_stderr` is set,
// mirrors them to the terminal. The agent loop logs heavily, so the file sink
// is what makes a failed run debuggable after the fact.
@[heap]
pub struct Logger {
pub mut:
	level     LogLevel = .info
	file_path string
	to_stderr bool
mut:
	handle  os.File
	is_open bool
}

pub fn new_logger(path string, level LogLevel, to_stderr bool) Logger {
	mut lg := Logger{
		level:     level
		file_path: path
		to_stderr: to_stderr
	}
	if path != '' {
		ensure_dir(os.dir(path)) or { return lg }
		f := os.open_append(path) or { return lg }
		lg.handle = f
		lg.is_open = true
	}
	return lg
}

pub fn discard_logger() Logger {
	return Logger{
		level: .error
	}
}

pub fn (mut l Logger) close() {
	if l.is_open {
		l.handle.close()
		l.is_open = false
	}
}

pub fn (mut l Logger) log(level LogLevel, msg string) {
	if int(level) > int(l.level) {
		return
	}
	stamp := time.now().format_ss_milli()
	line := '${stamp} ${level.str()} ${msg}'
	if l.is_open {
		l.handle.writeln(line) or {}
		l.handle.flush()
	}
	if l.to_stderr {
		eprintln(line)
	}
}

pub fn (mut l Logger) error(msg string) {
	l.log(.error, msg)
}

pub fn (mut l Logger) warn(msg string) {
	l.log(.warn, msg)
}

pub fn (mut l Logger) info(msg string) {
	l.log(.info, msg)
}

pub fn (mut l Logger) debug(msg string) {
	l.log(.debug, msg)
}

pub fn (mut l Logger) trace(msg string) {
	l.log(.trace, msg)
}
