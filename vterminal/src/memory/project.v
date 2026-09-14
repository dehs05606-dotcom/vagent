module memory

import os
import time
import src.utils

// ProjectMemory is the durable, human-readable half of memory: a markdown file
// in the repository's own .vagent directory. Markdown rather than a database
// on purpose — it is meant to be read, edited and reviewed by people, and to
// travel with the repository if they choose to commit it.
pub struct ProjectMemory {
pub mut:
	path  string
	notes []string
}

pub fn load_project_memory(root string) ProjectMemory {
	path := os.join_path(utils.project_config_dir(root), 'memory', 'notes.md')
	mut pm := ProjectMemory{
		path: path
	}
	content := os.read_file(path) or { return pm }
	for line in content.split('\n') {
		t := line.trim_space()
		if t.starts_with('- ') {
			pm.notes << t#[2..]
		}
	}
	return pm
}

// remember appends a note, skipping exact duplicates so a repeated run does
// not grow the file without bound.
pub fn (mut pm ProjectMemory) remember(note string) ! {
	n := note.trim_space()
	if n == '' {
		return
	}
	if n in pm.notes {
		return
	}
	pm.notes << n
	utils.ensure_dir(os.dir(pm.path))!
	stamp := time.now().format_ss()
	mut f := os.open_append(pm.path) or {
		return utils.err_hint(.filesystem, 'cannot write project memory', err.msg())
	}
	defer { f.close() }
	if pm.notes.len == 1 {
		f.writeln('# V-AGENT project memory')!
		f.writeln('')!
	}
	f.writeln('- ${n}  <!-- ${stamp} -->')!
}

// render is injected into the system prompt when the file is non-empty.
pub fn (pm &ProjectMemory) render() string {
	if pm.notes.len == 0 {
		return ''
	}
	mut out := '<project_memory>\nNotes carried over from previous sessions in this repository:\n'
	for n in pm.notes {
		out += '- ${n}\n'
	}
	out += '</project_memory>\n'
	return out
}

pub fn (pm &ProjectMemory) summary() string {
	if pm.notes.len == 0 {
		return 'no project memory yet (${pm.path})'
	}
	return '${pm.notes.len} note(s) in ${pm.path}'
}
