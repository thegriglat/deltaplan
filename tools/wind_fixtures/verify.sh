#!/usr/bin/env bash
# Пересъёмка эталонов ветра во временный каталог и побитное сравнение с tests/fixtures/wind/
# (.bin, .desc.json, places/*; в cases/*.json поле generator — коммит — не сравнивается).
# Случаи с полем Пикара идут на GPU (окно). Дневной случай (~5 мин) — отдельный прогон, набор 1 —
# один: параллельно, иначе проверка не укладывается в 15 минут приёмки. exit 0 — совпало.
set -uo pipefail
cd "$(dirname "$0")/../.."
tmp="$(mktemp -d)"
pg_backup="$tmp/project.godot.bak"
cp project.godot "$pg_backup"
trap 'cmp -s project.godot "$pg_backup" || cp "$pg_backup" project.godot; rm -rf "$tmp"' EXIT
ref=tests/fixtures/wind

# импорт один раз (параллельные прогоны его не делают)
profile="$tmp/profile"
mkdir -p "$profile"
XDG_DATA_HOME="$profile" godot --headless --path . --import >/dev/null 2>&1 || true

# группы случаев: каждый ongudai_day_* отдельно, остальные вместе
rest=""
days=()
for f in "$ref"/cases/*.json; do
	n="$(basename "$f" .json)"
	case "$n" in
	*.desc) continue ;;
	ongudai_day_*) days+=("$n") ;;
	*) rest="${rest:+$rest,}$n" ;;
	esac
done
groups=()
[ -n "$rest" ] && groups+=("$rest")
groups+=("${days[@]}")

pids=()
i=0
for g in "${groups[@]}"; do
	WIND_FIXTURES_NO_IMPORT=1 tools/wind_fixtures/run.sh --out="$tmp/g$i" --only="$g" >"$tmp/run$i.log" 2>&1 &
	pids+=($!)
	i=$((i + 1))
done
bad=0
for k in "${!pids[@]}"; do
	wait "${pids[$k]}" || { tail -30 "$tmp/run$k.log"; echo "verify: генератор упал (группа ${groups[$k]})"; bad=2; }
done
[ "$bad" = 0 ] || exit "$bad"

# один каталог на файл: случай/место есть ровно в своей группе (places/ongudai — в нескольких: сравниваются все)
for f in $(cd "$ref" && find places cases -type f | sort); do
	found=0
	for d in "$tmp"/g*; do
		[ -e "$d/$f" ] || continue
		found=1
		case "$f" in
		*.tmp) continue ;;
		cases/*.desc.json | *.bin | places/*) cmp -s "$d/$f" "$ref/$f" || { echo "verify: расходится $f"; bad=1; } ;;
		cases/*.json)
			python3 - "$d/$f" "$ref/$f" <<'P' || { echo "verify: расходится $f"; bad=1; }
import json, sys
a, b = (json.load(open(p)) for p in sys.argv[1:3])
a.pop("generator", None); b.pop("generator", None)
sys.exit(0 if a == b else 1)
P
			;;
		esac
	done
	[ "$found" = 1 ] || { echo "verify: нет в пересъёмке $f"; bad=1; }
done
[ "$bad" = 0 ] && echo "verify: фикстуры воспроизводятся побитно"
exit "$bad"
