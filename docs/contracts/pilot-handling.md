---
type: contract
status: "active"
module: pilot-handling
area: flight
updated: "2026-11-04"
summary: "Что модуль pilot-handling может менять (подпись ползунка, X) и что нет (ход мыши, боковая модель), формат итогов PHD-2/3."
related: ["docs/plan/pilot-handling.md", "docs/contracts/pilot-feedback-trim.md", "docs/contracts/bar-mouse.md", "docs/contracts/pendulum.md"]
contracts: [{"id": "PHD-К1", "version": 1}, {"id": "PHD-К2", "version": 1}]
---
# Контракты модуля pilot-handling

План — `docs/plan/pilot-handling.md`. Менять — только координатор (версия +1, что изменилось, уведомить потребителей).
Контрактный тест — `tests/contracts/test_pilot_handling_contracts.gd` (headless): заголовки «## PHD-К<n>. … (v<n>)»,
значения ключей PHD-К1. Новых интерфейсов кода модуль не вводит; исследования (PHD-2, PHD-3) код и конфиги игры не меняют.

## PHD-К1. Управление и боковая модель: что модуль меняет и что нет (v1)
Владелец — координатор модуля. Потребители — `scripts/ui/settings_panel.gd`, `locale/ui.csv`, `scripts/game/input_controller.gd`,
`scripts/game/mouse_bar.gd` (BM-К1), PD-К2 (`docs/contracts/pendulum.md`).

Неизменные (закрыто PFT-3, PFT-К1 v2; боковая модель — PD-К2; менять только шлюзом):

| Ключ | Файл | Значение |
|---|---|---|
| `mouse.bar_travel_px` | `configs/controls.json` | 4000.0 |
| `bar_sensitivity_range` | `configs/ui.json` | [0.1, 4.0] |
| `yaw.cn_beta` | `configs/pendulum.json` | 0.05 |
| `yaw.cn_p_add` | `configs/pendulum.json` | 0.15 |
| `yaw.cn_r_add` | `configs/pendulum.json` | −0.03 |

Может менять модуль:
- Подпись ползунка (PHD-1): ключи `locale/ui.csv` `settings_bar_sensitivity`, `settings_bar_sensitivity_fmt` и новые ключи
  с префиксом `settings_bar_` (ru и en). Направление — инвариант: больше множитель → меньше ход до упора
  (`bar_travel_px / множитель` отсчётов) → резче. Ход в см — при 800 DPI (315 отсчётов/см), как сейчас.
- `keyboard.center_time_s` (`configs/controls.json`, сейчас 0.2) — только PHD-4 по итогам PHD-2 и с учётом шлюза (план, § 6).

## PHD-К2. Итог исследования PHD-2/PHD-3 (v1)
Владельцы — PHD-2 (п. 3), PHD-3 (п. 2). Потребитель — PHD-4 (карточка правки), координатор (шлюз).

Файл `tools/research/pilot-handling/out/<ID>_verdict.json` (JSON, UTF-8, пишется один раз: временный файл + переименование):
```
{"task": "PHD-2", "items": [
  {"item": 3, "verdict": "input|physics|config|none", "cause": "строка",
   "evidence": [{"what": "строка", "value": число, "unit": "строка", "ref": "путь#раздел"}],
   "proposal": [{"key": "файл → ключ | файл:функция", "from": значение|null, "to": значение|null, "why": "строка"}]}
 ],
 "modes": [{"wing": "id", "case": "строка", "mode": "dutch_roll|pilot_swing|roll|spiral|phugoid",
            "omega_rad_s": число, "zeta": число, "source": "game|proto|linear|literature"}]}
```
`item` — пункт отзыва (2 — «надувной», 3 — раскачка после X). `verdict`: `input` — причина в вводе (X, мышь, руки),
`physics` — в модели (тогда `key` — файл/функция, `from`/`to` — `null`), `config` — значение конфига, `none` — дефекта нет.
`modes` — замеры частоты и затухания (до и после предложенной правки — отдельными записями с `case`). `proposal` пуст при `none`.
Числа — из замеров записки или источников со ссылкой.
