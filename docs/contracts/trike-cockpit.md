---
type: contract
status: "active"
module: trike-cockpit
area: flight
updated: "2026-10-23"
summary: "Стык trike-cockpit: тахометр и топливо дельталёта видны и показывают из кабины (TC-К1) — инварианты отрисовки и показаний."
related: ["docs/plan/trike-cockpit.md", "docs/contracts/trike-pilot.md"]
contracts: [{"id": "TC-К1", "version": 1}]
---
# Контракты trike-cockpit (код задач TC)

Правка интерфейса — только через координатора: версия +1, этот файл и контрактный тест — в том же шаге. Контрактный тест
проверяет версию своего раздела по заголовку (шаблон — `tests/contracts/test_trike_pilot_k5.gd`/`test_trike_model_k1.gd`:
`const DOC`, `const VERSION`, регулярка `^## (TC-К\d) v(\d+)\.`). Основание — решения пользователя 2026-10-23: в кабине
дельталёта — только тахометр и топливо (полётные приборы не добавлять), они должны показывать из кабины; вид от третьего
лица (HUD `TrikeGaugesHud`) работает — не менять.

## TC-К1 v1. Приборы дельталёта видны и показывают из кабины
Владелец — TC-1. Потребители — нет (игра). Контрактные тесты — `tests/contracts/test_trike_cockpit_k1.gd` (headless) и
`tests/contracts/test_trike_cockpit_k1_gpu.gd` (`needs_gpu() == true`, прогон `tools/gpu_tests.sh`), пишет TC-1.

Интерфейсы TP-К4 v2 (`TrikeGauges3D`, `update_readout`, `needle_angle_deg`, `RpmNeedle`/`FuelNeedle`) и TP-К8 v1
(монтаж в `InstrumentPanel`, HUD только в `chase`) **не меняются**; если исправление требует их правки — `contract:`
координатору. Состав приборов — только тахометр и топливо.

Сцена проверки: `Game` с `vehicle "trike"` на колёсах (по образцу `test_trike_pilot_k8.gd test_trike_in_game`),
`camera.mode == "cockpit"`, взгляд по умолчанию (`camera.json → cockpit`, без поворота головы), не меньше 5 кадров после
старта. «Циферблат» — каждый из двух приборов `TrikeGauges3D`, центр — центр его AABB.

**Инварианты (headless):**
1. `TrikeGauges3D` в дереве, `is_visible_in_tree()`, потомок `InstrumentPanel`; у каждого `VisualInstance3D` приборов
   `layers & camera.cull_mask != 0` (кабинная камера их рисует).
2. Центры обоих циферблатов — в пирамиде видимости кабинной камеры (`Camera3D.is_position_in_frustum`), перед камерой.
3. Лицевая сторона к глазу: для каждого циферблата `dot(нормаль лица (+Z корня TrikeGauges3D в мире), глаз − центр) > 0`.
4. Угловой диаметр каждого циферблата из глаза ≥ 3° (читаемость: ≈ 60 px по ширине 1920 при FOV 90).
5. Показания доходят в игровом цикле: двигатель запущен, обороты меняются (газ) → после ≥ 3 кадров поворот `RpmNeedle`
   = `needle_angle_deg(engine.engine_rpm, …)` ± 0,5° (без прямого вызова `update_readout` из теста); `FuelNeedle` —
   по `engine.fuel_l` так же.
6. `vehicle "glider"` — прежний вид кабины (тесты `pilot_hud`, `cockpit`, `trike_pilot_k8` зелёные).

**Инвариант (GPU, отрисовка):**
7. Тот же кадр кабины (окно `gpu_tests.sh`), два кадра подряд: обороты 0 и ≥ 80 % шкалы тахометра (состояние двигателя
   задаётся тестом). В прямоугольнике проекции AABB тахометра на экран доля пикселей, изменившихся > 10/255 хотя бы по
   одному каналу, ≥ 2 %. Средняя яркость прямоугольника тахометра ≥ 0,05 (не чёрный). Числа — в вывод теста.
