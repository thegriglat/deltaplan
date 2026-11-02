---
type: research
status: active
module: pilot-feedback-trim
summary: Команды воспроизведения замеров отклика Маятника на ход штанги (PFT-2)
updated: 2026-11-02
---
# PFT-2: мышь и отклик крыла
Скрипт `mouse_response.gd` (+`.tscn`) — отклик «Маятника» на ход штанги: ступенька 0,1/0,3/0,6/1,0, перекладка 30/45°, тангаж.
Воспроизведение (из корня копии, ≈ 5 мин, CPU):
```
export XDG_DATA_HOME=~/.cache/dp-xdg/$(basename "$PWD")
godot --headless --path . --import
.dpcli/dpcli lock cpu pft2 -- godot --headless --path . res://tools/research/pilot-feedback-trim/mouse/mouse_response.tscn -- --out=tools/research/pilot-feedback-trim/mouse/response.json
```
Результат — `response.json`. Вывод — `docs/research/pilot-feedback-trim/mouse.md`. Данные игры — только конфиги репозитория; внешних данных нет.
Источники (веб, ссылки в записке): Davis Straub (нормы HGMA/DHV), Will's Swing, ICAS 2022, Keychron/SteelSeries (DPI) — тексты не копировались, лицензии не требуют.
