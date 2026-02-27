# Getting Started

> Install, configure, and start using OSA

## Guides

- [Configuration](configuration.md) — Environment variables, feature flags, and directory structure
- [Troubleshooting](troubleshooting.md) — Common issues and solutions

## Quick Start

```bash
# Clone and build
git clone https://github.com/your-org/optimal-system-agent.git
cd optimal-system-agent
mix deps.get && mix compile

# Configure (at minimum, one provider key)
echo 'ANTHROPIC_API_KEY=sk-ant-...' >> ~/.osa/.env

# Run
mix run --no-halt
# or
./osagent
```

## Prerequisites

- **Elixir** >= 1.16
- **Erlang/OTP** >= 26
- **SQLite3** (for message persistence)
- At least one LLM provider key OR Ollama installed locally
