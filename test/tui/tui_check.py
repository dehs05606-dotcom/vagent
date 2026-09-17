import os, sys, json
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from pty_drive import drive
from screen import Screen

def run(name, keys, checks, wait=0.5, quit=True):
    raw = drive([k.encode('latin1') if isinstance(k,str) else k for k in keys], wait=wait, quit=quit)
    sc = Screen()
    sc.feed(raw)
    txt = sc.text()
    ok = True
    for want, should in checks:
        present = want in txt
        if present != should:
            ok = False
            print(f'  ✗ {name}: {"missing" if should else "unexpected"} {want!r}')
    print(('  ✓ ' if ok else '  ✗ ') + name)
    if not ok:
        print('--- screen ---')
        print(txt)
        print('--------------')
    return ok

results = []
results.append(run('typing shows in the box', ['hello world'],
    [('hello world', True), ('❯ hello world', True)]))
results.append(run('backspace deletes', ['abcdef', '\x7f\x7f'],
    [('abcd', True), ('abcdef', False)]))
results.append(run('/about prints two lines', ['/about', '\r'],
    [('FullAgent v3.1.0 — advanced terminal AI agent', True),
     ('OpenCode Zen & TokenRouter providers', True)]))
results.append(run('unknown command is an error panel', ['/nope', '\r'],
    [('error', True), ('unknown command: /nope', True)]))
results.append(run('/help opens the overlay', ['/help', '\r'],
    [('HELP', True), ('Esc close', True), ('/model', True)]))
results.append(run('escape closes the overlay', ['/help', '\r', '\x1b'],
    [('Esc close', False)]))
results.append(run('ctrl+t opens the model picker', ['\x14'],
    [('SELECT MODEL', True)]))
results.append(run('ctrl+e opens the effort picker', ['\x05'],
    [('SELECT EFFORT', True)]))
results.append(run('slash completion menu appears', ['/mo'],
    [('/model', True)]))
results.append(run('tab picks a completion', ['/eff', '\t'],
    [('❯ /effort', True)]))
results.append(run('ctrl+u clears the line', ['garbage here', '\x15'],
    [('garbage here', False)]))
results.append(run('esc+enter makes a newline', ['one', '\x1b\r', 'two'],
    [('one', True), ('two', True)]))
results.append(run('/effort sets the level and the border shows it',
    ['/effort low', '\r'],
    [('effort → LOW', True), ('effort: low', True)], quit=False))
results.append(run('/autonomy sets the level', ['/autonomy 5', '\r'],
    [('autonomy → L5', True)]))
results.append(run('ctrl+c on a non-empty line clears it', ['keep typing', '\x03'],
    [('keep typing', False), ('input cleared', True)], quit=False))
results.append(run('ctrl+c on an empty line hints how to quit', ['\x03'],
    [('type /exit or Ctrl+D to quit', True)], quit=False))
results.append(run('/state reads the log', ['/state', '\r'],
    [('branch: main', True), ('autonomy: L', True)]))
results.append(run('/goal rejects an unprovable clause',
    ['/goal set ship it | it feels right', '\r'],
    [('machine-checkable proof', True)]))

print()
print(f'{sum(results)}/{len(results)} passed')
sys.exit(0 if all(results) else 1)
