"""A minimal ANSI screen emulator: enough to assert on what a user sees."""
import re

class Screen:
    def __init__(self, cols=100, rows=30):
        self.cols, self.rows = cols, rows
        self.grid = [[' '] * cols for _ in range(rows)]
        self.cy = self.cx = 0

    def _scroll(self):
        self.grid.pop(0)
        self.grid.append([' '] * self.cols)

    def _put(self, ch):
        if self.cx >= self.cols:
            self.cx = 0
            self.cy += 1
        while self.cy >= self.rows:
            self._scroll(); self.cy -= 1
        self.grid[self.cy][self.cx] = ch
        self.cx += 1

    def feed(self, text):
        i = 0
        n = len(text)
        while i < n:
            c = text[i]
            if c == '\x1b':
                m = re.match(r'\x1b\[([0-9;?]*)([A-Za-z])', text[i:])
                if not m:
                    i += 1; continue
                params, cmd = m.group(1), m.group(2)
                nums = [int(x) for x in params.replace('?','').split(';') if x.isdigit()]
                a = nums[0] if nums else 1
                if cmd == 'A': self.cy = max(0, self.cy - a)
                elif cmd == 'B': self.cy = min(self.rows-1, self.cy + a)
                elif cmd == 'C': self.cx = min(self.cols-1, self.cx + a)
                elif cmd == 'D': self.cx = max(0, self.cx - a)
                elif cmd == 'G': self.cx = max(0, a - 1)
                elif cmd == 'H':
                    self.cy = (nums[0]-1) if nums else 0
                    self.cx = (nums[1]-1) if len(nums)>1 else 0
                elif cmd == 'J':
                    mode = nums[0] if nums else 0
                    if mode == 2:
                        self.grid = [[' ']*self.cols for _ in range(self.rows)]
                        self.cy = self.cx = 0
                    elif mode == 0:
                        for x in range(self.cx, self.cols): self.grid[self.cy][x] = ' '
                        for y in range(self.cy+1, self.rows): self.grid[y] = [' ']*self.cols
                elif cmd == 'K':
                    for x in range(self.cx, self.cols): self.grid[self.cy][x] = ' '
                i += m.end(); continue
            if c == '\r': self.cx = 0
            elif c == '\n':
                self.cy += 1; self.cx = 0
                while self.cy >= self.rows:
                    self._scroll(); self.cy -= 1
            elif c == '\b': self.cx = max(0, self.cx-1)
            elif c == '\t': self.cx = min(self.cols-1, (self.cx//8+1)*8)
            elif ord(c) >= 32: self._put(c)
            i += 1

    def lines(self):
        return [''.join(r).rstrip() for r in self.grid]

    def text(self):
        return '\n'.join(self.lines())
