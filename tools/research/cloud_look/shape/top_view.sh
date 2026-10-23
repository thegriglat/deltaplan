#!/usr/bin/env bash
# CLK-2: вид сверху на слой кучевых (top_view_shot.gd) в окне xvfb — для размеров облаков.
#   top_view.sh <out_dir> <tag> [--clouds=off] [доп. флаги top_view_shot.gd]
# --clouds=off — тот же кадр без облаков (маска: tools/research/cloud_look/shape/sizes_top.py).
# Профиль Godot — XDG_DATA_HOME (по умолчанию временный), кеш Онгудая — общий с menu_art
# (MB_XDG=<каталог с Deltaplan/>). Под замком: .dpcli/dpcli lock cpu <имя> -- top_view.sh …
set -uo pipefail
cd "$(dirname "$0")/../../../.."
out=${1:?out_dir}; tag=${2:?tag}; shift 2
clouds=on
args=()
for a in "$@"; do
	case "$a" in
		--clouds=off) clouds=off ;;
		*) args+=("$a") ;;
	esac
done
size=${SIZE:-1920x1080}
export XDG_DATA_HOME="${MB_XDG:-$(mktemp -d)}"
mkdir -p "$XDG_DATA_HOME/Deltaplan/configs"
if [[ $clouds == off ]]; then
	echo '{"clouds": {"enabled": false}}' > "$XDG_DATA_HOME/Deltaplan/configs/atmosphere.json"
else
	echo '{}' > "$XDG_DATA_HOME/Deltaplan/configs/atmosphere.json"
fi
timeout "${TV_TIMEOUT:-900}" xvfb-run -a -s "-screen 0 ${size}x24" \
	godot --path . --audio-driver Dummy --resolution "$size" \
	res://tools/research/cloud_look/shape/top_view_shot.tscn -- \
	--autostart --bots=0 --location=ongudai --hour=12 --temp=30 --wind=3 --world-t=5400 \
	"--out=$out" "--tag=$tag" "${args[@]}"
echo "top_view.sh: код $?"
