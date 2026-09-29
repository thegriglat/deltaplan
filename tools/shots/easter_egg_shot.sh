#!/usr/bin/env bash
# Кадр пасхалки: главная сцена с --autostart --autopilot --egg=<id>, окно 1920x1080.
# tools/shots/easter_egg_shot.sh <id> <файл.jpg> [аргументы игры...]
# Печатает EGG_GPU_MS <id> <мс> — среднее GPU кадра за 2 с до снимка. Тот же запуск с --egg=none
# даёт базу (метка none): разница — цена пасхалки (приёмка: <= 0,2 мс на «Высоком»).
# Аргументы игры идут после умолчаний и перекрывают их (--egg=none, --time=…, --look-at=egg).
# Умолчания: --egg=<id>:5 (появится на 5-й с), --time=12, --look-at=egg.
# Кадры — build/screenshots/easter_eggs/<№>_<имя>.jpg в основной копии (не в git).
# GPU иногда занят исследованиями: под flock /tmp/heat_ca_gpu.lock (ждать до 30 мин, не мешать).
# Окну нужен настоящий дисплей (DISPLAY=:0); звук выключен.
set -euo pipefail
cd "$(dirname "$0")/../.."
id="${1:?usage: easter_egg_shot.sh <id> <файл.jpg> [аргументы игры...]}"
file="${2:?usage: easter_egg_shot.sh <id> <файл.jpg> [аргументы игры...]}"
shift 2
mkdir -p "$(dirname "$file")"
export DISPLAY="${DISPLAY:-:0}"
xdg="$(mktemp -d)"
trap 'rm -rf "$xdg"' EXIT
label="$id"
for a in "$@"; do
	[[ "$a" == "--egg=none" ]] && label="none"
done
flock -w 1800 /tmp/heat_ca_gpu.lock \
	env XDG_DATA_HOME="$xdg" timeout 180 godot --path . --audio-driver Dummy --fullscreen \
	--resolution 1920x1080 -- --autostart --autopilot "--egg=$id:5" --time=12 --look-at=egg \
	"--gpu-report=$label" "$@" "--screenshot=$file" 2>&1 \
	| grep -E "^screenshot:|EGG_GPU_MS|ERROR|SCRIPT ERROR" || true
