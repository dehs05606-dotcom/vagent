module vagent

fn test_fnmatch_star_crosses_separators() {
	assert fnmatch_name('main.py', '*.py')
	assert fnmatch_name('main.py', '*')
	assert !fnmatch_name('main.pyc', '*.py')
	assert fnmatch_name('a/b/c.py', '*.py') // fnmatch's `*` crosses `/`
	assert fnmatch_name('test_x.py', 'test_*.py')
	assert !fnmatch_name('x_test.py', 'test_*.py')
}

fn test_fnmatch_question_and_classes() {
	assert fnmatch_name('a.c', '?.c')
	assert !fnmatch_name('ab.c', '?.c')
	assert fnmatch_name('a.c', '[abc].c')
	assert !fnmatch_name('d.c', '[abc].c')
	assert fnmatch_name('d.c', '[!abc].c')
	assert fnmatch_name('f5.txt', 'f[0-9].txt')
	assert !fnmatch_name('fx.txt', 'f[0-9].txt')
	// an unterminated class is a literal bracket, as in fnmatch
	assert fnmatch_name('[x', '[x')
}

fn test_glob_star_stops_at_separator() {
	assert glob_match('main.py', '*.py')
	assert !glob_match('src/main.py', '*.py')
	assert glob_match('src/main.py', '*/*.py')
	assert glob_match('src/main.py', 'src/*.py')
}

fn test_glob_doublestar_spans_directories() {
	assert glob_match('main.py', '**/*.py')
	assert glob_match('src/main.py', '**/*.py')
	assert glob_match('a/b/c/main.py', '**/*.py')
	assert !glob_match('a/b/c/main.txt', '**/*.py')
	assert glob_match('src/a/b.py', 'src/**/*.py')
	assert glob_match('src/b.py', 'src/**/*.py') // `**/` matches zero dirs
	assert glob_match('anything/at/all', '**')
}

fn test_glob_exact_and_empty() {
	assert glob_match('README.md', 'README.md')
	assert !glob_match('README.md', 'README')
	assert glob_match('', '')
	assert !glob_match('x', '')
	assert glob_match('', '*')
}
