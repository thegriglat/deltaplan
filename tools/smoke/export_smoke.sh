#!/usr/bin/env bash
# RW-21a: smoke собранной игры (build/<платформа>/ из tools/build.sh): место грузится, DLL/so dp_air
# подхватилась, поле READY, ветер != 0, фаза flying.
#   tools/smoke/export_smoke.sh linux   [время_полёта_с=20]
#   tools/smoke/export_smoke.sh windows [время_полёта_с=20]   # под wine, чистый WINEPREFIX
# Игра: --autostart --bots=0 --time=N на встроенном месте; признаки — по журналу (stdout).
# Отдельно (расширение + ветер у земли без игры) — addons/dp_air/smoke.tscn через override.cfg.
set -uo pipefail
cd "$(dirname "$0")/../.."
os="${1:?linux|windows}"
ft="${2:-20}"
out="build/smoke/RW-21a/$os"
mkdir -p "$out"
export DISPLAY="${DISPLAY:-:0}"
prof=$(mktemp -d)
trap 'rm -rf "$prof"' EXIT
case "$os" in
linux) run=("$PWD/build/linux/deltaplan.x86_64") ;;
windows)
	export WINEPREFIX="$prof/wine" WINEDEBUG=-all
	run=(wine "$PWD/build/windows/deltaplan.exe")
	;;
*) echo "linux|windows" >&2; exit 2 ;;
esac
shotp="$PWD/$out/shot.png"; [[ "$os" == windows ]] && shotp="Z:${shotp//\//\\}"
args=(--audio-driver Dummy -- --autostart --location=training_island --site=thermal_plain --bots=0 --air-start "--time=$ft" "--screenshot=$shotp")

# 1. игра
log="$out/game.log"
XDG_DATA_HOME="$prof/xdg" timeout 600 "${run[@]}" "${args[@]}" >"$log" 2>&1
echo "game rc=$?" | tee "$out/summary.txt"
for pat in "dp_air: расширение загружено" "dp_air: READY" "Рассчитываем ветер" "FAILED" "SCRIPT ERROR" "Screenshot"; do
	printf '%s: %s\n' "$pat" "$(grep -c -- "$pat" "$log")" | tee -a "$out/summary.txt"
done

# 2. дымовая сцена расширения (ветер у земли != 0) — подмена главной сцены через override.cfg
cp build/$os/override.cfg "$out/override.cfg.bak" 2>/dev/null || true
printf '[application]\nrun/main_scene="res://addons/dp_air/smoke.tscn"\n' >build/$os/override.cfg
slog="$out/ext.log"
(cd build/$os && XDG_DATA_HOME="$prof/xdg" timeout 400 "${run[@]}" --headless) >"$slog" 2>&1
echo "ext rc=$?" | tee -a "$out/summary.txt"
rm -f build/$os/override.cfg
grep -E "DP_AIR_SMOKE" "$slog" | tail -6 | tee -a "$out/summary.txt"
ls -l "$out/shot.png" 2>&1 | tee -a "$out/summary.txt"
