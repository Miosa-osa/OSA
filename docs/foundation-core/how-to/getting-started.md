# Getting Started

Audience: developers and operators setting up OSA for the first time.

This guide takes you from zero to a running agent in under ten minutes.

---

## Prerequisites

| Requirement | Minimum version | Notes |
|-------------|----------------|-------|
| Elixir | 1.17 | `elixir --version` |
| Erlang/OTP | 27 | Ships with Elixir on most installers |
| Git | any recent | For cloning the repository |
| Node.js | 18 LTS | Required only for the Tauri desktop app |
| Rust / Cargo | stable | Required only for the Tauri desktop app |

Elixir 1.17 requires Erlang/OTP 26 or 27. OTP 27 is recommended. The mix.exs
constraint is `~> 1.17` so later patch releases are accepted automatically.

Node.js and Rust are optional. Skip them if you only need the CLI or HTTP API.

### Install Elixir

The recommended path is `asdf` or the official Elixir installer:

```sh
# macOS with Homebrew
brew install elixir

# asdf (cross-platform)
asdf plugin add elixir
asdf plugin add erlang
asdf install erlang 27.2
asdf install elixir 1.17.3-otp-27
asdf global erlang 27.2
asdf global elixir 1.17.3-otp-27
```

Verify:

```sh
elixir --version
# Erlang/OTP 27 [erts-15.x] ... Elixir 1.17.x (compiled with Erlang/OTP 27)
```

---

## Install

```sh
git clone https://github.com/Miosa-osa/OSA.git
cd OSA
```

### mix setup

`mix setup` is a single alias that runs three steps:

1. `mix deps.get` — fetch all Hex dependencies
2. `mix ecto.setup` — create and migrate the SQLite database (`osa.db`)
3. `mix compile` — compile the project and all dependencies

```sh
mix setup
```

Expected output ends with something like:

```
Generated optimal_system_agent app
```

If you see compilation errors, check that your Elixir and Erlang/OTP versions
match the requirements above.

---

## First Run

Start the agent:

```sh
bin/osa
```

Alternatively, using the Mix alias:

```sh
mix chat
```

On the very first launch, OSA detects that no provider is configured and opens
the interactive setup wizard automatically. The wizard asks:

1. Which LLM provider to use (Anthropic, OpenAI, Groq, Ollama, etc.)
2. The API key for that provider
3. (Optional) A default model name

The wizard writes your answers to `~/.osa/.env`. You can edit that file
directly at any time.

---

## Provider Setup

### Option A: Interactive wizard

```sh
bin/osa setup
```

or, if you are running from source:

```sh
./bin/osagent setup
```

The wizard prompts for the provider and API key, then validates the key with a
lightweight ping before saving.

### Option B: Environment variables

Set the relevant key before starting OSA. The runtime reads from the shell
environment first, then from `.env` in the project root, then from
`~/.osa/.env`.

```sh
# Anthropic
export ANTHROPIC_API_KEY=sk-ant-...

# OpenAI
export OPENAI_API_KEY=sk-...

# Groq
export GROQ_API_KEY=gsk_...

# Ollama (local, no key needed)
export OLLAMA_URL=http://localhost:11434
export OLLAMA_MODEL=qwen2.5:7b

# Override the active provider explicitly
export OSA_DEFAULT_PROVIDER=anthropic
export OSA_MODEL=claude-opus-4-5
```

Provider auto-detection order when `OSA_DEFAULT_PROVIDER` is not set:

1. `ANTHROPIC_API_KEY` present → `:anthropic`
2. `OPENAI_API_KEY` present → `:openai`
3. `GROQ_API_KEY` present → `:groq`
4. `OPENROUTER_API_KEY` present → `:openrouter`
5. Ollama reachable on `OLLAMA_URL` → `:ollama`

### Option C: .env file

Create `.env` in the project root or `~/.osa/.env`:

```
ANTHROPIC_API_KEY=sk-ant-...
OSA_DEFAULT_PROVIDER=anthropic
OSA_MODEL=claude-opus-4-5
```

Lines starting with `#` are ignored. Variables already in the shell environment
take precedence and are never overwritten by `.env`.

---

## Verify the Installation

Once OSA is running you should see the startup banner followed by the chat
prompt. Run a quick health check from a second terminal:

```sh
curl http://localhost:9089/health
```

Expected response:

```json
{
  "status": "ok",
  "version": "...",
  "provider": "anthropic",
  "model": "claude-opus-4-5",
  "uptime_seconds": 12
}
```

If the HTTP port is in use, set `OSA_HTTP_PORT` to a free port:

```sh
OSA_HTTP_PORT=9000 bin/osa
```

---

## Next Steps

- [Understanding the Core](./understanding-the-core.md) — mental model of how OSA processes messages
- [Building on Core](./building-on-core/creating-a-service.md) — add your own GenServer to the supervision tree
- [Debugging Core](./debugging/debugging-core.md) — inspect the running system
