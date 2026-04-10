#!/usr/bin/env bash
set -euo pipefail

DRIVE_REMOTE=${DRIVE_REMOTE:-drive}
DRIVE_PREFIX=${DRIVE_PREFIX:-mimo-backups/prod}
WORKDIR=${WORKDIR:-/opt/mimo-recovery}
TARGET_USER=${TARGET_USER:-hoangtung}
TARGET_HOME=${TARGET_HOME:-/home/hoangtung}

log(){ echo "[recovery] $*"; }
need_root(){ [ "${EUID:-$(id -u)}" -eq 0 ] || { echo "Run with sudo" >&2; exit 1; }; }

apt_install(){
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -y
  apt-get install -y --no-install-recommends "$@"
}

ensure_base(){
  apt_install ca-certificates curl git jq zstd gnupg lsb-release
}

ensure_user(){
  if id "$TARGET_USER" >/dev/null 2>&1; then return; fi
  log "Creating user $TARGET_USER"
  useradd -m -s /bin/bash "$TARGET_USER"
}

ensure_docker(){
  command -v docker >/dev/null 2>&1 || apt_install docker.io docker-compose-plugin
  systemctl enable --now docker || true
}

ensure_rclone(){ command -v rclone >/dev/null 2>&1 || apt_install rclone; }

ensure_pg_redis(){
  apt_install postgresql postgresql-client redis-server
  systemctl enable --now postgresql || true
  systemctl enable --now redis-server || true
}

fetch_drive(){ rclone copyto "${DRIVE_REMOTE}:$1" "$2" --progress --transfers 4; }

restore_postgres(){
  local dump="$1"
  log "Restoring Postgres (db=chatbot_hub)"
  sudo -u postgres dropdb --if-exists chatbot_hub || true
  sudo -u postgres createdb chatbot_hub || true
  sudo -u postgres pg_restore -d chatbot_hub --clean --if-exists "$dump"
}

compose_up(){
  log "Starting qdrant+tei via docker compose"
  docker compose -f "$WORKDIR/docker-compose.yml" up -d
}

wait_http(){
  local url="$1"; local n=0
  until curl -fsSL "$url" >/dev/null 2>&1; do
    n=$((n+1));
    [ $n -gt 60 ] && return 1
    sleep 1
  done
}

restore_qdrant_snapshots(){
  local snapdir="$1"
  log "Waiting qdrant..."
  wait_http http://127.0.0.1:6333/collections
  log "Uploading snapshots"
  shopt -s nullglob
  for f in "$snapdir"/*.snapshot; do
    base=$(basename "$f")
    col=${base%%__*}
    curl -fsSL -X POST "http://127.0.0.1:6333/collections/${col}/snapshots/upload" -F "snapshot=@${f}" >/dev/null || true
  done
}

restore_cloudflared(){
  if [ -f "$WORKDIR/secrets/cloudflared/config.yml" ]; then
    log "Restoring cloudflared config"
    install -d -m 755 /etc/cloudflared
    cp -f "$WORKDIR/secrets/cloudflared/config.yml" /etc/cloudflared/config.yml
    systemctl enable --now cloudflared || true
  fi
}

restore_openclaw(){
  if ! command -v openclaw >/dev/null 2>&1; then
    log "Installing openclaw"
    npm -g i openclaw@latest
  fi
  install -d -m 700 /root/.openclaw
  if [ -f "$WORKDIR/secrets/openclaw/openclaw.json" ]; then
    cp -f "$WORKDIR/secrets/openclaw/openclaw.json" /root/.openclaw/openclaw.json
  elif [ -f "$WORKDIR/bundle/config/openclaw/openclaw.json" ]; then
    cp -f "$WORKDIR/bundle/config/openclaw/openclaw.json" /root/.openclaw/openclaw.json
  fi
  if [ -d "$WORKDIR/bundle/config/openclaw/agents" ]; then
    cp -a "$WORKDIR/bundle/config/openclaw/agents" /root/.openclaw/agents || true
  fi
  openclaw gateway start || openclaw gateway restart || true
}

restore_chatbot(){
  # Requires repo url inside secrets. We store it as plain text file.
  local repo_file="$WORKDIR/secrets/chatbot/repo_url.txt"
  if [ ! -f "$repo_file" ]; then
    return
  fi
  local repo
  repo=$(cat "$repo_file")
  log "Restoring chatbot repo: $repo"
  install -d -m 755 "$TARGET_HOME/Documents"
  chown -R "$TARGET_USER:$TARGET_USER" "$TARGET_HOME/Documents"
  local dir="$TARGET_HOME/Documents/chatbot-hub-refactor"
  if [ ! -d "$dir/.git" ]; then
    sudo -u "$TARGET_USER" git clone "$repo" "$dir"
  else
    sudo -u "$TARGET_USER" git -C "$dir" pull --ff-only || true
  fi

  if [ -f "$WORKDIR/secrets/chatbot/chatbot-hub-refactor.env" ]; then
    cp -f "$WORKDIR/secrets/chatbot/chatbot-hub-refactor.env" "$dir/.env"
    chown "$TARGET_USER:$TARGET_USER" "$dir/.env"
  fi

  log "Installing node deps"
  sudo -u "$TARGET_USER" bash -lc "cd '$dir' && npm ci"

  log "Creating systemd user unit"
  local unit="/home/${TARGET_USER}/.config/systemd/user/chatbot-hub-refactor.service"
  sudo -u "$TARGET_USER" mkdir -p "/home/${TARGET_USER}/.config/systemd/user"
  cat > "$unit" <<UNIT
[Unit]
Description=Chatbot Hub Refactor
After=network.target

[Service]
Type=simple
WorkingDirectory=$dir
Environment=NODE_ENV=production
ExecStart=/usr/bin/node $dir/src/server.js
Restart=always
RestartSec=2

[Install]
WantedBy=default.target
UNIT
  chown "$TARGET_USER:$TARGET_USER" "$unit"

  log "Starting chatbot service"
  sudo -u "$TARGET_USER" systemctl --user daemon-reload
  sudo -u "$TARGET_USER" systemctl --user enable --now chatbot-hub-refactor.service
}

healthcheck(){
  log "Healthcheck"
  curl -fsSL http://127.0.0.1:6333/collections >/dev/null && echo "- qdrant OK" || echo "- qdrant FAIL"
  curl -fsSL http://127.0.0.1:8080/info >/dev/null && echo "- tei OK" || echo "- tei FAIL"
  curl -fsSL http://127.0.0.1:3010/health >/dev/null && echo "- hub local OK" || echo "- hub local FAIL"
  openclaw status >/dev/null 2>&1 && echo "- openclaw OK" || echo "- openclaw FAIL"
}

main(){
  need_root
  ensure_base
  apt_install nodejs npm
  ensure_user
  ensure_docker
  ensure_rclone
  ensure_pg_redis

  mkdir -p "$WORKDIR"
  cd "$WORKDIR"

  log "Fetching LATEST.json"
  fetch_drive "${DRIVE_PREFIX}/latest/LATEST.json" "LATEST.json"
  bundleName=$(jq -r '.bundle' LATEST.json)
  secretsName=$(jq -r '.secrets' LATEST.json)

  log "Downloading secrets + bundle"
  fetch_drive "${DRIVE_PREFIX}/latest/${secretsName}" "$secretsName"
  fetch_drive "${DRIVE_PREFIX}/latest/${bundleName}" "$bundleName"

  log "Decrypting secrets"
  rm -rf secrets && mkdir -p secrets
  gpg --batch --yes --decrypt "$secretsName" | tar -C secrets -xf -

  log "Install rclone config"
  mkdir -p /root/.config/rclone
  cp -f secrets/rclone/rclone.conf /root/.config/rclone/rclone.conf

  log "Extract bundle"
  rm -rf bundle && mkdir -p bundle
  tar --use-compress-program=unzstd -C bundle -xf "$bundleName"

  log "Write docker-compose.yml"
  cp -f "$WORKDIR/docker-compose.yml" "$WORKDIR/docker-compose.yml" 2>/dev/null || true

  restore_postgres "bundle/postgres.dump"

  # bring up qdrant+tei
  cp -f /dev/null /dev/null 2>/dev/null || true
  # ensure compose file is present
  if [ ! -f "$WORKDIR/docker-compose.yml" ]; then
    echo "missing docker-compose.yml" >&2; exit 2
  fi
  compose_up
  restore_qdrant_snapshots "bundle/qdrant"

  restore_cloudflared
  restore_openclaw
  restore_chatbot
  healthcheck
  log "DONE"
}

main "$@"
