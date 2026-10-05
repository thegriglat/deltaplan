#!/usr/bin/env bash
# Эксперимент ST-1: экспорт Linux-сборки (release) из временного проекта в трёх вариантах и запуск:
#   steam   — расширение включено, метка steam
#   plain   — exclude_filter="addons/godotsteam/*" (сборка для itch без Steam)
#   noexcl  — расширение в проекте, фильтра нет, метки steam нет (одна сборка на всё)
# Печатает для каждого: состав каталога экспорта и строку STEAM_EXPORT.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"; GODOT="${GODOT:-godot}"
XD="$(mktemp -d)"; mkdir -p "$XD/godot"; ln -s "${GODOT_TEMPLATES:-$HOME/.local/share/godot/export_templates}" "$XD/godot/export_templates"
P="$(mktemp -d)"; trap 'rm -rf "$P"' EXIT
cat > "$P/project.godot" <<'PG'
config_version=5
[application]
config/name="steam_export_probe"
run/main_scene="res://main.tscn"
[rendering]
textures/vram_compression/import_etc2_astc=true
PG
cat > "$P/main.tscn" <<'TS'
[gd_scene load_steps=2 format=3]
[ext_resource type="Script" path="res://probe_node.gd" id="1"]
[node name="Main" type="Node"]
script = ExtResource("1")
TS
cp "$HERE/probe_node.gd" "$P/"
bash "$HERE/fetch_godotsteam.sh" "$P" >&2
mk() { # имя, features, exclude
cat <<EOP
[preset.$1]
name="$2"
platform="Linux"
runnable=true
dedicated_server=false
custom_features="$3"
export_filter="all_resources"
include_filter=""
exclude_filter="$4"
export_path=""
[preset.$1.options]
binary_format/embed_pck=false
binary_format/architecture="x86_64"
EOP
}
{ mk 0 steam steam ""; mk 1 plain "" "addons/godotsteam/*"; mk 2 noexcl "" "";
  printf '[preset.3]\nname="win"\nplatform="Windows Desktop"\nrunnable=true\ncustom_features="steam"\nexport_filter="all_resources"\ninclude_filter=""\nexclude_filter=""\nexport_path=""\n[preset.3.options]\nbinary_format/embed_pck=false\nbinary_format/architecture="x86_64"\n'
  printf '[preset.4]\nname="mac"\nplatform="macOS"\nrunnable=true\ncustom_features="steam"\nexport_filter="all_resources"\ninclude_filter=""\nexclude_filter=""\nexport_path=""\n[preset.4.options]\nbinary_format/architecture="universal"\ncodesign/codesign=1\nnotarization/notarization=0\napplication/min_macos_version_x86_64="10.15"\napplication/min_macos_version_arm64="11.00"\napplication/bundle_identifier="org.example.steamprobe"\n'
} > "$P/export_presets.cfg"
for i in 1 2; do (cd "$P" && XDG_DATA_HOME="$XD" timeout 120 "$GODOT" --headless --path "$P" --import >/dev/null 2>&1); done
for v in steam plain noexcl; do
  mkdir -p "$P/out/$v"
  (cd "$P" && XDG_DATA_HOME="$XD" timeout 300 "$GODOT" --headless --path "$P" --export-release "$v" "$P/out/$v/game.x86_64" 2>&1 | sed 's/\x1b\[[0-9;]*m//g' | grep -iE "error|warn" | head -5)
  echo "== $v: файлы экспорта"; (cd "$P/out/$v" && find . -type f -printf '%P %s\n' | sort)
  (cd "$P/out/$v" && XDG_DATA_HOME="$XD" timeout 60 ./game.x86_64 --headless 2>&1 | grep -E "STEAM_EXPORT|ERROR" | head -3)
done

# Windows и macOS: только состав экспорта (запустить нельзя)
mkdir -p "$P/out/win" "$P/out/mac"
(cd "$P" && XDG_DATA_HOME="$XD" timeout 300 "$GODOT" --headless --path "$P" --export-release win "$P/out/win/game.exe" 2>&1 | sed 's/\x1b\[[0-9;]*m//g' | grep -iE "error|warn" | head -5)
echo "== win: файлы экспорта"; (cd "$P/out/win" && find . -type f -printf '%P %s\n' | sort)
(cd "$P" && XDG_DATA_HOME="$XD" timeout 300 "$GODOT" --headless --path "$P" --export-release mac "$P/out/mac/game.zip" 2>&1 | sed 's/\x1b\[[0-9;]*m//g' | grep -iE "error|warn" | head -5)
echo "== mac: файлы в zip"; python3 -c "
import zipfile,sys
for i in zipfile.ZipFile('$P/out/mac/game.zip').infolist():
    if not i.is_dir() and ('dylib' in i.filename or 'Info.plist' in i.filename or 'MacOS' in i.filename or 'Frameworks' in i.filename): print(i.filename,i.file_size)
" 2>&1 | head -20
