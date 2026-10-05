#!/usr/bin/env bash
# Живая проверка на App ID 480. Ждёт клиент Steam до $1 секунд (по умолчанию 0 — не ждать); без клиента — выход 3.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"; GODOT="${GODOT:-godot}"
WAIT="${1:-0}"; t=0
while ! pgrep -x steam >/dev/null; do
  [ "$t" -ge "$WAIT" ] && { echo "LIVE skipped: клиент Steam не запущен"; exit 3; }
  sleep 2; t=$((t+2))
done
P="$(mktemp -d)"; trap 'rm -rf "$P"' EXIT
printf 'config_version=5\n[application]\nconfig/name="steam_live"\n' > "$P/project.godot"
bash "$HERE/fetch_godotsteam.sh" "$P" >&2; cp "$HERE/live_check.gd" "$P/"
imp() { ( (cd "$P" && XDG_DATA_HOME="$(mktemp -d)" timeout 120 "$GODOT" --headless --path "$P" --import >/dev/null 2>&1) ) 2>/dev/null || true; }
imp; imp
XDG_DATA_HOME="$(mktemp -d)" timeout 90 "$GODOT" --headless --path "$P" -s live_check.gd 2>&1 | grep -E '^LIVE|ERROR|S_API'
