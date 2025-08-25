#!/bin/bash

# Automated installer for vless CLI and Telegram bot
# Usage: sudo bash scripts/setup_vless_bot.sh [--non-interactive]

set -Eeuo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

info(){ echo -e "${GREEN}[INFO]${NC} $*"; }
warn(){ echo -e "${YELLOW}[WARN]${NC} $*"; }
err(){ echo -e "${RED}[ERROR]${NC} $*"; }

require_root(){ if [[ ${EUID:-$(id -u)} -ne 0 ]]; then err "Run as root (sudo)"; exit 1; fi; }
have(){ command -v "$1" >/dev/null 2>&1; }

REPO_ROOT=$(cd "$(dirname "$0")/.." && pwd)
VLESS_SRC="$REPO_ROOT/scripts/vless"
# In current layout, REPO_ROOT already points to the bot/ directory
BOT_SRC_DIR="$REPO_ROOT"
BOT_DST_DIR="/opt/vless-bot"
ENV_DST="/etc/vless-bot.env"
SERVICE_DST="/etc/systemd/system/vless-bot.service"
NON_INTERACTIVE=false

for a in "$@"; do
  case "$a" in
    --non-interactive) NON_INTERACTIVE=true ;;
  esac
done

require_root

info "Installing dependencies"
if have apt; then
  apt update -y
  apt install -y python3-venv jq qrencode curl uuid-runtime
elif have dnf; then
  dnf install -y python3-virtualenv jq qrencode curl util-linux
elif have yum; then
  yum install -y python3-virtualenv jq qrencode curl util-linux
else
  warn "Unknown package manager; please install: python3-venv/jq/qrencode/curl/uuidgen"
fi

info "Installing vless CLI to /usr/local/bin/vless"
if [[ ! -f "$VLESS_SRC" ]]; then
  err "Source CLI not found at $VLESS_SRC"
  exit 1
fi
install -m 755 "$VLESS_SRC" /usr/local/bin/vless

info "Preparing bot directory at $BOT_DST_DIR"
mkdir -p "$BOT_DST_DIR"
install -m 644 "$BOT_SRC_DIR/requirements.txt" "$BOT_DST_DIR/requirements.txt"
install -m 644 "$BOT_SRC_DIR/telegram_bot.py" "$BOT_DST_DIR/telegram_bot.py"
chown -R root:root "$BOT_DST_DIR"

info "Creating Python venv and installing requirements"
python3 -m venv "$BOT_DST_DIR/.venv"
"$BOT_DST_DIR/.venv/bin/pip" install --upgrade pip >/dev/null
"$BOT_DST_DIR/.venv/bin/pip" install -r "$BOT_DST_DIR/requirements.txt"

if [[ -f "$ENV_DST" ]]; then
  warn "$ENV_DST exists; leaving as is"
else
  info "Creating $ENV_DST"
  if [[ "$NON_INTERACTIVE" == true ]]; then
    cat > "$ENV_DST" <<EOF
TELEGRAM_BOT_TOKEN=
TELEGRAM_ADMINS=
VLESS_BIN=/usr/local/bin/vless
VLESS_OUTPUT_DIR=/root/vless-configs
EOF
  else
    read -r -p "Enter TELEGRAM_BOT_TOKEN: " BOT_TOKEN
    read -r -p "Enter TELEGRAM_ADMINS (comma or space separated ids): " ADMINS
    cat > "$ENV_DST" <<EOF
TELEGRAM_BOT_TOKEN=${BOT_TOKEN}
TELEGRAM_ADMINS=${ADMINS}
VLESS_BIN=/usr/local/bin/vless
VLESS_OUTPUT_DIR=/root/vless-configs
EOF
  fi
  chmod 600 "$ENV_DST"
  chown root:root "$ENV_DST"
fi

info "Creating systemd service at $SERVICE_DST"
cat > "$SERVICE_DST" <<EOF
[Unit]
Description=VLESS Telegram Bot
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
EnvironmentFile=$ENV_DST
WorkingDirectory=$BOT_DST_DIR
ExecStart=$BOT_DST_DIR/.venv/bin/python telegram_bot.py
User=root
Group=root
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF

info "Enabling and starting service"
systemctl daemon-reload
systemctl enable --now vless-bot
systemctl status vless-bot | cat || true

info "Done. Edit $ENV_DST if needed and restart: systemctl restart vless-bot"


