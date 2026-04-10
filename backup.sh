#!/usr/bin/env bash
set -euo pipefail

# Creates a single compressed bundle and uploads it to Google Drive via rclone.
# Requires: rclone remote `drive:` configured on this machine.

DRIVE_REMOTE=${DRIVE_REMOTE:-drive}
DRIVE_PREFIX=${DRIVE_PREFIX:-mimo-backups/prod}
HOSTNAME=${HOSTNAME:-$(hostname -s)}
TS=${TS:-$(date -u +%Y%m%dT%H%M%SZ)}
WORKDIR=${WORKDIR:-/home/hoangtung/Documents/mimo-backup-work}
OUTDIR=${OUTDIR:-/home/hoangtung/Documents/mimo-backup-out}

BUNDLE_NAME="mimo-system-bundle-${HOSTNAME}-${TS}.tar.zst"
SECRETS_NAME="mimo-secrets.tar.gpg"  # uploaded separately; not generated here
LATEST_JSON="LATEST.json"

log(){ echo "[backup] $*"; }

require_cmd(){ command -v "$1" >/dev/null 2>&1 || { echo "Missing command: $1" >&2; exit 1; }; }

main(){
  require_cmd rclone
  require_cmd zstd
  require_cmd tar
  require_cmd psql
  require_cmd pg_dump
  require_cmd curl
  require_cmd jq

  mkdir -p "$WORKDIR" "$OUTDIR"
  rm -rf "$WORKDIR"/*

  log "Dumping Postgres (custom format)..."
  # Dump as postgres to stdout, write file as current user/root to avoid permission issues.
  if id postgres >/dev/null 2>&1; then
    sudo -n -u postgres pg_dump -Fc postgres > "$WORKDIR/postgres.dump" || sudo -u postgres pg_dump -Fc postgres > "$WORKDIR/postgres.dump"
  else
    echo "postgres user not found; set PGPASSWORD/PG* env and re-run" >&2
    exit 2
  fi

  log "Snapshot Qdrant collections..."
  mkdir -p "$WORKDIR/qdrant"
  # List collections
  cols=$(curl -fsSL http://127.0.0.1:6333/collections | jq -r '.result.collections[].name')
  for c in $cols; do
    log "- snapshot $c"
    snap=$(curl -fsSL -X POST "http://127.0.0.1:6333/collections/${c}/snapshots" | jq -r '.result.name')
    curl -fSL "http://127.0.0.1:6333/collections/${c}/snapshots/${snap}" -o "$WORKDIR/qdrant/${c}__${snap}.snapshot"
  done

  log "Capture configs/state..."
  mkdir -p "$WORKDIR/config/openclaw" "$WORKDIR/config/cloudflared" "$WORKDIR/config/systemd-user" "$WORKDIR/config/pm2" "$WORKDIR/config/chatbot"

  cp -a "$HOME/.openclaw/openclaw.json" "$WORKDIR/config/openclaw/openclaw.json" 2>/dev/null || true
  cp -a "$HOME/.openclaw/agents" "$WORKDIR/config/openclaw/agents" 2>/dev/null || true
  cp -a "$HOME/.openclaw/workspace" "$WORKDIR/config/openclaw/workspace" 2>/dev/null || true

  cp -a /etc/cloudflared/config.yml "$WORKDIR/config/cloudflared/config.yml" 2>/dev/null || true

  # systemd user units
  systemctl --user cat chatbot-hub-refactor.service > "$WORKDIR/config/systemd-user/chatbot-hub-refactor.service" 2>/dev/null || true
  systemctl --user cat openclaw-gateway.service > "$WORKDIR/config/systemd-user/openclaw-gateway.service" 2>/dev/null || true
  systemctl --user cat cliproxyapi.service > "$WORKDIR/config/systemd-user/cliproxyapi.service" 2>/dev/null || true

  # pm2 dump
  pm2 save --force >/dev/null 2>&1 || true
  cp -a "$HOME/.pm2/dump.pm2" "$WORKDIR/config/pm2/dump.pm2" 2>/dev/null || true

  # chatbot env (if you want to keep it in secrets instead, remove this line)
  cp -a "/home/hoangtung/Documents/chatbot-hub-refactor/.env" "$WORKDIR/config/chatbot/chatbot-hub-refactor.env" 2>/dev/null || true

  log "Build bundle: $BUNDLE_NAME"
  tar -C "$WORKDIR" -cf - . | zstd -19 -T0 -o "$OUTDIR/$BUNDLE_NAME"
  (cd "$OUTDIR" && sha256sum "$BUNDLE_NAME" > "$BUNDLE_NAME.sha256")

  log "Upload bundle to Drive: ${DRIVE_REMOTE}:${DRIVE_PREFIX}/latest/"
  rclone copyto "$OUTDIR/$BUNDLE_NAME" "${DRIVE_REMOTE}:${DRIVE_PREFIX}/latest/$BUNDLE_NAME" --progress
  rclone copyto "$OUTDIR/$BUNDLE_NAME.sha256" "${DRIVE_REMOTE}:${DRIVE_PREFIX}/latest/$BUNDLE_NAME.sha256" --progress

  log "Write LATEST.json"
  jq -n --arg bundle "$BUNDLE_NAME" --arg secrets "$SECRETS_NAME" --arg ts "$TS" --arg host "$HOSTNAME" \
    '{bundle:$bundle,secrets:$secrets,ts:$ts,host:$host}' > "$OUTDIR/$LATEST_JSON"
  rclone copyto "$OUTDIR/$LATEST_JSON" "${DRIVE_REMOTE}:${DRIVE_PREFIX}/latest/LATEST.json" --progress

  log "Done."
}

main "$@"
