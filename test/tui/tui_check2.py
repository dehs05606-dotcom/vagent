import os, sys
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from pty_drive import drive
from screen import Screen

def screen_of(keys, wait=0.5, quit=False, cols=100, rows=40):
    raw = drive([k.encode('latin1') if isinstance(k,str) else k for k in keys],
                wait=wait, quit=quit, cols=cols, rows=rows)
    sc = Screen(cols, rows)
    sc.feed(raw)
    return sc

results = []
def check(name, cond, dump=None):
    results.append(bool(cond))
    print(('  ✓ ' if cond else '  ✗ ') + name)
    if not cond and dump is not None:
        print('--- screen ---'); print(dump); print('--------------')

# 1. the box survives a burst of output and stays whole at the bottom
sc = screen_of(['/state\r', '/state\r', '/state\r', '/state\r'], wait=0.45)
lines = [l for l in sc.lines() if l.strip()]
tail = lines[-3:]
check('the box stays whole under repeated output',
      tail[0].startswith('╭') and tail[1].startswith('│') and tail[2].startswith('╰'),
      sc.text())

# 2. no scrollback line is eaten when output arrives with the menu open
#    (/about opens a completion menu; the reply must keep both its lines)
sc = screen_of(['/about\r'], wait=0.6)
txt = sc.text()
check('no scrollback is eaten while the completion menu is open',
      'advanced terminal AI agent' in txt and 'hand-written terminal engine' in txt,
      txt)

# 3. arrow keys move the picker selection
sc = screen_of(['\x14', '\x1b[B', '\x1b[B'], wait=0.4)
check('the picker marks a moved selection', '▶ ' in sc.text(), sc.text())

# 4. a picker selection applies and flashes
sc = screen_of(['\x05', '\x1b[B', '\r'], wait=0.4)
check('choosing an effort applies it', 'effort →' in sc.text(), sc.text())

# 5. multi-line input shows a continuation row
sc = screen_of(['first line', '\x1b\r', 'second line'], wait=0.4)
t = sc.text()
check('a multi-line draft shows both rows',
      'first line' in t and 'second line' in t, t)

# 6. history recall after a submitted line
sc = screen_of(['/about\r', '\x1b[A'], wait=0.5)
check('up-arrow recalls the last submission', '❯ /about' in sc.text(), sc.text())

# 7. /clear wipes the screen but keeps the box
sc = screen_of(['/state\r', '/clear\r'], wait=0.5)
t = sc.text()
check('/clear wipes scrollback and redraws the box',
      'branch: main' not in t and '╰' in t, t)

# 8. a narrow terminal still draws a closed box
sc = screen_of(['hi'], wait=0.4, cols=60, rows=24)
lines = [l for l in sc.lines() if l.strip()]
tail = lines[-3:]
check('a 60-column terminal still closes the box',
      tail[0].startswith('╭') and tail[0].endswith('╮') and tail[2].endswith('╯'),
      sc.text())

# 9. the box is torn down on exit — the shell gets a clean line
raw = drive([b'/exit\r'], wait=0.6, quit=False)
sc = Screen(100, 40); sc.feed(raw)
lines = [l for l in sc.lines() if l.strip()]
check('exit leaves no half-box behind',
      lines[-1].startswith('bye — session'), sc.text())

# 10. every border row is exactly the terminal width (no wrap, no gap)
sc = screen_of(['x'], wait=0.4, cols=100, rows=40)
grid = sc.lines()
box = [i for i,l in enumerate(grid) if l.startswith('╭')]
ok = False
if box:
    i = box[-1]
    top, mid, bot = grid[i], grid[i+1], grid[i+2]
    ok = (top.endswith('╮') and mid.endswith('│') and bot.endswith('╯'))
check('every border row closes at the right edge', ok, sc.text())

print()
print(f'{sum(results)}/{len(results)} passed')
sys.exit(0 if all(results) else 1)
