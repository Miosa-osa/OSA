# File Tools

File tools provide read, write, edit, search, and exploration capabilities for the local filesystem. All file tools enforce path allowlists and sensitive-path blocklists before performing any operation.

---

## Security Model

All file tools share the same security constants:

### Allowed read paths (default)
```
~, /tmp
```
Configurable via `:allowed_read_paths` in application config.

### Allowed write paths (default)
```
~, /tmp
```
Configurable via `:allowed_write_paths` in application config.

### Blocked sensitive paths (read)
```
.ssh/id_rsa, .ssh/id_ed25519, .ssh/id_ecdsa, .ssh/id_dsa,
.gnupg/, .aws/credentials, .env, /etc/shadow, /etc/sudoers,
/etc/master.passwd, .netrc, .npmrc, .pypirc
```

### Blocked write paths
```
.ssh/, .gnupg/, /etc/, /boot/, /usr/, /bin/, /sbin/, /var/, .aws/, .env
```

Dotfiles outside `~/.osa/` are also blocked from writes. This prevents agents from accidentally modifying shell configs, git config, or other dotfiles while allowing writes to OSA's own configuration directory.

---

## `file_read`

Read a file from the filesystem.

**Module:** `OptimalSystemAgent.Tools.Builtins.FileRead`
**Safety:** `:read_only`

### Parameters

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `path` | string | yes | Path to the file |
| `offset` | integer | no | 1-based line number to start reading from |
| `limit` | integer | no | Maximum lines to read |

### Behavior

- Expands `~` and resolves the path before checking allowlists
- With `offset`/`limit`: returns numbered lines (`  123| line content`) using `File.stream!` for memory efficiency
- Without range parameters: returns full file content
- **Image support**: `.png`, `.jpg`, `.jpeg`, `.gif`, `.webp`, `.bmp`, `.tiff` files are returned as `{:image, %{media_type, data, path}}` tuples with base64-encoded content for vision-capable models. Maximum image size: 10MB.

### Example

```json
{"path": "lib/my_module.ex", "offset": 50, "limit": 30}
```

---

## `file_write`

Write content to a file. Creates parent directories automatically.

**Module:** `OptimalSystemAgent.Tools.Builtins.FileWrite`
**Safety:** `:write_safe`

### Parameters

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `path` | string | yes | Path to write to |
| `content` | string | yes | Content to write |

### Path resolution

Relative paths are automatically rooted at `~/.osa/workspace/`:
- `"my-app/server.js"` → `~/.osa/workspace/my-app/server.js`
- `"~/projects/app.ex"` → `~/projects/app.ex` (absolute honored)
- `"/tmp/output.txt"` → `/tmp/output.txt` (absolute honored)

### Example

```json
{"path": "my-app/index.js", "content": "console.log('hello');"}
```

---

## `file_edit`

Make a surgical string replacement in a file.

**Module:** `OptimalSystemAgent.Tools.Builtins.FileEdit`
**Safety:** `:write_safe`

### Parameters

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `path` | string | yes | Absolute path to the file |
| `old_string` | string | yes | Exact text to find (must be unique unless `replace_all` is true) |
| `new_string` | string | yes | Replacement text |
| `replace_all` | boolean | no | Replace all occurrences (default: false) |

### Behavior

- `old_string` must occur exactly once unless `replace_all: true`
- Returns an error listing the occurrence count when uniqueness fails — add more surrounding context to make the match unique
- Returns a unified diff showing the change with 2 lines of context on success

### Error cases

| Error | Cause |
|-------|-------|
| `old_string not found` | Text not in file |
| `old_string found N times` | Ambiguous match; add context |
| `old_string and new_string are identical` | No-op detected |
| `old_string cannot be empty` | Empty pattern rejected |

### Hashline Drift-Guard (Content-Hash Edit Verification)

**Module:** `OptimalSystemAgent.Tools.Builtins.FileEdit.DriftGuard`

`Tools.FileState` already rejects an edit when the target file's on-disk
`{mtime, size}` differs from what was recorded at the model's last
`file_read` — the primary read-before-edit / stale-write guard. `DriftGuard`
adds a second, independent **content-hash** guard on top of it, scoped to
`file_edit`, closing the one blind spot an `{mtime, size}` identity check
can't see: two different files (or two different revisions of the same file)
that land on the exact same size in the exact same wall-clock second — mtime
is second-resolution, so a hook, a linter-on-save, or a concurrent sub-agent
rewrite that reproduces both by coincidence sails straight through the
mtime/size check.

After every successful `file_edit` write, `record/5` stores the resulting
file's `{mtime, size}` together with a normalized content fingerprint, keyed
by `{session, canonical_path}`. Before the *next* edit to that path in the
same session, `verify/5`:

- finds no baseline → **defer** (bootstrap, nothing to compare)
- finds a baseline whose `{mtime, size}` differs from current → **defer**
  (the file's identity has genuinely moved on — a fresh `file_read` + retry,
  or `FileState` already gated the transition)
- finds a baseline whose `{mtime, size}` matches current → cross-check the
  content fingerprint; if it matches too, allow; if it doesn't, **reject**
  with a re-read-and-retry instruction — the exact aliasing collision
  `FileState`'s coarser check can't see

The fingerprint normalizes CRLF/CR to LF and strips trailing whitespace per
line, so a pure formatting pass never spuriously trips the guard. DriftGuard
can only ever be *stricter* than `FileState` within that narrow collision
window — it never blocks an edit that `FileState` alone would allow through a
real, distinguishable state transition. Storage is a self-owned,
unsupervised ETS table (`:osa_file_edit_drift_guard`); the `nil`/`"test"`
sentinel sessions are exempt, matching `FileState`'s own scope.

---

## `multi_file_edit`

Apply multiple string replacements across one or more files atomically.

**Module:** `OptimalSystemAgent.Tools.Builtins.MultiFileEdit`
**Safety:** `:write_safe`

### Parameters

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `edits` | array | yes | List of edit objects (max 20) |

Each edit object:
```json
{
  "path": "/absolute/path/to/file.ex",
  "old_string": "exact text to replace",
  "new_string": "replacement text"
}
```

### Behavior

Two-phase execution:
1. **Validate all edits** — check paths, uniqueness, access. Collect ALL failures before rejecting.
2. **Apply all edits** — only runs if zero validation failures.

If any edit fails validation, none are applied and a detailed error lists every failure. This prevents partial updates that leave code in an inconsistent state.

Maximum 20 edits per call.

---

## `file_glob`

Find files matching a glob pattern.

**Module:** `OptimalSystemAgent.Tools.Builtins.FileGlob`
**Safety:** `:read_only`

### Parameters

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `pattern` | string | yes | Glob pattern (e.g., `**/*.ex`, `lib/**/*.ex`) |
| `path` | string | no | Root directory (default: current directory) |

Returns a newline-separated list of matching file paths, sorted. Respects the read path allowlist.

---

## `file_grep`

Search file contents with a regex pattern.

**Module:** `OptimalSystemAgent.Tools.Builtins.FileGrep`
**Safety:** `:read_only`

### Parameters

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `pattern` | string | yes | Regex pattern to search for |
| `path` | string | yes | File or directory to search |
| `max_results` | integer | no | Maximum matching lines to return (default: 50) |

Returns `file:line_number: matching_line` format. Respects the read path allowlist.

---

## `dir_list`

List the contents of a directory.

**Module:** `OptimalSystemAgent.Tools.Builtins.DirList`
**Safety:** `:read_only`

### Parameters

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `path` | string | no | Directory to list (default: `~/.osa/workspace`) |

Returns entries as tab-separated `type\tsize\tname` lines where type is `file` or `dir`.

---

## `code_symbols`

Extract function, module, and class definitions from code files without reading full content.

**Module:** `OptimalSystemAgent.Tools.Builtins.CodeSymbols`
**Safety:** `:read_only`

### Parameters

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `path` | string | no | File or directory to scan (default: `~/.osa/workspace`) |
| `glob` | string | no | File filter (auto-detected from project type if omitted) |
| `include_private` | boolean | no | Include private symbols (default: false) |

### Supported languages

| Language | File extensions | Extracted symbols |
|----------|----------------|------------------|
| Elixir | `.ex`, `.exs` | `module`, `def`, `defp`, `defmacro`, `behaviour` |
| Go | `.go` | `func`, `func (priv)`, `struct`, `interface` |
| TypeScript/JavaScript | `.ts`, `.tsx`, `.js`, `.jsx` | `export`, `export const`, `function`, `class` |
| Python | `.py` | `class`, `def`, `method` |
| Rust | `.rs` | `pub fn`, `fn`, `struct`, `trait`, `enum` |

### Output format

```
347 symbols across 28 file(s):

lib/my_app/module.ex
  12: [module] MyApp.Module
  18: [def] start_link
  45: [def] handle_call
  89: [defp] do_work
```

Output is capped at 8KB. Skips `_build`, `deps`, `node_modules`, `.git`, and other build artifacts.

### Auto glob detection

The tool detects project type from config files in the root:
- `mix.exs` → `**/*.{ex,exs}`
- `go.mod` → `**/*.go`
- `Cargo.toml` → `**/*.rs`
- `pyproject.toml` or `requirements.txt` → `**/*.py`
- Otherwise → all supported extensions

---

## `codebase_explore`

Composite exploration tool that combines directory listing, config reading, file search, and MCTS indexing into a single structured report.

**Module:** `OptimalSystemAgent.Tools.Builtins.CodebaseExplore`
**Safety:** `:read_only`

### Parameters

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `goal` | string | yes | What you're trying to understand |
| `path` | string | no | Root directory (default: current directory) |
| `depth` | string | no | `quick`, `standard`, or `deep` (default: `standard`) |

### Depth levels

| Depth | Output |
|-------|--------|
| `quick` | Project type detection + directory structure |
| `standard` | + config file reading + goal-relevant file search + top 3 file previews |
| `deep` | + MCTS analysis (100 iterations) + grep for keywords + pattern detection |

All internal calls use `Tools.execute_direct/2` (lock-free) to avoid GenServer deadlock. Output is capped at 12KB.

### Pattern detection

At `deep` depth, the tool reports structural patterns found in the root:
- Test directory present
- Docker setup present
- GitHub Actions configured
- Environment variables configured
- Makefile automation
- Priv directory (assets/migrations/templates)

### Example

```json
{"goal": "authentication and session management", "depth": "deep"}
```

---

## See Also

- [Tools Overview](./overview.md)
- [Execution Tools](./execution-tools.md)
- [Intelligence Tools](./intelligence-tools.md)
