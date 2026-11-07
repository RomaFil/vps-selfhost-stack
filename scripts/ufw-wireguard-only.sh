#!/usr/bin/env bash
# Firewall policy for a small VPS where everything that manages the server
# lives behind WireGuard. Prints the commands by default; --apply runs them.
#
#   SSH_PORT=22 WG_PORT=51820 WG_SUBNET=10.0.0.0/24 APP_PORTS="8080 3000" ./ufw-wireguard-only.sh
#   ... ./ufw-wireguard-only.sh --apply
#
# The line that matters:   ufw allow from <WG_SUBNET> to any port <APP_PORT>
# is a different statement from                ufw allow <APP_PORT>
# The first exposes the service to the admin tunnel only; the second to the world.
#
# WARNING: --apply enables ufw. Keep a second SSH session open and make sure
# SSH_PORT is correct before you run it, or you will lock yourself out.
set -euo pipefail

SSH_PORT="${SSH_PORT:-22}"
WG_PORT="${WG_PORT:-51820}"
WG_SUBNET="${WG_SUBNET:-10.0.0.0/24}"
APP_PORTS="${APP_PORTS:-8080}"

cmds=(
    "ufw default deny incoming"
    "ufw default allow outgoing"
    "ufw limit ${SSH_PORT}/tcp comment 'ssh, rate limited'"
    "ufw allow ${WG_PORT}/udp comment 'wireguard'"
)
for p in $APP_PORTS; do
    case "$p" in ''|*[!0-9]*) echo "APP_PORTS must be numbers, got: $p" >&2; exit 1 ;; esac
    cmds+=("ufw allow from ${WG_SUBNET} to any port ${p} proto tcp comment 'app ${p}, admin subnet only'")
done
cmds+=("ufw --force enable" "ufw status verbose")

if [ "${1:-}" != "--apply" ]; then
    echo "# dry run - nothing was changed. Re-run with --apply to execute:"
    printf '%s\n' "${cmds[@]}"
    exit 0
fi
[ "$(id -u)" -eq 0 ] || { echo "run as root: sudo $0 --apply" >&2; exit 1; }
for c in "${cmds[@]}"; do
    echo "+ $c"
    eval "$c"
done
