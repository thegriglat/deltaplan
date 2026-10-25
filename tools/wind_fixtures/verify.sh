#!/usr/bin/env bash
# Пересъёмка эталонов ветра во временный каталог и побитное сравнение с tests/fixtures/wind/
# (.bin, .desc.json, places/*; в cases/*.json поле generator — коммит — не сравнивается).
# Случаи с полем Пикара идут на GPU (окно). exit 0 — совпало.
set -uo pipefail
cd "$(dirname "$0")/../.."
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
tools/wind_fixtures/run.sh --out="$tmp" >"$tmp/run.log" 2>&1 || { tail -30 "$tmp/run.log"; echo "verify: генератор упал"; exit 2; }
ref=tests/fixtures/wind
bad=0
for f in $(cd "$tmp" && find places cases -type f | sort); do
	case "$f" in
	*.tmp) continue ;;
	cases/*.desc.json | *.bin | places/*) cmp -s "$tmp/$f" "$ref/$f" || { echo "verify: расходится $f"; bad=1; } ;;
	cases/*.json)
		python3 - "$tmp/$f" "$ref/$f" <<'P' || { echo "verify: расходится $f"; bad=1; }
import json, sys
a, b = (json.load(open(p)) for p in sys.argv[1:3])
a.pop("generator", None); b.pop("generator", None)
sys.exit(0 if a == b else 1)
P
		;;
	esac
done
for f in $(cd "$ref" && find places cases -type f | sort); do
	[ -e "$tmp/$f" ] || { echo "verify: нет в пересъёмке $f"; bad=1; }
done
[ "$bad" = 0 ] && echo "verify: фикстуры воспроизводятся побитно"
exit "$bad"
