---
type: contract
status: "active"
module: cloud-view
area: world
updated: "2026-11-05"
summary: "Стыки cloud-view: формат замеров кадров у облаков (CSV, v1) и действующий интерфейс CloudWhiteout (v1)."
related: ["docs/plan/cloud-view.md", "docs/contracts/cloud-field.md"]
contracts: [{"id": "CVW-К1", "version": 1}, {"id": "CVW-К2", "version": 1}]
---

# Контракты модуля cloud-view

## CVW-К1. Замеры кадров у облаков — CSV (v1)
Владелец — координатор. Пишут: стенды CVW-1, CVW-2 (`tools/shots/cloud_view_*_shot.gd`). Читают: задачи правки (кадры и числа до/после), отчёт модуля.

Файл `tools/research/cloud_view/<ID>/measures.csv`, UTF-8, разделитель `,`, точка — десятичный знак, строка на кадр. Обязательные колонки — в этом порядке:

```
frame,loc,hour,cam_x,cam_z,cam_y_msl,cam_agl,yaw_deg,pitch_deg,cloud_base_msl,cloud_top_msl,cover_cam,density_cam,whiteout_amount,fog_density,fog_r,fog_g,fog_b,fog_sky_affect,mean_r,mean_g,mean_b,luma_mean,luma_std,png
```

- `frame` — имя кадра (без пути), `loc` — id места, `hour` — час атмосферы (ч, местное);
- `cam_*` — мировые координаты камеры, м; `cam_agl` — над рельефом, м; `yaw_deg`, `pitch_deg` — градусы;
- `cloud_base_msl`, `cloud_top_msl`, `cover_cam` — `CloudField.sample(cam)` (x, y, z), м / 0..1;
- `density_cam` — `CloudField.density_at(cam)` (то, что игра подаёт в `CloudWhiteout.update`, К2);
- `whiteout_amount` — `CloudWhiteout.amount` после обновления; `fog_*` — итоговые `Environment.fog_density`, `fog_light_color` (r, g, b), `fog_sky_affect` в кадре;
- `mean_*`, `luma_*` — по всему кадру, линейные 0..1 из PNG (luma = 0,2126 R + 0,7152 G + 0,0722 B);
- `png` — путь кадра (кадры лежат вне репозитория, см. карточку).

Нет величины (нет поля, нет мглы) — пустое поле, не 0. Дополнительные колонки — после `png`, имя с префиксом `x_` (например `x_haze_top_msl`, `x_cloud_alpha_center`), смысл и единицы — в README рядом. Контрактная проверка — первая строка файла совпадает с заголовком выше (проверка `csv_header` в карточках).

## CVW-К2. CloudWhiteout — «белая мгла» в облаке (v1, действующий код)
Владелец — `scripts/game/cloud_whiteout.gd`; вызывает `scripts/game/game.gd` (`_whiteout.update(d, dt)`, `_whiteout.apply(environment)`), параметры — `configs/game.json → cloud_whiteout`.

```
var amount: float                       # 0..1
func setup(cfg: Dictionary) -> void     # density_gain, rise_time_s, fog_density, color
func update(density: float, dt: float) -> void   # цель clamp(density × gain, 0, 1), выход — экспонента rise_time_s
func apply(env: Environment) -> void    # смешивает исходный туман окружения с мглой по amount
```

Инварианты: `density = 0` → `amount` спадает к 0, исходные параметры тумана окружения возвращаются точно; мгла зависит только от плотности облака в точке камеры. Контрактный тест — `tests/game/test_game_logic.gd::test_cloud_whiteout` (фильтр `test_game_logic`: `--filter` — подстрока имени файла теста). Изменение интерфейса или инвариантов — только координатор, версия +1.
