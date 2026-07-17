# Build System

Audience: contributors and operators who need to compile, release, or package OSA.

## Mix Project Overview

OSA is a standard Mix project defined in `mix.exs`. The application name is `:optimal_system_agent` and the current version is read from the `VERSION` file at compile time:

```elixir
@version "VERSION" |> File.read!() |> String.trim()
```

The Mix environment determines which config file is merged on top of `config/config.exs`:

| `MIX_ENV` | Config overlay | Logger level |
|-----------|---------------|-------------|
| `dev` (default) | `config/dev.exs` | `:debug` |
| `test` | `config/test.exs` | (test defaults) |
| `prod` | `config/prod.exs` | `:info` |

Runtime config (`config/runtime.exs`) is evaluated at startup in all environments. It reads environment variables and `.env` files, then writes final config values.

## Mix Aliases

| Alias | Expands to | Purpose |
|-------|-----------|---------|
| `mix setup` | `deps.get`, `ecto.setup`, `compile` | First-time dev setup |
| `mix chat` | `run --no-halt -e 'OptimalSystemAgent.Channels.CLI.start()'` | Interactive CLI |
| `mix ecto.setup` | `ecto.create`, `ecto.migrate` | Create and migrate SQLite DB |
| `mix ecto.reset` | `ecto.drop`, `ecto.setup` | Drop and recreate DB |

## Dependencies

Dependencies are declared in `mix.exs` `deps/0`. All resolved versions are pinned in `mix.lock`.

| Dependency | Version | Purpose |
|------------|---------|---------|
| `goldrush` | GitHub `main` | Event routing — compiled Erlang bytecode dispatch. Forked at `robertohluna/goldrush` for BEAM-speed event fan-out in `OptimalSystemAgent.Events`. |
| `req` | `~> 0.5` | HTTP client for all LLM provider API calls. Used by every adapter in `lib/optimal_system_agent/providers/`. |
| `jason` | `~> 1.4` | JSON encoding/decoding. Used for provider request/response serialization and JSONL session files. |
| `ex_json_schema` | `~> 0.11` | JSON Schema validation. Validates tool call arguments against each skill's `parameters/0` schema before `execute/1` is called. |
| `phoenix_pubsub` | `~> 2.1` | Standalone PubSub for internal event fan-out. OSA does not use the Phoenix framework — this is the PubSub library in isolation. |
| `yaml_elixir` | `~> 2.9` | YAML parsing for SKILL.md frontmatter and YAML-formatted config files. |
| `bandit` | `~> 1.6` | HTTP server. Powers the SDK API on port 9089. Chosen over Cowboy for its pure-Elixir implementation and lower resource usage. |
| `plug` | `~> 1.16` | Request routing and middleware. Used with Bandit for the HTTP channel. |
| `ecto_sql` | `~> 3.12` | SQL query builder and migration runner. |
| `ecto_sqlite3` | `~> 0.17` | Ecto adapter for SQLite3. Provides the `Store.Repo` that persists messages, budget records, tasks, and treasury ledger. |
| `postgrex` | `~> 0.19` | PostgreSQL driver for the optional Platform.Repo (multi-tenant mode enabled via `DATABASE_URL`). |
| `bcrypt_elixir` | `~> 3.0` | Password hashing. Production-only (`only: :prod, optional: true`). Required only when the platform multi-tenant auth module is active. |
| `amqp` | `~> 4.1` | RabbitMQ publisher for events consumed by Go workers. Optional — OSA works without it. |
| `telemetry` | `~> 1.2` | Erlang telemetry events. Subscribed to by `OptimalSystemAgent.Telemetry.Metrics`. |
| `telemetry_metrics` | `~> 1.0` | Metric definitions on top of `:telemetry`. |

## SQLite Compilation

`ecto_sqlite3` depends on `exqlite`, which compiles a SQLite C extension as a NIF. This requires a C compiler at build time. The `mix deps.compile` step handles this automatically when `gcc` and `make` are present.

In Docker builds, `apk add build-base` (Alpine) or `apt-get install build-essential` (Debian) satisfies this requirement.

## Building the Go Tokenizer

The Go tokenizer is a self-contained binary in `priv/go/tokenizer/`. It must be built separately before `mix release`:

```bash
cd priv/go/tokenizer
CGO_ENABLED=0 go build -o osa-tokenizer .
```

`CGO_ENABLED=0` produces a statically linked binary that runs on the target platform without a Go runtime installed. The release step (`mix release osagent`) copies the binary into the release tree via the custom `copy_go_tokenizer/1` step defined in `mix.exs`.

If the binary does not exist at release time, `copy_go_tokenizer/1` silently skips it. OSA will fall back to word-count heuristic token counting.

## Building a Release

```bash
# 1. Build the Go tokenizer
cd priv/go/tokenizer && CGO_ENABLED=0 go build -o osa-tokenizer . && cd ../../..

# 2. Fetch production deps
MIX_ENV=prod mix deps.get --only prod
MIX_ENV=prod mix deps.compile

# 3. Compile application
MIX_ENV=prod mix compile

# 4. Assemble release
MIX_ENV=prod mix release osagent
```

The release is assembled at `_build/prod/rel/osagent/`. The release name is `osagent` (defined in `releases/0` in `mix.exs`).

### What the Release Contains

`mix release osagent` runs three steps in order:

1. `:assemble` — standard Mix release assembly (ERTS, all compiled .beam files, config)
2. `copy_go_tokenizer/1` — copies `priv/go/tokenizer/osa-tokenizer` into the release `priv/go/tokenizer/` directory
3. `copy_osagent_wrapper/1` — renames the generated boot script from `bin/osagent` to `bin/osagent_release` and installs a shell wrapper script at `bin/osagent`

The wrapper script (`bin/osagent`) dispatches subcommands via OTP `eval`:

```
osagent          → CLI.chat()
osagent setup    → CLI.setup()
osagent version  → CLI.version()
osagent serve    → CLI.serve()
osagent doctor   → CLI.doctor()
```

### Packaging for Distribution

To create a tarball for distribution (matches the CI release job):

```bash
cd _build/prod/rel/osagent
tar -czf ../../../../osa-linux-x64.tar.gz .
```

## Docker Build

The `Dockerfile` uses a two-stage build:

**Stage 1: `builder` (elixir:1.17-alpine)**

- Installs `build-base git go`
- Fetches and compiles production deps
- Builds the Go tokenizer
- Compiles the Elixir application
- Assembles the OTP release

**Stage 2: `runner` (alpine:3.19)**

- Installs `libstdc++ openssl ncurses-libs` (ERTS runtime requirements)
- Creates a non-root `osa` user
- Copies the release from the builder stage
- Exposes port 9089
- Sets `CMD ["bin/osagent", "serve"]`

Build and run:

```bash
docker build -t osa:local .
docker run -p 9089:9089 \
  -e ANTHROPIC_API_KEY=sk-ant-... \
  -v osa_data:/root/.osa \
  osa:local
```

With Docker Compose (includes Ollama):

```bash
cp .env.example .env   # Add API keys to .env
docker compose up
```

The `docker-compose.yml` mounts `osa_data` to `/root/.osa` inside the container and connects the `osa` service to `ollama` via the internal network at `http://ollama:11434`.

## ERTS Inclusion

The release includes ERTS (Erlang Runtime System). The target machine does not need Elixir or Erlang installed. The only runtime requirements are:

- `libstdc++` (for NIF shared libraries)
- `openssl` (for TLS)
- `ncurses-libs` (for the terminal CLI)

These are installed in the Docker runner stage and are available by default on most Linux distributions.
