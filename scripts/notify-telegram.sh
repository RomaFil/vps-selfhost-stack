#!/usr/bin/env bash
# Send one message to a Telegram chat. The bot token is read from a root-only
# env file and handed to curl through stdin, so it never appears in the process
# list, the shell history or the arguments of this script.
#
#   /etc/vps-stack/telegram.env   (chmod 600)
#       BOT_TOKEN=123456:replace-me
#       CHAT_ID=123456789
#
#   notify-telegram.sh "backup failed on host1"
#   DRY_RUN=1 notify-telegram.sh "just print it"
set -euo pipefail

msg="${1:?usage: notify-telegram.sh <message>}"
env_file="${TG_ENV_FILE:-/etc/vps-stack/telegram.env}"

if [ "${DRY_RUN:-0}" = "1" ]; then
    echo "[dry-run] would send: $msg"
    exit 0
fi
if [ ! -f "$env_file" ]; then
    echo "notify-telegram: $env_file not found, message not sent: $msg" >&2
    exit 1
fi
mode="$(stat -c %a "$env_file")"
if [ "$mode" != "600" ] && [ "$mode" != "400" ]; then
    echo "notify-telegram: $env_file must be chmod 600 (is $mode)" >&2
    exit 1
fi

BOT_TOKEN=""; CHAT_ID=""
while IFS='=' read -r key value; do
    case "$key" in
        BOT_TOKEN) BOT_TOKEN="$value" ;;
        CHAT_ID)   CHAT_ID="$value" ;;
    esac
done < "$env_file"
[ -n "$BOT_TOKEN" ] && [ -n "$CHAT_ID" ] || { echo "notify-telegram: BOT_TOKEN or CHAT_ID missing in $env_file" >&2; exit 1; }

printf 'url = "https://api.telegram.org/bot%s/sendMessage"\n' "$BOT_TOKEN" \
    | curl -sS --fail --max-time 20 -K - \
        --data-urlencode "chat_id=$CHAT_ID" \
        --data-urlencode "text=$msg" > /dev/null
