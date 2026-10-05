#!/usr/bin/env bash
# Скачивает VC++ runtime (Redist x64) из официальных пакетов Visual Studio 2022 Build Tools через msvc-wine
# (github.com/mstorsjo/msvc-wine) — вне репозитория, на Linux. Результат — каталог для MSVC_REDIST_DIR:
#   MSVC_ACCEPT_LICENSE=yes tools/release/fetch_msvc_redist.sh [каталог]   (по умолчанию ~/msvc)
#   MSVC_ACCEPT_LICENSE=yes MSVC_REDIST_DIR=$(tools/release/fetch_msvc_redist.sh) native/air_onnx/build.sh windows
# Лицензию Visual Studio Build Tools принимает автор: без MSVC_ACCEPT_LICENSE=yes скрипт ничего не качает.
# Качается только Redist (Microsoft.VC.<ver>.CRT.Redist.X64), не компилятор. Последняя строка stdout — каталог DLL.
set -euo pipefail

MSVC_WINE_COMMIT=514f8ea34842cd6d831804d0e9658d3a32870ae1
VS_MAJOR=17                          # Visual Studio 2022 (у vsdownload.py по умолчанию уже 2026)
PKG_RE='^Microsoft\.VC\.14\.44\.[0-9.]+\.CRT\.Redist\.X64$'   # закреплённая линейка 14.44 (см. native/air_onnx/build.sh)
OUT="${1:-$HOME/msvc}"
SRC="${MSVC_WINE_DIR:-$HOME/msvc-wine}"

if [ "${MSVC_ACCEPT_LICENSE:-}" != yes ]; then
	echo "Лицензия Visual Studio Build Tools (https://go.microsoft.com/fwlink/?linkid=2086102) не принята:" >&2
	echo "принять её — решение автора, задайте MSVC_ACCEPT_LICENSE=yes." >&2
	exit 1
fi

[ -d "$SRC/.git" ] || git clone -q https://github.com/mstorsjo/msvc-wine "$SRC"
git -C "$SRC" checkout -q "$MSVC_WINE_COMMIT"

mkdir -p "$OUT"
PKG="$(python3 "$SRC/vsdownload.py" --major "$VS_MAJOR" --accept-license --list-packages 2>/dev/null \
	| grep -E "$PKG_RE" | sort -V | tail -1)"
[ -n "$PKG" ] || { echo "пакет $PKG_RE не найден в манифесте VS $VS_MAJOR" >&2; exit 1; }
echo "пакет: $PKG" >&2
python3 "$SRC/vsdownload.py" --major "$VS_MAJOR" --accept-license --cache "$OUT/cache" --dest "$OUT/vs" \
	--with-default no --with-msvc no --with-sdk no --with-msbuild no --with-devcmd no --with-workload no "$PKG" >&2 || true

DIR="$(find "$OUT/vs" "$OUT/cache" -type d -ipath '*x64*' -iname 'Microsoft.VC14*.CRT' -print -quit 2>/dev/null || true)"
[ -n "$DIR" ] || { echo "Microsoft.VC14x.CRT не найден под $OUT" >&2; find "$OUT/vs" -iname 'msvcp140.dll' >&2; exit 1; }
echo "$DIR"
