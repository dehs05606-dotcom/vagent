module context

import os
import strings
import src.tools
import src.utils

// Snapshot is what V-AGENT learns about a project before it says anything.
// Collecting this up front is what lets the first model turn already know the
// language, the build commands and the current VCS state, instead of spending
// three tool calls rediscovering them every session.
pub struct Snapshot {
pub mut:
	root            string
	workdir         string
	platform        string
	git_branch      string
	git_dirty       int
	git_recent      []string
	languages       []string
	build_commands  []string
	entries         []string
	readme_excerpt  string
	manifest_files  []string
	rules           []string
	collected_files int
}

// marker_files map a manifest to the ecosystem it implies and to the command a
// contributor would actually run. The mapping is deliberately conservative:
// a wrong build command wastes a whole agent iteration.
const marker_files = {
	'v.mod':            'V'
	'go.mod':           'Go'
	'Cargo.toml':       'Rust'
	'package.json':     'JavaScript/TypeScript'
	'pyproject.toml':   'Python'
	'requirements.txt': 'Python'
	'setup.py':         'Python'
	'Gemfile':          'Ruby'
	'composer.json':    'PHP'
	'pom.xml':          'Java (Maven)'
	'build.gradle':     'Java (Gradle)'
	'CMakeLists.txt':   'C/C++ (CMake)'
	'Makefile':         'Make'
	'Dockerfile':       'Docker'
	'mix.exs':          'Elixir'
	'pubspec.yaml':     'Dart/Flutter'
}

const build_hints = {
	'v.mod':          'v build . ; v test .'
	'go.mod':         'go build ./... ; go test ./...'
	'Cargo.toml':     'cargo build ; cargo test'
	'package.json':   'npm install ; npm test'
	'pyproject.toml': 'pytest'
	'Makefile':       'make'
	'CMakeLists.txt': 'cmake -B build && cmake --build build'
	'pom.xml':        'mvn -q test'
	'build.gradle':   'gradle test'
}

// rule_files are project-authored instructions that override V-AGENT defaults.
const rule_files = ['.vagent/rules.md', 'AGENTS.md', 'CONVENTIONS.md']

// collect gathers the project snapshot. Every step is best-effort: a missing
// git binary or an unreadable README degrades the snapshot, never the session.
pub fn collect(root string, workdir string) Snapshot {
	mut s := Snapshot{
		root:     root
		workdir:  workdir
		platform: utils.current_platform().str()
	}
	collect_entries(mut s)
	collect_manifests(mut s)
	collect_readme(mut s)
	collect_git(mut s)
	collect_rules(mut s)
	return s
}

fn collect_entries(mut s Snapshot) {
	mut names := os.ls(s.root) or { return }
	names.sort()
	for n in names {
		if n.starts_with('.') && n !in ['.github', '.vagent'] {
			continue
		}
		if tools.is_skipped_dir(n) {
			continue
		}
		full := os.join_path(s.root, n)
		s.entries << if os.is_dir(full) { '${n}/' } else { n }
		if s.entries.len >= 60 {
			break
		}
	}
}

fn collect_manifests(mut s Snapshot) {
	for file, lang in marker_files {
		if !os.exists(os.join_path(s.root, file)) {
			continue
		}
		s.manifest_files << file
		if lang !in s.languages {
			s.languages << lang
		}
		if hint := build_hints[file] {
			if hint !in s.build_commands {
				s.build_commands << hint
			}
		}
	}
}

fn collect_readme(mut s Snapshot) {
	for name in ['README.md', 'README.rst', 'README.txt', 'README'] {
		path := os.join_path(s.root, name)
		if !os.exists(path) {
			continue
		}
		content := os.read_file(path) or { continue }
		s.readme_excerpt = utils.truncate(content.trim_space(), 1500)
		return
	}
}

fn collect_git(mut s Snapshot) {
	if !utils.has_command('git') {
		return
	}
	if !os.exists(os.join_path(s.root, '.git')) {
		return
	}
	branch := os.execute('git -C "${s.root}" rev-parse --abbrev-ref HEAD 2>/dev/null')
	if branch.exit_code == 0 {
		s.git_branch = branch.output.trim_space()
	}
	status := os.execute('git -C "${s.root}" status --porcelain 2>/dev/null')
	if status.exit_code == 0 {
		s.git_dirty = status.output.split('\n').filter(it.trim_space() != '').len
	}
	log := os.execute('git -C "${s.root}" log --max-count=5 --pretty=format:"%h %s" 2>/dev/null')
	if log.exit_code == 0 && log.output.trim_space() != '' {
		s.git_recent = log.output.split('\n').filter(it.trim_space() != '')
	}
}

fn collect_rules(mut s Snapshot) {
	for rel in rule_files {
		path := os.join_path(s.root, rel)
		if !os.exists(path) {
			continue
		}
		content := os.read_file(path) or { continue }
		if content.trim_space() == '' {
			continue
		}
		s.rules << '# from ${rel}\n${utils.truncate(content.trim_space(), 4000)}'
	}
	// Anything dropped into .vagent/rules/ is treated as project policy too.
	dir := os.join_path(s.root, '.vagent', 'rules')
	if os.is_dir(dir) {
		mut files := os.ls(dir) or { [] }
		files.sort()
		for f in files {
			if !f.ends_with('.md') && !f.ends_with('.txt') {
				continue
			}
			content := os.read_file(os.join_path(dir, f)) or { continue }
			s.rules << '# from .vagent/rules/${f}\n${utils.truncate(content.trim_space(), 4000)}'
		}
	}
}

// render turns the snapshot into the text block that is injected into the
// system prompt. Order matters: identity first, then state, then rules, since
// later lines carry more weight with most models.
pub fn (s &Snapshot) render() string {
	mut sb := strings.new_builder(2048)
	sb.write_string('<project>\n')
	sb.write_string('root: ${s.root}\n')
	if s.workdir != s.root {
		sb.write_string('working directory: ${s.workdir}\n')
	}
	sb.write_string('platform: ${s.platform}\n')
	if s.languages.len > 0 {
		sb.write_string('stack: ${s.languages.join(', ')}\n')
	}
	if s.manifest_files.len > 0 {
		sb.write_string('manifests: ${s.manifest_files.join(', ')}\n')
	}
	if s.build_commands.len > 0 {
		sb.write_string('likely build/test commands: ${s.build_commands.join(' | ')}\n')
	}
	if s.git_branch != '' {
		sb.write_string('git branch: ${s.git_branch} (${s.git_dirty} uncommitted change(s))\n')
	}
	if s.git_recent.len > 0 {
		sb.write_string('recent commits:\n')
		for c in s.git_recent {
			sb.write_string('  ${c}\n')
		}
	}
	if s.entries.len > 0 {
		sb.write_string('top level: ${s.entries.join(' ')}\n')
	}
	if s.readme_excerpt != '' {
		sb.write_string('\n<readme>\n${s.readme_excerpt}\n</readme>\n')
	}
	sb.write_string('</project>\n')
	if s.rules.len > 0 {
		sb.write_string('\n<project_rules>\nThese come from the repository itself and take precedence over your defaults.\n')
		for r in s.rules {
			sb.write_string('${r}\n')
		}
		sb.write_string('</project_rules>\n')
	}
	return sb.str()
}

// summary is the one-liner shown by /context.
pub fn (s &Snapshot) summary() string {
	mut parts := []string{}
	if s.languages.len > 0 {
		parts << s.languages.join('/')
	}
	if s.git_branch != '' {
		parts << 'git:${s.git_branch}'
	}
	parts << '${s.entries.len} top-level entries'
	if s.rules.len > 0 {
		parts << '${s.rules.len} rule file(s)'
	}
	return parts.join(', ')
}
