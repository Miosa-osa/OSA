#!/usr/bin/env bash
set -euo pipefail

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
NC='\033[0m'

echo -e "${PURPLE}"
echo "  ╔══════════════════════════════════════════════════╗"
echo "  ║       OptimalSystemAgent — One-Click Install     ║"
echo "  ║  Signal Theory optimized proactive AI agent      ║"
echo "  ╚══════════════════════════════════════════════════╝"
echo -e "${NC}"

OSA_DIR="${OSA_DIR:-$HOME/osa}"

# --- Homebrew ---
if ! command -v brew &>/dev/null; then
  echo -e "${BLUE}Installing Homebrew...${NC}"
  /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"

  # Add to path for this session
  if [[ -f /opt/homebrew/bin/brew ]]; then
    eval "$(/opt/homebrew/bin/brew shellenv)"
  elif [[ -f /usr/local/bin/brew ]]; then
    eval "$(/usr/local/bin/brew shellenv)"
  fi
else
  echo -e "${GREEN}Homebrew found.${NC}"
fi

# --- mise ---
if ! command -v mise &>/dev/null; then
  echo -e "${BLUE}Installing mise (version manager)...${NC}"
  brew install mise
  eval "$(mise activate bash)"
else
  echo -e "${GREEN}mise found.${NC}"
fi

# --- Erlang/OTP + Elixir ---
echo -e "${BLUE}Installing Erlang/OTP 28 and Elixir 1.19...${NC}"
mise use --global erlang@28
mise use --global elixir@1.19

# Verify
echo -e "${GREEN}Erlang: $(erl -eval '{ok, V} = file:read_file(filename:join([code:root_dir(), "releases", erlang:system_info(otp_release), "OTP_VERSION"])), io:fwrite(V), halt().' -noshell 2>/dev/null || echo 'installed')${NC}"
echo -e "${GREEN}Elixir: $(elixir --version | head -1)${NC}"

# --- Clone / Update ---
if [[ -d "$OSA_DIR" ]]; then
  echo -e "${BLUE}Updating existing OSA installation...${NC}"
  cd "$OSA_DIR"
  git pull origin main
else
  echo -e "${BLUE}Cloning OptimalSystemAgent...${NC}"
  git clone https://github.com/Miosa-osa/OSA.git "$OSA_DIR"
  cd "$OSA_DIR"
fi

# --- Dependencies ---
echo -e "${BLUE}Installing Elixir dependencies...${NC}"
mix local.hex --force
mix local.rebar --force
mix deps.get
mix compile

# --- Setup Wizard ---
echo ""
echo -e "${PURPLE}Running setup wizard...${NC}"
mix osa.setup

echo ""
echo -e "${GREEN}╔══════════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}║          Installation Complete!                  ║${NC}"
echo -e "${GREEN}╚══════════════════════════════════════════════════╝${NC}"
echo ""
echo -e "Start chatting:  ${BLUE}cd $OSA_DIR && mix chat${NC}"
echo -e "Run as daemon:   ${BLUE}launchctl load ~/Library/LaunchAgents/com.osa.agent.plist${NC}"
echo ""
