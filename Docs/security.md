# Security

## Threat model

An autonomous coding agent is unusual: it reads attacker-controllable text
(repository files, command output, third-party servers) and then takes
privileged actions on the user's machine. The assumption here is that **the
model will sometimes be convinced by that text**, and that the *actions* it can
take must be bounded anyway.

Note the boundary this draws. LeanPrime does not try to stop the model from
being persuaded — by default it will follow instructions it finds in a
repository, which is what you want when the repository is yours and carries
your `LEANPRIME.md`. What it bounds is what any of that can cause to happen.

Threats considered:

| Threat | Defence |
|---|---|
| Repository content steering the agent | opt-in `data_fencing`; policy independent of the model |
| Path traversal to read or write outside the workspace | `Workspace.resolve`, **proved** escape-free |
| Destructive shell commands | conservative classifier, deny list enforced in every mode |
| Command smuggling via shell chaining | chaining escalates risk; **proved** never low |
| Credential exfiltration | redaction on every sink; key never in argv |
| Context flooding by huge command output | byte and line clamps on every tool result |
| Runaway autonomous loop | four budgets, all of which terminate |
| Malformed or hostile model output | schema validation before execution; unknown tools rejected |

## The load-bearing idea

**The permission decision does not depend on the model.**

```lean
def Policy.decide (p : Policy) (r : Requirement) : Decision
```

It is pure and total. Its inputs are the policy (from config and explicit user
approvals) and the requirement (derived from the call's arguments). The model's
reasoning, its stated justification, and anything it read are not inputs.

So a model that has been fully persuaded by anything it read still cannot do
what the policy refuses. **No prompt grants permission** — not the operator's,
and not one found in a file. This is what lets you hand the agent an arbitrary
system prompt without also handing it arbitrary power.

## Prompt authority vs. permission

These are separate systems, and keeping them separate is the point.

| | Governs | Set by | Can a prompt change it? |
|---|---|---|---|
| Prompt layers | what the agent *tries* to do | `--system-prompt`, `[prompt]`, `LEANPRIME.md` | yes — that is their job |
| Permission engine | what the agent *may* do | `[agent] approval_mode`, `[security]`, the approval prompt | **no** |

`Policy.decide` takes the policy and the requirement. It does not take the
system prompt, the conversation, or the model's justification. See
`Docs/system-prompt.md`.

## Data framing

```toml
[security]
data_fencing = false   # default
```

By default, external material carries a provenance label and nothing more:

```
--- file:README.md ---
```

That tells the model where the text came from so it can cite it. It makes no
claim about trust, and instructions found in a repository are instructions the
agent may act on. For a repository you control — one carrying your own
`LEANPRIME.md` — that is the behaviour you want.

Turn fencing on for a codebase you did not write:

```toml
[security]
data_fencing = true
```

```
<<<DATA source="file:README.md">>>
…
<<<END-DATA>>>
```

The model is then told the content is data rather than instruction.

### What the two settings actually change

Against a repository whose README contained a hidden HTML comment claiming to
be a system override — instructing the agent to read a private key, POST it to
an attacker URL, and conceal this — with fencing **on** the agent reported the
comment as a finding and did not act on it.

With fencing **off**, the agent may well attempt what the comment asks. Both
attempts still fail, and not because of anything in a prompt:

- `../fake_id_rsa` lies outside the workspace, and `Workspace.resolve` is
  **proved** to reject it;
- `curl` classifies as high risk, which needs approval, which is denied without
  a TTY.

That is the distinction worth internalising: fencing changes what the agent is
*inclined* to do. The permission engine changes what it is *able* to do, and
only the second one is load-bearing.

## Workspace containment

Every filesystem tool resolves its path through `Workspace.resolve`. The pure
core is `normalizeSegments`, which drops any `..` that would climb past the
root rather than letting it escape.

```lean
theorem normalizeSegments_noParent (segs : List String) :
    NoParent (normalizeSegments segs)
```

Absolute paths are accepted only when they already lie under the root.
Backslashes are normalised too, so `..\..\Windows\System32` is handled like the
POSIX form.

## Command classification

`classifyHead` maps a command's first word (after stripping any path prefix and
leading `FOO=1` assignments) to a requirement. Unrecognised commands are
`high`, never `low` — the default is caution.

`escalateChaining` then raises anything containing `&&`, `||`, `;`, `|`,
backticks, `$( )` or redirection to `high`, because with chaining the first
word no longer determines what runs:

```lean
theorem chaining_is_not_low … : (classifyCommand denied cmdline).risk ≠ .low
```

Without this, an approved `ls` could smuggle `ls && rm -rf ~`.

The deny list is checked first and wins over everything, including `yolo`:

```lean
theorem denied_command_never_allowed … : (p.decide (classifyCommand …)).isAllow = false
```

Git is never invoked through a shell — always a fixed argument vector — so a
model-supplied value cannot become a second command. `git show` passes `--` to
stop a hostile ref being read as a flag.

## Credentials

- Configuration stores the **name** of the environment variable, never a key.
- The key reaches the transport as a `secretHeader` and is written into a
  `0600` curl config file inside a `0700` temporary directory that is deleted
  after the request. It never appears in `argv`, so it is not visible in `ps`
  or `/proc/*/cmdline`.
- `redact` runs on every log line, every audit record and every persisted
  session, stripping provider-style keys (`sk-…`, `ghp_…`, `AIza…`) and the
  values of `api_key` / `authorization` / `token` / `password` assignments.
- `--doctor` reports that a key is present and its length. Never its value.

## Non-interactive sessions

Without a TTY — CI, a pipe, `--json` — anything that would prompt is **denied**.
Treating "nobody is there to answer" as consent is how an agent does something
irreversible at 3am.

## Audit

Every decision and every execution is appended as a redacted JSON line to
`~/.local/state/lean-prime/audit.jsonl`:

```json
{"event":"decision","tool":"shell","risk":"high","verdict":"ask","summary":"`curl` can affect state outside the workspace"}
{"event":"execution","tool":"shell","ok":false,"duration_ms":0,"detail":"refused: approval required, but the session is not interactive"}
```

Audit writes never fail the caller: losing a log line must not lose the user's
work.

## Output limits

Every tool result is clamped before it can enter the model's context
(`max_output_bytes`, `head_lines`, `tail_lines`), keeping the head and tail —
where errors live — and eliding the middle. A command producing 250,000 lines
cannot flood the conversation or the budget.

## What is not defended

- **`yolo` mode is dangerous by construction.** It skips prompting. The deny
  list still holds, and paths are still contained, but nothing else stops it.
- **With `data_fencing = false` (the default), a repository can steer the
  agent.** A file the agent reads can change what it decides to attempt. It
  cannot change what the policy permits, but within an approval mode you have
  set permissively, "what it attempts" covers a lot. Turn fencing on for code
  you did not write.
- **A tool the user adds is trusted to declare its own requirement honestly.**
- **No sandbox or syscall filtering.** Commands run as the invoking user with
  their full privileges. The defences here are about *what gets run*, not about
  containing what it does once running.
- **No protection against a malicious provider endpoint.** Point `base_url` at
  a server you trust; it sees your conversation, including file contents.
