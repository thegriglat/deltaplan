#!/usr/bin/env bash
# ON-7: сквозная проверка пути пользователя (data/air_nn/README.md) на ЭКСПОРТИРОВАННОЙ Linux-сборке:
# сеть кладётся в user://air_nn/model.onnx временного профиля, включается engine = nn
# (user://configs/atmosphere.json — то же, что пишет пункт настроек «нейросеть»), сборка стартует
# headless (--smoke: встроенное место, автопилот) и печатает строку журнала air_model.
# Использование: tools/air_onnx/export_smoke.sh <model.onnx> [--build]
#   --build — сначала tools/build.sh linux (иначе берётся готовый build/linux/deltaplan.x86_64).
# Профиль пилота (~/.local/share/Deltaplan) не трогается: XDG_DATA_HOME временный. Код 0 — строка
# «air_model: поле (нейросеть …)» есть.
set -uo pipefail
cd "$(dirname "$0")/../.."
model="${1:?нужен путь к .onnx}"
[[ -f "$model" ]] || { echo "нет файла $model" >&2; exit 2; }
model="$(realpath "$model")"

export XDG_DATA_HOME
XDG_DATA_HOME=$(mktemp -d)
trap 'rm -rf "$XDG_DATA_HOME"; git checkout -- project.godot 2>/dev/null || true' EXIT
real_templates="$HOME/.local/share/godot/export_templates"
if [[ -d "$real_templates" ]]; then
	mkdir -p "$XDG_DATA_HOME/godot"
	ln -s "$real_templates" "$XDG_DATA_HOME/godot/export_templates"
fi

if [[ "${2:-}" == "--build" || ! -x build/linux/deltaplan.x86_64 ]]; then
	echo "== сборка Linux" >&2
	tools/build.sh linux >&2 || { echo "сборка не удалась" >&2; exit 1; }
fi

# профиль: project.godot → use_custom_user_dir, имя Deltaplan → $XDG_DATA_HOME/Deltaplan
user="$XDG_DATA_HOME/Deltaplan"
mkdir -p "$user/air_nn" "$user/configs"
cp "$model" "$user/air_nn/model.onnx"
echo '{"air_model": {"engine": "nn"}}' > "$user/configs/atmosphere.json"

echo "== запуск build/linux/deltaplan.x86_64 --headless -- --smoke" >&2
out=$(timeout 300 build/linux/deltaplan.x86_64 --headless -- --smoke 2>&1)
rc=$?
echo "$out" | grep -E "air_model|smoke|ERROR|SCRIPT ERROR"
echo "код выхода игры: $rc" >&2
echo "$out" | grep -q "air_model: поле (нейросеть"
