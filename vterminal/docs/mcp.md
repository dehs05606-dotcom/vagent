# MCP gateway

**Status: not implemented.** `/mcp` says so rather than pretending. This
document is the design the rest of the codebase was built to accommodate, so
that landing it is additive.

## Intent

The Model Context Protocol lets external servers expose tools. The agent
runtime should never learn that a tool came from a server rather than from
`src/tools`:

```
                    MCP Gateway
                         │
          ┌──────────────┼──────────────┐
          ▼              ▼              ▼
      Server A        Server B       Server C
          │              │              │
        Tools          Tools          Tools
                         │
                         ▼
                   Tool Registry   ← indistinguishable from built-ins
```

## Why it fits without changes

`tools.Tool` is an interface, and `Registry.execute` already owns argument
decoding, validation, permission checks and output bounding. An `McpTool` that
holds a client handle plus a cached schema satisfies the interface as-is, and
`Registry.register` already lets a later registration shadow an earlier name.

Permission levels map directly: an MCP tool declaring a read-only annotation
registers as `READ`, everything else as `EXECUTE` or `NETWORK` depending on the
server's transport. Since policy is written against levels rather than names, a
newly discovered tool is governed from its first call.

## What remains

| Piece | Work |
|---|---|
| `src/mcp/protocol.v` | JSON-RPC 2.0 envelopes, `initialize`, `tools/list`, `tools/call`, error mapping |
| `src/mcp/transport.v` | stdio (spawn + framed pipes) and HTTP/SSE |
| `src/mcp/client.v` | one server: handshake, capability negotiation, request/response correlation, restart on crash |
| `src/mcp/registry.v` | discover tools across servers, namespace collisions as `server/tool`, adapt each to `tools.Tool` |
| config | an `"mcp": { "servers": { ... } }` block |
| `/mcp` | list servers, their state, and the tools each contributed |

The transport is the real work. V's `os.Process` supports redirected stdio, but
a robust stdio client needs non-blocking framed reads and a supervisor that
notices a server dying mid-call and fails the in-flight request instead of
hanging the agent loop.

## Planned configuration

```json
{
  "mcp": {
    "servers": {
      "filesystem": {
        "transport": "stdio",
        "command": "npx",
        "args": ["-y", "@modelcontextprotocol/server-filesystem", "."],
        "enabled": true
      },
      "internal-docs": {
        "transport": "http",
        "url": "https://mcp.internal.example/sse",
        "headers": { "Authorization": "Bearer ${DOCS_TOKEN}" }
      }
    }
  }
}
```

## Interim

Until this lands, a custom tool (`examples/custom_tool.v`) covers the same
ground for a single integration: a struct with two methods, registered once.
