# Serialization

Audience: developers working with OSA's data formats, adding new storage
backends, or integrating external systems that consume OSA's output.

OSA uses four serialization formats across different subsystems. Each format
was chosen for a specific trade-off between structure, readability,
appendability, and tooling support.

---

## JSON (Jason)

**Library:** [`jason`](https://hex.pm/packages/jason)
**Use:** HTTP API communication, tool arguments, database JSON fields.

Jason is OSA's standard JSON library. It is used for all API request/response
bodies, all `:map` type Ecto field serialisation, and all inter-process
message payloads that cross a network boundary.

### Encoding

```elixir
# Encode a map to JSON string
Jason.encode!(%{role: "user", content: "Hello"})
# => ~s({"content":"Hello","role":"user"})

# Encode with options
Jason.encode!(%{data: <<1, 2, 3>>}, escape: :unicode_safe)
```

### Decoding

```elixir
# Decode JSON string to map (string keys)
{:ok, map} = Jason.decode(~s({"role":"user","content":"Hello"}))
# => {:ok, %{"role" => "user", "content" => "Hello"}}

# Decode with atom keys (only for trusted internal data)
{:ok, map} = Jason.decode(json, keys: :atoms)
```

### HTTP API Convention

All HTTP API endpoints use `Content-Type: application/json`. Requests and
responses use string-keyed maps. The HTTP channel's Plug pipeline decodes
inbound JSON via `Plug.Parsers` and encodes outbound responses via `Jason.encode!`.

```elixir
# In route handler:
data = conn.body_params   # Already decoded by Plug.Parsers
conn |> json(%{status: "ok", reply: response})  # Encoded by Jason
```

### Tool Arguments

Tool arguments from the LLM arrive as JSON strings and are decoded before
being passed to `execute/1`:

```elixir
# Provider returns:
%{id: "call_1", name: "file_read", arguments: %{"path" => "/tmp/report.txt"}}
# arguments is already a decoded map
```

---

## YAML (yaml_elixir)

**Library:** [`yaml_elixir`](https://hex.pm/packages/yaml_elixir)
**Use:** Skill definitions (`SKILL.md` frontmatter), custom command definitions,
and vault entries — all of which use a YAML frontmatter block.

YAML in OSA is used **only** for the frontmatter of human-authored markdown files.
It is *not* used for OSA's runtime configuration: the primary config file is
`~/.osa/config.json` (JSON, see below) and MCP servers are configured in
`~/.osa/mcp.json` (also JSON). There is no `config.yaml`.

### Parsing Frontmatter

SKILL.md files use YAML frontmatter delimited by `---`:

```elixir
content = File.read!(skill_file)

case String.split(content, "---", parts: 3) do
  ["", frontmatter, body] ->
    {:ok, meta} = YamlElixir.read_from_string(frontmatter)
    # meta is a string-keyed map
    name        = meta["name"]
    description = meta["description"]
    triggers    = meta["triggers"] || []

  _ ->
    # No frontmatter; treat entire content as skill body
    nil
end
```

### SKILL.md Frontmatter Example

```yaml
---
name: code-review
description: Structured code review with security checklist
triggers:
  - review
  - "code review"
priority: 3
tools:
  - file_read
  - file_grep
---
```

### Runtime Configuration Is JSON, Not YAML

OSA's runtime configuration is **JSON**, read from `~/.osa/config.json` (see
`OptimalSystemAgent.Machines`, which resolves `Path.join(config_dir(), "config.json")`).
MCP servers are configured in `~/.osa/mcp.json`, also JSON. There is no
`config.yaml` / `osa_config.yaml` overlay — YAML appears only in the frontmatter
of skill, command, and vault markdown files.

```elixir
# Runtime config is loaded as JSON:
{:ok, raw}  = File.read(Path.join(config_dir(), "config.json"))
{:ok, config} = Jason.decode(raw)
providers = get_in(config, ["providers", "fallback_chain"])
```

---

## JSONL (JSON Lines)

**Use:** Episodic memory storage, learning capture, session event logs.
No library required — JSONL is newline-delimited JSON, one object per line.

JSONL is chosen for append-only storage because:
- Files can be appended atomically with a single write (no file rewrite needed).
- Each line is independently parseable (corrupt lines do not invalidate the file).
- Simple tooling — `grep`, `jq`, `tail -n` work directly on the files.
- Memory-efficient streaming — files can be read line by line without loading
  the entire file into memory.

### Storage Locations

```
~/.osa/
├── sessions/
│   ├── <session_id>.jsonl     # Conversation history per session
│   └── ...
├── memory.jsonl               # Long-term memories
├── learning/
│   ├── interactions.jsonl     # Observed interactions for learning engine
│   ├── corrections.jsonl      # User corrections
│   └── errors.jsonl           # Tool error records
└── episodic/
    └── events.jsonl           # Episodic memory events
```

### Entry Format

Each line is a standalone JSON object. Fields vary by file type but always
include a timestamp:

```json
{"role":"user","content":"Deploy to staging","session_id":"ses_abc","timestamp":"2026-03-14T10:00:00Z"}
{"role":"assistant","content":"Deploying to staging now...","session_id":"ses_abc","timestamp":"2026-03-14T10:00:01Z","token_count":42}
{"role":"tool","content":"Deploy complete: v1.2.3","tool_call_id":"call_1","timestamp":"2026-03-14T10:00:05Z"}
```

### Writing

```elixir
# Append a single entry to a JSONL file
entry = Jason.encode!(map) <> "\n"
File.write!(path, entry, [:append])
```

### Reading and Parsing

```elixir
# Stream all entries from a JSONL file
entries =
  path
  |> File.stream!()
  |> Enum.flat_map(fn line ->
    case Jason.decode(String.trim(line)) do
      {:ok, entry} -> [entry]
      {:error, _}  -> []       # Skip malformed lines
    end
  end)
```

### Searching

Full-text search over session JSONL files uses SQLite FTS5 via the
`sessions_fts` virtual table. The memory store maintains an in-memory
ETS index for keyword-based recall without file I/O on the hot path.

---

## Markdown with YAML Frontmatter

**Use:** Vault entries, custom commands, skill definitions.

The vault (`~/.osa/vault/`) stores structured knowledge as markdown files.
Each file has a YAML frontmatter section followed by markdown content.

### Vault Entry Format

```markdown
---
title: Production Database Connection String
category: secrets
tags:
  - database
  - production
created_at: 2026-03-14T10:00:00Z
---

The production PostgreSQL connection string is stored in the AWS Parameter Store
at the path `/myapp/production/db_url`.

Retrieve with:
```bash
aws ssm get-parameter --name /myapp/production/db_url --with-decryption
```
```

### Custom Command Format

```markdown
---
name: deploy
description: Trigger a deployment to the specified environment
aliases:
  - ship
arguments:
  - name: environment
    description: Target environment (staging or production)
    required: true
---

Deploy the current main branch to {{environment}}.

Check the CI status first:
- Run `gh run list --branch main --limit 5` to see recent pipeline runs.
- Only proceed if the latest run is green.

Then trigger the deployment pipeline and monitor for 5 minutes.
```

### Parsing

```elixir
content = File.read!(path)

case String.split(content, "---", parts: 3) do
  ["", frontmatter, body] ->
    {:ok, meta} = YamlElixir.read_from_string(frontmatter)
    {:ok, %{meta: meta, body: String.trim(body)}}

  _ ->
    {:ok, %{meta: %{}, body: content}}
end
```

---

## Format Selection Guide

| Scenario | Format | Reason |
|---|---|---|
| HTTP API request/response | JSON | Standard for REST/HTTP |
| LLM tool arguments | JSON | LLM output is always JSON |
| Database `:map` fields | JSON (via Ecto) | Automatic via ecto_sqlite3 |
| Skill/command definitions | Markdown + YAML frontmatter | Human-authored, readable |
| Runtime configuration (`~/.osa/config.json`, `mcp.json`) | JSON | Machine-read config, `Jason` everywhere |
| Session conversation history | JSONL | Append-only, streamable |
| Long-term memory | JSONL | Append-only, grep-friendly |
| Learning capture | JSONL | Append-only, streaming analysis |
| Vault knowledge entries | Markdown + YAML | Rich text with structured metadata |
