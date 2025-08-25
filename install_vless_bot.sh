#!/bin/bash

# Online installer for VLESS CLI and Telegram bot
# Repo: https://github.com/vladkolchik/vless-reality-installer
# Bot folder: https://github.com/vladkolchik/vless-reality-installer/tree/main/bot
# Usage examples:
#   # Install (interactive)
#   bash <(curl -fsSL https://raw.githubusercontent.com/vladkolchik/vless-reality-installer/main/install_vless_bot.sh)
#   # Install (non-interactive)
#   bash <(curl -fsSL https://raw.githubusercontent.com/vladkolchik/vless-reality-installer/main/install_vless_bot.sh) --non-interactive
#   # Update to latest bot/CLI from repo
#   bash <(curl -fsSL https://raw.githubusercontent.com/vladkolchik/vless-reality-installer/main/install_vless_bot.sh) update
#   # Override base (optional)
#   bash <(curl -fsSL https://raw.githubusercontent.com/vladkolchik/vless-reality-installer/main/install_vless_bot.sh) \
#        --raw-base https://raw.githubusercontent.com/vladkolchik/vless-reality-installer/main
# Options:
#   --raw-base URL        Base raw URL to fetch files (required if not set via RAW_BASE env)
#   --non-interactive     Do not prompt; create empty /etc/vless-bot.env if missing

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

RAW_BASE="${RAW_BASE:-}"
NON_INTERACTIVE=false
MODE="install"

while (( "$#" )); do
  case "$1" in
    --raw-base)
      RAW_BASE="${2:-}"; shift 2 || true ;;
    --non-interactive)
      NON_INTERACTIVE=true; shift || true ;;
    update)
      MODE="update"; shift || true ;;
    *)
      shift || true ;;
  esac
done

if [[ -z "$RAW_BASE" ]]; then
  RAW_BASE="https://raw.githubusercontent.com/vladkolchik/vless-reality-installer/main"
  info "RAW_BASE not provided; using default: $RAW_BASE"
fi

require_root

BOT_DST_DIR="/opt/vless-bot"
ENV_DST="/etc/vless-bot.env"
SERVICE_DST="/etc/systemd/system/vless-bot.service"

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

tmpdir=$(mktemp -d)
cleanup(){ rm -rf "$tmpdir"; }
trap cleanup EXIT

info "Downloading files from $RAW_BASE"
curl -fsSL "$RAW_BASE/bot/telegram_bot.py" -o "$tmpdir/telegram_bot.py"
curl -fsSL "$RAW_BASE/bot/requirements.txt" -o "$tmpdir/requirements.txt"
curl -fsSL "$RAW_BASE/bot/scripts/vless" -o "$tmpdir/vless"

install -m 755 "$tmpdir/vless" /usr/local/bin/vless
info "Installed/updated CLI: /usr/local/bin/vless"

mkdir -p "$BOT_DST_DIR"
install -m 644 "$tmpdir/requirements.txt" "$BOT_DST_DIR/requirements.txt"
install -m 644 "$tmpdir/telegram_bot.py" "$BOT_DST_DIR/telegram_bot.py"
chown -R root:root "$BOT_DST_DIR"

if [[ ! -d "$BOT_DST_DIR/.venv" ]]; then
  info "Creating Python venv"
  python3 -m venv "$BOT_DST_DIR/.venv"
fi
info "Installing/upgrading Python deps"
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

if [[ ! -f "$SERVICE_DST" ]]; then
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
fi

systemctl daemon-reload
if [[ "$MODE" == "update" ]]; then
  info "Updating bot files complete; restarting service"
  systemctl restart vless-bot || systemctl enable --now vless-bot
  systemctl status vless-bot | cat || true
  info "Update done."
else
  info "Enabling and starting service"
  systemctl enable --now vless-bot
  systemctl status vless-bot | cat || true
  info "Install done. Edit $ENV_DST if needed and restart: systemctl restart vless-bot"
fi


