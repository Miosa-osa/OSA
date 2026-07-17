#!/bin/bash
# OSA Development Launcher (backend-focused)
#
# Day-to-day OSA development is the Elixir backend (OTP) on :9089. That is what
# this script starts by default. The old SvelteKit / Tauri desktop frontend is
# LEGACY and hidden by default — only start it (--frontend / --tauri) if you are
# specifically working on that surface.
#
# Usage:
#   ./dev.sh              Start the backend on :9089  (default)
#   ./dev.sh --backend    Same as default (explicit)
#   ./dev.sh --tauri      Backend + LEGACY desktop frontend (native Tauri window)
#   ./dev.sh --frontend   ONLY the LEGACY desktop frontend (browser mode)
#
# Prefer the packaged CLI for a production-style run:   osa
# Or run the serve task directly:                       mix osa.serve

set -e
cd "$(dirname "$0")"

RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[0;33m'
DIM='\033[0;90m'
BOLD='\033[1m'
NC='\033[0m'

banner() {
  echo ""
  echo -e "${BLUE}${BOLD}  OSA${NC}${DIM} — Optimal System Agent (dev)${NC}"
  echo -e "${DIM}  ─────────────────────────────${NC}"
  echo ""
}

# Elixir is always required. Node is only needed for the legacy frontend.
check_backend_deps() {
  if ! command -v elixir &>/dev/null; then
    echo -e "${RED}  Missing: elixir${NC} — install from https://elixir-lang.org/install.html"
    echo ""
    exit 1
  fi
}

check_frontend_deps() {
  if ! command -v node &>/dev/null; then
    echo -e "${RED}  Missing: node${NC} — install from https://nodejs.org or use nvm"
    echo ""
    exit 1
  fi
}

start_backend() {
  echo -e "${GREEN}  Starting backend...${NC}  ${DIM}(Elixir/OTP on :9089)${NC}"

  # Load env if present
  if [ -f .env ]; then
    set -a; source .env; set +a
  fi

  # Ensure deps are fetched
  if [ ! -d deps ] || [ ! -d _build ]; then
    echo -e "${DIM}  Fetching dependencies...${NC}"
    mix deps.get --quiet
  fi

  mix osa.serve &
  BACKEND_PID=$!
  echo -e "${DIM}  Backend PID: ${BACKEND_PID}${NC}"
}

# LEGACY: the desktop frontend is no longer the primary surface. Kept as a dev
# convenience for anyone still working on it.
start_frontend() {
  local mode="${1:-dev}"
  echo -e "${YELLOW}  [legacy]${NC} ${GREEN}Starting desktop frontend...${NC}  ${DIM}(SvelteKit on :5199)${NC}"

  cd desktop

  if [ ! -d node_modules ]; then
    echo -e "${DIM}  Installing npm dependencies...${NC}"
    npm install --silent
  fi

  if [ "$mode" = "tauri" ]; then
    echo -e "${BLUE}  Mode: Native Tauri window${NC}"
    npm run tauri:dev &
  else
    echo -e "${BLUE}  Mode: Browser — http://localhost:5199${NC}"
    npm run dev &
  fi
  FRONTEND_PID=$!
  echo -e "${DIM}  Frontend PID: ${FRONTEND_PID}${NC}"
  cd ..
}

cleanup() {
  echo ""
  echo -e "${DIM}  Shutting down...${NC}"
  [ -n "$BACKEND_PID" ] && kill "$BACKEND_PID" 2>/dev/null
  [ -n "$FRONTEND_PID" ] && kill "$FRONTEND_PID" 2>/dev/null
  wait 2>/dev/null
  echo -e "${GREEN}  Done.${NC}"
}

trap cleanup EXIT INT TERM

# ── Main ──────────────────────────────────────────────────────

banner

case "${1:-}" in
  --frontend)
    check_frontend_deps
    echo -e "${YELLOW}  Legacy desktop frontend only (no backend).${NC}"
    start_frontend "${2:-dev}"
    echo ""
    echo -e "${GREEN}  Frontend running.${NC} Press Ctrl+C to stop."
    wait
    ;;
  --tauri)
    check_backend_deps
    check_frontend_deps
    echo -e "${YELLOW}  Backend + legacy desktop frontend (Tauri).${NC}"
    start_backend
    sleep 2
    start_frontend tauri
    echo ""
    echo -e "${GREEN}  Both services running.${NC} Press Ctrl+C to stop."
    wait
    ;;
  --backend | "" | *)
    check_backend_deps
    start_backend
    echo ""
    echo -e "${GREEN}  Backend running on :9089.${NC} Press Ctrl+C to stop."
    echo -e "${DIM}  The desktop frontend is legacy — use ${NC}${BLUE}./dev.sh --tauri${NC}${DIM} if you need it.${NC}"
    wait
    ;;
esac
