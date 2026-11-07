# vps-selfhost-stack

Small, boring building blocks for running a few Docker Compose services on **one VPS** without turning it into a liability: services reachable **only over WireGuard**, **verified** nightly SQLite backups with a restore test, a **boot order** that survives reboots, and a Telegram alert when something silently stops.

These are cleaned-up versions of scripts I run on my own server (several Compose stacks behind one WireGuard interface). All names, addresses and ports here are placeholders.

> Українською коротко: шаблони для невеликого VPS — сервіси лише за WireGuard, нічні бекапи SQLite з перевіркою й тестом відновлення, порядок старту Docker після тунелю, сповіщення в Telegram, коли щось тихо зламалось. Нижче англійською; `make test` перевіряє скрипти.

## The four ideas

1. **Nothing that manages the server is on the public internet.** Container ports are published on the tunnel address (`10.0.0.1:8080`), and the firewall rule says *from the admin subnet*, not *from anywhere*. `ufw allow from <subnet> to any port 8080` is a different statement from `ufw allow 8080`.
2. **A backup is only real after it passes a check.** Snapshots use `VACUUM INTO` (safe for WAL databases that are written to all the time), get an `integrity_check` and an optional row-count floor, and old archives are rotated **only after** the fresh one is verified. A run of broken backups can never push the good ones out.
3. **A backup that was never restored is a hope.** `restore-check.sh` unpacks an archive and runs the same checks, listing every table with its row count.
4. **Silent failure is the real enemy.** A watchdog complains when the newest archive is older than 26 hours, so a cron job that quietly stopped does not go unnoticed for months.

## Layout

| Path | What it does |
|---|---|
| `scripts/sqlite-backup.sh` | Verified, rotated backup of a SQLite database. Host mode or Docker mode (snapshot is made inside the container) |
| `scripts/restore-check.sh` | Restore test: unpack, `integrity_check`, table row counts |
| `scripts/check-backup-fresh.sh` | Alerts when the newest archive is missing or too old |
| `scripts/notify-telegram.sh` | Sends a Telegram message; the bot token comes from a `chmod 600` env file and goes to `curl` through stdin, never through arguments |
| `scripts/setup-boot-order.sh` | systemd drop-in: Docker starts **after** `wg-quick@wg0`, so ports bound to the tunnel address do not fail with `cannot assign requested address` |
| `scripts/ufw-wireguard-only.sh` | Firewall policy: SSH rate-limited, WireGuard port open, app ports only from the admin subnet. Dry run by default |
| `compose/` | Example stack with the port published on the WireGuard address only |
| `cron/crontab.example` | 04:30 backup + 09:00 freshness check |
| `tests/` | 35 checks, no Docker needed (a shim stands in for `docker compose exec`) |

## Quick start

```bash
git clone https://github.com/RomaFil/vps-selfhost-stack ~/vps-selfhost-stack
cd ~/vps-selfhost-stack && make test            # all checks should pass

# 1. firewall (read the printed commands first!)
SSH_PORT=22 WG_PORT=51820 WG_SUBNET=10.0.0.0/24 APP_PORTS="8000" scripts/ufw-wireguard-only.sh
# 2. boot order
sudo scripts/setup-boot-order.sh --dry-run && sudo scripts/setup-boot-order.sh
# 3. a service on the tunnel address
cp compose/.env.example compose/.env && (cd compose && docker compose up -d)
# 4. backup + restore test
BACKUP_NAME=myapp DB_PATH=/data/app.db COMPOSE_DIR=$HOME/myapp SERVICE=app scripts/sqlite-backup.sh
scripts/restore-check.sh ~/backups/myapp myapp
# 5. alerts
sudo install -d -m 700 /etc/vps-stack      # then create telegram.env, see notify-telegram.sh
```

**Done when:** `restore-check.sh` ends with `RESTORE OK`, `ss -ltn` shows your service on the tunnel address only, and after a reboot `docker ps` shows the containers running.

## What is tested, and what is not

- `make test` (35 checks, run on Ubuntu): backup in host mode and in Docker mode through a shim, `gzip -t`, file mode 600, rotation (`KEEP`), **a failing run leaves the existing archives untouched**, the failure notification, restore test (good and corrupt archive), freshness watchdog, Telegram script refusing a world-readable env file, dry runs of the boot-order and firewall scripts (including rejection of a malformed port list).
- **Not tested here:** real Docker (only the shim), a live `ufw`/`systemd` (dry runs only), the Telegram API call itself. The boot-order drop-in is the generalised version of the one I installed on my own VPS and verified with a reboot.
- `--apply` of the firewall script enables ufw: keep a second SSH session open.

## Limits, stated honestly

- SQLite only. For PostgreSQL/MySQL use their dump tools and keep the same three rules (verify, then rotate; test the restore; alert on staleness).
- Docker mode needs `python` inside the container image.
- Backups stay on the same server. Copy them off-site (rsync/restic to another host) if the server itself is the risk.

## Related

[vps-vpn-hardening](https://github.com/RomaFil/vps-vpn-hardening): the WireGuard management-plane design and an audit checklist.

MIT licensed.
