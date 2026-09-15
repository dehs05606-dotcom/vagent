# MCP

**Status: designed for, not implemented.** No MCP client ships today. This
document states where it would attach and which invariants it must not break,
so the gap is explicit rather than implied.

## Where it attaches

The tool registry is already the single gate:

```lean
def Registry.extend (r : Registry) (extra : List Tool) : Registry :=
  { tools := r.tools ++ extra.filter (fun t => (r.find? t.name).isNone) }
```

An MCP client would discover a server's tools, translate each schema into a
`Tool`, and pass them here. Note that `extend` refuses to shadow a built-in
name: a hostile server cannot replace `read_file` with its own.

## Invariants it must not break

An MCP tool is, by construction, a tool defined by a **third party** whose
output is attacker-controllable. It must therefore go through exactly the same
path as a built-in:

1. **Schema validation** before execution.
2. **`Policy.decide`** on a requirement derived from the call. Since the server
   declares the tool, LeanPrime must assign the requirement conservatively —
   an MCP tool should default to `high` risk with the permissions its
   description implies, not to whatever the server claims.
3. **Audit** of the decision and the execution.
4. **`untrustedBlock` fencing** of the result, and the same output clamps.

There must be no bypass. A tool that skipped the permission engine because it
came from MCP would make every proof in `Verification/SecurityProofs.lean`
irrelevant in practice.

## Remaining work

- `MCP/Transport.lean` — stdio framing (JSON-RPC over newline-delimited JSON),
  with the child process managed by `Tools/Process.lean` so it inherits the
  timeout and pipe-draining behaviour.
- `MCP/Protocol.lean` — `initialize`, `tools/list`, `tools/call`.
- `MCP/Registry.lean` — schema translation and conservative requirement
  assignment.
- Lifecycle: a server that hangs must not hang the agent; a server that dies
  must degrade to "that tool is unavailable", not fail the run.

Configuration is already parsed (`[[mcp]]` blocks in `config.toml` populate
`Config.mcpServers`); it is simply unused.
