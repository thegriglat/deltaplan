#!/usr/bin/env bash
# Один кадр из игры по параметрам JSON (по умолчанию tools/shots/menu_background.json) — основа tools/shots/menu_art.py.
# tools/shots/menu_background.sh [--size=3840x2160|2560x1440] [--out=файл.jpg] [--config=файл.json]
# Окно — виртуальный дисплей xvfb нужного размера (Vulkan на видеокарте), профиль пилота временный.
# Пресет графики «Высокое», «Масштаб рендера» 100 % (без FSR), без прибора и меню. Детерминированно:
# сид мира, время симуляции и прогрев кадрами заданы в JSON; повторы различаются только мелочами.
set -uo pipefail
cd "$(dirname "$0")/../.."

size="3840x2160"
out="build/screenshots/menu_background.jpg"
cfg="tools/shots/menu_background.json"
for a in "$@"; do
	case "$a" in
		--size=*) size="${a#--size=}" ;;
		--out=*) out="${a#--out=}" ;;
		--config=*) cfg="${a#--config=}" ;;
		*) echo "неизвестный аргумент: $a" >&2; exit 2 ;;
	esac
done
[[ "$size" =~ ^[0-9]+x[0-9]+$ ]] || { echo "формат --size=ШxВ" >&2; exit 2; }
mkdir -p "$(dirname "$out")"
out_abs="$(realpath -m "$out")"
cfg_abs="$(realpath "$cfg")"
mapfile -t flags < <(python3 -c 'import json,sys; print("\n".join(json.load(open(sys.argv[1]))["flags"]))' "$cfg_abs")

export XDG_DATA_HOME
XDG_DATA_HOME="${MB_XDG:-$(mktemp -d)}"  # MB_XDG — общий кеш мест для --latlon
timeout "${MB_TIMEOUT:-300}" xvfb-run -a -s "-screen 0 ${size}x24" \
	godot --path . --audio-driver Dummy --resolution "$size" \
	res://tools/shots/menu_background.tscn -- "${flags[@]}" "--mb-config=$cfg_abs" "--mb-out=$out_abs"
code=$?
echo "menu_background.sh: код $code, файл $out_abs"
exit $code
