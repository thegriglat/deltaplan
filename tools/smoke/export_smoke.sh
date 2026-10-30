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
out="build/smoke/RW-29/$os"
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
game_rc=$?
echo "game rc=$game_rc" | tee "$out/summary.txt"
for pat in "dp_air: расширение загружено" "dp_air: READY" "Рассчитываем ветер" "game: фаза flying" "FAILED" "SCRIPT ERROR" "Screenshot"; do
	printf '%s: %s\n' "$pat" "$(grep -c -- "$pat" "$log")" | tee -a "$out/summary.txt"
done
fail=0
chk() { echo "CHECK $1: $2" | tee -a "$out/summary.txt"; [[ "$2" == ok ]] || fail=1; }
[[ $game_rc -eq 0 ]] && chk game_rc ok || chk game_rc "FAIL rc=$game_rc"
grep -q "dp_air: расширение загружено, api_version=6" "$log" && chk dp_air_api6 ok || chk dp_air_api6 FAIL
grep -q "dp_air: READY" "$log" && chk ready ok || chk ready FAIL
! grep -qE "FAILED|SCRIPT ERROR" "$log" && chk no_errors ok || chk no_errors FAIL
# фаза flying и ветер ≠ 0 — строка игры: «game: фаза flying, ветер у крыла X м/с»
wind=$(grep -o "game: фаза flying, ветер у крыла [0-9.]* м/с" "$log" | head -1 | grep -o "[0-9.]* м/с" | cut -d' ' -f1)
echo "ветер у крыла: ${wind:-нет строки}" | tee -a "$out/summary.txt"
[[ -n "$wind" ]] && chk phase_flying ok || chk phase_flying FAIL
[[ -n "$wind" ]] && awk -v w="$wind" 'BEGIN{exit !(w>0.1)}' && chk wind_nonzero ok || chk wind_nonzero FAIL

# 2. дымовая сцена расширения (ветер у земли != 0) — подмена главной сцены через override.cfg
cp build/$os/override.cfg "$out/override.cfg.bak" 2>/dev/null || true
printf '[application]\nrun/main_scene="res://addons/dp_air/smoke.tscn"\n' >build/$os/override.cfg
slog="$out/ext.log"
(cd build/$os && XDG_DATA_HOME="$prof/xdg" timeout 400 "${run[@]}" --headless) >"$slog" 2>&1
ext_rc=$?
echo "ext rc=$ext_rc" | tee -a "$out/summary.txt"
rm -f build/$os/override.cfg
grep -E "DP_AIR_SMOKE" "$slog" | tail -6 | tee -a "$out/summary.txt"
grep -q "^DP_AIR_SMOKE OK" "$slog" && [[ $ext_rc -eq 0 ]] && chk ext_smoke ok || chk ext_smoke FAIL
ls -l "$out/shot.png" 2>&1 | tee -a "$out/summary.txt"
[[ -s "$out/shot.png" ]] && chk shot ok || chk shot FAIL
if [[ $fail -eq 0 ]]; then echo "EXPORT_SMOKE OK ($os)"; else echo "EXPORT_SMOKE FAIL ($os)" >&2; exit 1; fi
