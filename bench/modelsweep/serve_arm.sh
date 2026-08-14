#!/usr/bin/env bash
# Boot an OSA backend pinned to ONE OpenRouter model, fully isolated from the
# operator's live daemon.
#
# Isolation rests on config/runtime.exs: `config_dir = System.get_env("OSA_HOME")
# || ~/.osa`, and bootstrap_dir / sessions_dir / data_dir / Store.Repo's sqlite
# path are all re-derived from it at boot. Pointing OSA_HOME at a scratch dir
# therefore moves config.toml, config.json, the session store AND the database
# away from ~/.osa. Nothing here can touch the daemon on :9089.
#
# Model selection rests on Application.load_provider_env/1, which maps
# {PROVIDER}_MODEL -> :{provider}_model. In application.ex the resolution chain is
#
#   ConfigFile model (provider-scoped) || OLLAMA_MODEL (ollama only)
#     || :{provider}_model || :default_model
#
# so OPENROUTER_MODEL is the lever that actually wins. OSA_MODEL does NOT --
# config/config.exs hardcodes :openrouter_model to anthropic/claude-opus-5, which
# sits AHEAD of :default_model in that chain, so every arm would silently run
# opus-5. Set OPENROUTER_MODEL, never OSA_MODEL.
#
# usage: serve_arm.sh <model-slug> <port> [logfile]
set -euo pipefail

MODEL="${1:?model slug required}"
PORT="${2:?port required}"
LOG="${3:-/tmp/osa-modelsweep-${PORT}.log}"

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
KEY_FILE="${OPENROUTER_KEY_FILE:-$HOME/.osa/openrouter.key}"

if [[ "$PORT" == "9089" ]]; then
  echo "refusing: :9089 is the operator's live daemon" >&2
  exit 2
fi
if [[ ! -r "$KEY_FILE" ]]; then
  echo "no readable OpenRouter key at $KEY_FILE" >&2
  exit 2
fi

# One home per arm, keyed by the model, so two arms can never share a session
# store or a sqlite file.
SLUG="$(echo "$MODEL" | tr '/:.' '___')"
HOME_DIR="$REPO/bench/modelsweep/homes/$SLUG"
mkdir -p "$HOME_DIR"

export PATH="$HOME/.asdf/shims:$HOME/.asdf/bin:$PATH"
export OSA_HOME="$HOME_DIR"
# Same airgap deny-list the glm baseline ran under, so the arms differ only in
# the model. Unset means no airgap, and run_bench --airgap would then refuse.
if [[ -n "${OSA_SETTINGS:-}" ]]; then export OSA_SETTINGS; fi
export OSA_HTTP_PORT="$PORT"
export OSA_DEFAULT_PROVIDER="openrouter"
export OPENROUTER_MODEL="$MODEL"
# Read at call time, never written to disk or echoed.
OPENROUTER_API_KEY="$(cat "$KEY_FILE")"
export OPENROUTER_API_KEY

cd "$REPO"
echo "arm: model=$MODEL port=$PORT home=$HOME_DIR log=$LOG"
nohup mix osa.serve >"$LOG" 2>&1 &
echo "pid=$!"
