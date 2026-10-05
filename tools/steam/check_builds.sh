#!/usr/bin/env bash
# Проверка сборок ST-3: itch Linux без файлов Steam, Steam Linux с библиотеками, smoke Steam-сборки.
# Печатает одну строку: ITCH_STEAM_FILES=<n> STEAM_LIBS_OK=<1|0> STEAM_SMOKE=<inactive (…)|active|…>
# AIR_ONNX=0 (расширение ветра не собирается). Профиль Godot — временный.
set -uo pipefail
cd "$(dirname "$0")/../.."
export AIR_ONNX=0
XDG_DATA_HOME=$(mktemp -d); export XDG_DATA_HOME
real="$HOME/.local/share/godot/export_templates"
[[ -d "$real" ]] && { mkdir -p "$XDG_DATA_HOME/godot"; ln -s "$real" "$XDG_DATA_HOME/godot/export_templates"; }
trap 'rm -rf "$XDG_DATA_HOME"; git checkout -- project.godot 2>/dev/null' EXIT
tools/steam/fetch_godotsteam.sh >&2
godot --headless --path . --import >/dev/null 2>&1 || godot --headless --path . --import >/dev/null 2>&1 || true
tools/build.sh linux >&2 2>&1 || echo "itch: сборка не удалась" >&2
tools/build.sh linux-steam >&2 2>&1 || echo "steam: сборка не удалась" >&2
n=$(find build/linux \( -iname 'libsteam_api*' -o -iname '*godotsteam*' -o -iname 'steam_api*' -o -iname 'steam_appid*' \) 2>/dev/null | wc -l)
n=$((n + $(grep -ac -e godotsteam -e libsteam_api build/linux/*.pck 2>/dev/null || true)))
ok=1
[[ -f build/linux-steam/deltaplan.x86_64 ]] || ok=0
ls build/linux-steam/ 2>/dev/null | grep -q '^libsteam_api' || find build/linux-steam -name 'libsteam_api*' | grep -q . || ok=0
find build/linux-steam -name 'libgodotsteam*' | grep -q . || ok=0
# HOME временный: запущенный клиент Steam на машине иначе даст active (его сокет ищется в ~/.steam)
smoke=$(HOME=$(mktemp -d) timeout 120 build/linux-steam/deltaplan.x86_64 --headless -- --smoke 2>&1 | grep -o '^steam: .*' | head -1)
case "$smoke" in
	"steam: inactive"*) s="inactive (${smoke#*\(}" ;;
	"steam: active"*) s="active" ;;
	*) s="none" ;;
esac
echo "ITCH_STEAM_FILES=$n STEAM_LIBS_OK=$ok STEAM_SMOKE=$s"
