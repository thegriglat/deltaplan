#!/usr/bin/env bash
# picard-terrain: без флагов picard_rs решает побитно как до модуля (PT2, PT3 — «путь решения побитно R1»).
# Собирает picard_rs из базы (merge-base HEAD с BASE, по умолчанию feature/picard-terrain) и из рабочего
# дерева, решает 4 случая ref/ на 4 потоках, сравнивает R2 (rust/picard_rs/contract/compare_r2.py).
# Последняя строка — identical=<k>/<n>; код 0 только при identical=4/4.
# Запуск Godot нет; тяжёлое CPU — запускать под `.dpcli/dpcli lock cpu <ID> -- …` (accept делает сам).
set -euo pipefail
ROOT=$(git rev-parse --show-toplevel)
BASE=${BASE:-feature/picard-terrain}
MB=$(git -C "$ROOT" merge-base HEAD "$BASE")
W=${PT_DEFAULT_WORK:-${XDG_CACHE_HOME:-$HOME/.cache}/picard_terrain/check_default}
mkdir -p "$W"
rm -rf "$W/base_src" "$W/before" "$W/after"
mkdir -p "$W/base_src" "$W/before" "$W/after"
git -C "$ROOT" archive "$MB" rust/picard_rs | tar -x -C "$W/base_src"
CARGO_TARGET_DIR="$W/target_base" cargo build -q --release --manifest-path "$W/base_src/rust/picard_rs/Cargo.toml"
CARGO_TARGET_DIR="$W/target_new" cargo build -q --release --manifest-path "$ROOT/rust/picard_rs/Cargo.toml"
F="$ROOT/tests/atmosphere/fixtures/air_model/ref"
for c in flat_wind agnesi heated_slope saddle; do
  "$W/target_base/release/picard" solve "$F/$c.json" --threads 4 --out "$W/before/$c.json" >/dev/null
  "$W/target_new/release/picard" solve "$F/$c.json" --threads 4 --out "$W/after/$c.json" >/dev/null
done
out=$(python3 "$ROOT/rust/picard_rs/contract/compare_r2.py" "$W/before" "$W/after" --case saddle --threads 4)
echo "base=$MB"
echo "$out" | grep -v '^ratio' || true
last=$(echo "$out" | grep '^identical=' | tail -1)
echo "$last"
[ "$last" = "identical=4/4" ]
