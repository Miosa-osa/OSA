# Development Environment Setup

Audience: contributors setting up OSA for local development and testing.

## Required Toolchain

### Elixir and Erlang/OTP

OSA builds on **Elixir 1.17.3 / OTP 26.2.5**, and only that. Not "1.17 or newer" — the exact pair, because it is the pair `release.yml` uses to build the binaries users download. OTP 27 is **not** supported for release builds: it has Mix-release bugs and `erlexec` is pinned to a pre-OTP-27 version in `mix.exs` (see [CI/CD Pipeline](ci-cd.md)).

The versions live in **`.tool-versions` at the repository root**, which is the single source of truth. `ci.yml` and `release.yml` carry the same numbers in their `env:` blocks, and `test/toolchain_pin_test.exs` fails the suite if the file, the two workflows, and the running VM ever disagree — so you will hear about drift rather than discover it in a release.

That test exists because this went wrong: for eight releases (v1.0.76–v1.0.83) there was no `.tool-versions` in the repo, development happened on Elixir 1.19 / OTP 28, and every locally-green suite was a statement about a toolchain no user received. CI was red the entire time on a real ReDoS in the safety gate that could not be observed from OTP 28.

With `asdf` — no version arguments, because the file already has them:
```bash
asdf plugin add erlang
asdf plugin add elixir
asdf install          # reads .tool-versions
```

With `mise`, which reads `.tool-versions` natively:
```bash
mise install
```

Verify — this must match `.tool-versions` exactly:
```bash
elixir --version
# Erlang/OTP 26 [erts-14.2.5] ... Elixir 1.17.3 (compiled with Erlang/OTP 26)
```

Building Erlang from source takes a while. On Ubuntu/Debian x86_64 you can drop in a prebuilt OTP instead:
```bash
curl -fsSL -o otp.tar.gz "https://builds.hex.pm/builds/otp/ubuntu-24.04/OTP-26.2.5.tar.gz"
mkdir -p ~/.asdf/installs/erlang/26.2.5
tar -xzf otp.tar.gz --strip-components=1 -C ~/.asdf/installs/erlang/26.2.5
(cd ~/.asdf/installs/erlang/26.2.5 && ./Install -minimal "$PWD")
asdf reshim erlang
```
Swap `ubuntu-24.04` for your release; the available targets are listed at <https://builds.hex.pm/builds/otp/>.

### Go (for the tokenizer sidecar)

OSA includes a Go-based BPE tokenizer (`priv/go/tokenizer/`) used for accurate token counting. Go 1.22+ is required to build it.

```bash
# macOS
brew install go

# Linux
wget https://go.dev/dl/go1.22.linux-amd64.tar.gz
sudo tar -C /usr/local -xzf go1.22.linux-amd64.tar.gz
export PATH=$PATH:/usr/local/go/bin
```

The tokenizer is optional — OSA falls back to a word-count heuristic when the binary is absent or `OSA_GO_TOKENIZER` is not set to `true`.

### System Dependencies

**macOS:**
```bash
brew install git openssl
```

**Ubuntu/Debian:**
```bash
sudo apt-get install -y build-essential git libssl-dev libncurses-dev
```

**Alpine (Docker builder image):**
```bash
apk add --no-cache build-base git go
```

The `exqlite` dependency compiles a SQLite NIF at `mix deps.compile` time. The C toolchain (`gcc`, `make`) must be present.

### Ollama (recommended for local testing)

Ollama lets you run LLMs locally without API keys. Install and pull a model:

```bash
# macOS
brew install ollama
ollama serve &
ollama pull qwen2.5:7b   # default model in config.exs

# Linux
curl -fsSL https://ollama.com/install.sh | sh
ollama serve &
ollama pull qwen2.5:7b
```

OSA auto-detects a running Ollama instance at startup and sets it as the default provider if no cloud API keys are configured.

## Cloning and Initial Setup

```bash
git clone https://github.com/Miosa-osa/OSA.git
cd OSA

# Install Hex package manager and rebar3
mix local.hex --force
mix local.rebar --force

# Install deps + create SQLite DB + compile
mix setup
```

`mix setup` is defined in `mix.exs` as `["deps.get", "ecto.setup", "compile"]`, where `ecto.setup` runs `ecto.create` and `ecto.migrate` to create `~/.osa/osa.db`.

### Configuration Directory

On first run, OSA creates `~/.osa/` with the following structure:

```
~/.osa/
├── osa.db          # SQLite database (messages, budget, tasks, treasury)
├── .env            # API keys and overrides (optional; project .env takes priority)
├── mcp.json        # MCP server definitions
├── skills/         # User-defined SKILL.md files
├── sessions/       # JSONL conversation files
├── data/           # Vault memory store
└── metrics.json    # Runtime metrics snapshot (written every 5 minutes)
```

Run the interactive setup wizard to configure a provider and API key:

```bash
mix run --no-halt -e 'OptimalSystemAgent.CLI.setup()'
# or with the release binary:
./bin/osagent setup
```

### Building the Go Tokenizer (optional)

To enable accurate BPE token counting:

```bash
cd priv/go/tokenizer
CGO_ENABLED=0 go build -o osa-tokenizer .
cd ../../..
# Enable in environment:
export OSA_GO_TOKENIZER=true
```

## Running the Application

```bash
# Interactive CLI chat (default)
mix chat

# Run tests
mix test
mix test --cover

# Run a single test file
mix test test/signal/classifier_test.exs

# Format code
mix format

# Start HTTP server only (headless API mode)
mix run --no-halt
```

## IDE Recommendations

**VS Code:** Install the `ElixirLS` extension (identifier: `jakebecker.elixir-ls`). It provides autocomplete, go-to-definition, and inline diagnostics backed by `mix compile`.

**Emacs:** `elixir-mode` with `lsp-mode` pointing at `elixir-ls`.

**Neovim:** `nvim-lspconfig` with the `elixirls` server configured.

### Recommended VS Code settings for this project:

```json
{
  "elixirLS.projectDir": ".",
  "elixirLS.mixEnv": "dev",
  "editor.formatOnSave": true,
  "[elixir]": {
    "editor.defaultFormatter": "jakebecker.elixir-ls"
  }
}
```

## Common Setup Problems

**`exqlite` compilation fails:** Ensure `gcc` and `make` are installed. On macOS, run `xcode-select --install`.

**`goldrush` fetch fails:** The dependency is pulled from GitHub (`robertohluna/goldrush`, branch `main`). Ensure Git is installed and you have outbound network access.

**Ollama not detected at startup:** OSA performs a TCP probe to `localhost:11434` during `runtime.exs` evaluation to build the fallback chain. Start `ollama serve` before running OSA or set `OSA_DEFAULT_PROVIDER` explicitly.

**Database location:** The SQLite database defaults to `~/.osa/osa.db`. Override with `DATABASE_URL` (PostgreSQL) if you need a different backend for platform mode.
