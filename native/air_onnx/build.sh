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
# VC++ runtime для onnxruntime.dll (MSVC) — app-local рядом с ним (README, «Windows»). Источник — официальный
# распространяемый пакет Visual Studio 2022 (VC\Redist\MSVC\<ver>\x64\Microsoft.VC143.CRT), который автор
# берёт со своей машины с бесплатной Visual Studio Community / Build Tools. Раздача DLL — по условиям лицензии
# Visual Studio (Distributable Code), автор принимает её сам: сборка Windows требует явного согласия
# MSVC_ACCEPT_LICENSE=yes (молча не принимается). Версия и sha256 каждой DLL закреплены.
#   MSVC_REDIST_DIR=<каталог>  — Microsoft.VC143.CRT или любой выше (…\VC\Redist\MSVC\<ver>\x64), скопированный с
#                                 машины с VS; DLL ищутся рекурсивно.
MSVC_RT_VER=14.44.35112
MSVC_RT_SHA256="msvcp140.dll=0f885b509a685d2bbfa652fed26b5fb31d88fbdab0a978c641d1c7b8aa460aa9
msvcp140_1.dll=bfad5aef4c63a669e3c140655cdfdf395b6c979b400a447bd5dcb65ed8826c3d
vcruntime140.dll=d5e4d9a3e835fa679450145d6a7d94e36573a509317111904d9b3712c30d9066
vcruntime140_1.dll=1f2d41c4aa5db0bc33ebf7b66d72943a817d7ce6cbe880502a9403823633093f"
MSVC_RT_DLLS="msvcp140.dll msvcp140_1.dll vcruntime140.dll vcruntime140_1.dll"

# Копирует VC++ runtime из $MSVC_REDIST_DIR в каталог $1 с проверкой sha256; без источника или согласия — ошибка.
copy_msvc_runtime() { # каталог_назначения
	local dest="$1" d f want got
	if [ "${MSVC_ACCEPT_LICENSE:-}" != yes ]; then
		echo "Windows: VC++ runtime $MSVC_RT_VER берётся из Visual Studio 2022 (VC\\Redist) и раздаётся по лицензии Visual Studio" >&2
		echo "(Microsoft Software License Terms, Distributable Code). Принять её — решение автора: задайте MSVC_ACCEPT_LICENSE=yes." >&2
		return 1
	fi
	if [ -z "${MSVC_REDIST_DIR:-}" ] || [ ! -d "$MSVC_REDIST_DIR" ]; then
		echo "Windows: не задан MSVC_REDIST_DIR (каталог VC\\Redist\\MSVC\\<ver>\\x64 или Microsoft.VC143.CRT," >&2
		echo "скопированный с машины с Visual Studio 2022 Community / Build Tools; см. native/air_onnx/README.md)." >&2
		return 1
	fi
	for d in $MSVC_RT_DLLS; do
		f="$(find "$MSVC_REDIST_DIR" -ipath '*x64*' -iname "$d" -print -quit)"
		[ -n "$f" ] || f="$(find "$MSVC_REDIST_DIR" -iname "$d" -print -quit)"
		[ -n "$f" ] || { echo "в $MSVC_REDIST_DIR нет $d" >&2; return 1; }
		want="$(printf '%s\n' "$MSVC_RT_SHA256" | sed -n "s/^$d=//p")"
		got="$(sha256sum "$f" | cut -d' ' -f1)"
		if [ "$got" != "$want" ]; then
			echo "$f: sha256 $got не совпадает с закреплённым для VC++ runtime $MSVC_RT_VER ($want)." >&2
			echo "Нужна именно эта версия Redist; если автор сознательно обновляет — поменять MSVC_RT_VER и хэши здесь и в ASSETS.md." >&2
			return 1
		fi
		cp "$f" "$dest/$d"
	done
}

TARGETS="${1:-linux}"
if [ "$TARGETS" = clean ]; then
	rm -rf "$BIN_DIR" "$ADDON_DIR/air_onnx.gdextension" "$ADDON_DIR/air_onnx.gdextension.uid"
	EL="$ROOT/.godot/extension_list.cfg"
	if [ -f "$EL" ]; then
		grep -v '^res://addons/air_onnx/air_onnx.gdextension$' "$EL" > "$EL.tmp" || true
		mv "$EL.tmp" "$EL"
	fi
	echo "убрано: $BIN_DIR, $ADDON_DIR/air_onnx.gdextension(.uid), запись в .godot/extension_list.cfg"
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
		mkdir -p "$BIN_DIR/windows"
		copy_msvc_runtime "$BIN_DIR/windows"   # до сборки: без источника DLL падаем сразу
		cmake -S "$HERE" -B "$BUILD_DIR/windows" -DCMAKE_BUILD_TYPE=Release -DDEPS_DIR="$DEPS_DIR" \
			-DCMAKE_TOOLCHAIN_FILE="$HERE/cmake/llvm-mingw.cmake" -DLLVM_MINGW="$LM" \
			-DGODOTCPP_API_VERSION="$GODOT_API" -DORT_DIR="$ORT_DIR" -DAIR_ONNX_BIN_DIR="$BIN_DIR/windows"
		cmake --build "$BUILD_DIR/windows" -j "$JOBS"
		cp "$ORT_DIR/lib/onnxruntime.dll" "$BIN_DIR/windows/"
		;;
	*) echo "неизвестная цель $T"; exit 2 ;;
	esac
done

# .gdextension появляется только после сборки: его наличие и регистрирует расширение в проекте
# (README, «Как расширение попадает в игру»). Без него игра о расширении не знает и не ругается.
cp "$HERE/air_onnx.gdextension.in" "$ADDON_DIR/air_onnx.gdextension"
echo "готово: $BIN_DIR"; ls -la "$BIN_DIR"/*/
