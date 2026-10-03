#!/usr/bin/env bash
# Сборка GDExtension AirOnnx (контракт O2): скачивает ORT и godot-cpp, собирает расширение.
#   ./build.sh            — Linux x86_64 (системные cmake + g++)
#   ./build.sh windows    — Windows x86_64 из Linux (llvm-mingw, скачивается; против MSVC-сборки ORT через C ABI)
#   ./build.sh all        — обе
#   ./build.sh clean      — убрать собранное из проекта (bin/, .gdextension и строку в .godot/extension_list.cfg:
#                           импорт редактора сам устаревшую запись не убирает — ошибки при каждом запуске)
# Зависимости — в $DEPS_DIR (по умолчанию ~/.cache/deltaplan-air-onnx-deps, общий для копий), сборка — build/,
# результат — addons/air_onnx/bin/{linux,windows}/ + addons/air_onnx/air_onnx.gdextension
# (оба не в git: без сборки расширения в проекте нет, игра работает без него — см. README).
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
DEPS_DIR="${DEPS_DIR:-${XDG_CACHE_HOME:-$HOME/.cache}/deltaplan-air-onnx-deps}"   # общий для всех копий
BUILD_DIR="${BUILD_DIR:-$HERE/build}"
ADDON_DIR="$ROOT/addons/air_onnx"
BIN_DIR="$ADDON_DIR/bin"
JOBS="${JOBS:-$(nproc)}"

ORT_VER=1.30.0                       # = onnxruntime в venv пилота (эталон)
GODOT_CPP_TAG=10.0.0-stable         # godot-cpp v10 версируется отдельно от Godot; API 4.7 — встроенный (api_version)
GODOT_CPP_COMMIT=507ed9d840c01a3c5b2a39af8bb4000bfac30bf5
GODOT_API=4.7
LLVM_MINGW_VER=20260922
# VC++ runtime для onnxruntime.dll (MSVC) — app-local рядом с ним (README, «Windows»). Источник —
# колесо PyPI msvc-runtime (те же DLL, что в vc_redist.x64.exe), закреплено по sha256.
MSVC_RT_VER=14.44.35112
MSVC_RT_URL="https://files.pythonhosted.org/packages/21/3b/134d04268ab8e35853cd007582076429b45d60d6abb1036d159be9c50342/msvc_runtime-$MSVC_RT_VER-cp312-cp312-win_amd64.whl"
MSVC_RT_SHA256=32f9c706009e16ccc319d6947ce3bffe20e5192bee52b18cf48313f9e7bedfbe
MSVC_RT_DLLS="msvcp140.dll msvcp140_1.dll vcruntime140.dll vcruntime140_1.dll"

TARGETS="${1:-linux}"
if [ "$TARGETS" = clean ]; then
	rm -rf "$BIN_DIR" "$ADDON_DIR/air_onnx.gdextension"
	EL="$ROOT/.godot/extension_list.cfg"
	if [ -f "$EL" ]; then
		grep -v '^res://addons/air_onnx/air_onnx.gdextension$' "$EL" > "$EL.tmp" || true
		mv "$EL.tmp" "$EL"
	fi
	echo "убрано: $BIN_DIR, $ADDON_DIR/air_onnx.gdextension, запись в .godot/extension_list.cfg"
	exit 0
fi
[ "$TARGETS" = all ] && TARGETS="linux windows"

mkdir -p "$DEPS_DIR" "$BUILD_DIR" "$BIN_DIR"

fetch() { # url dest
	[ -f "$2" ] || { echo "скачиваю $1"; curl -fL --retry 3 -o "$2.part" "$1" && mv "$2.part" "$2"; }
}

# Распаковка в каталог .part и переименование: прерванная распаковка в общем кэше не оставляет
# полупустой каталог, который следующий запуск принял бы за готовый. В архиве — один каталог верхнего уровня.
unpack() { # каталог_результата команда_распаковки… (последний аргумент команды — куда распаковать)
	local dest="$1" tmp="$1.part"
	[ -d "$dest" ] && return 0
	rm -rf "$tmp"; mkdir -p "$tmp"
	"${@:2}" "$tmp"
	mv "$tmp/$(ls "$tmp")" "$dest"; rmdir "$tmp"
}

# --- godot-cpp ---
if [ ! -d "$DEPS_DIR/godot-cpp/.git" ]; then
	rm -rf "$DEPS_DIR/godot-cpp.part"
	git clone --depth 1 --branch "$GODOT_CPP_TAG" https://github.com/godotengine/godot-cpp "$DEPS_DIR/godot-cpp.part"
	mv "$DEPS_DIR/godot-cpp.part" "$DEPS_DIR/godot-cpp"
fi
test "$(git -C "$DEPS_DIR/godot-cpp" rev-parse HEAD)" = "$GODOT_CPP_COMMIT" || { echo "godot-cpp: не тот коммит"; exit 1; }

for T in $TARGETS; do
	case "$T" in
	linux)
		ORT_DIR="$DEPS_DIR/onnxruntime-linux-x64-$ORT_VER"
		fetch "https://github.com/microsoft/onnxruntime/releases/download/v$ORT_VER/onnxruntime-linux-x64-$ORT_VER.tgz" "$DEPS_DIR/ort-linux-$ORT_VER.tgz"
		unpack "$ORT_DIR" tar -xzf "$DEPS_DIR/ort-linux-$ORT_VER.tgz" -C
		mkdir -p "$BIN_DIR/linux"
		cmake -S "$HERE" -B "$BUILD_DIR/linux" -DCMAKE_BUILD_TYPE=Release -DDEPS_DIR="$DEPS_DIR" \
			-DGODOTCPP_API_VERSION="$GODOT_API" -DORT_DIR="$ORT_DIR" -DAIR_ONNX_BIN_DIR="$BIN_DIR/linux"
		cmake --build "$BUILD_DIR/linux" -j "$JOBS"
		cp -L "$ORT_DIR/lib/libonnxruntime.so.$ORT_VER" "$BIN_DIR/linux/libonnxruntime.so.1"
		;;
	windows)
		ORT_DIR="$DEPS_DIR/onnxruntime-win-x64-$ORT_VER"
		fetch "https://github.com/microsoft/onnxruntime/releases/download/v$ORT_VER/onnxruntime-win-x64-$ORT_VER.zip" "$DEPS_DIR/ort-win-$ORT_VER.zip"
		unpack "$ORT_DIR" python3 -m zipfile -e "$DEPS_DIR/ort-win-$ORT_VER.zip"
		LM="$DEPS_DIR/llvm-mingw-$LLVM_MINGW_VER-ucrt-ubuntu-22.04-x86_64"
		fetch "https://github.com/mstorsjo/llvm-mingw/releases/download/$LLVM_MINGW_VER/llvm-mingw-$LLVM_MINGW_VER-ucrt-ubuntu-22.04-x86_64.tar.xz" "$DEPS_DIR/llvm-mingw-$LLVM_MINGW_VER.tar.xz"
		unpack "$LM" tar -xJf "$DEPS_DIR/llvm-mingw-$LLVM_MINGW_VER.tar.xz" -C
		RT_WHL="$DEPS_DIR/msvc-runtime-$MSVC_RT_VER.whl"
		RT_DIR="$DEPS_DIR/msvc-runtime-$MSVC_RT_VER"
		fetch "$MSVC_RT_URL" "$RT_WHL"
		echo "$MSVC_RT_SHA256  $RT_WHL" | sha256sum -c --quiet
		if [ ! -d "$RT_DIR" ]; then
			rm -rf "$RT_DIR.part"; mkdir -p "$RT_DIR.part"
			python3 -m zipfile -e "$RT_WHL" "$RT_DIR.part"
			mv "$RT_DIR.part" "$RT_DIR"
		fi
		mkdir -p "$BIN_DIR/windows"
		cmake -S "$HERE" -B "$BUILD_DIR/windows" -DCMAKE_BUILD_TYPE=Release -DDEPS_DIR="$DEPS_DIR" \
			-DCMAKE_TOOLCHAIN_FILE="$HERE/cmake/llvm-mingw.cmake" -DLLVM_MINGW="$LM" \
			-DGODOTCPP_API_VERSION="$GODOT_API" -DORT_DIR="$ORT_DIR" -DAIR_ONNX_BIN_DIR="$BIN_DIR/windows"
		cmake --build "$BUILD_DIR/windows" -j "$JOBS"
		cp "$ORT_DIR/lib/onnxruntime.dll" "$BIN_DIR/windows/"
		for d in $MSVC_RT_DLLS; do
			f="$(find "$RT_DIR" -iname "$d" -print -quit)"
			[ -n "$f" ] || { echo "в msvc-runtime нет $d"; exit 1; }
			cp "$f" "$BIN_DIR/windows/$d"
		done
		;;
	*) echo "неизвестная цель $T"; exit 2 ;;
	esac
done

# .gdextension появляется только после сборки: его наличие и регистрирует расширение в проекте
# (README, «Как расширение попадает в игру»). Без него игра о расширении не знает и не ругается.
cp "$HERE/air_onnx.gdextension.in" "$ADDON_DIR/air_onnx.gdextension"
echo "готово: $BIN_DIR"; ls -la "$BIN_DIR"/*/
