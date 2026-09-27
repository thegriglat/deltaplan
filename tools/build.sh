#!/usr/bin/env bash
# Сборка: tools/build.sh [linux|windows|all] [--release]
# Результат: build/<платформа>/ + архив build/deltaplan-<платформа>.zip
# Рядом с игрой кладётся папка configs/ — пилот правит её без пересборки (NFR-7).
set -euo pipefail
cd "$(dirname "$0")/.."
target="${1:-all}"
mode="--export-debug"
[[ "${2:-}" == "--release" ]] && mode="--export-release"

# Коммит сборки для «Об игре» (BuildInfo): 6 символов, «+» — есть незакоммиченные правки.
commit="$(git rev-parse --short=6 HEAD 2>/dev/null || echo "")"
[[ -n "$commit" && -n "$(git status --porcelain --untracked-files=no 2>/dev/null)" ]] && commit="$commit+"
printf '{"commit": "%s"}\n' "$commit" > data/build_info.json

godot --headless --path . --import >/dev/null 2>&1 || true

build_one() {
	local preset="$1" dir="$2" bin="$3"
	rm -rf "build/$dir"
	mkdir -p "build/$dir"
	godot --headless --path . "$mode" "$preset" "build/$dir/$bin"
	cp -r configs "build/$dir/configs"
	(cd build && rm -f "deltaplan-$dir.zip" && zip -qr "deltaplan-$dir.zip" "$dir")
	echo "готово: build/$dir/$bin, build/deltaplan-$dir.zip"
}

[[ "$target" == linux || "$target" == all ]] && build_one Linux linux deltaplan.x86_64
[[ "$target" == windows || "$target" == all ]] && build_one Windows windows deltaplan.exe
exit 0  # иначе «build.sh linux» возвращает 1 от последней проверки [[ windows ]]
