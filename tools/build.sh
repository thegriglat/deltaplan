#!/usr/bin/env bash
# Сборка: tools/build.sh [linux|windows|macos|all] [--release]
# Результат: build/<платформа>/ + архив build/deltaplan-<платформа>.zip
# macOS: Godot сам пакует Deltaplan.app в zip (универсальный x86_64+arm64, подпись ad-hoc без
# нотаризации); build/macos/ — распакованный .app для butler. configs/ рядом не кладём: внутри .app
# это ломает подпись, а снаружи Config его не ищет — на Mac настройки только встроенные.
# Рядом с игрой кладётся папка configs/ — пилот правит её без пересборки (NFR-7).
# Расширение AirOnnx (нейросеть ветра, native/air_onnx): нет собранного для платформы — собирается
# (native/air_onnx/build.sh, нужна сеть при первом запуске); после экспорта проверяется, что расширение
# и ONNX Runtime лежат рядом с исполняемым файлом. AIR_ONNX=0 — не собирать и не проверять (игра без
# расширения работает на упрощённой модели ветра). macOS — расширение не собирается (README там).
set -euo pipefail
cd "$(dirname "$0")/.."
target="${1:-all}"
mode="--export-debug"
[[ "${2:-}" == "--release" ]] && mode="--export-release"

# Коммит сборки для «Об игре» (BuildInfo): 6 символов, «+» — есть незакоммиченные правки.
commit="$(git rev-parse --short=6 HEAD 2>/dev/null || echo "")"
[[ -n "$commit" && -n "$(git status --porcelain --untracked-files=no 2>/dev/null)" ]] && commit="$commit+"
printf '{"commit": "%s"}\n' "$commit" > data/build_info.json

# Файлы расширения AirOnnx в сборке по платформам (bin/<платформа>/ в addons/air_onnx и рядом с exe).
air_onnx_files() {
	case "$1" in
	linux) echo "libair_onnx.so libonnxruntime.so.1" ;;
	windows) echo "air_onnx.dll onnxruntime.dll msvcp140.dll msvcp140_1.dll vcruntime140.dll vcruntime140_1.dll" ;;
	esac
}
air_onnx="${AIR_ONNX:-1}"
if [[ "$air_onnx" != 0 ]]; then
	plats=()
	[[ "$target" == linux || "$target" == all ]] && plats+=(linux)
	[[ "$target" == windows || "$target" == all ]] && plats+=(windows)
	for p in "${plats[@]}"; do
		for f in $(air_onnx_files "$p"); do
			if [[ ! -f "addons/air_onnx/bin/$p/$f" || ! -f addons/air_onnx/air_onnx.gdextension ]]; then
				echo "AirOnnx: нет addons/air_onnx/bin/$p/$f — собираю native/air_onnx/build.sh $p"
				native/air_onnx/build.sh "$p"
				break
			fi
		done
	done
fi

# Импорт регистрирует расширение (addons/air_onnx/air_onnx.gdextension → .godot/extension_list.cfg).
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
	if [[ "$air_onnx" != 0 ]]; then
		for f in $(air_onnx_files "$dir"); do
			[[ -f "build/$dir/$f" ]] || { echo "ОШИБКА: в сборке нет $f (расширение AirOnnx)" >&2; exit 1; }
		done
	fi
	(cd build && rm -f "deltaplan-$dir.zip" && zip -qr "deltaplan-$dir.zip" "$dir")
	echo "готово: build/$dir/$bin, build/deltaplan-$dir.zip"
}

[[ "$target" == linux || "$target" == all ]] && build_one Linux linux deltaplan.x86_64
[[ "$target" == windows || "$target" == all ]] && build_one Windows windows deltaplan.exe

build_macos() {
	rm -rf build/macos build/deltaplan-macos.zip
	mkdir -p build/macos
	cp project.godot "build/.project.godot.bak"
	godot "${export_flags[@]}" --path . "$mode" macOS build/deltaplan-macos.zip
	cmp -s project.godot "build/.project.godot.bak" || cp "build/.project.godot.bak" project.godot
	rm -f "build/.project.godot.bak"
	(cd build/macos && unzip -q ../deltaplan-macos.zip)
	python3 tools/release/third_party_notices.py --out build/macos --preset macOS
	echo "готово: build/macos/$(ls build/macos), build/deltaplan-macos.zip"
}
[[ "$target" == macos || "$target" == all ]] && build_macos
exit 0  # иначе «build.sh linux» возвращает 1 от последней проверки [[ windows ]]
