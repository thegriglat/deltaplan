#!/usr/bin/env bash
# Сборка пробника AirNnProbe (NN-7а): скачивает ORT и godot-cpp, собирает GDExtension.
#   ./build.sh            — Linux x86_64 (системные cmake + g++)
#   ./build.sh windows    — Windows x86_64 из Linux (llvm-mingw, скачивается; против MSVC-сборки ORT через C ABI)
#   ./build.sh all        — обе
# Зависимости — в $DEPS_DIR (по умолчанию third_party/ здесь, игнорируется git), сборка — build/,
# результат — bin/ (библиотеки + air_nn_probe.gdextension; bin/ не в git и скрыт от редактора .gdignore).
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEPS_DIR="${DEPS_DIR:-$HERE/third_party}"
BUILD_DIR="${BUILD_DIR:-$HERE/build}"
BIN_DIR="$HERE/bin"
JOBS="${JOBS:-$(nproc)}"

ORT_VER=1.30.0                       # = onnxruntime в venv пилота (эталон)
GODOT_CPP_TAG=10.0.0-stable         # godot-cpp v10 версируется отдельно от Godot; API 4.7 — встроенный (api_version)
GODOT_CPP_COMMIT=507ed9d840c01a3c5b2a39af8bb4000bfac30bf5
GODOT_API=4.7
LLVM_MINGW_VER=20260922

TARGETS="${1:-linux}"
[ "$TARGETS" = all ] && TARGETS="linux windows"

mkdir -p "$DEPS_DIR" "$BUILD_DIR" "$BIN_DIR"

fetch() { # url dest
	[ -f "$2" ] || { echo "скачиваю $1"; curl -fL --retry 3 -o "$2.part" "$1" && mv "$2.part" "$2"; }
}

# --- godot-cpp ---
if [ ! -d "$DEPS_DIR/godot-cpp/.git" ]; then
	git clone --depth 1 --branch "$GODOT_CPP_TAG" https://github.com/godotengine/godot-cpp "$DEPS_DIR/godot-cpp"
fi
test "$(git -C "$DEPS_DIR/godot-cpp" rev-parse HEAD)" = "$GODOT_CPP_COMMIT" || { echo "godot-cpp: не тот коммит"; exit 1; }

for T in $TARGETS; do
	case "$T" in
	linux)
		ORT_DIR="$DEPS_DIR/onnxruntime-linux-x64-$ORT_VER"
		fetch "https://github.com/microsoft/onnxruntime/releases/download/v$ORT_VER/onnxruntime-linux-x64-$ORT_VER.tgz" "$DEPS_DIR/ort-linux.tgz"
		[ -d "$ORT_DIR" ] || tar -C "$DEPS_DIR" -xzf "$DEPS_DIR/ort-linux.tgz"
		cmake -S "$HERE" -B "$BUILD_DIR/linux" -DCMAKE_BUILD_TYPE=Release \
			-DGODOTCPP_API_VERSION="$GODOT_API" -DORT_DIR="$ORT_DIR" -DPROBE_BIN_DIR="$BIN_DIR/linux"
		cmake --build "$BUILD_DIR/linux" -j "$JOBS"
		cp -L "$ORT_DIR/lib/libonnxruntime.so.$ORT_VER" "$BIN_DIR/linux/libonnxruntime.so.1"
		;;
	windows)
		ORT_DIR="$DEPS_DIR/onnxruntime-win-x64-$ORT_VER"
		fetch "https://github.com/microsoft/onnxruntime/releases/download/v$ORT_VER/onnxruntime-win-x64-$ORT_VER.zip" "$DEPS_DIR/ort-win.zip"
		[ -d "$ORT_DIR" ] || (cd "$DEPS_DIR" && python3 -m zipfile -e ort-win.zip .)
		LM="$DEPS_DIR/llvm-mingw-$LLVM_MINGW_VER-ucrt-ubuntu-22.04-x86_64"
		fetch "https://github.com/mstorsjo/llvm-mingw/releases/download/$LLVM_MINGW_VER/llvm-mingw-$LLVM_MINGW_VER-ucrt-ubuntu-22.04-x86_64.tar.xz" "$DEPS_DIR/llvm-mingw.tar.xz"
		[ -d "$LM" ] || tar -C "$DEPS_DIR" -xJf "$DEPS_DIR/llvm-mingw.tar.xz"
		cmake -S "$HERE" -B "$BUILD_DIR/windows" -DCMAKE_BUILD_TYPE=Release \
			-DCMAKE_TOOLCHAIN_FILE="$HERE/cmake/llvm-mingw.cmake" -DLLVM_MINGW="$LM" \
			-DGODOTCPP_API_VERSION="$GODOT_API" -DORT_DIR="$ORT_DIR" -DPROBE_BIN_DIR="$BIN_DIR/windows"
		cmake --build "$BUILD_DIR/windows" -j "$JOBS"
		cp "$ORT_DIR/lib/onnxruntime.dll" "$BIN_DIR/windows/"
		;;
	*) echo "неизвестная цель $T"; exit 2 ;;
	esac
done

cp "$HERE/air_nn_probe.gdextension.in" "$BIN_DIR/air_nn_probe.gdextension"
touch "$BIN_DIR/.gdignore"
echo "готово: $BIN_DIR"; ls -la "$BIN_DIR"/*/
