---
type: "contract"
status: "active"
module: "pendulum-body-vg"
area: "flight"
updated: "2026-10-15"
summary: "Стыки модуля pendulum-body-vg: разделение прототипа маятника между PB-1 и PB-2 (PB-К1), формат сводки опытов до/после (PB-К2)."
related: ["docs/plan/pendulum-body-vg.md", "docs/contracts/pendulum.md", "tools/research/pendulum/README.md"]
contracts: [{"id": "PB-К1", "version": 1}, {"id": "PB-К2", "version": 1}]
---
# Контракты модуля pendulum-body-vg

План — `docs/plan/pendulum-body-vg.md`. Менять — только координатор (версия +1, что изменилось, уведомить потребителей). Контракты игры (PD-К1…К6) — `docs/contracts/pendulum.md`; их новые версии для переноса (PB-3, PB-4) пишутся здесь же до запуска исполнителей.

Контрактный тест (оба стыка): `tools/research/pendulum/pb_contract_check.py <summary.json>` — проверяет заголовки «## PB-К<n>. … (v<версия>)» этого файла и форму сводки PB-К2. Запуск: `python3 tools/research/pendulum/pb_contract_check.py tools/research/pendulum/out/pb1/summary.json`.

## PB-К1. Прототип маятника: кто что меняет (v1)
Владельцы: PB-1 (тело пилота), PB-2 (VG). Задачи идут параллельно в разных ветках; файлы не пересекаются.

| Файл (`tools/research/pendulum/`) | PB-1 | PB-2 |
|---|---|---|
| `pendulum/pilot_body.py` (новый) | владелец | — |
| `pendulum/model.py` | только силы/инерция пилота (узел пилота, руки — как есть) | не трогает |
| `pendulum/trim.py` | только сопротивление/сила пилота в балансировке | не трогает |
| `pendulum/params.py` | новые поля в конце `Params`: `pilot_body: str = "point"` и `body_*` | не трогает |
| `pendulum/vg.py` (новый) | — | владелец |
| `pendulum/geometry.py` | не трогает | можно, если VG меняет полосы (крутка, хорды, V) |
| `run_all.py`, `scenarios.py`, `report.py`, `pd*.py` | не трогают (импортируют) | не трогают (импортируют) |
| свои скрипты | `pb1_*.py`, данные `out/pb1/` | `pb2_*.py`, данные `out/pb2/` |
| документ | `docs/research/pendulum/pilot-body.md` | `docs/research/pendulum/vg.md` |

- PB-1: `Params.pilot_body` — `"point"` (как сейчас: изотропное `pilot_cda`, без инерции тела; числа прошлых опытов воспроизводятся без изменений) | `"body"` (новая модель). Все новые параметры — поля `body_*` с единицами и источником в комментарии (оценки помечены `EST`, как в `params.py`).
- PB-2: `vg.apply_vg(p: Params, vg: float) -> Params` — новая копия (`dataclasses.replace`), `vg` 0…1 (0 — отпущен, как сейчас; 1 — затянут полностью); меняет только параметры крыла; `vg = 0` возвращает параметры без изменений; крыло без VG — без изменений при любом `vg`. Список крыльев с VG и паспортные числа — в `vg.py` или `out/pb2/` (с источником). VG в опытах постоянен на прогон.
- Нужно поменять чужой файл — сообщение координатору `<ID> contract: <что>`.

## PB-К2. Сводка опытов до/после (v1)
Владелец: PB-1 — `out/pb1/summary.json`, PB-2 — `out/pb2/summary.json` (пути от `tools/research/pendulum/`). Потребители: координатор (шлюз), PB-3/PB-4 (эталон переноса), PB-5.

```json
{
  "contract": "PB-К2 v1",
  "task": "PB-1",
  "variants": {
    "base": {"desc": "…", "wings": {"training": {…}, "laminar": {…}, "sport": {…}}},
    "<вариант>": {…}
  },
  "notes": {"<метрика или вариант>": "почему null / оговорки"},
  "sources": [{"what": "…", "ref": "автор, год, название", "url": "…"}],
  "reproduce": "команда"
}
```
- `variants.base` обязателен — нынешний прототип в конфигурации игры; PB-1 — ещё хотя бы `body`; PB-2 — `vg0`, `vg05`, `vg1` (`vg0` совпадает с `base`).
- `wings` — ровно `training`, `laminar`, `sport` (умолчания «Аппарата» класса, трим, эталонная масса); PB-2 может добавить другие крылья с VG.
- Метрики каждого крыла (все ключи есть; число или `null` с причиной в `notes`):

| Ключ | Единицы | Смысл |
|---|---|---|
| `clp`, `cnp`, `cn_beta`, `cl_beta`, `cy_beta`, `cnr`, `clr` | безразм., 1/рад | производные системы, как `trim.lateral_derivatives` (PD-21) |
| `dutch_omega_rad_s`, `dutch_zeta` | рад/с, — | голландский шаг: отклик на толчок по рысканию, Прони (PD-21) |
| `reversal_45_s`, `reversal_30_s` | с | перекладка 45→45, 30→30 полным смещением |
| `reversal_beta_max_deg` | ° | наибольшее \|β\| в перекладке 45→45 |
| `turn30_beta_cg_deg`, `turn30_ribbon_deg` | ° | ровный вираж 30°: скольжение у ЦМ и у узла ленты; + внутрь виража |
| `ochi_bank_7s_deg` | ° | опыт Ochi: 30 Н вбок, крен через 7 с |
| `turb_capsize_n`, `turb_runs_n` | шт. | болтанка σ 1 м/с: прогонов с \|крен\| ≥ 60° из всех (поля и шаги — как PD-19/PD-21) |
| `trim_kmh`, `sink_ms`, `full_pull_kmh` | км/ч, м/с, км/ч | трим, снижение на триме, установившаяся скорость при полном «на себя» |

- PB-2 добавляет `"passport": {"<wing_id>": {"vmax_vg0_kmh": …, "vmax_vg100_kmh": …, "source": "…"}}` для крыльев в сводке.
- Запись — во временный файл и переименование.
