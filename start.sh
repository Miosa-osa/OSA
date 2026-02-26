#!/bin/bash
# OptimalSystemAgent startup script
set -e
cd "$(dirname "$0")"

# Load env vars
if [ -f .env ]; then
  set -a; source .env; set +a
fi

# Check Ollama if using local provider
if [ "${OSA_DEFAULT_PROVIDER:-ollama}" = "ollama" ]; then
  ollama list > /dev/null 2>&1 || {
    echo "Ollama not running. Start it with: ollama serve"
    echo "Or set OSA_DEFAULT_PROVIDER=anthropic to use cloud LLM."
    exit 1
  }
fi

echo "Starting OptimalSystemAgent..."
echo "CLI chat: mix chat"
exec mix run --no-halt
