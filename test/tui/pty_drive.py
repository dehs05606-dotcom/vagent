import os, pty, sys, time, select, re, tempfile

# the binary under test, and a throwaway state directory so a test run never
# touches the machine's own event log
BINARY = os.environ.get('VAGENT_BIN',
                        os.path.join(os.path.dirname(os.path.abspath(__file__)),
                                     '..', '..', 'vagent-bin'))
HOME = os.environ.get('VAGENT_TEST_HOME',
                      os.path.join(tempfile.gettempdir(), 'vagent-tui-test'))
os.makedirs(HOME, exist_ok=True)

def drive(keys, wait=0.6, cols=100, rows=30, quit=True):
    pid, fd = pty.fork()
    if pid == 0:
        os.environ['FULLAGENT_HOME'] = HOME
        os.environ['TERM'] = 'xterm-256color'
        os.execv(BINARY, [BINARY])
    import fcntl, struct, termios
    fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack('HHHH', rows, cols, 0, 0))
    out = b''
    t0 = time.time()
    def pump(dur):
        nonlocal out
        end = time.time() + dur
        while time.time() < end:
            r, _, _ = select.select([fd], [], [], 0.05)
            if r:
                try:
                    chunk = os.read(fd, 65536)
                except OSError:
                    return False
                if not chunk: return False
                out += chunk
        return True
    pump(1.2)
    for k in keys:
        os.write(fd, k if isinstance(k, bytes) else k.encode())
        if not pump(wait): break
    pump(0.5)
    if quit:
        try: os.write(fd, b'\x04')
        except OSError: pass
        pump(0.8)
    else:
        import signal
        try: os.kill(pid, signal.SIGKILL)
        except ProcessLookupError: pass
    try: os.close(fd)
    except OSError: pass
    try: os.waitpid(pid, 0)
    except ChildProcessError: pass
    return out.decode('utf-8', 'replace')

if __name__ == '__main__':
    import json
    keys = json.loads(sys.argv[1]) if len(sys.argv) > 1 else []
    keys = [k.encode().decode('unicode_escape').encode('latin1') for k in keys]
    text = drive(keys)
    sys.stdout.write(text)
