#!/usr/bin/env bash
# Restore test: a backup that has never been restored is only a hope.
# Unpacks an archive into a temp dir, runs PRAGMA integrity_check and prints
# every table with its row count. Exit code 0 only when the database is sound.
#
#   restore-check.sh /path/to/myapp-2026-11-07.db.gz
#   restore-check.sh /path/to/backup-dir myapp      # newest archive for a prefix
set -euo pipefail

target="${1:?usage: restore-check.sh <archive.db.gz | backup-dir> [name-prefix]}"
if [ -d "$target" ]; then
    prefix="${2:?give the archive prefix when a directory is passed}"
    archive="$(ls -1t "$target"/"$prefix"-*.db.gz 2>/dev/null | head -n 1 || true)"
    [ -n "$archive" ] || { echo "no archives for prefix $prefix in $target" >&2; exit 1; }
else
    archive="$target"
fi
[ -f "$archive" ] || { echo "no such file: $archive" >&2; exit 1; }

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
gzip -dc "$archive" > "$work/restored.db"

python3 - "$work/restored.db" "$archive" <<'PY'
import sqlite3, sys
db, archive = sys.argv[1], sys.argv[2]
con = sqlite3.connect(db)
if con.execute("PRAGMA integrity_check").fetchone()[0] != "ok":
    sys.exit("RESTORE FAILED: integrity_check did not return ok")
tables = [r[0] for r in con.execute("SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%' ORDER BY name")]
if not tables:
    sys.exit("RESTORE FAILED: the database has no tables")
print("archive:", archive)
for t in tables:
    print("  %-30s %d rows" % (t, con.execute('SELECT COUNT(*) FROM "%s"' % t.replace('"', '""')).fetchone()[0]))
print("RESTORE OK")
PY
