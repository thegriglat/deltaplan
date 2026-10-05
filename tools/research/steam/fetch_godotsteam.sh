#!/usr/bin/env bash
# Скачивает закреплённую версию GodotSteam GDExtension в <копия>/addons/godotsteam/.
# Использование: fetch_godotsteam.sh [корень_проекта]   (по умолчанию — корень текущей git-копии)
# Идемпотентно: если стоит нужная версия (маркер .fetched), ничего не делает. Бинарники в git не коммитить.
set -euo pipefail
VERSION="4.22.1"
URL="https://codeberg.org/godotsteam/godotsteam/releases/download/v${VERSION}-gde/godotsteam-${VERSION}-gdextension-plugin-4.4.zip"
SHA256="2b12b3499434c50da16104a0d22b725aee15cc5cd41223c1cea825bae59bfa8f"
ROOT="${1:-$(git rev-parse --show-toplevel)}"
DEST="$ROOT/addons/godotsteam"
if [ -f "$DEST/.fetched" ] && [ "$(cat "$DEST/.fetched")" = "$VERSION $SHA256" ]; then
  echo "godotsteam $VERSION уже в $DEST"; exit 0
fi
CACHE="${GODOTSTEAM_CACHE:-$HOME/.cache/deltaplan}"
mkdir -p "$CACHE"
ZIP="$CACHE/godotsteam-$VERSION-gde.zip"
if ! { [ -f "$ZIP" ] && echo "$SHA256  $ZIP" | sha256sum -c --status; }; then
  curl -fsSL -o "$ZIP.part" "$URL"; mv "$ZIP.part" "$ZIP"
fi
echo "$SHA256  $ZIP" | sha256sum -c --status || { echo "sha256 не совпал: $ZIP" >&2; rm -f "$ZIP"; exit 1; }
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
unzip -q "$ZIP" -d "$TMP"
rm -rf "$DEST"; mkdir -p "$ROOT/addons"
cp -r "$TMP/addons/godotsteam" "$DEST"
echo "$VERSION $SHA256" > "$DEST/.fetched"
echo "godotsteam $VERSION -> $DEST"
