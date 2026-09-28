#!/usr/bin/env bash
# MPFB 2 (MakeHuman для Blender) — инструмент сборки пилота (tools/blender/build_pilot.py).
# Ставится в ОТДЕЛЬНЫЙ пользовательский каталог Blender (~/.cache/deltaplan/blender_user), не в
# ~/.config/blender. Повторный запуск ничего не делает. Потом сборка пилота:
#   BLENDER_USER_RESOURCES=~/.cache/deltaplan/blender_user \
#       blender --background --python tools/blender/build_pilot.py
set -euo pipefail
VER=2.0.17
SHA=4f0a879d64a39bf646fbf5f53601ac678855da329d650617dca5737548239a87
URL=https://extensions.blender.org/download/sha256:$SHA/add-on-mpfb-v$VER.zip
CACHE=~/.cache/deltaplan
ZIP=$CACHE/mpfb-$VER.zip
export BLENDER_USER_RESOURCES=$CACHE/blender_user
mkdir -p "$CACHE" "$BLENDER_USER_RESOURCES"

if [[ -f "$BLENDER_USER_RESOURCES/extensions/user_default/mpfb/__init__.py" ]] &&
	blender --background --python-exit-code 1 --python-expr \
		"import bl_ext.user_default.mpfb.services.humanservice" >/dev/null 2>&1; then
	echo "MPFB уже установлен: $BLENDER_USER_RESOURCES"
	exit 0
fi
if [[ ! -f "$ZIP" ]] || ! echo "$SHA  $ZIP" | sha256sum -c --status; then
	echo "Скачиваю MPFB $VER…"
	curl -fL -o "$ZIP.part" "$URL"
	echo "$SHA  $ZIP.part" | sha256sum -c --status || {
		echo "ОШИБКА: sha256 архива MPFB не совпадает" >&2
		exit 1
	}
	mv "$ZIP.part" "$ZIP"
fi
blender --background --command extension install-file -r user_default -e "$ZIP"
blender --background --python-exit-code 1 --python-expr "import bl_ext.user_default.mpfb.services.humanservice" \
	>/dev/null
echo "MPFB $VER установлен: $BLENDER_USER_RESOURCES"
