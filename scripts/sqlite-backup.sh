#!/usr/bin/env bash
# Nightly, verified backup of a SQLite database (WAL-safe).
#
# Two rules, both learned the hard way:
#   1. Snapshot with VACUUM INTO, not cp: a WAL-mode database that is written to
#      every minute can be caught mid-transaction by a plain file copy.
#   2. Rotate old archives ONLY after the fresh one has been verified.
#      Otherwise a run of broken backups pushes the good ones out.
#
# Two modes:
#   host mode   - DB_PATH is a file on this machine, python3 (>= 3.27 sqlite) is installed
#   docker mode - set COMPOSE_DIR and SERVICE; the snapshot is made inside the
#                 container (it needs python) and streamed out, DB_PATH is the
#                 path INSIDE the container
#
# Configuration (environment variables):
#   BACKUP_NAME   archive prefix, e.g. myapp                          (required)
#   DB_PATH       path of the database                                (required)
#   BACKUP_DIR    where archives go            (default ~/backups/$BACKUP_NAME)
#   KEEP          how many newest archives to keep              (default 14)
#   CHECK_TABLE   optional table whose row count is sanity-checked
#   MIN_ROWS      fail when CHECK_TABLE has fewer rows           (default 1)
#   COMPOSE_DIR, SERVICE   docker mode
#   NOTIFY_CMD    optional command, called with one message argument on failure
set -euo pipefail
# cron starts with a minimal PATH; add the usual directories (docker lives in one of them)
export PATH="$PATH:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

NAME="${BACKUP_NAME:?set BACKUP_NAME}"
DB_PATH="${DB_PATH:?set DB_PATH}"
DEST="${BACKUP_DIR:-$HOME/backups/$NAME}"
KEEP="${KEEP:-14}"
CHECK_TABLE="${CHECK_TABLE:-}"
MIN_ROWS="${MIN_ROWS:-1}"
COMPOSE_DIR="${COMPOSE_DIR:-}"
SERVICE="${SERVICE:-}"
NOTIFY_CMD="${NOTIFY_CMD:-}"

mkdir -p "$DEST"
LOG="$DEST/backup.log"
say() { echo "$(date '+%F %T') $*" >> "$LOG"; }
die() {
    say "ERROR: $*"
    echo "ERROR: $*" >&2
    if [ -n "$NOTIFY_CMD" ]; then "$NOTIFY_CMD" "backup $NAME FAILED on $(hostname): $*" || true; fi
    exit 1
}

if [ -n "$CHECK_TABLE" ] && ! [[ "$CHECK_TABLE" =~ ^[A-Za-z0-9_]+$ ]]; then
    die "CHECK_TABLE must be a plain table name"
fi
case "$KEEP" in ''|*[!0-9]*) die "KEEP must be a number" ;; esac
[ "$KEEP" -ge 1 ] || die "KEEP must be at least 1"

if [ -n "$COMPOSE_DIR" ]; then
    [ -n "$SERVICE" ] || die "docker mode needs SERVICE"
    SNAP="$(dirname "$DB_PATH")/.backup-snapshot.db"          # inside the container
    run_py() { (cd "$COMPOSE_DIR" && docker compose exec -T "$SERVICE" python - "$@"); }
else
    SNAP="$DEST/.snapshot.$$.db"                                # on this machine
    run_py() { python3 - "$@"; }
fi

TMP="$(mktemp "$DEST/.tmp.XXXXXX")"
cleanup() {
    rm -f "$TMP" "$DEST/.snapshot.$$.db"
    if [ -n "$COMPOSE_DIR" ]; then
        (cd "$COMPOSE_DIR" && docker compose exec -T "$SERVICE" sh -c "rm -f '$SNAP'") >/dev/null 2>&1 || true
    fi
}
trap cleanup EXIT

PY='
import os, sqlite3, sys
db, snap, table, min_rows = sys.argv[1], sys.argv[2], sys.argv[3], int(sys.argv[4])
if os.path.exists(snap):
    os.remove(snap)
src = sqlite3.connect(db, timeout=120)
src.execute("PRAGMA busy_timeout=120000")
src.execute("VACUUM INTO ?", (snap,))
src.close()
chk = sqlite3.connect(snap)
if chk.execute("PRAGMA integrity_check").fetchone()[0] != "ok":
    sys.exit("integrity_check failed")
msg = "integrity=ok"
if table:
    n = chk.execute("SELECT COUNT(*) FROM \"%s\"" % table).fetchone()[0]
    if n < min_rows:
        sys.exit("%s has only %d rows, below the floor of %d" % (table, n, min_rows))
    msg += " %s=%d" % (table, n)
chk.close()
print(msg)
'

# 1. snapshot + integrity check (inside the container in docker mode)
summary="$(printf '%s' "$PY" | run_py "$DB_PATH" "$SNAP" "$CHECK_TABLE" "$MIN_ROWS")" \
    || die "snapshot failed verification: ${summary:-no output}"
summary="$(echo "$summary" | tr -d '\r')"

# 2. get the snapshot to this machine
if [ -n "$COMPOSE_DIR" ]; then
    (cd "$COMPOSE_DIR" && docker compose exec -T "$SERVICE" cat "$SNAP") > "$TMP" \
        || die "could not stream the snapshot out of the container"
else
    mv "$SNAP" "$TMP"
fi
[ -s "$TMP" ] || die "the snapshot is empty"

# 3. compress, verify the archive, publish atomically
OUT="$DEST/$NAME-$(date +%F).db.gz"
gzip -c "$TMP" > "$OUT.part" || die "gzip failed"
gzip -t "$OUT.part" || die "the archive does not pass gzip -t"
mv "$OUT.part" "$OUT"
chmod 600 "$OUT"
say "ok: $OUT, $summary, $(stat -c%s "$OUT") bytes"

# 4. rotation - only now that the fresh archive is verified
ls -1t "$DEST"/"$NAME"-*.db.gz 2>/dev/null | tail -n +"$((KEEP + 1))" | xargs -r rm -f
say "rotation: $(ls -1 "$DEST"/"$NAME"-*.db.gz | wc -l) archives kept"
