---
type: contract
status: "closed"
module: pilot-feedback-trim
area: flight
updated: "2026-11-02"
summary: "Умолчания, которые модуль может менять (мышь-штанга, клавиша X, подвеска), и формат итогов исследования PFT-1/2."
related: ["docs/plan/pilot-feedback-trim.md", "docs/contracts/bar-mouse.md", "docs/contracts/pendulum.md"]
contracts: [{"id": "PFT-К1", "version": 2}, {"id": "PFT-К2", "version": 1}]
---
# Контракты модуля pilot-feedback-trim

План — `docs/plan/pilot-feedback-trim.md`. Менять — только координатор (версия +1, что изменилось, уведомить потребителей).
Контрактный тест — `tests/contracts/test_pilot_feedback_trim_contracts.gd` (headless): заголовки «## PFT-К<n>. … (v<n>)»,
значения ключей PFT-К1. Новых интерфейсов кода модуль не вводит; исследование (PFT-1, PFT-2) код и конфиги игры не меняет.

## PFT-К1. Умолчания управления и аппарата, которые модуль может поменять (v2)
v2 (2026-11-02, по PFT-2 `docs/research/pilot-feedback-trim/mouse.md`): `mouse.bar_travel_px` 2500 → 4000, `bar_sensitivity_range`
[0.25, 4.0] → [0.1, 4.0] — ход до упора по умолчанию 12,7 см при 800 DPI, 3,2 см при 3200 DPI (у пилотов ≈ 3200–3600 DPI);
минимум ×0,1 — 40000 отсчётов (12,7 см при 3200 DPI). Отклик модели на штангу в норме (перекладка 45°→45° 3,6–4,7 с), правка — только ход.
Та же правка — в BM-К1 (`docs/contracts/bar-mouse.md`, v3) и его тесте. Владелец — координатор модуля, правка — PFT-3. Потребители — `scripts/game/input_controller.gd`,
`scripts/game/mouse_bar.gd` (BM-К1 v2), `scripts/ui/settings_panel.gd`, `scripts/game/flight_settings.gd` (PD-К3 v2),
тесты `tests/contracts/test_bar_mouse_contracts.gd`, `tests/flight/pendulum/test_pendulum_hang_shift.gd`.

Значения (v1 — по коду 2026-11-02; v2 — целевые после PFT-3):

| Ключ | Файл | Значение | Смысл |
|---|---|---|---|
| `mouse.bar_travel_px` | `configs/controls.json` | 4000.0 (v1: 2500.0) | отсчётов мыши от нейтрали до упора при множителе 1 (BM-К1) |
| `mouse.bar_sensitivity` | `configs/controls.json` | 1.0 | множитель пилота по умолчанию |
| `mouse.bar_deadzone` | `configs/controls.json` | 0.02 | мёртвая зона, доля хода |
| `bar_sensitivity_range` | `configs/ui.json` | [0.1, 4.0] (v1: [0.25, 4.0]) | диапазон слайдера «Чувствительность штанги» |
| `keyboard.center_time_s` | `configs/controls.json` | удалён (pilot-handling PHD-К1 v2, 2026-11-04: не действовал; темп руки — `hand.tau_s`, PHD-К1 v3) | X: постоянная времени ухода штанги в нейтраль, с |
| `mouse.bar_return_to_center_per_s` | `configs/controls.json` | 0.0 | возврат трапеции в нейтраль без ввода |
| `apparatus_defaults.hang_shift_cm` | `configs/pendulum.json` | 0.0 | сдвиг подвески по умолчанию, см (+ к носу) |
| диапазон `hang_shift_cm` | `scripts/game/flight_settings.gd` | [−4, 4, шаг 0,5] | PD-К3 v2 |

Инварианты: паспортные `trim_speed_kmh`, поляра и блок `pendulum` крыльев (`configs/wings/*.json`, PD-К2 v9; блок генерирует
`tools/flight/pendulum_params.py`) этим контрактом не меняются — их правка только через шлюз (план, § 6).

## PFT-К2. Итог исследования PFT-1/PFT-2 (v1)
Владельцы — PFT-1 (`longitudinal`), PFT-2 (`mouse`). Потребитель — PFT-3 (карточка правки), координатор (шлюз).

Файл `tools/research/pilot-feedback-trim/out/<ID>_verdict.json` (JSON, UTF-8, пишется один раз: временный файл + переименование):
```
{"task": "PFT-1", "items": [
  {"item": 1, "verdict": "physics|config|none", "cause": "строка",
   "evidence": [{"what": "строка", "value": число, "unit": "строка", "ref": "путь#раздел"}],
   "proposal": [{"key": "файл → ключ", "from": значение, "to": значение, "why": "строка"}]}
]}
```
`item` — номер пункта отзыва (1 — кабрирование на нейтрали, 2 — маятник после X, 3 — мышь). `proposal` пуст при `none`;
при `physics` — `key` указывает файл/функцию модели, `from`/`to` — `null`. Числа — из замеров записки, не оценки без источника.
