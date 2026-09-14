# vagent

**V-AGENT** — a native terminal AI coding agent written in [V](https://vlang.io).

The project lives in [`vterminal/`](vterminal/). Start there:

```sh
cd vterminal
make build     # -> bin/vagent
make test
export VAGENT_API_KEY=sk-...
bin/vagent "fix the failing test"
```

See [vterminal/README.md](vterminal/README.md) for setup, configuration and
usage, and [vterminal/docs/](vterminal/docs/) for the architecture, the tool
contract, provider support and the MCP design.
