# Deployment Guide

Audience: operators deploying OSA in a persistent or production environment.

## Deployment Options

| Method | Best for | ERTS included | Elixir required on host |
|--------|----------|--------------|------------------------|
| Homebrew (macOS) | Personal use, macOS | Yes | No |
| Pre-built tarball | Linux servers | Yes | No |
| Docker | Containerized, Ollama bundled | Yes (in image) | No |
| Docker Compose | Full stack with Ollama | Yes (in image) | No |
| From source | Development, custom builds | No | Yes |

## Homebrew (macOS)

```bash
brew tap Miosa-osa/tap
brew install osa

osa setup         # configure provider and API key
osa               # start interactive chat
```

Homebrew installs the release tarball into `libexec/` and exposes `osa`, `osagent`, and `miosa` command entrypoints.

## Pre-built Tarball (Linux / macOS)

Download the tarball for your platform from the GitHub releases page:

```
https://github.com/Miosa-osa/OSA/releases/latest
```

Available targets: `linux-x64`, `macos-arm64`, `windows-x64`.

```bash
VERSION=1.0.002
PLATFORM=linux-x64   # or macos-arm64

curl -fsSL "https://github.com/Miosa-osa/OSA/releases/download/v${VERSION}/osa-${PLATFORM}.tar.gz" \
  | tar -xz -C /opt/osagent

# Add to PATH
export PATH="/opt/osagent/bin:$PATH"

osagent setup
osagent serve     # headless HTTP API mode
```

Runtime dependencies on Linux (install if not present):

```bash
# Debian/Ubuntu
apt-get install -y libstdc++6 openssl libncurses6

# Alpine
apk add libstdc++ openssl ncurses-libs
```

## Docker

Build the image from source:

```bash
docker build -t osa:latest .
```

Run in serve (headless API) mode:

```bash
docker run -d \
  --name osa \
  -p 9089:9089 \
  -e ANTHROPIC_API_KEY=sk-ant-... \
  -e OSA_DEFAULT_PROVIDER=anthropic \
  -v osa_data:/root/.osa \
  osa:latest
```

The container exposes port 9089. The `/root/.osa` directory holds the SQLite database, session files, vault memory, and the `.env` config. Mount it as a named volume to persist data across container restarts.

Health check: `GET http://localhost:9089/health` returns `{"status":"ok"}`. The Dockerfile configures this check with a 30-second interval, 5-second timeout, 10-second start period, and 3 retries.

## Docker Compose (with Ollama)

The `docker-compose.yml` in the repository root starts both OSA and Ollama:

```bash
# Copy and populate the environment file
cp .env.example .env    # if available, else create .env manually

docker compose up -d
```

The compose file:
- Configures `OLLAMA_URL=http://ollama:11434` and `OSA_DEFAULT_PROVIDER=ollama` for the `osa` service.
- Mounts `osa_data` volume to `/root/.osa` in the `osa` container and `ollama_data` volume to `/root/.ollama` in the `ollama` container.
- Sets `restart: unless-stopped` on both services.
- Waits for Ollama's health check to pass before starting OSA (`depends_on: condition: service_healthy`).

After startup, pull a model into Ollama:

```bash
docker compose exec ollama ollama pull qwen2.5:7b
```

## From Source

Requires Elixir 1.17+ and OTP 27+ on the host.

```bash
git clone https://github.com/Miosa-osa/OSA.git
cd OSA
MIX_ENV=prod mix setup
MIX_ENV=prod mix release osagent
```

Start the release:

```bash
./_build/prod/rel/osagent/bin/osagent serve
```

Or build and run in one step without a release:

```bash
MIX_ENV=prod mix run --no-halt
```

## Production Environment Configuration

OSA reads configuration from environment variables at startup. Set these before starting the release binary or Docker container.

**Minimum for cloud provider use:**

```bash
ANTHROPIC_API_KEY=sk-ant-...          # or OPENAI_API_KEY, GROQ_API_KEY, etc.
OSA_DEFAULT_PROVIDER=anthropic        # explicit provider selection
```

**Recommended for production:**

```bash
OSA_REQUIRE_AUTH=true
OSA_SHARED_SECRET=change-this-to-a-long-random-string
OSA_HTTP_PORT=9089
OSA_DAILY_BUDGET_USD=50.0
OSA_MONTHLY_BUDGET_USD=500.0
```

**Platform mode (multi-tenant, optional):**

```bash
DATABASE_URL=postgres://user:pass@host:5432/osa_prod
POOL_SIZE=10
JWT_SECRET=your-jwt-signing-secret
AMQP_URL=amqp://user:pass@rabbitmq:5672    # optional
```

The full list of environment variables is in `configuration-reference.md`.

## Systemd Service (Linux)

To run OSA as a systemd service:

```ini
# /etc/systemd/system/osagent.service
[Unit]
Description=OSA Agent
After=network.target

[Service]
Type=exec
User=osa
Group=osa
WorkingDirectory=/opt/osagent
ExecStart=/opt/osagent/bin/osagent serve
Restart=on-failure
RestartSec=5
Environment=OSA_HTTP_PORT=9089
Environment=OSA_REQUIRE_AUTH=true
Environment=OSA_SHARED_SECRET=your-secret
EnvironmentFile=/etc/osa/env

[Install]
WantedBy=multi-user.target
```

```bash
sudo systemctl daemon-reload
sudo systemctl enable --now osagent
sudo systemctl status osagent
```

## Post-Deployment Verification

```bash
# Health check
curl http://localhost:9089/health
# Expected: {"status":"ok"}

# Version
curl http://localhost:9089/api/v1/version   # or: osagent version

# Send a test message (unauthenticated if OSA_REQUIRE_AUTH=false)
curl -X POST http://localhost:9089/api/v1/sessions \
  -H "Content-Type: application/json" \
  -d '{"message": "hello"}'
```
