#!/usr/bin/env bash
# Прототип ST-1: временный проект Godot вне репозитория, headless.
# Вариант A: с расширением, без инициализации (загрузка).      -> STEAM_PROBE loaded=true init=skipped
# Вариант B: с расширением, steamInitEx(480) (клиент не нужен для кода статуса). -> STEAM_PROBE loaded=true init=2/...
# Вариант C: без расширения — игра не должна падать.           -> STEAM_PROBE loaded=false init=none
# Вариант E: расширение без libsteam_api.so.
# Вариант D: только если клиент Steam запущен (pgrep -x steam): инициализация на 480.
# Выход 0 только если A дал loaded=true, C дал loaded=false и ни один запуск не упал.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
GODOT="${GODOT:-godot}"
P="$(mktemp -d)"; trap 'rm -rf "$P"' EXIT
cat > "$P/project.godot" <<'PG'
config_version=5
[application]
config/name="steam_probe"
PG
cp "$HERE/probe.gd" "$P/probe.gd"
bash "$HERE/fetch_godotsteam.sh" "$P" >&2 || { echo "STEAM_PROBE loaded=false init=fetch_failed"; exit 1; }
run() { # $1 — метка, остальное — аргументы
  local tag="$1"; shift
  local out
  out="$(cd "$P" && XDG_DATA_HOME="$(mktemp -d)" timeout 60 "$GODOT" --headless --path "$P" -s probe.gd -- "$@" 2>&1)"
  local rc=$?
  echo "$out" | grep -E 'STEAM_PROBE|ERROR|SCRIPT ERROR' | sed "s/^/[$tag] /" | head -8
  echo "[$tag] exit=$rc"
  return $rc
}
rc_all=0
# Импорт проекта строит .godot/extension_list.cfg. Наблюдение ST-1: первый --import свежего проекта
# с расширением завершается SIGABRT при выходе (работа сделана, файл записан), поэтому импорт два раза.
imp() { ( (cd "$P" && XDG_DATA_HOME="$(mktemp -d)" timeout 120 "$GODOT" --headless --path "$P" --import >/dev/null 2>&1) ) 2>/dev/null || true; }
imp; imp
run "A with-ext noinit" noinit || rc_all=1
run "B with-ext init-480" appid=480 || rc_all=1
if pgrep -x steam >/dev/null; then
  echo "[D] клиент Steam запущен"; run "D client-480" appid=480 || rc_all=1
else
  echo "[D] клиент Steam не запущен — вариант D пропущен"
fi
# E: расширение есть, а библиотека libsteam_api.so потеряна — в логе ERROR, но игра жива, loaded=false
mv "$P/addons/godotsteam/linux64/libsteam_api.so" "$P/libsteam_api.so.bak"
run "E ext-without-libsteam_api" appid=480 || rc_all=1
mv "$P/libsteam_api.so.bak" "$P/addons/godotsteam/linux64/libsteam_api.so"
# C: без расширения вообще
rm -rf "$P/addons" "$P/.godot"; imp
run "C no-ext" appid=480 || rc_all=1
exit $rc_all
