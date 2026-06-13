# Python Debugger (pdb + debugpy)

Three tools, picked by situation:

| Tool | When |
|---|---|
| **`breakpoint()` + pdb** | Local, interactive, simplest. Add `breakpoint()` in the source, run normally, get a REPL at that line. |
| **`python -m pdb`** | Launch an existing script under pdb with no source edits. Useful for quick poking. |
| **`debugpy`** | Remote / headless / "attach to already-running process." Talks DAP, scriptable from terminal, works for long-lived processes (gateway, daemon, PTY children). |

**Start with `breakpoint()`.** It's the cheapest thing that works.

## When to Use

- A test fails and the traceback doesn't reveal why a value is wrong
- You need to step through a function and watch a collection mutate
- A long-running process (hermes gateway, tui_gateway) misbehaves and you can't restart it
- Post-mortem: an exception fired in prod-ish code and you want to inspect locals at the crash site
- A subprocess / child (Python `_SlashWorker`, PTY bridge worker) is the actual bug site

**Don't use for:** things `print()` / `logging.debug` solve in under a minute, or things `pytest -vv --tb=long --showlocals` already reveals.

## pdb Quick Reference

Inside any pdb prompt (`(Pdb)`):

| Command | Action |
|---|---|
| `h` / `h cmd` | help |
| `n` | next line (step over) |
| `s` | step into |
| `r` | return from current function |
| `c` | continue |
| `unt N` | continue until line N |
| `j N` | jump to line N (same function only) |
| `l` / `ll` | list source around current line / full function |
| `w` | where (stack trace) |
| `u` / `d` | move up / down in the stack |
| `a` | print args of the current function |
| `p expr` / `pp expr` | print / pretty-print expression |
| `display expr` | auto-print expr on every stop |
| `b file:line` | set breakpoint |
| `b func` | break on function entry |
| `b file:line, cond` | conditional breakpoint |
| `cl N` | clear breakpoint N |
| `tbreak file:line` | one-shot breakpoint |
| `!stmt` | execute arbitrary Python (assignments included) |
| `interact` | drop into full Python REPL in current scope (Ctrl+D to exit) |
| `q` | quit |

## Recipe 1: Local breakpoint

```python
def compute(x, y):
    result = some_helper(x)
    breakpoint()           # <-- drops into pdb here
    return result + y
```

Run the code normally. You land at the `breakpoint()` line with full access to locals.

**Don't forget to remove `breakpoint()` before committing.**

## Recipe 2: Launch a script under pdb (no source edits)

```bash
python -m pdb path/to/script.py arg1 arg2
(Pdb) b path/to/script.py:42
(Pdb) c
```

## Recipe 3: Debug a pytest test

```bash
# Drop to pdb on failure:
scripts/run_tests.sh tests/path/to/test_file.py::test_name --pdb

# Drop to pdb at the START:
scripts/run_tests.sh tests/path/to/test_file.py::test_name --trace

# Show locals without pdb:
scripts/run_tests.sh tests/path/to/test_file.py --showlocals --tb=long
```

Note: `scripts/run_tests.sh` uses xdist (`-n 4`) by default, and pdb does NOT work under xdist. Add `-p no:xdist` or run a single test with `-n 0`.

## Recipe 4: Post-mortem on any exception

```python
import pdb, sys
try:
    run_the_thing()
except Exception:
    pdb.post_mortem(sys.exc_info()[2])
```

## Recipe 5: Remote debug with debugpy (attach to running process)

### Pattern A: Source-edit — process waits for debugger at launch

```python
import debugpy
debugpy.listen(("127.0.0.1", 5678))
print("debugpy listening on 5678, waiting for client...", flush=True)
debugpy.wait_for_client()
debugpy.breakpoint()
```

### Pattern B: No source edit — launch with `-m debugpy`

```bash
python -m debugpy --listen 127.0.0.1:5678 --wait-for-client your_script.py arg1
```

### Pattern C: Attach to an already-running process

```bash
python -m debugpy --listen 127.0.0.1:5678 --pid <pid>
```

Some kernels/security configs block the ptrace-based injection. Fix with:
```bash
echo 0 | sudo tee /proc/sys/kernel/yama/ptrace_scope
```

### Connecting a client

**Option 1: `remote-pdb`** (cleanest agent-friendly choice):

```bash
pip install remote-pdb
```

```python
from remote_pdb import set_trace
set_trace(host="127.0.0.1", port=4444)   # blocks until connection
```

```bash
nc 127.0.0.1 4444   # Get a (Pdb) prompt as if debugging locally
```

**Option 2: VS Code / Cursor / Zed** — add a `launch.json`:
```json
{
  "name": "Attach to Hermes",
  "type": "debugpy",
  "request": "attach",
  "connect": { "host": "127.0.0.1", "port": 5678 },
  "justMyCode": false,
  "pathMappings": [{ "localRoot": "${workspaceFolder}", "remoteRoot": "/home/bb/hermes-agent" }]
}
```

## Common Pitfalls

1. **pdb under pytest-xdist silently does nothing.** Always use `-p no:xdist` or `-n 0`.
2. **`breakpoint()` in CI / non-TTY contexts hangs the process.** Never commit it.
3. **`PYTHONBREAKPOINT=0`** disables all `breakpoint()` calls.
4. **`debugpy.listen` blocks only if you also call `wait_for_client()`.**
5. **Attach to PID fails on hardened kernels.**
6. **Threads.** `pdb` only debugs the current thread. For multithreaded, use `debugpy`.
7. **asyncio.** Use `remote-pdb` or `debugpy`.
8. **Forking / multiprocessing.** pdb does not follow forks.

## Verification Checklist

- [ ] After `pip install debugpy`, confirm: `python -c "import debugpy; print(debugpy.__version__)"`
- [ ] For remote debug, confirm the port is actually listening: `ss -tlnp | grep 5678`
- [ ] First breakpoint actually hits (check `PYTHONBREAKPOINT`, xdist, attach timing)
- [ ] `where` / `w` shows the expected call stack
- [ ] Post-debug cleanup: no stray `breakpoint()` / `set_trace()` in committed code
