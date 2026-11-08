#!/usr/bin/env bash
# RW-6u: перепечь эталона training_island/landing_hill CPU-путём фаз (f64) на опорной ревизии c591b1026.
# Использование: tools/research/rust_wind_t1_ref/run.sh [site] (по умолчанию landing_hill). Нужны окно (DISPLAY),
# GPU для Пикара и ~1 ГБ диска под временную копию ревизии. Копия и профиль Godot удаляются не здесь.
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
REPO=$(cd "$HERE/../../.." && pwd)
REF=${REF:-$HOME/worktrees/deltaplan/rw6u-ref}
SITE=${1:-landing_hill}
# WF-2: фикстура tests/fixtures/wind/baked удалена (нигде не загружалась) — печать идёт во временный каталог
OUT=${OUT:-$REPO/build/rust_wind_t1_ref}
[ -d "$REF" ] || git -C "$REPO" worktree add --detach "$REF" c591b1026
git -C "$REF" apply "$HERE/ref_c591b1026.patch"   # крючки: CPU-фазы, статус решателя (если уже применён — ошибка, это ок)
export XDG_DATA_HOME=${XDG_DATA_HOME:-$HOME/.cache/dp-xdg/rw6u-ref}
godot --headless --path "$REF" --import
mkdir -p "$OUT"
DISPLAY=${DISPLAY:-:0} "$REPO/.dpcli/dpcli" lock cpu rw6u-bake -- \
  godot --path "$REF" --audio-driver Dummy --disable-vsync res://tools/terrain/bake_air.tscn -- \
  --id=training_island --site="$SITE" --out="$OUT" --cpu_phases
# уборка: git -C "$REPO" worktree remove --force "$REF"
