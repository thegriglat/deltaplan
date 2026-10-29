#!/usr/bin/env bash
# Дамп RW-9 из Godot (опорная ревизия c591b1026): rust/dp-air/tests/data/RW-9/dump.sh [--out=<каталог>]
# Headless, временный профиль, project.godot возвращается как был.
# Godot — под замком cpu: .dpcli/dpcli lock cpu <имя> -- rust/dp-air/tests/data/RW-9/dump.sh
set -uo pipefail
cd "$(dirname "$0")/../../../../.."
out=""
for a in "$@"; do
	case "$a" in
	--out=*) out="${a#--out=}" ;;
	esac
done
tmp="$(mktemp -d)"
profile="$tmp/profile"
mkdir -p "$profile"
cp project.godot "$tmp/project.godot.bak"
trap 'cmp -s project.godot "$tmp/project.godot.bak" || cp "$tmp/project.godot.bak" project.godot; rm -rf "$tmp"' EXIT
XDG_DATA_HOME="$profile" godot --headless --path . --import >/dev/null 2>&1 || true
dst="${out:-$PWD/rust/dp-air/tests/data/RW-9}"
dst="$(realpath -m "$dst")"
XDG_DATA_HOME="$profile" godot --headless --path . res://rust/dp-air/tests/data/RW-9/dump.tscn -- "--out=$dst" || exit 2
du -sh "$dst"
