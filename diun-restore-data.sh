#!/bin/bash

# Restore Diun's data directory from one of the archives the `backups`
# container has taken.
#
# That directory holds one small database: the images Diun has already seen and
# the digests they resolved to.
#
#     chmod +x diun-restore-data.sh
#     ./diun-restore-data.sh
#
# Be clear about what this is for, because it is not disaster recovery. Losing
# the database costs nothing permanent — the next scan rebuilds it from what is
# running. What it costs is quiet: with DIUN_WATCH_FIRSTCHECKNOTIF on, a
# rebuilt database treats every image as new and sends one message per image
# you run. Restoring is how you avoid that.
set -euo pipefail
cd "$(dirname "$0")"

COMPOSE_FILE="${DOCKER_COMPOSE_FILE:-diun-docker-compose.yml}"
PROJECT="${COMPOSE_PROJECT_NAME:-diun}"
BACKUP_PATH="${DATA_BACKUPS_PATH:-/srv/diun-data/backups}"
RESTORE_PATH="${DATA_PATH:-/data}"

dc() { docker compose -f "$COMPOSE_FILE" -p "$PROJECT" "$@"; }

APP_CONTAINER="$(dc ps -aq diun | head -n 1)"
BACKUPS_CONTAINER="$(dc ps -aq backups | head -n 1)"
[ -n "$APP_CONTAINER" ] || { echo "the diun container was not found — is the stack up?" >&2; exit 1; }
[ -n "$BACKUPS_CONTAINER" ] || { echo "the backups container was not found — is the stack up?" >&2; exit 1; }

echo "--> All available data backups:"
docker exec "$BACKUPS_CONTAINER" sh -c "ls -1 $BACKUP_PATH" || true

echo "--> Copy and paste the backup name from the list above and press [ENTER]
--> Example: diun-data-backup-YYYY-MM-DD_hh-mm.tar.gz"
echo -n "--> "
read -r SELECTED
[ -n "$SELECTED" ] || { echo "nothing selected, nothing restored" >&2; exit 1; }

if ! docker exec "$BACKUPS_CONTAINER" sh -c "tar -tzf '${BACKUP_PATH}/${SELECTED}' > /dev/null"; then
  echo "that file is not a readable tar archive — nothing has been stopped or deleted" >&2
  exit 1
fi
echo "--> $SELECTED was selected and reads as a valid archive"

echo "--> Stopping Diun..."
docker stop "$APP_CONTAINER" > /dev/null

echo "--> Restoring the data directory..."
# The archive stores paths relative to /, so it extracts there. The directory
# is emptied first: a merge would leave two databases and no way to tell which
# one Diun opens.
docker exec "$BACKUPS_CONTAINER" sh -c "rm -rf '${RESTORE_PATH:?}'/* && tar -zxpf '${BACKUP_PATH}/${SELECTED}' -C /"
echo "--> Data recovery completed."

echo "--> Starting Diun..."
docker start "$APP_CONTAINER" > /dev/null
echo "--> The next scheduled scan compares against the restored digests."
echo "--> Anything published while the archive was stale reports then."
