---
type: "plan"
status: "active"
module: "debug-draw"
updated: "2026-10-07"
summary: "Удаление аддона Debug Draw 3D (GDExtension): отладочные стрелки ветра F5 — своим кодом на штатных средствах Godot; сборка, ASSETS.md, лицензии и контракты steam-assets — без него."
related: ["docs/contracts/steam-assets.md", "TODO.md"]
---
# debug-draw — удалить Debug Draw 3D

## Решения пользователя (не обсуждаются)
- 07.10.2026: аддон `addons/debug_draw_3d` (GDExtension, `libdd3d`) удалить из проекта целиком; стрелки ветра (F5) и всё прочее, что рисовалось через DebugDraw3D, рисуем сами — штатными средствами Godot 4.7.2 (ImmediateMesh/MultiMesh, unshaded-материал), без сторонних расширений.
- Debug Menu (`addons/debug_menu`, F2) — не трогаем (не входит в решение; T-71 закрывается только в части Debug Draw 3D).
- Не шлифовать: внешний вид — не больше 2 попыток.

## Контракты
Свой интерфейс модуль не меняет: `DebugOverlays` (`scripts/game/debug_overlays.gd` — `setup`, `enable`, `toggle_wind`, `toggle_thermals`, `mean_air_at`, `w_color` …) остаётся прежним для `game.gd`, `launch_options.gd` и тестов.
Меняются контракты steam-assets (`docs/contracts/steam-assets.md`, правит координатор до исполнителя): SA-К1 v3, SA-К2 v5, SA-К3 v4 — из сборки, `licenses/` и раздела «Движок и библиотеки» ASSETS.md убран `debug_draw_3d`. Контрактные тесты — `tests/contracts/test_steam_assets_contracts_sa3.gd` (нет строк debug_draw_3d/libdd3d, нет каталога аддона и синглтона), `_sa4.gd` (набор `licenses/` без `MIT-debug_draw_3d`).

## DD-1. Удалить Debug Draw 3D, стрелки ветра — своим кодом
- Исполнитель: `dp-engineer` (Sonnet).
- Скоуп: удалить `addons/debug_draw_3d/` и `licenses/MIT-debug_draw_3d.txt`; `scripts/game/debug_overlays.gd` — F5 (стрелки ветра на сетке вокруг камеры: направление, величина, цвет по вертикальной скорости — как было) на своём ImmediateMesh или MultiMesh с unshaded-материалом по образцу F6; `export_presets.cfg` — убрать `forced_dd3d` из `custom_features`; `tools/release/build_inventory.py`, `tools/release/third_party_notices.py` — без dd3d; `ASSETS.md` — убрать строку; `docs/plan/steam-assets.md` — актуальные места про dd3d; `TODO.md` T-71 — отметить, что часть Debug Draw 3D сделана (DD-1), Debug Menu остаётся; тесты `tests/game/test_debug_overlays.gd` по новому коду.
- Не трогать: `docs/archive/`, `docs/research/`, `tools/research/`, журналы `docs/plan/*/`, контракт steam-assets и контрактные тесты (координатор), `addons/debug_menu`.
- Приёмка: нет `addons/debug_draw_3d` и ссылок на DebugDraw3D/dd3d в коде, экспорте, ASSETS.md, контрактах; headless-тесты `debug_overlays`, `steam_assets_contracts`, `game` зелёные; `build_inventory.py --check` проходит на всех пресетах; проект импортируется без ошибок расширения; один скриншот F5 через `tools/shots/debug_overlay_shot` в `/home/greg/deltaplan/build/screenshots/DD-1/`.
- Оценка: 1–2 ч.
