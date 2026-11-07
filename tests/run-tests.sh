#!/usr/bin/env bash
# Tests for the scripts. Needs bash, python3 (sqlite >= 3.27), gzip, coreutils.
# Docker is NOT needed: docker mode is exercised through a tiny shim (tests/shim/docker)
# that runs "docker compose exec -T <svc> <cmd>" on this machine.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
S="$ROOT/scripts"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
pass=0; fail=0
ok()   { pass=$((pass + 1)); echo "  ok    $1"; }
bad()  { fail=$((fail + 1)); echo "  FAIL  $1"; }
check() { local name="$1"; shift; if "$@" >/dev/null 2>&1; then ok "$name"; else bad "$name"; fi; }
check_not() { local name="$1"; shift; if "$@" >/dev/null 2>&1; then bad "$name"; else ok "$name"; fi; }

# sample database in WAL mode with 1500 rows
DB="$WORK/app.db"
python3 - "$DB" <<'PY'
import sqlite3, sys
con = sqlite3.connect(sys.argv[1])
con.execute("PRAGMA journal_mode=WAL")
con.execute("CREATE TABLE events(id INTEGER PRIMARY KEY, note TEXT)")
con.executemany("INSERT INTO events(note) VALUES (?)", [("row %d" % i,) for i in range(1500)])
con.commit(); con.close()
PY

echo "syntax"
for f in "$S"/*.sh "$0"; do check "bash -n $(basename "$f")" bash -n "$f"; done

echo "backup, host mode"
B="$WORK/b1"
export BACKUP_NAME=app DB_PATH="$DB" BACKUP_DIR="$B" KEEP=3 CHECK_TABLE=events MIN_ROWS=1000
check "backup exits 0" bash "$S/sqlite-backup.sh"
arch="$(ls -1 "$B"/app-*.db.gz 2>/dev/null | head -n 1)"
check "archive was created"            test -n "$arch"
check "archive passes gzip -t"          gzip -t "$arch"
check "archive is chmod 600"            test "$(stat -c %a "$arch")" = "600"
check "log mentions the row count"      grep -q "events=1500" "$B/backup.log"
check "no leftover temp files"          test -z "$(ls -A "$B" | grep -E '^\.(tmp|snapshot)' || true)"
check "restore-check accepts it"        bash "$S/restore-check.sh" "$arch"
check "restore-check by directory"      bash "$S/restore-check.sh" "$B" app

echo "rotation happens only after a verified archive"
for d in 01 02 03 04 05; do
    echo old | gzip -c > "$B/app-2026-01-$d.db.gz"
    touch -d "2026-01-$d 04:00" "$B/app-2026-01-$d.db.gz"
done
bash "$S/sqlite-backup.sh" >/dev/null 2>&1
check "KEEP=3 leaves exactly 3 archives" test "$(ls -1 "$B"/app-*.db.gz | wc -l)" -eq 3
check "the newest one is today's"        test -f "$B/app-$(date +%F).db.gz"

echo "a failing run must not delete good archives"
before="$(ls -1 "$B"/app-*.db.gz | wc -l)"
cnt_file="$WORK/notified.txt"
cat > "$WORK/notify.sh" <<EOF
#!/usr/bin/env bash
echo "\$1" >> "$cnt_file"
EOF
chmod +x "$WORK/notify.sh"
MIN_ROWS=999999 KEEP=1 NOTIFY_CMD="$WORK/notify.sh" bash "$S/sqlite-backup.sh" >/dev/null 2>&1
rc=$?
check "failing run exits non-zero"       test "$rc" -ne 0
check "archives are untouched"           test "$(ls -1 "$B"/app-*.db.gz | wc -l)" -eq "$before"
check "NOTIFY_CMD was called"            grep -q "FAILED" "$cnt_file"

echo "backup, docker mode (via shim)"
B2="$WORK/b2"; mkdir -p "$WORK/compose"
PATH="$ROOT/tests/shim:$PATH" BACKUP_DIR="$B2" COMPOSE_DIR="$WORK/compose" SERVICE=web \
    bash "$S/sqlite-backup.sh" >/dev/null 2>&1
check "docker-mode archive was created"  test -n "$(ls -1 "$B2"/app-*.db.gz 2>/dev/null)"
check "docker-mode restore-check"        bash "$S/restore-check.sh" "$B2" app

echo "corrupt archive is rejected by restore-check"
echo "not a database" | gzip -c > "$WORK/bad.db.gz"
check_not "restore-check fails on garbage" bash "$S/restore-check.sh" "$WORK/bad.db.gz"

echo "freshness watchdog"
unset CHECK_TABLE MIN_ROWS
check "fresh archive passes"             env BACKUP_DIR="$B" BACKUP_NAME=app bash "$S/check-backup-fresh.sh"
touch -d "3 days ago" "$B"/app-*.db.gz
: > "$cnt_file"
check_not "stale archive fails"          env BACKUP_DIR="$B" BACKUP_NAME=app NOTIFY_CMD="$WORK/notify.sh" bash "$S/check-backup-fresh.sh"
check "stale archive notifies"           grep -q "old" "$cnt_file"
check_not "empty directory fails"        env BACKUP_DIR="$WORK/nothing" BACKUP_NAME=app bash "$S/check-backup-fresh.sh"

echo "telegram notifier"
check "dry run prints the message"       env DRY_RUN=1 bash "$S/notify-telegram.sh" "hello"
printf 'BOT_TOKEN=x\nCHAT_ID=1\n' > "$WORK/tg.env"; chmod 644 "$WORK/tg.env"
check_not "refuses a world-readable env" env TG_ENV_FILE="$WORK/tg.env" bash "$S/notify-telegram.sh" "hello"
check_not "refuses a missing env file"   env TG_ENV_FILE="$WORK/none.env" bash "$S/notify-telegram.sh" "hello"

echo "boot order and firewall (dry runs)"
check "drop-in orders docker after wg0"  bash -c "'$S/setup-boot-order.sh' --dry-run | grep -q 'After=wg-quick@wg0.service'"
check "WG_IFACE is respected"            bash -c "WG_IFACE=wg1 '$S/setup-boot-order.sh' --dry-run | grep -q 'wg-quick@wg1.service'"
check "ufw rule is subnet-scoped"        bash -c "APP_PORTS='8080' '$S/ufw-wireguard-only.sh' | grep -q 'ufw allow from 10.0.0.0/24 to any port 8080'"
check_not "no bare public allow of the app port" bash -c "APP_PORTS='8080' '$S/ufw-wireguard-only.sh' | grep -E '^ufw allow 8080'"
check_not "bad port list is rejected"    env APP_PORTS="80;reboot" bash "$S/ufw-wireguard-only.sh"

echo
echo "passed: $pass, failed: $fail"
[ "$fail" -eq 0 ]
