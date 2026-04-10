#!/usr/bin/env bash
set -euo pipefail

# Mimo Disaster Recovery - one-command bootstrap+restore
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/lehoangtung01/mimo-disaster-recovery/main/mimo-recover.sh | sudo bash
#
# Requires: Ubuntu + internet + sudo.

DRIVE_REMOTE=${DRIVE_REMOTE:-drive}
DRIVE_PREFIX=${DRIVE_PREFIX:-mimo-backups/prod}
WORKDIR=${WORKDIR:-/opt/mimo-recovery}

log(){ echo "[recovery] $*"; }

need_root(){
  if [ "${EUID:-$(id -u)}" -ne 0 ]; then
    echo "Please run as root (sudo)." >&2
    exit 1
  fi
}

apt_install(){
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -y
  apt-get install -y --no-install-recommends "$@"
}

ensure_base(){
  log "Installing base dependencies..."
  apt_install ca-certificates curl git jq zstd gnupg
}

ensure_docker(){
  if command -v docker >/dev/null 2>&1; then
    log "Docker already installed."
    return
  fi
  log "Installing Docker (docker.io + compose plugin)..."
  apt_install docker.io docker-compose-plugin
  systemctl enable --now docker || true
}

ensure_rclone(){
  if command -v rclone >/dev/null 2>&1; then
    log "rclone already installed."
    return
  fi
  log "Installing rclone..."
  apt_install rclone
}

fetch_from_drive(){
  local src="$1" dst="$2"
  rclone copyto "${DRIVE_REMOTE}:${src}" "${dst}" --progress --transfers 4
}

main(){
  need_root
  ensure_base
  ensure_docker
  ensure_rclone

  mkdir -p "$WORKDIR"
  cd "$WORKDIR"

  log "Fetching latest pointer from Drive..."
  fetch_from_drive "${DRIVE_PREFIX}/latest/LATEST.json" "LATEST.json"

  local bundle secrets
  bundle=$(jq -r '.bundle' LATEST.json)
  secrets=$(jq -r '.secrets' LATEST.json)

  if [ -z "$bundle" ] || [ "$bundle" = "null" ]; then
    echo "LATEST.json missing .bundle" >&2; exit 2
  fi
  if [ -z "$secrets" ] || [ "$secrets" = "null" ]; then
    echo "LATEST.json missing .secrets" >&2; exit 2
  fi

  log "Downloading secrets bundle: $secrets"
  fetch_from_drive "${DRIVE_PREFIX}/latest/${secrets}" "${secrets}"

  log "Downloading system bundle: $bundle"
  fetch_from_drive "${DRIVE_PREFIX}/latest/${bundle}" "${bundle}"

  log "Decrypting secrets (will prompt for passphrase)..."
  mkdir -p secrets
  gpg --batch --yes --decrypt "${secrets}" | tar -C secrets -xf -

  # secrets layout expectation:
  # secrets/rclone/rclone.conf
  # secrets/chatbot-hub-refactor/.env
  # secrets/openclaw/openclaw.json
  # secrets/cloudflared/config.yml (+ credentials if needed)

  log "Installing rclone config from secrets..."
  mkdir -p /root/.config/rclone
  if [ -f secrets/rclone/rclone.conf ]; then
    cp -f secrets/rclone/rclone.conf /root/.config/rclone/rclone.conf
  else
    echo "Missing secrets/rclone/rclone.conf" >&2; exit 3
  fi

  log "Extracting system bundle..."
  mkdir -p bundle
  tar --use-compress-program=unzstd -C bundle -xf "${bundle}"

  log "Next steps (placeholder): restore services and data."
  echo "OK: downloaded and unpacked bundle + secrets into $WORKDIR"
  echo "TODO: implement restore of Postgres/Qdrant/Redis/OpenClaw/chatbot services"
}

main "$@"
