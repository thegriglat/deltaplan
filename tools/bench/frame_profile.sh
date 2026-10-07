#!/usr/bin/env bash
# Профиль кадра (PF-1, docs/perf/frame_profile.md): для каждого пресета × локации —
#  1) по процессу на каждую отметку MARKS (долететь, пауза, опыты-переключения рендера, выход):
#     после долгой паузы полёт с автопилотом не всегда доживает до следующей отметки;
#  2) прогон «полёт» без паузы: кадры на всех отметках, пересчёт поля воздуха (--air=),
#     затем CPU по поддеревьям Game (--cpu=0).
#   tools/bench/frame_profile.sh <out_dir> "<пресеты>" "<локации>" [доп. аргументы опытов...]
#   пример: tools/bench/frame_profile.sh build/perf/run1 "low medium high" "ongudai altai" --sample=2
# Профиль Godot — временный (XDG_DATA_HOME в out_dir/xdg_<пресет>). Нужен дисплей (DISPLAY=:0);
# SKIP_FLY=1 — без прогона «полёт»; TAG_SUFFIX — к именам файлов отметок.
# вызывать под `dp lock gpu` / `dp job --lock gpu`. Итог — tools/bench/frame_profile_report.py <out_dir>.
set -uo pipefail
trap 'kill 0' TERM INT  # dp job stop — не оставлять godot сиротой
cd "$(dirname "$0")/../.."
out=${1:?out_dir}; presets=${2:-medium}; locs=${3:-ongudai}; shift 3 || true
mkdir -p "$out"
out=$(realpath "$out")
export DISPLAY="${DISPLAY:-:0}"
MARKS=${MARKS:-"2:cockpit 30:chase 60:chase"}
AIR_T=${AIR_T:-65}
fail=0
run() {  # имя_лога аргументы...
	local name=$1; shift
	timeout 1000 godot --path . --audio-driver Dummy --disable-vsync --fullscreen \
		--resolution 1920x1080 ${GPU_PROFILE_FLAG---gpu-profile} res://tools/bench/frame_profile.tscn -- \
		"$@" >"$out/$name.log" 2>&1
	echo "$name exit=$? $(grep -c '^PROFILE ' "$out/$name.log") строк; $(grep -E '^frame_profile:' "$out/$name.log")"
	grep -q "^frame_profile: OK" "$out/$name.log" || fail=1
}
for p in $presets; do
	export XDG_DATA_HOME="$out/xdg_$p"
	mkdir -p "$XDG_DATA_HOME"
	godot --headless --path . res://tools/bench/set_preset.tscn -- --preset="$p" 2>&1 | grep -E "set_preset|ERROR" || true
	for loc in $locs; do
		for m in $MARKS; do
			export DP_AIR_CHUNK_LOG="$out/${p}_${loc}_load_air_chunks.jsonl"
			run "${p}_${loc}_${m%%:*}${TAG_SUFFIX:-}" "--location=$loc" "--tag=$p" "--marks=$m" \
				"--out=$out/${p}_${loc}_${m%%:*}${TAG_SUFFIX:-}.jsonl" "$@"
		done
		[[ -n "${SKIP_FLY:-}" ]] && continue
		export DP_AIR_CHUNK_LOG="$out/${p}_${loc}_fly_air_chunks.jsonl"
		run "${p}_${loc}_fly" "--location=$loc" "--tag=$p" "--marks=${MARKS// /,}" --pause=0 \
			--exps=none "--air=$AIR_T" --cpu=0 "--out=$out/${p}_${loc}_fly.jsonl" "$@"
	done
done
exit $fail
