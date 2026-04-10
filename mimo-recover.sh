#!/usr/bin/env bash
set -euo pipefail

# One-command bootstrap + restore.
# curl -fsSL https://raw.githubusercontent.com/lehoangtung01/mimo-disaster-recovery/main/mimo-recover.sh | sudo bash

DRIVE_REMOTE=${DRIVE_REMOTE:-drive}
DRIVE_PREFIX=${DRIVE_PREFIX:-mimo-backups/prod}
WORKDIR=${WORKDIR:-/opt/mimo-recovery}

log(){ echo "[recovery] $*"; }
need_root(){ [ "${EUID:-$(id -u)}" -eq 0 ] || { echo "Run with sudo" >&2; exit 1; }; }

apt_install(){
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -y
  apt-get install -y --no-install-recommends "$@"
}

ensure_base(){ apt_install ca-certificates curl git jq zstd gnupg lsb-release; }
ensure_docker(){ command -v docker >/dev/null 2>&1 || apt_install docker.io docker-compose-plugin; systemctl enable --now docker || true; }
ensure_rclone(){ command -v rclone >/dev/null 2>&1 || apt_install rclone; }
ensure_postgres_tools(){ apt_install postgresql-client; }

fetch_drive(){ rclone copyto "${DRIVE_REMOTE}:$1" "$2" --progress --transfers 4; }

restore_postgres(){
  local dump="$1"
  if ! id postgres >/dev/null 2>&1; then
    log "Installing Postgres server..."
    apt_install postgresql
  fi
  systemctl enable --now postgresql || true
  log "Restoring Postgres from dump..."
  sudo -u postgres dropdb --if-exists chatbot_hub || true
  sudo -u postgres createdb chatbot_hub || true
  sudo -u postgres pg_restore -d chatbot_hub --clean --if-exists "$dump"
}

restore_qdrant(){
  local snapdir="$1"
  # If qdrant not present, run it via docker
  if ! curl -fsSL http://127.0.0.1:6333/collections >/dev/null 2>&1; then
    log "Starting Qdrant via docker..."
    mkdir -p /var/lib/qdrant
    docker run -d --name qdrant -p 6333:6333 -v /var/lib/qdrant:/qdrant/storage qdrant/qdrant:v1.17.0 || true
    sleep 2
  fi
  log "Restoring Qdrant snapshots..."
  for f in "$snapdir"/*.snapshot; do
    [ -f "$f" ] || continue
    base=$(basename "$f")
    col=${base%%__*}
    log "- upload snapshot for $col"
    curl -fsSL -X POST "http://127.0.0.1:6333/collections/${col}/snapshots/upload" -F "snapshot=@${f}" >/dev/null || true
  done
}

main(){
  need_root
  ensure_base
  ensure_docker
  ensure_rclone
  ensure_postgres_tools

  mkdir -p "$WORKDIR"
  cd "$WORKDIR"

  log "Fetching LATEST.json from Drive..."
  fetch_drive "${DRIVE_PREFIX}/latest/LATEST.json" "LATEST.json"
  bundle=$(jq -r '.bundle' LATEST.json)
  secrets=$(jq -r '.secrets' LATEST.json)

  log "Downloading secrets: $secrets"
  fetch_drive "${DRIVE_PREFIX}/latest/${secrets}" "$secrets"

  log "Downloading bundle: $bundle"
  fetch_drive "${DRIVE_PREFIX}/latest/${bundle}" "$bundle"

  log "Decrypting secrets (enter passphrase)..."
  rm -rf secrets && mkdir -p secrets
  gpg --batch --yes --decrypt "$secrets" | tar -C secrets -xf -

  log "Installing rclone config from secrets"
  mkdir -p /root/.config/rclone
  cp -f secrets/rclone/rclone.conf /root/.config/rclone/rclone.conf

  log "Extracting bundle"
  rm -rf bundle && mkdir -p bundle
  tar --use-compress-program=unzstd -C bundle -xf "$bundle"

  # Restore data
  restore_postgres "bundle/postgres.dump"
  restore_qdrant "bundle/qdrant"

  log "Restore configs (OpenClaw/cloudflared) - manual finalize may be needed"
  # OpenClaw config
  if [ -f secrets/openclaw/openclaw.json ]; then
    install -d -m 700 /root/.openclaw
    cp -f secrets/openclaw/openclaw.json /root/.openclaw/openclaw.json
  fi

  log "Done."
  log "Next: restore cloudflared + OpenClaw gateway + chatbot services (WIP)"
}

main "$@"
