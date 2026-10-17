#!/bin/bash
# AWW-2: замер W1 до/после правки 1 (θ′·h механизма F). Пробник — копия AWW-1/probe.gd (окно — GPU, как lee_cal/run.sh).
# run.sh <метка> [main] — прогоны в out/<метка>/; с «main» правка временно снимается (git apply -R
# AWW-1/proto_theta_h.patch) и возвращается git checkout в конце. Режим calc (--nobake), сид — configs/atmosphere.json.
# Строки: 8 встроенных стартов (погода старта) + Онгудай/Аскарово в два дня (weak: --wind=2 --sky=clear,
# strong: --wind=5 --sky=partly; оба --hour=12 --from=launch). Параллельно 2 godot; предел расчёта в пробнике 1200 с (GPU общий).
# Пачка: .dpcli/dpcli job start aww2-<метка> 7200 tools/research/air_weak_wind/AWW-2/run.sh <метка> [main]
HERE="$(cd "$(dirname "$0")" && pwd)"; ROOT="$(cd "$HERE/../../../.." && pwd)"; cd "$ROOT" || exit 2
export XDG_DATA_HOME=${XDG_DATA_HOME:-$HOME/.cache/dp-xdg/$(basename "$ROOT")}
TAG=${1:?метка}; VAR=${2:-}
O=$HERE/out/$TAG; mkdir -p "$O"
FILES=(scripts/atmosphere/air_model/air_phase.glsl scripts/atmosphere/air_model/air_phase_cpu.gd)
if [ "$VAR" = main ]; then
  git apply -R tools/research/air_weak_wind/AWW-1/proto_theta_h.patch || exit 3
  trap 'git checkout -- "${FILES[@]}"' EXIT
fi
# импорт: после правки .glsl без него берётся старый SPIR-V
godot --headless --path . --import > "$O/import.log" 2>&1 || true
git checkout -- project.godot 2>/dev/null || true
JOBS=(
  "training_island_ridge_west_start --location=training_island --site=ridge_west"
  "training_island_thermal_plain_start --location=training_island --site=thermal_plain"
  "training_island_landing_hill_start --location=training_island --site=landing_hill"
  "training_island_lee_bowl_start --location=training_island --site=lee_bowl"
  "volcano_island_east_cliffs_start --location=volcano_island --site=east_cliffs"
  "volcano_island_crater_ridge_start --location=volcano_island --site=crater_ridge"
  "volcano_island_thermal_slope_start --location=volcano_island --site=thermal_slope"
  "volcano_island_plateau_landing_start --location=volcano_island --site=plateau_landing"
)
for ps in ongudai/kayancha_south askarovo/biyagoda_west askarovo/biyagoda_east; do
  p=${ps%%/*}; s=${ps##*/}
  JOBS+=("${p}_${s}_weak --location=$p --site=$s --wind=2 --hour=12 --sky=clear --from=launch")
  JOBS+=("${p}_${s}_strong --location=$p --site=$s --wind=5 --hour=12 --sky=partly --from=launch")
done
one() {
  local f=$O/$1; shift
  DISPLAY="${DISPLAY:-:0}" timeout 2400 godot --path . --audio-driver Dummy --resolution 320x240 --disable-vsync \
    res://tools/research/air_weak_wind/AWW-2/probe.tscn -- --autostart --bots=0 "$@" --nobake \
    --secs=60 --out=$f.json > $f.log 2>&1
  echo "$(basename $f): $(grep -o 'aww_probe: .*' $f.log) | $(grep -o 'air_model: .*' $f.log | tail -1 | cut -c1-120)"
}
# готовые (json есть) пропускаются; места вне островов — по одному (параллельный запуск одного места в общем
# профиле пересобирает его и роняет загрузку соседа)
for j in "${JOBS[@]}"; do
  [ -s "$O/${j%% *}.json" ] && continue
  if [[ "$j" == training_island* || "$j" == volcano_island* ]]; then
    while [ "$(jobs -rp | wc -l)" -ge 2 ]; do wait -n; done
    # shellcheck disable=SC2086
    one $j &
  else
    wait
    # shellcheck disable=SC2086
    one $j
  fi
done
wait
if [ "$VAR" = main ]; then
  git checkout -- "${FILES[@]}"
fi
git checkout -- project.godot 2>/dev/null || true
git status --short -- scripts configs
