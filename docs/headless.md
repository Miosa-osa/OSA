# `osa run`: OSA as a headless agent

`osa run` runs the OSA agent with no TUI, the way `claude -p` runs Claude Code and `codex exec` runs Codex.
It reads a task, works on it to completion with the same session engine the TUI uses, prints the result, and exits.
It never opens the TUI, never starts the setup wizard, never puts the terminal in raw mode, never asks a question on stdin, binds no port and starts no messaging channel, so it runs fine with no TTY and beside an `osa` daemon on the same machine.

```sh
osa run "fix the failing test"                       # text: prints the answer
echo "fix the failing test" | osa run                # the task on stdin
osa run --format stream-json --overdrive < task.txt  # NDJSON events, full auto
osa run --format stream-json --resume <id> < next.txt
osa run --input-format stream-json --format stream-json   # one process, many turns
```

Every launcher routes `run` here: the installed `osa` (`scripts/install.sh`), the source checkout's `bin/osa`, the release's `osagent run`, and `mix osa.run`.

## Sessions and multi-turn

A run is one turn of an OSA session; a session is one conversation.
Sessions persist to `$OSA_HOME/sessions/<id>.json` (default `~/.osa`), the same store the TUI uses, so a session started headless can be continued headless or in the TUI.
The context window, auto-compaction and resumed-session sizing are exactly the TUI's: when a conversation nears the window OSA compacts it and keeps going, so a session can continue indefinitely.

| Flag | Meaning |
|---|---|
| (none) | New session with a generated id (`headless-<ms>-<hex>`), reported in every event. |
| `--session-id <id>` | New session with this id, so a caller can assign it up front. Exit 2 if it already exists. |
| `-r, --resume <id>` | Continue that session: full history, tool state and its working directory. Exit 79 if it is not on this machine. |
| `-c, --continue` | Continue the newest session saved for the current directory. Exit 79 if there is none. |
| `--input-format stream-json` | Keep the process alive and take one user message per stdin line, emitting a full turn of events per message, until stdin closes. Needs `--format stream-json`. |

Session ids are letters, digits, `-` and `_` (up to 128), so `<id>.json` is always the file name.
A resumed session runs in the directory it was saved with (unless `--cwd` is given), and stays on the model it ran on unless `--model` names another or the provider changed.
Each run states its own permission mode: resuming a session that ran with `--overdrive` does not inherit it.

Input lines for `--input-format stream-json` use Claude Code's shape:

```json
{"type":"user","message":{"role":"user","content":"What did I ask you to remember?"}}
```

`content` may be a string or a list of `{"type":"text","text":"..."}` blocks; `{"type":"user","content":"..."}` and `{"prompt":"..."}` are accepted too.
A line that is not a user message produces `{"type":"system","subtype":"input_error",...}` and is skipped.

## Output formats

* `--format text` (default): the final answer on stdout, scrubbed of terminal control sequences. Errors go to stderr.
* `--format json`: one JSON object, the `result` event below.
* `--format stream-json`: newline-delimited JSON events, one object per line.

stdout carries nothing but the output: logs go to stderr (`--verbose` for more, `-q` for none), and the launchers give the event stream its own file descriptor so nothing the VM prints can land in it.
JSON is written with every non-ASCII character escaped, so a line is inert on a terminal and decodes to exactly the original text.

## Event schema (`--format stream-json`)

Every event is one JSON object with `type` first and `session_id` on every event.
The shape follows Claude Code's stream-json where the two overlap (`system`/`init`, `assistant` messages, the closing `result` with `result`, `is_error`, `session_id`, `total_cost_usd`, `usage`).

```json
{"type":"system","subtype":"init","session_id":"headless-1791507688355-efd495a19f59","cwd":"/workspace","history_messages":0,"mcp_servers":[{"name":"docs","status":"ready"}],"model":"deepseek-v4.1-flash:cloud","osa_version":"1.0.209","permission_mode":"default","provider":"ollama","resumed":false,"tools":["file_read","shell_execute","..."]}
{"type":"token","session_id":"...","delta":"Let me check"}
{"type":"thinking","session_id":"...","delta":"The user wants..."}
{"type":"assistant","session_id":"...","message":{"role":"assistant","content":[{"type":"text","text":"Let me check the notes."}]}}
{"type":"tool_use","session_id":"...","id":"call_7206441","input":{"command":"cat note.txt"},"name":"shell_execute"}
{"type":"tool_result","session_id":"...","content":"the launch is on friday","is_error":false,"name":"shell_execute","tool_use_id":"call_7206441","truncated":false}
{"type":"usage","session_id":"...","duration_ms":812,"usage":{"cache_creation_tokens":0,"cache_read_tokens":0,"input_tokens":32042,"output_tokens":17}}
{"type":"compaction_start","session_id":"...","tokens_before":171200,"trigger":"auto"}
{"type":"compaction_end","session_id":"...","duration_ms":9120,"messages_after":9,"messages_before":214,"success":true,"tokens_after":21480,"tokens_before":171200}
{"type":"result","subtype":"success","session_id":"...","compactions":0,"content":"note.txt says the launch is on Friday.","context":{"compact_at_tokens":891289,"percent":3.1,"used_tokens":32042,"window_tokens":1048576},"duration_ms":4210,"is_error":false,"model":"deepseek-v4.1-flash:cloud","num_turns":2,"provider":"ollama","result":"note.txt says the launch is on Friday.","session_cost_usd":0.0031,"session_usage":{"...":"cumulative"},"total_cost_usd":0.0012,"tree_cost_usd":0.0031,"usage":{"cache_creation_tokens":0,"cache_read_tokens":0,"input_tokens":64084,"output_tokens":41},"usage_complete":true}
```

| Event | Fields | When |
|---|---|---|
| `system` / `init` | `cwd`, `model`, `provider`, `permission_mode` (Claude Code's names: `default`, `acceptEdits`, `plan`, `bypassPermissions`), `tools`, `mcp_servers`, `resumed`, `history_messages`, `osa_version` | Once per process, first line. |
| `token` | `delta` | Streamed answer text. |
| `thinking` | `delta` | Streamed reasoning, when the model emits it. |
| `assistant` | `message.role`, `message.content[].text` | Each complete model message (before its tool calls, and the final answer). |
| `tool_use` | `id`, `name`, `input` (the arguments exactly as the model sent them) | Before the call is approved or run, so a denied call still appears. |
| `tool_result` | `tool_use_id`, `name`, `content`, `is_error`, `truncated` | After the call. A denial is `is_error: true` with `content` starting `Blocked:`. `content` is capped at 100,000 bytes (`truncated: true`). |
| `usage` | `usage.{input_tokens, output_tokens, cache_creation_tokens, cache_read_tokens}`, `duration_ms` | Each model round-trip that reported usage. |
| `compaction_start` | `trigger` (`auto`, `manual`, `model_switch`), `tokens_before` | Compaction began. |
| `compaction_end` | `success`, then `tokens_before`, `tokens_after`, `messages_before`, `messages_after`, `duration_ms`; or `error`, `duration_ms` | Compaction finished. |
| `result` | see below | Last event of every turn. |
| `system` / `input_error` | `error` | An unusable `--input-format stream-json` line. |

The `result` event:

| Field | Meaning |
|---|---|
| `subtype` | `success` or `error_during_execution`. |
| `is_error` | `true` when the turn failed: a provider error, or the turn ended on a provider outage (OSA's `turn_error`), even though the loop produced text. |
| `result`, `content` | The final answer (on failure, the error text). `content` is the field name of OSA's earlier headless stream, kept for its readers. |
| `error` | On failure, the reason (`... (fault: provider)` when attributed). |
| `session_id` | The session to `--resume`. |
| `model`, `provider` | What answered. |
| `num_turns` | Agent iterations in this turn. |
| `duration_ms` | Wall time of the turn. |
| `usage`, `total_cost_usd` | This turn's tokens and cost. |
| `session_usage`, `session_cost_usd`, `tree_cost_usd` | The session's running totals (`tree` includes subagents). |
| `usage_complete` | `false` when spend could not be read; the numbers are then not a measurement. |
| `context` | `used_tokens`, `window_tokens`, `percent`, `compact_at_tokens`: the TUI's context meter, after this turn. |
| `compactions` | Compactions during this turn. |

## Permissions and the approval hook

| Mode | What happens to a tool call that needs approval |
|---|---|
| default (no flag) | Nobody can answer a prompt, so it is refused (`tool_result` with `is_error: true`), unless an approval hook covers the tool, in which case the hook decides. Read-only tools and calls covered by allow rules run. |
| `--overdrive` (also `--dangerously-skip-permissions`, `--yolo`, `--permission-mode overdrive`) | No prompts at all. The approval hook, if configured, still runs. |
| `--permission-mode plan` / `auto-edit` | OSA's plan and accept-edits modes. |

OSA's hard limits apply in every mode and cannot be delegated to a hook: the dangerous-command circuit breaker, saved deny rules, writes to protected paths (`.git` internals, OSA's own settings, shell rc files) and deletes whose target cannot be resolved.

### `OSA_PRE_TOOL_HOOK`

```sh
OSA_PRE_TOOL_HOOK="/bin/sh /opt/gate/approve.sh"   # the command, run by /bin/sh
OSA_PRE_TOOL_HOOK_TIMEOUT=86400                   # seconds to wait for it (default 86400)
OSA_PRE_TOOL_HOOK_MATCHER="shell_execute|mcp__.*" # which tools (default: all)
```

Before each covered tool call, OSA runs the command with the call as Claude Code `PreToolUse` JSON on stdin:

```json
{"hook_event_name":"PreToolUse","session_id":"headless-...","transcript_path":"","cwd":"/workspace","permission_mode":"default","tool_name":"shell_execute","tool_input":{"command":"git push origin main"},"tool_use_id":"call_42"}
```

and obeys its answer:

| Hook answer | Decision |
|---|---|
| exit 0, empty or non-JSON stdout | allow |
| exit 0, `{"hookSpecificOutput":{"permissionDecision":"allow"}}` | allow |
| exit 0, `{"hookSpecificOutput":{"permissionDecision":"deny","permissionDecisionReason":"..."}}` | deny with that reason |
| exit 0, `{"continue":false,"stopReason":"..."}` or `{"decision":"block","reason":"..."}` | deny with that reason |
| exit 0, `"permissionDecision":"ask"` | deny (nobody can answer in a headless run) |
| exit 0, `hookSpecificOutput.updatedInput` | run with the rewritten arguments |
| exit 2 | deny; the reason is stdout (its JSON reason fields when it is JSON), else stderr |
| any other exit code, a crash, or no answer within the timeout | deny (fails closed) |

This is the Claude Code `PreToolUse` contract, so a gate written for Claude Code's `--settings` hooks works unchanged.
`OSA_SETTINGS` / `--settings` hooks in Claude Code's `hooks.PreToolUse` shape also run, with Claude Code's semantics (a failing settings hook does not block), but only `OSA_PRE_TOOL_HOOK` can answer an approval OSA would otherwise refuse.
A denial becomes the tool's result (`Blocked: <reason>`), which the model reads and works around, like any refused call.
With an approval hook, OSA's tool backstop (20 minutes) is extended by the hook's timeout, so a person can take their time.

## Model and provider

`--model` picks the model on the configured provider; `--provider` overrides the provider.
Provider selection is unchanged: `OSA_DEFAULT_PROVIDER`, `OSA_MODEL`, `<PROVIDER>_MODEL`, vendor keys, `OPENAI_BASE_URL`/`OPENAI_API_KEY`, the MIOSA AI Gateway (`MIOSA_AI_GATEWAY_URL` + `MIOSA_AI_GATEWAY_KEY`), native Ollama and Ollama Cloud (`OLLAMA_API_KEY`, `OLLAMA_URL`), then `~/.osa/.env`, then the platform env file (`OSA_PLATFORM_ENV_FILE`, default `/opt/osagent/env.sh`) as the lowest-precedence defaults.

## Onboarding

Onboarding (the setup wizard and the TUI's first-run provider picker) is only for a local user with nothing configured.
It never appears, in the TUI either, when `OSA_SKIP_ONBOARDING` is `1`/`true`/`yes`/`on`, when `osa --no-onboarding` is used, when any provider is configured in the environment, or when the platform env file or `~/.osa/.env` configures one.
`osa run` never runs onboarding at all.

## Exit codes

| Code | Meaning |
|---|---|
| 0 | Every turn succeeded. |
| 1 | A turn failed (`result.is_error: true`). With `--input-format stream-json`, any turn. |
| 2 | Usage error: unknown flag, empty prompt, bad session id, `--session-id` already taken, bad `--mcp-config`. Nothing was started. |
| 3 | OSA could not start. |
| 79 | `--resume`/`--continue` found no session (stderr starts `HARNESS_SESSION_MISSING:`). |

## Parity with Claude Code and Codex

| Capability | Claude Code (`claude -p`) | Codex (`codex exec`) | OSA (`osa run`) |
|---|---|---|---|
| Non-interactive run | `-p, --print` | `exec` | `run` (`-p` accepted and ignored) |
| Prompt | argument or stdin | argument or stdin | argument or stdin |
| Output format | `--output-format text\|json\|stream-json` | `--json` | `--format`/`--output-format text\|json\|stream-json` |
| Streaming input | `--input-format stream-json` | none | `--input-format stream-json` |
| Model | `--model` | `-m, --model` | `-m, --model` (+ `--provider`) |
| Resume by id | `-r, --resume <id>` | `exec resume <id>` | `-r, --resume <id>` |
| Continue latest | `-c, --continue` | `exec resume --last` | `-c, --continue` |
| Assign session id | `--session-id <uuid>` | none | `--session-id <id>` |
| No approval prompts | `--dangerously-skip-permissions` | `--dangerously-bypass-approvals-and-sandbox` | `--overdrive` (also `--dangerously-skip-permissions`, `--yolo`) |
| Permission mode | `--permission-mode` | `-s, --sandbox` | `--permission-mode ask\|auto-edit\|plan\|overdrive` (Claude's names accepted) |
| Approval hook | `PreToolUse` hook in `--settings` | `-c hooks.PreToolUse=[...]` | `OSA_PRE_TOOL_HOOK` (same protocol), or `PreToolUse` in `--settings` |
| Append to system prompt | `--append-system-prompt[-file]` | none | `--append-system-prompt[-file]` |
| Replace system prompt | `--system-prompt[-file]` | none | `--system-prompt[-file]` |
| Allowed tools / rules | `--allowedTools` | none | `--allowed-tools` / `--allowedTools` (rules like `shell_execute(git:*)`; Claude names such as `Bash` work) |
| Disallowed tools | `--disallowedTools` | none | `--disallowed-tools` / `--disallowedTools` |
| Available tools | `--tools` | none | `--tools` |
| Max turns | `--max-turns` | none | `--max-turns` (model round-trips per turn) |
| Spend cap | `--max-budget-usd` | none | `--max-budget` / `--max-budget-usd` |
| Working directory | process cwd, `--add-dir` | `-C, --cd`, `--add-dir` | `-C, --cd, --cwd`, `--add-dir` |
| MCP servers | `--mcp-config`, `--strict-mcp-config` | config | `--mcp-config <file\|json>` (repeatable), `--strict-mcp-config` |
| Settings file | `--settings` | `-c key=value` | `--settings` (`OSA_SETTINGS`) |
| Effort | `--effort` | `-c model_reasoning_effort` | `--effort fast\|medium\|high\|xhigh\|ultra` |
| Last message to a file | none | `-o, --output-last-message` | `-o, --output-last-message` |
| Verbose / quiet | `--verbose` | none | `--verbose` / `-q, --quiet` (stderr only) |
| Exit codes | 0 / 1 | 0 / 1 | 0, 1, 2, 3, 79 (above) |

Not supported yet: `--fork-session`, `--fallback-model`, `--json-schema`/`--output-schema`, `--no-session-persistence`, and Codex's `-i, --image`.
