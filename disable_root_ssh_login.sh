#!/bin/bash

# Disable SSH login for root safely
# - Backs up /etc/ssh/sshd_config
# - Sets PermitRootLogin no
# - Validates config (sshd -t)
# - Restarts SSH service (ssh/sshd)

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

print_status() { echo -e "${GREEN}[INFO]${NC} $1"; }
print_warning() { echo -e "${YELLOW}[WARN]${NC} $1"; }
print_error() { echo -e "${RED}[ERROR]${NC} $1"; }

require_root() {
  if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
    print_error "Run this script as root (sudo)."
    exit 1
  fi
}

detect_ssh_service() {
  if command -v systemctl >/dev/null 2>&1; then
    if systemctl list-unit-files | grep -q '^ssh\.service'; then
      echo ssh
      return
    fi
    if systemctl list-unit-files | grep -q '^sshd\.service'; then
      echo sshd
      return
    fi
  fi
  # Fallback guess
  if service ssh status >/dev/null 2>&1; then echo ssh; else echo sshd; fi
}

main() {
  require_root

  print_warning "Make sure you already have a non-root user with sudo access before disabling root SSH login."

  local cfg="/etc/ssh/sshd_config"
  local backup="/etc/ssh/sshd_config.$(date +%F_%H-%M-%S).bak"

  cp "$cfg" "$backup"
  print_status "Backup saved: $backup"

  if grep -Eq '^\s*PermitRootLogin\b' "$cfg"; then
    sed -i 's/^\s*PermitRootLogin\s\+.*/PermitRootLogin no/' "$cfg"
  else
    printf '\nPermitRootLogin no\n' >> "$cfg"
  fi

  # Optional hardening (commented):
  # if grep -Eq '^\s*PasswordAuthentication\b' "$cfg"; then
  #   sed -i 's/^\s*PasswordAuthentication\s\+.*/PasswordAuthentication no/' "$cfg"
  # else
  #   printf 'PasswordAuthentication no\n' >> "$cfg"
  # fi

  # Validate config
  if command -v sshd >/dev/null 2>&1; then
    if ! sshd -t 2>/tmp/ssh_test.err; then
      print_error "Validation failed. Restoring backup."
      cat /tmp/ssh_test.err >&2 || true
      mv -f "$backup" "$cfg"
      exit 1
    fi
  fi

  # Restart service
  local svc
  svc=$(detect_ssh_service)
  if command -v systemctl >/dev/null 2>&1; then
    systemctl restart "$svc"
    systemctl is-active --quiet "$svc" && print_status "Service '$svc' restarted." || { print_error "Service '$svc' not active"; exit 1; }
  else
    service "$svc" restart
  fi

  print_status "Root SSH login disabled (PermitRootLogin no)."
}

main "$@"


