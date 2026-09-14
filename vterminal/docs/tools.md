# Tools

## The contract

```v
pub interface Tool {
	spec() Spec
	execute(mut ctx Context, args map[string]json2.Any) Result
}
```

`Spec` declares the name, description, parameters and permission level.
`Result` carries `ok`, the `output` the model sees, and the one-line `summary`
the terminal shows.

The registry — not the tool — handles argument decoding, schema validation,
permission checks, output truncation and logging. A tool therefore only has to
do its job and describe its failure.

`execute` returns a `Result` rather than an error even for failures, because
every outcome has to become a `tool` message; an unrecoverable error here would
abandon the conversation mid-turn.

## Permission levels

| Level | Meaning | Built-ins |
|---|---|---|
| `READ` | observe the filesystem or environment | `read_file` `list_directory` `search_files` `search_text` `git_status` `git_diff` `git_log` `update_plan` |
| `WRITE` | modify files inside the workspace | `write_file` `edit_file` `delete_file` `git_commit` |
| `EXECUTE` | run arbitrary commands | `shell` |
| `NETWORK` | reach outside the machine | (none built in) |
| `ADMIN` | privileged or irreversible | (none built in) |

## Built-in tools

### Files

**`read_file`** `path` `offset?` `limit?` — returns line-numbered text so later
edits can cite accurate line numbers. Refuses binaries (NUL probe). Pages with
`offset`/`limit` and tells the model the offset to continue from.

**`write_file`** `path` `content` — creates or replaces a whole file, making
parent directories as needed.

**`edit_file`** `path` `old_string` `new_string` `replace_all?` — exact string
replacement. `old_string` must match exactly once unless `replace_all` is set;
an ambiguous match is an error naming the occurrence count, not a guess.

**`delete_file`** `path` `recursive?` — refuses a non-empty directory without
`recursive`, and always refuses the project root.

**`list_directory`** `path?` `depth?` `show_hidden?` — a tree, skipping `.git`,
`node_modules`, `target`, `dist`, `__pycache__` and friends. Capped at 800
entries.

### Search

**`search_files`** `pattern` `path?` `max_results?` — glob matching where `*`
stays within one path segment and `**` crosses segments. Results are ordered by
modification time, newest first, because recently touched files are usually
the relevant ones.

**`search_text`** `pattern` `path?` `glob?` `regex?` `ignore_case?`
`max_results?` — returns `path:line: content`. Literal substring by default,
regular expressions with `regex: true`. Binary files are skipped.

### Shell

**`shell`** `command` `workdir?` `timeout_secs?` — runs through the platform
shell and returns combined stdout/stderr plus the exit code and wall time.

On POSIX the command is wrapped in coreutils `timeout` when it is available
(probed once at startup), so a hung command cannot wedge the session; exit code
124 is reported as a timeout with partial output. Windows has no equivalent, so
the timeout is advisory there.

The command and the working directory are shell-quoted, so a path with spaces
or quotes cannot become a second command.

### Git

**`git_status`**, **`git_diff`** (`path?` `staged?` `stat?`), **`git_log`**
(`limit?` `path?`) are `READ`. **`git_commit`** (`message` `paths?`) is `WRITE`
and stages either the named paths or all modified tracked files. There is no
push tool, by design.

These exist rather than "just use `shell`" for two reasons: the model gets a
stable documented interface, and the permission engine can grant repository
inspection without granting the whole shell.

### Planning

**`update_plan`** `steps` `active?` — the model sends the full ordered step list
every time, not a delta, and the terminal renders it:

```
  Plan
  ✓ Inspect the auth flow
  ● Modify token validation
  ○ Run the tests
```

The plan lives in the tool context rather than in agent state, which is what
lets a tool write it without `tools` depending on `agent`.

## Writing your own

See `examples/custom_tool.v` for a complete, commented example. The short
version:

```v
pub struct MyTool {}

pub fn (t MyTool) spec() Spec {
	return Spec{
		name:        'my_tool'
		description: 'What it does, and when the model should reach for it.'
		level:       .read
		params:      [Param{ name: 'thing', description: '...', required: true }]
	}
}

pub fn (t MyTool) execute(mut ctx Context, args map[string]json2.Any) Result {
	thing := utils.jstr(args, 'thing', '')
	return ok_result('full output for the model', 'one line for the user')
}
```

Then `r.register(MyTool{})` in `register_builtins`.

Two things worth getting right:

* **Write the description for the model, not for a docs page.** It is the only
  thing that decides whether the tool gets called at the right moment. Say when
  to use it and when not to.
* **Use `ctx.resolve_path`** for anything path-shaped. It expands `~`,
  normalises, and enforces the workspace boundary. Bypassing it bypasses
  confinement.
