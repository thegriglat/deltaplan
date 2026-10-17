#!/usr/bin/env bash
# Кадры слоя поля облачности (CLF-5): Онгудай с высоты, Алматы с земли на хребет, учебный остров.
# tools/shots/cloud_field/shots.sh <out_dir> [доп. флаги игры]   (под .dpcli/dpcli lock gpu, DISPLAY)
set -uo pipefail
cd "$(dirname "$0")/../../.."
out=${1:?out_dir}; shift || true
mkdir -p "$out"
export DISPLAY="${DISPLAY:-:0}"
export XDG_DATA_HOME="${XDG_DATA_HOME:-$HOME/.cache/dp-xdg/$(basename "$PWD")}"
cp project.godot "$out/.project.godot.bak"
trap 'cmp -s project.godot "$out/.project.godot.bak" || cp "$out/.project.godot.bak" project.godot; rm -f "$out/.project.godot.bak"' EXIT
shot() {  # тег флаги...
	local tag=$1; shift
	timeout 700 godot --path . --audio-driver Dummy --resolution 1920x1080 \
		res://tools/shots/cloud_field_shot.tscn -- --autostart --bots=0 --out="$out" --tag="$tag" "$@" \
		>"$out/$tag.log" 2>&1
	echo "$tag exit=$?"; grep -E "^cloud_field_shot" "$out/$tag.log"
}
shot ongudai --location=ongudai --hour=12 --temp=30 --wind=3 --world-t=5400 --views=high,low "$@"
[[ -n "${ONLY_ONGUDAI:-}" ]] && exit 0
shot almaty --latlon=43.20,76.90 --hour=12 --temp=30 --wind=3 --world-t=3600 --views=ground "$@"
shot island --location=training_island --hour=12 --temp=28 --world-t=3600 --views=low,high "$@"
