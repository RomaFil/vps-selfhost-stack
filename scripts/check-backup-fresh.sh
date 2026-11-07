#!/usr/bin/env bash
# Watchdog for the backup itself: a cron job that silently stops is the usual way
# backups die. Run this a few hours AFTER the backup time; it complains when the
# newest archive is missing or older than MAX_AGE_HOURS.
#
#   BACKUP_DIR=~/backups/myapp BACKUP_NAME=myapp NOTIFY_CMD=./notify-telegram.sh ./check-backup-fresh.sh
set -euo pipefail

NAME="${BACKUP_NAME:?set BACKUP_NAME}"
DEST="${BACKUP_DIR:-$HOME/backups/$NAME}"
MAX_AGE_HOURS="${MAX_AGE_HOURS:-26}"
NOTIFY_CMD="${NOTIFY_CMD:-}"

newest="$(ls -1t "$DEST"/"$NAME"-*.db.gz 2>/dev/null | head -n 1 || true)"
msg=""
if [ -z "$newest" ]; then
    msg="no backup archives for $NAME in $DEST"
else
    age_h=$(( ( $(date +%s) - $(stat -c %Y "$newest") ) / 3600 ))
    if [ "$age_h" -gt "$MAX_AGE_HOURS" ]; then
        msg="newest backup of $NAME is ${age_h} h old (limit ${MAX_AGE_HOURS} h): $newest"
    fi
fi

if [ -n "$msg" ]; then
    echo "STALE: $msg" >&2
    if [ -n "$NOTIFY_CMD" ]; then "$NOTIFY_CMD" "$(hostname): $msg" || true; fi
    exit 1
fi
echo "fresh: $newest"
