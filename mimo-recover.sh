#!/usr/bin/env bash
set -euo pipefail

# One-command bootstrap + restore (best-effort full system)
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
ensure_pg_tools(){ apt_install postgresql postgresql-client; systemctl enable --now postgresql || true; }
ensure_redis(){ apt_install redis-server; systemctl enable --now redis-server || true; }

fetch_drive(){ rclone copyto "${DRIVE_REMOTE}:$1" "$2" --progress --transfers 4; }

restore_postgres(){
  local dump="$1"
  log "Restoring Postgres from dump into local cluster..."
  # Restore into a database named chatbot_hub (can be adjusted later)
  sudo -u postgres dropdb --if-exists chatbot_hub || true
  sudo -u postgres createdb chatbot_hub || true
  sudo -u postgres pg_restore -d chatbot_hub --clean --if-exists "$dump"
}

ensure_qdrant(){
  if curl -fsSL http://127.0.0.1:6333/collections >/dev/null 2>&1; then
    return
  fi
  log "Starting Qdrant via docker (v1.17.0)..."
  mkdir -p /var/lib/qdrant
  docker rm -f qdrant >/dev/null 2>&1 || true
  docker run -d --restart unless-stopped --name qdrant -p 6333:6333 -v /var/lib/qdrant:/qdrant/storage qdrant/qdrant:v1.17.0
  sleep 2
}

restore_qdrant(){
  local snapdir="$1"
  ensure_qdrant
  log "Restoring Qdrant snapshots (upload)..."
  shopt -s nullglob
  for f in "$snapdir"/*.snapshot; do
    base=$(basename "$f")
    col=${base%%__*}
    log "- $col"
    curl -fsSL -X POST "http://127.0.0.1:6333/collections/${col}/snapshots/upload" -F "snapshot=@${f}" >/dev/null || true
  done
}

ensure_tei(){
  if curl -fsSL http://127.0.0.1:8080/info >/dev/null 2>&1; then
    return
  fi
  log "Starting TEI via docker on :8080 (best-effort)..."
  docker rm -f tei >/dev/null 2>&1 || true
  # NOTE: model+image may need adjustment; this is best-effort.
  docker run -d --restart unless-stopped --name tei -p 8080:80 ghcr.io/huggingface/text-embeddings-inference:1.9 --model-id sentence-transformers/all-MiniLM-L6-v2
  sleep 2
}

restore_openclaw(){
  if [ -f secrets/openclaw/openclaw.json ]; then
    log "Restoring OpenClaw config..."
    install -d -m 700 /root/.openclaw
    cp -f secrets/openclaw/openclaw.json /root/.openclaw/openclaw.json
  fi
  if [ -d bundle/config/openclaw/agents ]; then
    mkdir -p /root/.openclaw
    cp -a bundle/config/openclaw/agents /root/.openclaw/agents || true
  fi
  if command -v openclaw >/dev/null 2>&1; then
    log "Enabling OpenClaw gateway..."
    openclaw gateway start || openclaw gateway restart || true
  fi
}

restore_cloudflared(){
  if [ -f secrets/cloudflared/config.yml ]; then
    log "Restoring cloudflared config..."
    install -d -m 755 /etc/cloudflared
    cp -f secrets/cloudflared/config.yml /etc/cloudflared/config.yml
    systemctl enable --now cloudflared || true
  fi
}

restore_chatbot(){
  # Best-effort: if repo exists in bundle/config, restore env. Service install is environment-specific.
  if [ -f secrets/chatbot/chatbot-hub-refactor.env ]; then
    mkdir -p /home/hoangtung/Documents/chatbot-hub-refactor
    cp -f secrets/chatbot/chatbot-hub-refactor.env /home/hoangtung/Documents/chatbot-hub-refactor/.env || true
  fi
  systemctl --user enable --now chatbot-hub-refactor.service >/dev/null 2>&1 || true
}

healthcheck(){
  log "Healthcheck (best-effort):"
  curl -fsSL http://127.0.0.1:6333/collections >/dev/null && echo "- qdrant: OK" || echo "- qdrant: FAIL"
  curl -fsSL http://127.0.0.1:8080/info >/dev/null && echo "- tei: OK" || echo "- tei: FAIL"
  (command -v openclaw >/dev/null 2>&1 && openclaw status >/dev/null 2>&1 && echo "- openclaw: OK") || echo "- openclaw: UNKNOWN"
}

main(){
  need_root
  ensure_base
  ensure_docker
  ensure_rclone
  ensure_pg_tools
  ensure_redis

  mkdir -p "$WORKDIR"
  cd "$WORKDIR"

  log "Fetching LATEST.json from Drive..."
  fetch_drive "${DRIVE_PREFIX}/latest/LATEST.json" "LATEST.json"
  bundleName=$(jq -r '.bundle' LATEST.json)
  secretsName=$(jq -r '.secrets' LATEST.json)

  log "Downloading secrets: $secretsName"
  fetch_drive "${DRIVE_PREFIX}/latest/${secretsName}" "$secretsName"

  log "Downloading bundle: $bundleName"
  fetch_drive "${DRIVE_PREFIX}/latest/${bundleName}" "$bundleName"

  log "Decrypting secrets (enter passphrase)..."
  rm -rf secrets && mkdir -p secrets
  gpg --batch --yes --decrypt "$secretsName" | tar -C secrets -xf -

  log "Installing rclone config from secrets"
  mkdir -p /root/.config/rclone
  cp -f secrets/rclone/rclone.conf /root/.config/rclone/rclone.conf

  log "Extracting bundle"
  rm -rf bundle && mkdir -p bundle
  tar --use-compress-program=unzstd -C bundle -xf "$bundleName"

  restore_postgres "bundle/postgres.dump"
  restore_qdrant "bundle/qdrant"
  ensure_tei
  restore_cloudflared
  restore_openclaw
  restore_chatbot
  healthcheck

  log "DONE"
}

main "$@"
