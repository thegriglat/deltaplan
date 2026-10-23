---
type: "guide"
status: "active"
module: "crash-reports"
area: "release"
updated: "2026-10-23"
summary: "Скрипт CR-10: порядок событий старта меню и сборка compute-шейдеров облаков (Linux)."
related: ["docs/research/crash-reports/cr-10.md"]
---
# tools/research/crash-reports/cr-10

- `repro.sh [vulkan|d3d12] [boxes]` — запуск Godot под `lock cpu` с временной трассой (`cloud_build_trace.patch`, снимается после прогона); печатает строки `steam`, `air_model`, `CR10: cloud effect build at frame N`. Профиль `XDG_DATA_HOME=~/.cache/dp-xdg/<копия>`; в копии должен быть `.godot` (сначала `--import` под замком).
- Источники: issues thegriglat/deltaplan-reports #17, #18 (сырьё — `~/.cache/dp-crash-reports/`, не в репозитории); godotengine/godot #122671, #123833, godot-proposals #15661 (публичные страницы GitHub, данные не копировались). Лицензий данных нет.
