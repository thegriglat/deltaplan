#!/usr/bin/env bash
# LT-9: тесты «lee» на поле со срезанными клетками (feature/picard-terrain) с изменениями текущей
# ветки (LTM v1). Временная отсоединённая копия: ветки и коммиты в чужие ветки не создаются.
# Последняя строка вывода — «PT lee tests: <N> failed» (N из итога run_tests «M тестов, N упало»).
# Запуск из копии задачи: sh tools/research/lee_turb/pt_check/run.sh   (HEAD с коммитом изменений)
# Переменные: PT_BASE (по умолчанию feature/picard-terrain), PT_FILTER (по умолчанию lee),
# PT_KEEP=1 — не удалять копию (для разбора).
set -u
root=$(git rev-parse --show-toplevel)
cd "$root" || exit 2
base=${PT_BASE:-feature/picard-terrain}
filter=${PT_FILTER:-lee}
name=$(basename "$root")
tmp=$(mktemp -d "${TMPDIR:-/tmp}/pt-lee-XXXXXX")
wt="$tmp/wt"
xdg="$HOME/.cache/dp-xdg/pt-lee-$name"
export CARGO_TARGET_DIR="$HOME/.cache/dp-pt-lee-target/$name"
paths="rust/dp-air/src/terms/turb configs/atmosphere.json tests/contracts rust/dp-stand/src/lee.rs"
fail() { echo "PT lee tests: ERROR $1"; cleanup; exit 1; }
cleanup() {
	if [ "${PT_KEEP:-0}" != 1 ]; then
		git worktree remove --force "$wt" >/dev/null 2>&1
		rm -rf "$tmp"
	fi
}
git worktree add --detach "$wt" "$base" >/dev/null 2>&1 || fail "worktree add $base"
# shellcheck disable=SC2086
git diff feature/lee-turb...HEAD -- $paths >"$tmp/change.patch" || fail "diff"
(cd "$wt" && git apply --3way "$tmp/change.patch") >"$tmp/apply.log" 2>&1 || {
	cat "$tmp/apply.log"
	fail "apply"
}
(cd "$wt" && cargo build -q --release --manifest-path rust/Cargo.toml -p dp-gd) || fail "cargo build"
mkdir -p "$wt/addons/dp_air/bin"
cp "$CARGO_TARGET_DIR/release/libdp_gd.so" "$wt/addons/dp_air/bin/libdp_air_release.so" || fail "copy so"
mkdir -p "$xdg"
(cd "$wt" && XDG_DATA_HOME="$xdg" godot --headless --path . --import >/dev/null 2>&1)
out="$tmp/tests.log"
(cd "$wt" && XDG_DATA_HOME="$(mktemp -d)" godot --headless --path . res://tests/run_tests.tscn -- --filter="$filter") >"$out" 2>&1
grep -A3 "  FAIL" "$out" | head -60
n=$(grep -Eo "[0-9]+ тестов, [0-9]+ упало" "$out" | tail -1 | sed -E 's/.*, ([0-9]+) упало/\1/')
cleanup
[ -n "$n" ] || { echo "PT lee tests: ERROR no summary"; exit 1; }
echo "PT lee tests: $n failed"
