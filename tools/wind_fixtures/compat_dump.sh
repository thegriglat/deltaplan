#!/usr/bin/env bash
# Дамп совместимости Godot для dp-air (RW-8c): tools/wind_fixtures/compat_dump.sh [--out=<каталог>] | --verify
# Headless, временный профиль, project.godot возвращается как был. --verify — пересъёмка во временный
# каталог и побитное сравнение с rust/dp-air/tests/data/godot_compat/ (exit 0 — совпало).
# Godot — под замком cpu: .dpcli/dpcli lock cpu <имя> -- tools/wind_fixtures/compat_dump.sh
set -uo pipefail
cd "$(dirname "$0")/../.."
ref=rust/dp-air/tests/data/godot_compat
verify=0
out=""
for a in "$@"; do
	case "$a" in
	--verify) verify=1 ;;
	--out=*) out="${a#--out=}" ;;
	esac
done
tmp="$(mktemp -d)"
profile="$tmp/profile"
mkdir -p "$profile"
cp project.godot "$tmp/project.godot.bak"
trap 'cmp -s project.godot "$tmp/project.godot.bak" || cp "$tmp/project.godot.bak" project.godot; rm -rf "$tmp"' EXIT
XDG_DATA_HOME="$profile" godot --headless --path . --import >/dev/null 2>&1 || true
if [ "$verify" = 1 ]; then
	dst="$tmp/out"
elif [ -n "$out" ]; then
	dst="$(realpath -m "$out")"
else
	dst="$PWD/$ref"
fi
XDG_DATA_HOME="$profile" godot --headless --path . res://tools/wind_fixtures/compat_dump.tscn -- "--out=$dst" || exit 2
if [ "$verify" = 1 ]; then
	if diff -r "$ref" "$dst" >/dev/null; then
		echo "compat_dump: дамп воспроизводится побитно"
		exit 0
	fi
	diff -rq "$ref" "$dst"
	exit 1
fi
du -sh "$dst"
