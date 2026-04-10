# mimo-disaster-recovery

One-command recovery for the whole system.

## Target
- Storage: Google Drive via rclone remote `drive:`
- Drive prefix: `mimo-backups/prod/`

## Recover (on a fresh Ubuntu machine)
```bash
curl -fsSL https://raw.githubusercontent.com/lehoangtung01/mimo-disaster-recovery/main/mimo-recover.sh | sudo bash
```

The script will:
- install dependencies (docker, rclone, ...)
- download latest bundle from Drive
- decrypt secrets (asks passphrase)
- restore services + data (WIP)
