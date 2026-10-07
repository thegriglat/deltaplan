#!/usr/bin/env bash
# Сборка: tools/build.sh [linux|windows|macos|all] [--release]
# Результат: build/<платформа>/ + архив build/deltaplan-<платформа>.zip
# macOS: Godot сам пакует Deltaplan.app в zip (универсальный x86_64+arm64, подпись ad-hoc без
# нотаризации); build/macos/ — распакованный .app для butler. configs/ рядом не кладём: внутри .app
# это ломает подпись, а снаружи Config его не ищет — на Mac настройки только встроенные.
# Steam: linux-steam|windows-steam|macos-steam — пресеты «… Steam» (метка steam, GodotSteam из
# tools/steam/fetch_godotsteam.sh), каталог build/<платформа>-steam; в «all» не входят. itch-сборки без GodotSteam.
# Рядом с игрой кладётся папка configs/ — пилот правит её без пересборки (NFR-7).
set -euo pipefail
cd "$(dirname "$0")/.."
target="${1:-all}"
mode="--export-debug"
[[ "${2:-}" == "--release" ]] && mode="--export-release"

# Коммит сборки для «Об игре» (BuildInfo): 6 символов, «+» — есть незакоммиченные правки.
commit="$(git rev-parse --short=6 HEAD 2>/dev/null || echo "")"
[[ -n "$commit" && -n "$(git status --porcelain --untracked-files=no 2>/dev/null)" ]] && commit="$commit+"
printf '{"commit": "%s"}\n' "$commit" > data/build_info.json

[[ "$target" == *-steam ]] && tools/steam/fetch_godotsteam.sh
# Временный профиль (XDG_DATA_HOME=$(mktemp -d), как у агентов) — без шаблонов экспорта:
# подложить ссылку на шаблоны из обычного профиля.
tpl_home="$HOME/.local/share/godot/export_templates"
tpl_tmp="${XDG_DATA_HOME:-}/godot/export_templates"
if [[ -n "${XDG_DATA_HOME:-}" && -d "$tpl_home" && ! -L "$tpl_tmp" ]]; then
	# Godot при запуске создаёт пустой каталог шаблонов — его заменить ссылкой.
	[[ -d "$tpl_tmp" ]] && rmdir "$tpl_tmp" 2>/dev/null
	if [[ ! -e "$tpl_tmp" ]]; then
		mkdir -p "$XDG_DATA_HOME/godot"
		ln -s "$tpl_home" "$tpl_tmp"
	fi
fi

# Импорт регистрирует расширения и ресурсы.
godot --headless --path . --import >/dev/null 2>&1 || true

# Экспорт — с настоящим рендером, не --headless: иначе Shader Baker (shader_baker/enabled в
# export_presets.cfg) молча пропускает запекание шейдеров материалов, и пилот ждёт их компиляции
# при первом запуске. Нет дисплея — экспорт без запекания (с предупреждением).
export_flags=()
if [[ -z "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ]]; then
	echo "ВНИМАНИЕ: нет дисплея — экспорт --headless, шейдеры не запекаются" >&2
	export_flags=(--headless)
fi

build_one() {
	local preset="$1" dir="$2" bin="$3"
	rm -rf "build/$dir"
	mkdir -p "build/$dir"
	# Редактор с окном пересохраняет project.godot (выкидывает значения по умолчанию) — вернуть как было.
	cp project.godot "build/.project.godot.bak"
	godot "${export_flags[@]}" --path . "$mode" "$preset" "build/$dir/$bin"
	cmp -s project.godot "build/.project.godot.bak" || cp "build/.project.godot.bak" project.godot
	rm -f "build/.project.godot.bak"
	cp -r configs "build/$dir/configs"
	python3 tools/release/third_party_notices.py --out "build/$dir" --preset "$preset"
	# Манифест itch: без него приложение itch считает deltaplan.pck вторым кандидатом на запуск
	# (godot-pck через wine) и спрашивает, что запускать.
	printf '[[actions]]\nname = "play"\npath = "%s"\n' "$bin" > "build/$dir/.itch.toml"
	(cd build && rm -f "deltaplan-$dir.zip" && zip -qr "deltaplan-$dir.zip" "$dir")
	echo "готово: build/$dir/$bin, build/deltaplan-$dir.zip"
}

[[ "$target" == linux || "$target" == all ]] && build_one Linux linux deltaplan.x86_64
[[ "$target" == windows || "$target" == all ]] && build_one Windows windows deltaplan.exe

[[ "$target" == linux-steam ]] && build_one "Linux Steam" linux-steam deltaplan.x86_64
[[ "$target" == windows-steam ]] && build_one "Windows Steam" windows-steam deltaplan.exe

build_macos() {
	local preset="${1:-macOS}" dir="${2:-macos}"
	rm -rf "build/$dir" "build/deltaplan-$dir.zip"
	mkdir -p "build/$dir"
	cp project.godot "build/.project.godot.bak"
	godot "${export_flags[@]}" --path . "$mode" "$preset" "build/deltaplan-$dir.zip"
	cmp -s project.godot "build/.project.godot.bak" || cp "build/.project.godot.bak" project.godot
	rm -f "build/.project.godot.bak"
	(cd "build/$dir" && unzip -q "../deltaplan-$dir.zip")
	python3 tools/release/third_party_notices.py --out "build/$dir" --preset "$preset"
	echo "готово: build/$dir/$(ls build/$dir), build/deltaplan-$dir.zip"
}
[[ "$target" == macos || "$target" == all ]] && build_macos
[[ "$target" == macos-steam ]] && build_macos "macOS Steam" macos-steam
exit 0  # иначе «build.sh linux» возвращает 1 от последней проверки [[ windows ]]
