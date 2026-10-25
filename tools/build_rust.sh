#!/usr/bin/env bash
# Сборка расширения DpAir (W9): tools/build_rust.sh <tune|release> <linux|windows|macos>
# Результат — addons/dp_air/bin/ (в .gitignore): libdp_air_<профиль>.so | dp_air_<профиль>.dll
# Windows с Linux: цель x86_64-pc-windows-gnu, компоновщик mingw-w64 (rust/.cargo/config.toml);
#   пакет gcc-mingw-w64-x86-64 ставит пользователь. Нет компоновщика — SKIP, exit 0.
# macOS пока не поддерживается — сообщение, exit 0.
set -euo pipefail
cd "$(dirname "$0")/.."
profile="${1:?профиль: tune|release}"
os="${2:?ОС: linux|windows|macos}"
[[ "$profile" == tune || "$profile" == release ]] || { echo "профиль: tune|release" >&2; exit 2; }
manifest=rust/Cargo.toml
bin=addons/dp_air/bin
mkdir -p "$bin"

case "$os" in
linux)
	cargo build --manifest-path "$manifest" -p dp-gd --profile "$profile"
	cp "rust/target/$profile/libdp_gd.so" "$bin/libdp_air_$profile.so"
	;;
windows)
	if ! command -v x86_64-w64-mingw32-gcc >/dev/null 2>&1; then
		echo "SKIP: нет x86_64-w64-mingw32-gcc (пакет gcc-mingw-w64-x86-64) — DLL под Windows не собрана"
		exit 0
	fi
	rustup target add x86_64-pc-windows-gnu >/dev/null 2>&1 || true
	cargo build --manifest-path "$manifest" -p dp-gd --profile "$profile" --target x86_64-pc-windows-gnu
	cp "rust/target/x86_64-pc-windows-gnu/$profile/dp_gd.dll" "$bin/dp_air_$profile.dll"
	;;
macos)
	echo "macOS пока не поддерживается — расширение не собирается"
	exit 0
	;;
*) echo "ОС: linux|windows|macos" >&2; exit 2 ;;
esac
echo "готово: $bin ($os, $profile)"
