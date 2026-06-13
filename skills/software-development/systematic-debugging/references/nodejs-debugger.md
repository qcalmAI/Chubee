# Node.js Inspect Debugger

When `console.log` isn't enough, drive Node's built-in V8 inspector programmatically from the terminal. Two tools:

- **`node inspect`** — built-in, zero install, CLI REPL. Best for quick poking.
- **`ndb` / CDP via `chrome-remote-interface`** — scriptable from Node/Python; best for automation.

**Prefer `node inspect` first.**

## When to Use

- A Node test fails and you need to see intermediate state
- ui-tui crashes or behaves wrong and you want to inspect React/Ink state
- tui_gateway child processes misbehave
- You need to inspect a value in a closure
- Perf: attach to a running process to capture a CPU profile or heap snapshot

**Don't use for:** things `console.log` solves in under a minute.

## Quick Reference: `node inspect` REPL

```bash
node inspect path/to/script.js
# or with tsx
node --inspect-brk $(which tsx) path/to/script.ts
```

The `debug>` prompt accepts:

| Command | Action |
|---|---|
| `c` or `cont` | continue |
| `n` or `next` | step over |
| `s` or `step` | step into |
| `o` or `out` | step out |
| `pause` | pause running code |
| `sb('file.js', 42)` | set breakpoint at file.js line 42 |
| `sb('functionName')` | break when function is called |
| `cb('file.js', 42)` | clear breakpoint |
| `bt` | backtrace (call stack) |
| `list(5)` | show 5 lines of source around current position |
| `watch('expr')` | evaluate expr on every pause |
| `repl` | drop into REPL in current scope (Ctrl+C to exit) |
| `exec expr` | evaluate expression once |
| `restart` | restart script |
| `kill` | kill the script |
| `.exit` | quit debugger |

## Attaching to a Running Process

```bash
# Send SIGUSR1 to enable the inspector
kill -SIGUSR1 <pid>
# Node prints: Debugger listening on ws://127.0.0.1:9229/<uuid>

# Attach the debugger CLI
node inspect -p <pid>
```

Start with inspector from the beginning:
```bash
node --inspect script.js           # listen on 127.0.0.1:9229, keep running
node --inspect-brk script.js       # listen AND pause on first line
node --inspect=0.0.0.0:9230 script.js   # custom host:port
```

For TypeScript via tsx:
```bash
node --inspect-brk --import tsx script.ts
```

## Programmatic CDP (scripting from terminal)

```bash
npm i -g chrome-remote-interface
node --inspect-brk=9229 target.js &
```

Driver script (save as `/tmp/cdp-debug.js`):
```javascript
const CDP = require('chrome-remote-interface');
(async () => {
  const client = await CDP({ port: 9229 });
  const { Debugger, Runtime } = client;
  Debugger.paused(async ({ callFrames, reason }) => {
    const top = callFrames[0];
    console.log(`PAUSED: ${reason} @ ${top.url}:${top.location.lineNumber + 1}`);
    for (const scope of top.scopeChain) {
      if (scope.type === 'local' || scope.type === 'closure') {
        const { result } = await Runtime.getProperties({
          objectId: scope.object.objectId, ownProperties: true,
        });
        for (const p of result) {
          console.log(`  ${scope.type}.${p.name} =`, p.value?.value ?? p.value?.description);
        }
      }
    }
    await Debugger.resume();
  });
  await Runtime.enable();
  await Debugger.enable();
  await Debugger.setBreakpointByUrl({ urlRegex: '.*app\\.tsx$', lineNumber: 119, columnNumber: 0 });
  await Runtime.runIfWaitingForDebugger();
})();
```

## Debugging Hermes ui-tui

### Debugging a single Ink component
```bash
cd /home/bb/hermes-agent/ui-tui
npm run build
node --inspect-brk dist/entry.js
# In another terminal:
node inspect -p <node pid>
```

### Debugging a running `hermes --tui`
```bash
hermes --tui &
TUI_PID=$(pgrep -f 'ui-tui/dist/entry' | head -1)
kill -SIGUSR1 "$TUI_PID"
curl -s http://127.0.0.1:9229/json/list | jq -r '.[0].webSocketDebuggerUrl'
node inspect ws://127.0.0.1:9229/<uuid>
```

## Running Vitest Tests Under the Debugger
```bash
cd /home/bb/hermes-agent/ui-tui
node --inspect-brk ./node_modules/vitest/vitest.mjs run --no-file-parallelism src/app/foo.test.tsx
```
Use `--no-file-parallelism` (vitest) or `--runInBand` (jest).

## Heap Snapshots & CPU Profiles
```javascript
// CPU profile for 5 seconds
await client.Profiler.enable();
await client.Profiler.start();
await new Promise(r => setTimeout(r, 5000));
const { profile } = await client.Profiler.stop();
require('fs').writeFileSync('/tmp/cpu.cpuprofile', JSON.stringify(profile));
```

## Common Pitfalls

1. **Wrong line numbers in TS source.** Breakpoints hit the emitted JS. Enable sourcemaps with `node --enable-source-maps`.
2. **`--inspect` vs `--inspect-brk`.** Use `--inspect-brk` when you need to set breakpoints before any code runs.
3. **Port collisions.** Default is `9229`. Use `--inspect=0` for random port.
4. **Child processes.** `--inspect` on a parent does NOT inspect its children. Use `NODE_OPTIONS='--inspect-brk' node parent.js`.
5. **Background kills.** If you `Ctrl+C` out while the target is paused, it stays paused.
6. **Running `node inspect` through an agent terminal.** Use `terminal(pty=true)` or `background=true` + `process(action='submit')`.
7. **Security.** Always bind to `127.0.0.1` (the default) unless you have an isolated network.

## Verification Checklist
- [ ] `curl -s http://127.0.0.1:9229/json/list` returns exactly the target you expect
- [ ] First breakpoint actually hits
- [ ] Source listing at pause shows the right file
