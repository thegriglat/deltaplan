#!/usr/bin/env bash
# Эталоны погоды E1–E10 с GD-кода для dp-air (RW-14b): tools/wind_fixtures/weather_ref2.sh [--out=<каталог>] | --check
# Headless, временный профиль, project.godot возвращается как был. Каждый e*.jsonl сжимается в .jsonl.zst
# (zstd -19). --check (он же --verify) — пересъёмка во временный каталог и сравнение несжатого содержимого
# и manifest.json с rust/dp-air/tests/data/RW-14b/: печатает «repro: OK» (exit 0) или «repro: FAIL».
# --regrid — пересоздать синтетические сетки с дырами (обычно не нужно; файлы лежат в репозитории).
# Godot — под замком cpu: .dpcli/dpcli lock cpu <имя> -- tools/wind_fixtures/weather_ref2.sh
set -uo pipefail
cd "$(dirname "$0")/../.."
ref=rust/dp-air/tests/data/RW-14b
check=0
regrid=0
out=""
for a in "$@"; do
	case "$a" in
	--regrid) regrid=1 ;;
	--check | --verify) check=1 ;;
	--out=*) out="${a#--out=}" ;;
	esac
done
if [ "$regrid" = 1 ]; then
	# Синтетические сетки климата с дырами -32768 (в настоящих данных их нет): rust/dp-air/tests/data/RW-14b/grids/*_nodata.bin.
	# Заголовки берутся из data/climate/*.bin; нужен python3 с модулем brotli. Входы E1, в репозитории — готовые файлы.
	mkdir -p "$ref/grids"
	python3 -I - data/climate "$ref/grids" <<'PY'
import array, struct, sys, brotli
NLON, NLAT, NM = 360, 180, 12
SPECS = {"dew_point_1deg": (2, 1), "upper_air_1deg": (2, 0), "surface_t_1deg": (2, 0), "upper_misc_1deg": (3, 0)}
src, dst = sys.argv[1], sys.argv[2]
for name, (b3, b2) in SPECS.items():
    head = bytearray(open(f"{src}/{name}.bin", "rb").read(64))
    n3, n2 = NM * NLAT * NLON, NLAT * NLON
    raw = array.array("h", [0]) * (b3 * n3 + b2 * n2)
    def fill(base, b, m):
        for j in range(NLAT):
            row = base + j * NLON
            for i in range(NLON):
                raw[row + i] = ((j * 37 + i * 5 + m * 211 + b * 977) % 4001) - 2000
    for b in range(b3):
        for m in range(NM):
            fill(b * n3 + m * n2, b, m)
    for k in range(b2):
        fill(b3 * n3 + k * n2, 9, 0)
    def holes(base, m):
        def hole(j, i):
            raw[base + j * NLON + (i % NLON)] = -32768
        hole(20 + m, 100 + m)                       # одиночная
        hole(60, 200 + m); hole(60, 201 + m)        # пара в строке
        for dj in (0, 1):
            for di in (0, 1):
                hole(100 + m + dj, 300 + m + di)    # все четыре угла
        for dj in (0, 1):
            for di in (0, 1):
                hole(120 + dj, 359 + di)            # через антимеридиан (i = 359, 0)
        if m % 2 == 0:                              # строка пуста целиком
            for i in range(NLON):
                hole(140, i); hole(141, i)
        if m % 3 == 0:                              # строка пуста, кроме одной ячейки
            for i in range(NLON):
                if i != 77:
                    hole(150, i); hole(151, i)
        if m >= 6:                                  # полярные строки
            for i in range(NLON):
                hole(0, i); hole(179, i)
        hole(10, 5 + m); hole(11, 6 + m)            # диагональ
    for b in range(b3):
        for m in range(NM):
            holes(b * n2 * NM + m * n2, m)
    for k in range(b2):
        holes(b3 * n3 + k * n2, 0)
    comp = brotli.compress(raw.tobytes(), quality=11)
    struct.pack_into("<I", head, 48, len(raw) * 2)
    struct.pack_into("<I", head, 52, len(comp))
    open(f"{dst}/{name}_nodata.bin", "wb").write(bytes(head) + comp)
    print(name, len(comp))
PY
	exit $?
fi
tmp="$(mktemp -d)"
profile="$tmp/profile"
mkdir -p "$profile"
cp project.godot "$tmp/project.godot.bak"
trap 'cmp -s project.godot "$tmp/project.godot.bak" || cp "$tmp/project.godot.bak" project.godot; rm -rf "$tmp"' EXIT
XDG_DATA_HOME="$profile" godot --headless --path . --import >/dev/null 2>&1 || true
if [ "$check" = 1 ]; then
	dst="$tmp/out"
elif [ -n "$out" ]; then
	dst="$(realpath -m "$out")"
else
	dst="$PWD/$ref"
fi
log="$tmp/godot.log"
if ! XDG_DATA_HOME="$profile" timeout 1500 godot --headless --path . res://tools/wind_fixtures/weather_ref2.tscn -- "--out=$dst" >"$log" 2>&1; then
	tail -30 "$log"
	echo "weather_ref2: Godot упал"
	exit 2
fi
if grep -q "SCRIPT ERROR" "$log"; then
	grep -A3 "SCRIPT ERROR" "$log" | head -40
	echo "weather_ref2: ошибки сценария"
	exit 2
fi
if [ "$check" = 1 ]; then
	rc=0
	cmp -s "$ref/manifest.json" "$dst/manifest.json" || { echo "weather_ref2: manifest.json отличается"; rc=1; }
	n=0
	for z in "$ref"/*.jsonl.zst; do
		b="$(basename "$z" .zst)"
		n=$((n + 1))
		zstd -dcq "$z" | cmp -s - "$dst/$b" || { echo "weather_ref2: $b отличается"; rc=1; }
	done
	[ "$(ls "$dst"/*.jsonl | wc -l)" = "$n" ] || { echo "weather_ref2: число наборов отличается"; rc=1; }
	if [ "$rc" = 0 ]; then echo "repro: OK ($n наборов, побитно)"; else echo "repro: FAIL"; fi
	exit "$rc"
fi
for j in "$dst"/*.jsonl; do
	zstd -19 -q -f --no-progress "$j" -o "$j.zst" && rm -f "$j"
done
du -sh "$dst"
