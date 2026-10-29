#!/usr/bin/env bash
# Дамп хода дня и коэффициентов Godot для dp-air (RW-12c): tools/wind_fixtures/day_dump.sh [--out=<каталог>] | --verify
# Headless, временный профиль, project.godot возвращается как был. rows.jsonl сжимается в rows.jsonl.zst
# (zstd -19). --verify — пересъёмка во временный каталог и сравнение несжатого содержимого и manifest.json
# с rust/dp-air/tests/data/day_dump/ (exit 0 — совпало).
# Godot — под замком cpu: .dpcli/dpcli lock cpu <имя> -- tools/wind_fixtures/day_dump.sh
set -uo pipefail
cd "$(dirname "$0")/../.."
ref=rust/dp-air/tests/data/day_dump
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
log="$tmp/godot.log"
if ! XDG_DATA_HOME="$profile" timeout 1500 godot --headless --path . res://tools/wind_fixtures/day_dump.tscn -- "--out=$dst" >"$log" 2>&1; then
	tail -30 "$log"
	echo "day_dump: Godot упал"
	exit 2
fi
if grep -q "SCRIPT ERROR" "$log"; then
	grep "SCRIPT ERROR" "$log" | head -20
	echo "day_dump: ошибки сценария"
	exit 2
fi
if [ "$verify" = 1 ]; then
	rc=0
	cmp -s "$ref/manifest.json" "$dst/manifest.json" || { echo "day_dump: manifest.json отличается"; rc=1; }
	zstd -dcq "$ref/rows.jsonl.zst" | cmp -s - "$dst/rows.jsonl" || { echo "day_dump: rows.jsonl отличается"; rc=1; }
	[ "$rc" = 0 ] && echo "day_dump: дамп воспроизводится побитно"
	exit "$rc"
fi
zstd -19 -q -f --no-progress "$dst/rows.jsonl" -o "$dst/rows.jsonl.zst" && rm -f "$dst/rows.jsonl"
du -sh "$dst"
