---
type: contract
status: "closed"
module: bar-mouse
area: game
updated: "2026-10-23"
summary: "Мышь → штанга: ход в отсчётах мыши без окна, множитель в меню, мёртвая зона без скачка (BM-К1); мышь по камерам (BM-К2)."
related: ["docs/plan/bar-mouse.md", "docs/contracts/control-fix.md", "docs/contracts/control-bar.md"]
contracts: [{"id": "BM-К1", "version": 2}, {"id": "BM-К2", "version": 1}]
---
# Контракты модуля bar-mouse

План — `docs/plan/bar-mouse.md`, решение пользователя 2026-10-23 (`.dpcli/dpcli inbox bar-mouse`). Менять — только
координатор (версия +1, что изменилось, уведомить потребителей). Контрактный тест — `tests/contracts/test_bar_mouse_contracts.gd`
(headless): заголовки «## BM-К<n>. … (v<n>)», ключи и значения по умолчанию, форма и инварианты `MouseBar`. До BM-3 он красный —
это ожидаемо (класса и ключей ещё нет); `mouse_bar.gd` грузится через `load()`.

## BM-К1. Мышь → штанга (v2)
Владелец: BM-3. Потребители: `scripts/game/input_controller.gd` (`_unhandled_input`, `_update_bar`), настройки
(`scripts/ui/settings_panel.gd`, вкладка «Управление»), тесты маятника, читающие ход мыши (`tests/flight/pendulum/test_pendulum_symmetry.gd`,
`tests/game/test_mouse_bar_flight.gd`).

**Единицы.** Внутри — отсчёты мыши: `InputEventMouseMotion.screen_relative` при захвате курсора, «px» (v2; в проекте
растяжение окна выключено, `relative` = `screen_relative`, но `screen_relative` не зависит от растяжения). По BM-2
(`docs/research/bar-mouse-raw-input.md`): Windows (`WM_INPUT`) и X11 (`XI_RawMotion`) — сырые отсчёты устройства без ускорения
ОС; Wayland — ускоренные логические пиксели × масштаб окна; macOS — ускоренные точки × `screen_get_max_scale()`. Обхода
средствами игры нет; на Wayland/macOS ход зависит от скорости указателя ОС, подгонка — множителем. Сантиметров внутри нет: DPI мыши игре неизвестен; радианы — у обзора, у штанги угла нет.
Размер окна в расчёт **не входит**.

Ключи `configs/controls.json → mouse` (у каждого — `*_doc` по-русски):
- `bar_travel_px: float = 2500.0` — отсчётов мыши от нейтрали до упора штанги в одну сторону при множителе 1.
  Только конфиг, не меню.
- `bar_sensitivity: float = 1.0` — множитель пилота (слайдер «Чувствительность штанги»): ход до упора =
  `bar_travel_px / bar_sensitivity` px. Больше — чувствительнее.
- `bar_deadzone: float = 0.02` — мёртвая зона, доля хода, зажим [0, 0.5].
- `bar_return_to_center_per_s`, `look_sensitivity_deg_per_px`, `invert_look_y`, `capture_on_start` — смысл прежний.

`configs/ui.json`: `bar_sensitivity_range: [0.25, 4.0]` (+ `_doc`), шаг слайдера 0.05. `look_sensitivity_range` прежний.

**Обоснование чисел** (800 DPI = 315 отсчётов/см). Было: `0,5·H` px — 450 px при H = 900 (1,4 см), 540 px при 1080 (1,7 см);
пилот: «невозможно управлять». Решение 2026-10-23: полный ход порядка 10–20 см стола при 800 DPI. По умолчанию 2500 px —
7,9 см до упора в одну сторону, 15,9 см от упора до упора: ×5,6 мягче прежнего. Крен 0,3 хода (обычный разворот) — 2,4 см.
Диапазон 0,25×–4× → 10000…625 px (31,7…2,0 см при 800 DPI): покрывает разброс DPI мышей 400–3200 (×8) и сверху доходит
почти до прежней чувствительности (625 против 450–540 px).
Подсказка в меню рядом с числом: `≈ N см` до упора в одну сторону при 800 DPI, `N = bar_travel_px / bar_sensitivity / 315`
(строка locale, см/cm), формат `"%.2f×  ≈ %.1f см (800 DPI)"` — только при `DisplayServer.get_name()` ∈ {`Windows`, `X11`};
на остальных — только `"%.2f×"` (см там неверны, BM-2).

`class_name MouseBar extends RefCounted`, файл `scripts/game/mouse_bar.gd`, статические чистые функции:
- `travel_px(mouse: Dictionary) -> float` = `bar_travel_px / clamp(bar_sensitivity, 0.05, 20)`; отсутствующий ключ —
  значение по умолчанию выше; итог ≥ 1.
- `accumulate(offset: Vector2, rel: Vector2, mouse: Dictionary) -> Vector2` (`rel` — `screen_relative`) = `clamp(offset + rel / travel_px(mouse), −1, 1)`
  покомпонентно. Знаки прежние: `rel.y > 0` (мышь к себе, вниз по экрану) — `offset.y` растёт; `rel.x > 0` — `offset.x` растёт.
- `apply_deadzone(x: float, dz: float) -> float` = `0`, если `|x| ≤ dz`, иначе `sign(x)·(|x| − dz)/(1 − dz)`;
  `dz` зажат в [0, 0.5]. Непрерывна (скачка на пороге нет), `±1 → ±1`, нечётна, монотонна.

`input_controller.gd`: накопление `_mouse_offset = MouseBar.accumulate(_mouse_offset, event.screen_relative, _cfg.mouse)` вместо
`k = bar_sensitivity / (0,5·visible_rect.size.y)`; в `_update_bar` — `MouseBar.apply_deadzone` по каждой оси вместо
`if absf(...) > dz else 0`. Остальное (знаки `_roll_sign()`, `invert_pitch`, «в центр», возврат, ПКМ, `hands_off`) — без изменений.
Нелинейности нет (решение 2026-10-23, п. 5).

Инварианты (контрактный и поведенческий тесты):
- `travel_px` px мыши из нейтрали → `|offset| = 1` и `|control| = 1` по оси; `travel_px/2` → `control = (0,5 − dz)/(1 − dz)`;
- итог не зависит от размера окна;
- итог не зависит от частоты кадров/шагов: одна и та же последовательность px, разбитая на шаги 1/30 и 1/144 с, даёт тот же
  `control` (накопление по событиям, не по кадрам; возврат к центру при `bar_return_to_center_per_s = 0` выключен);
- `look_sensitivity_deg_per_px` не меняет `control.roll/pitch` ни в одной камере.

Изменения: **v2 (2026-10-23, BM-2)** — источник `screen_relative` вместо `relative` (тесты задают оба поля события);
подсказка «≈ см (800 DPI)» — только Windows/X11. Формулы, ключи, числа не менялись.

## BM-К2. Куда идёт мышь по камерам (v1)
Владелец: координатор (фиксирует нынешний код). Потребители: `scripts/game/camera_rig.gd` (`_unhandled_input`, `_look`,
`_mouse_looks`), `scripts/game/input_controller.gd` (`_unhandled_input`), `scripts/game/game.gd` (`hands_off` = свободная камера).
Порядок камер — `configs/camera.json → modes`: `cockpit → chase → free`, по умолчанию `cockpit`.

| Камера | Мышь без ПКМ | С зажатой ПКМ | `look_sensitivity_deg_per_px` |
|---|---|---|---|
| `cockpit` | штанга | голова (обзор), штанга держит положение | только голова по ПКМ |
| `chase` | штанга | ничего (штанга держит, обзора в chase нет) | не действует |
| `free` | камера (`hands_off`: крыло без рук, управление 0) | орбита камеры | камера |

Одновременно штанга и обзор от одного движения мыши — не допускается ни в одной камере (инвариант теста).
Расхождения кода с этой таблицей выявляет BM-1; изменение поведения камер — только решением пользователя (версия +1).
