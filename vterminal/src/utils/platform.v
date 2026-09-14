module utils

import os

pub enum Platform {
	linux
	macos
	windows
	wsl
	unknown
}

// current_platform distinguishes WSL from plain Linux, because the two need
// different defaults for shells and for path translation.
pub fn current_platform() Platform {
	$if windows {
		return .windows
	}
	$if macos {
		return .macos
	}
	$if linux {
		if is_wsl() {
			return .wsl
		}
		return .linux
	}
	return .unknown
}

pub fn (p Platform) str() string {
	return match p {
		.linux { 'linux' }
		.macos { 'macos' }
		.windows { 'windows' }
		.wsl { 'wsl' }
		.unknown { 'unknown' }
	}
}

fn is_wsl() bool {
	if os.getenv('WSL_DISTRO_NAME') != '' || os.getenv('WSLENV') != '' {
		return true
	}
	version := os.read_file('/proc/version') or { return false }
	lower := version.to_lower()
	return lower.contains('microsoft') || lower.contains('wsl')
}

// default_shell returns the shell V-AGENT runs `shell` tool commands through.
pub fn default_shell() (string, []string) {
	$if windows {
		comspec := os.getenv('COMSPEC')
		if comspec != '' {
			return comspec, ['/C']
		}
		return 'cmd.exe', ['/C']
	}
	sh := os.getenv('SHELL')
	if sh != '' && os.exists(sh) {
		return sh, ['-c']
	}
	return '/bin/sh', ['-c']
}

// home_dir is os.home_dir() with the trailing separator normalised away.
pub fn home_dir() string {
	return os.home_dir().trim_right(os.path_separator)
}

// user_config_dir is where the global ~/.vagent tree lives.
pub fn user_config_dir() string {
	if custom := os.getenv_opt('VAGENT_HOME') {
		if custom.trim_space() != '' {
			return custom
		}
	}
	return os.join_path(home_dir(), '.vagent')
}

// project_config_dir is the per-project ./.vagent tree for `root`.
pub fn project_config_dir(root string) string {
	return os.join_path(root, '.vagent')
}

// find_project_root walks up from `start` looking for the markers that make a
// directory the root of a project, so context and memory attach to the repo
// rather than to whatever subdirectory the user happened to launch from.
pub fn find_project_root(start string) string {
	markers := ['.git', '.vagent', 'v.mod', 'go.mod', 'package.json', 'Cargo.toml', 'pyproject.toml',
		'pom.xml', 'build.gradle', 'CMakeLists.txt', 'Makefile']
	mut dir := os.real_path(start)
	for {
		for marker in markers {
			if os.exists(os.join_path(dir, marker)) {
				return dir
			}
		}
		parent := os.dir(dir)
		if parent == dir || parent == '' {
			break
		}
		dir = parent
	}
	return os.real_path(start)
}

// has_command reports whether `name` is runnable from PATH.
pub fn has_command(name string) bool {
	os.find_abs_path_of_executable(name) or { return false }
	return true
}

// ensure_dir creates `path` (and parents) if it does not exist yet.
pub fn ensure_dir(path string) ! {
	if os.exists(path) {
		if os.is_dir(path) {
			return
		}
		return err_hint(.filesystem, 'cannot create directory ${path}',
			'a file with that name already exists')
	}
	os.mkdir_all(path) or {
		return err_hint(.filesystem, 'cannot create directory ${path}', err.msg())
	}
}
