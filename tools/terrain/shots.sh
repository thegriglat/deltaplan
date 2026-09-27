#!/usr/bin/env bash
# Стенд T01: снимает 7 фиксированных кадров рельефа (1920x1080) и меряет GPU, чтобы дальнейшие
# карточки группы «Рельеф» (T02-T06) сравнивались с базой и с 3 реальными фото.
# tools/terrain/shots.sh <выход> [--bench-frames=N]
# Результат в <выход>/: <id>.png на каждый кадр из tools/terrain/shots.json, bench.json
# (gpu_ms среднее/95% отдельно "полностью" и "рельеф" — без деревьев/травы/дымки), metrics.json
# и монтажи "кадр | фото" (tools/terrain/compare_ref.py).
# Кадры и разметка (прямоугольники лес/луг, полосы близко/средне/далеко, линия профиля S3) —
# tools/terrain/shots.json. Локации и старты — configs/locations/*.json.
# Скриншоты и замер GPU идут в Forward+, окну нужен настоящий дисплей: запуск через DISPLAY=:0,
# звук отключён (--audio-driver Dummy), на случай зависания — под timeout.
set -euo pipefail
cd "$(dirname "$0")/../.."

out="${1:-/tmp/terrain_shots}"
bench_frames="120"
for a in "$@"; do
  [[ "$a" == --bench-frames=* ]] && bench_frames="${a#--bench-frames=}"
done
mkdir -p "$out"

export DISPLAY="${DISPLAY:-:0}"
t0=$(date +%s)

run_godot() {
  timeout 120 godot --path . --audio-driver Dummy --resolution 1920x1080 \
    res://scenes/terrain/terrain_preview.tscn -- "$@"
}

echo "== кадры =="
while IFS=$'\t' read -r id args_line; do
  IFS=$'\t' read -r -a args <<< "$args_line"
  echo "-- $id --"
  run_godot "${args[@]}" "--shot=$out/$id.png"
done < <(python3 - <<'PY'
import json
shots = json.load(open("tools/terrain/shots.json", encoding="utf-8"))
for f in shots["frames"]:
    print(f["id"] + "\t" + "\t".join(f["args"]))
PY
)

echo "== бенч GPU: полностью / рельеф =="
bench_args=(--location=ongudai --site=kayancha_south --agl=800 --clearings "--bench-static=$bench_frames")
full_line=$(run_godot "${bench_args[@]}" | grep BENCH_STATIC_JSON | sed 's/^.*BENCH_STATIC_JSON://')
relief_line=$(run_godot "${bench_args[@]}" --no-trees --no-grass --no-haze | grep BENCH_STATIC_JSON | sed 's/^.*BENCH_STATIC_JSON://')
python3 - "$out" "$full_line" "$relief_line" <<'PY'
import json, sys
out, full_line, relief_line = sys.argv[1], sys.argv[2], sys.argv[3]
bench = {"full": json.loads(full_line), "relief": json.loads(relief_line)}
open(f"{out}/bench.json", "w", encoding="utf-8").write(json.dumps(bench, ensure_ascii=False, indent=2))
print(bench)
PY

echo "== метрики и монтажи =="
uv run --with numpy --with pillow python tools/terrain/compare_ref.py "$out"

t1=$(date +%s)
echo "shots.sh: готово за $((t1 - t0)) с, результат в $out"
