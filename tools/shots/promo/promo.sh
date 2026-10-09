#!/usr/bin/env bash
# Пробная съёмка промо-видео (README.md рядом): Movie Maker под xvfb → PNG + WAV → mp4.
#   tools/shots/promo/promo.sh <каталог_вывода> [секунд] [ширина] [высота] [-- флаги игры]
# Разрешение Movie Maker берёт из project.godot (--resolution игнорируется), поэтому съёмка идёт
# из временной копии проекта: ссылки на файлы репозитория + project.godot с нужным размером.
set -euo pipefail
cd "$(dirname "$0")/../../.."
root=$(pwd)
out=$(realpath -m "${1:?каталог вывода}"); shift
secs=${1:-20}; [[ $# -gt 0 ]] && shift
w=${1:-1920}; [[ $# -gt 0 ]] && shift
h=${1:-1080}; [[ $# -gt 0 ]] && shift
[[ "${1:-}" == "--" ]] && shift
game_flags=("$@")
if [[ ${#game_flags[@]} -eq 0 ]]; then
	game_flags=(--autostart --autopilot --autopilot-circle=1,-12 --camera=chase --location=ongudai
		--site=kayancha_south --wing=training --sky=clear --temp=33 --hour=13 --seed=20260927
		--bots=2 --air-start=1000,300)
fi
fps=30
proj=$(mktemp -d)
for f in "$root"/* "$root"/.godot; do
	[[ "$(basename "$f")" == project.godot || "$(basename "$f")" == build ]] && continue
	ln -s "$f" "$proj/"
done
sed -e "s/^window\/size\/viewport_width=.*/window\/size\/viewport_width=$w/" \
	-e "s/^window\/size\/viewport_height=.*/window\/size\/viewport_height=$h/" \
	"$root/project.godot" > "$proj/project.godot"
export XDG_DATA_HOME=${XDG_DATA_HOME:-$(mktemp -d)}
mkdir -p "$out"
rm -f "$out"/out*.png "$out/out.wav"
xvfb-run -a -s "-screen 0 ${w}x${h}x24" \
	godot --path "$proj" --audio-driver Dummy --write-movie "$out/out.png" --fixed-fps "$fps" \
	--quit-after $((secs * fps)) res://tools/shots/promo/promo.tscn -- "${game_flags[@]}"
ffmpeg -y -loglevel error -framerate "$fps" -i "$out/out%08d.png" -i "$out/out.wav" \
	-c:v libx264 -crf 15 -preset slow -pix_fmt yuv420p -c:a aac -b:a 192k -shortest "$out/promo.mp4"
rm -rf "$proj"
echo "готово: $out/promo.mp4"
