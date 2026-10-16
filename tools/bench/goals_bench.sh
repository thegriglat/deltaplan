#!/usr/bin/env bash
# GL-12: цена целей по кадру — main против feature/goals на одном полёте (docs/guide/goals.md, «Цена»).
# Берёт frame_profile.gd/.sh из ЭТОЙ копии и запускает их в двух деревьях проекта:
#   tools/bench/goals_bench.sh <out_dir> <дерево_main> <дерево_goals> [повторы=2] [пресеты="medium"]
# Рукава: main (без целей), goals_off (ветка целей, цели не отмечены), goals_on (цели из списка +
# цилиндры + след прошлой попытки + загруженный IGC). Порядок рукавов чередуется по кругам.
# Одинаково во всех рукавах: ongudai, старт kayancha_south, сид 4711, 15 июля, 13:00, ясно, ветер 3 м/с
# встречный, боты 0, кадры на отметках 2:cockpit 30:chase 60:chase, 3 с на выборку.
# Профиль Godot — отдельный в out_dir/xdg_<рукав>_<пресет>_<круг> (кэш рельефа копируется из CACHE_SRC).
# Вызывать под `.dpcli/dpcli lock gpu` (DISPLAY=:0). Итог — tools/bench/goals_bench.py не нужен:
# таблица считается ниже (python3 встроенный).
set -uo pipefail
here=$(cd "$(dirname "$0")/../.." && pwd)
out=$(realpath -m "${1:?out_dir}"); tree_main=$(realpath "${2:?дерево main}"); tree_goals=$(realpath "${3:?дерево goals}")
reps=${4:-2}; presets=${5:-medium}
CACHE_SRC=${CACHE_SRC:-$HOME/.cache/dp-xdg/deltaplan-goals-GL-15/Deltaplan}
IGC=${IGC:-$here/tools/shots/goals_track.igc}
export DISPLAY="${DISPLAY:-:0}"
MARKS=${MARKS:-"2:cockpit,30:chase,60:chase"}
mkdir -p "$out"
cp "$here/tools/bench/frame_profile.gd" "$tree_main/tools/bench/frame_profile.gd"
cp "$here/tools/bench/frame_profile.gd" "$tree_goals/tools/bench/frame_profile.gd"
GA="--game-args=--site=kayancha_south,--seed=4711,--bots=0,--wind=3,--from=launch,--sky=clear,--hour=13"
for tr in "$tree_main" "$tree_goals"; do
	[[ -d "$tr/.godot" ]] || (cd "$tr" && godot --headless --path . --import >/dev/null 2>&1)
done
run_arm() {  # рукав пресет круг
	local arm=$1 p=$2 r=$3 tree extra=()
	local tag="${arm}_${p}_$r"
	export XDG_DATA_HOME="$out/xdg_$tag"
	mkdir -p "$XDG_DATA_HOME/Deltaplan"
	cp -r "$CACHE_SRC/." "$XDG_DATA_HOME/Deltaplan/" 2>/dev/null
	rm -rf "$XDG_DATA_HOME/Deltaplan/tracks" "$XDG_DATA_HOME/Deltaplan/configs/goals"
	case $arm in
		main) tree=$tree_main ;;
		goals_off) tree=$tree_goals ;;
		goals_on)
			tree=$tree_goals
			mkdir -p "$XDG_DATA_HOME/Deltaplan/tracks/last"
			cp "$IGC" "$XDG_DATA_HOME/Deltaplan/tracks/last/ongudai.igc"
			extra=(--goals=1 --cylinders=1 --last-track=1 "--igc=$IGC") ;;
	esac
	( cd "$tree" && godot --headless --path . res://tools/bench/set_preset.tscn -- --preset="$p" 2>&1 | grep -E "ERROR" || true )
	( cd "$tree" && timeout 600 godot --path . --audio-driver Dummy --disable-vsync --fullscreen \
		--resolution 1920x1080 --gpu-profile res://tools/bench/frame_profile.tscn -- \
		--location=ongudai --tag="$tag" "--marks=$MARKS" --pause=0 --exps=none --sample=3 \
		"--out=$out/$tag.jsonl" "$GA" "${extra[@]}" >"$out/$tag.log" 2>&1 )
	echo "$tag exit=$? $(grep -E '^frame_profile:|goals_state' "$out/$tag.log" | tr '\n' ' ')"
}
for p in $presets; do
	for r in $(seq 1 "$reps"); do
		if (( r % 2 )); then arms="main goals_off goals_on"; else arms="goals_on goals_off main"; fi
		for a in $arms; do run_arm "$a" "$p" "$r"; done
	done
done
python3 - "$out" <<'PY'
import json, glob, os, sys, statistics as st
out = sys.argv[1]
rows = {}
for f in sorted(glob.glob(out + "/*.jsonl")):
    arm, preset, rep = os.path.basename(f)[:-6].rsplit("_", 2)[0:1] + os.path.basename(f)[:-6].rsplit("_", 2)[1:]
    for l in open(f):
        d = json.loads(l)
        if d.get("exp") == "fly":
            rows.setdefault((preset, d["cam"], d["t"], arm), []).append(d)
keys = ["frame_ms", "frame_ms_1pct", "gpu_ms", "gpu_ms_1pct", "process_ms", "physics_ms", "draw_calls"]
print("| пресет | отметка | рукав | n | " + " | ".join(keys) + " |")
print("|" + "---|" * (4 + len(keys)))
for k in sorted(rows):
    v = rows[k]
    print("| %s | %s@%s | %s | %d | " % (k[0], k[1], int(k[2]), k[3], len(v)) +
          " | ".join("%.2f" % st.mean(x.get(c, 0) for x in v) for c in keys) + " |")
PY
