#!/usr/bin/env bash
set -euo pipefail

DRIVE_REMOTE=${DRIVE_REMOTE:-drive}
DRIVE_PREFIX=${DRIVE_PREFIX:-mimo-backups/prod}
OUTDIR=${OUTDIR:-/home/hoangtung/Documents/mimo-backup-out}
HOSTNAME=${HOSTNAME:-$(hostname -s)}
TS=${TS:-$(date -u +%Y%m%dT%H%M%SZ)}

mkdir -p "$OUTDIR"

bundle_name="mimo-system-bundle-${HOSTNAME}-${TS}.tar.zst"

# Placeholder: will add pg_dump + qdrant snapshot + redis + configs

echo "TODO: implement actual backup bundle creation at $OUTDIR/$bundle_name" >&2
exit 1
