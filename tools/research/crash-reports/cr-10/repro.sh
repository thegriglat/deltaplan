#!/usr/bin/env bash
# CR-10: порядок событий старта меню: строка air_model -> сборка compute-шейдеров облаков (кадр 0).
# Запуск из корня копии игры: tools/research/crash-reports/cr-10/repro.sh [vulkan|d3d12] [conf]
#   conf=boxes — пользовательский конфиг clouds.renderer=boxes (эффект облаков не создаётся).
# Godot — только под замком cpu; правка игры накладывается на время прогона и снимается.
set -euo pipefail
drv=${1:-vulkan}; conf=${2:-}
here=$(cd "$(dirname "$0")" && pwd); root=$(git rev-parse --show-toplevel); cd "$root"
export XDG_DATA_HOME=${XDG_DATA_HOME:-$HOME/.cache/dp-xdg/$(basename "$PWD")}
cfg="$XDG_DATA_HOME/Deltaplan/configs/atmosphere.json"
out=${OUT:-$HOME/.cache/dp-crash-reports/cr10-run.log}
git apply "$here/cloud_build_trace.patch"
trap 'git checkout scripts/atmosphere/cloud_compositor_effect.gd; [ -z "$conf" ] || rm -f "$cfg"' EXIT
if [ "$conf" = boxes ]; then mkdir -p "$(dirname "$cfg")"; echo '{"clouds":{"renderer":"boxes"}}' > "$cfg"; fi
.dpcli/dpcli lock cpu cr10-run --no-tmux -- timeout 90 godot --path . --rendering-driver "$drv" --quit-after 400 > "$out" 2>&1 || true
grep -nE "^(steam:|air_model:|CR10:)" "$out"
