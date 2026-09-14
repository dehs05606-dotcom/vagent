module tui

import os
import term

// Style centralises every escape sequence, so `color: false` genuinely means
// plain text everywhere rather than "mostly plain".
pub struct Style {
pub:
	color   bool = true
	unicode bool = true
}

const esc = '\x1b['

pub fn (s Style) paint(code string, text string) string {
	if !s.color {
		return text
	}
	return '${esc}${code}m${text}${esc}0m'
}

pub fn (s Style) dim(t string) string {
	return s.paint('2', t)
}

pub fn (s Style) bold(t string) string {
	return s.paint('1', t)
}

pub fn (s Style) red(t string) string {
	return s.paint('31', t)
}

pub fn (s Style) green(t string) string {
	return s.paint('32', t)
}

pub fn (s Style) yellow(t string) string {
	return s.paint('33', t)
}

pub fn (s Style) blue(t string) string {
	return s.paint('34', t)
}

pub fn (s Style) magenta(t string) string {
	return s.paint('35', t)
}

pub fn (s Style) cyan(t string) string {
	return s.paint('36', t)
}

pub fn (s Style) grey(t string) string {
	return s.paint('90', t)
}

pub fn (s Style) inverse(t string) string {
	return s.paint('7', t)
}

// Glyph names the small set of symbols the UI draws, with ASCII fallbacks for
// terminals (and CI logs) that cannot render box drawing or bullets.
pub enum Glyph {
	bullet
	done
	active
	pending
	failed
	arrow
	warn
	hbar
	prompt
}

pub fn (s Style) glyph(g Glyph) string {
	if !s.unicode {
		return match g {
			.bullet { '*' }
			.done { '[x]' }
			.active { '[>]' }
			.pending { '[ ]' }
			.failed { '[!]' }
			.arrow { '->' }
			.warn { '!' }
			.hbar { '-' }
			.prompt { '>' }
		}
	}
	return match g {
		.bullet { '◉' }
		.done { '✓' }
		.active { '●' }
		.pending { '○' }
		.failed { '✗' }
		.arrow { '→' }
		.warn { '⚠' }
		.hbar { '─' }
		.prompt { '❯' }
	}
}

// terminal_width falls back to 80 when stdout is not a tty, which is what
// happens when V-AGENT runs in a pipeline or under CI.
pub fn terminal_width() int {
	w, _ := term.get_terminal_size()
	if w <= 0 || w > 400 {
		return 80
	}
	return w
}

pub fn is_tty() bool {
	return os.is_atty(1) > 0
}

// rule draws a horizontal separator across the terminal.
pub fn (s Style) rule(width int) string {
	ch := s.glyph(.hbar)
	mut out := ''
	for _ in 0 .. width {
		out += ch
	}
	return s.grey(out)
}
