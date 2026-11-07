#!/usr/bin/env bash
# Make Docker start AFTER the WireGuard tunnel is up.
#
# Why: when container ports are published on the tunnel address (for example
# 10.0.0.1:8080) and Docker starts before the wg interface exists, publishing
# fails with "bind: cannot assign requested address". By default docker and
# wg-quick are both ordered only after network-online.target, not relative to
# each other - a race that is decided at random on every boot.
#
# This installs a systemd drop-in. It affects EVERY docker stack on the host.
#
#   sudo ./setup-boot-order.sh --dry-run     # print what would be installed
#   sudo ./setup-boot-order.sh               # install and verify
#   sudo ./setup-boot-order.sh --reboot      # install, verify, reboot in 5 s
#   WG_IFACE=wg1 sudo -E ./setup-boot-order.sh
set -euo pipefail

WG_IFACE="${WG_IFACE:-wg0}"
DIR=/etc/systemd/system/docker.service.d
CONF="$DIR/10-wireguard-order.conf"

content="[Unit]
# Ports are bound to the address of the tunnel interface ${WG_IFACE}.
# Wants, not Requires: if the tunnel fails to come up docker must still start -
# better containers without the published port than no containers at all.
After=wg-quick@${WG_IFACE}.service
Wants=wg-quick@${WG_IFACE}.service
"

if [ "${1:-}" = "--dry-run" ]; then
    echo "# would write $CONF:"
    printf '%s' "$content"
    exit 0
fi

[ "$(id -u)" -eq 0 ] || { echo "run as root: sudo $0 $*" >&2; exit 1; }

mkdir -p "$DIR"
printf '%s' "$content" > "$CONF"
chmod 644 "$CONF"
echo "written: $CONF"
systemctl daemon-reload

echo "== verification =="
if systemctl show docker.service -p After | tr ' ' '\n' | grep -q "wg-quick@${WG_IFACE}"; then
    echo "docker.service is now ordered After=wg-quick@${WG_IFACE}: YES"
else
    echo "docker.service is NOT ordered after wg-quick@${WG_IFACE}: something went wrong" >&2
    exit 1
fi

if [ "${1:-}" = "--reboot" ]; then
    echo "rebooting in 5 s, Ctrl+C to cancel"
    sleep 5
    systemctl reboot
fi
echo "Done. After the next reboot check:  docker ps  and  ss -ltn | grep <tunnel address>"
