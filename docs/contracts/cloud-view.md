---
type: contract
status: "active"
module: cloud-view
area: world
updated: "2026-11-05"
summary: "Стыки cloud-view: замеры кадров (CSV v1), CloudWhiteout v2 без протечки в небо и дымку облаков, плотность рисуемого облака (v1)."
related: ["docs/plan/cloud-view.md", "docs/contracts/cloud-field.md"]
contracts: [{"id": "CVW-К1", "version": 1}, {"id": "CVW-К2", "version": 2}, {"id": "CVW-К3", "version": 1}]
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

## CVW-К2. CloudWhiteout — «белая мгла» в облаке (v2)
Владелец — `scripts/game/cloud_whiteout.gd` (правит CVW-3); вызывает `scripts/game/game.gd` (`_whiteout.update(d, dt)`, `_whiteout.apply(environment)`), параметры — `configs/game.json → cloud_whiteout`. Потребитель тумана — `scripts/atmosphere/cloud_layer.gd::_update_light` (дымка облаков). v1 → v2 (2026-11-05, по CVW-1/CVW-2): источник `density` — К3; мгла не протекает в небо ступенькой и в дымку облаков.

```
var amount: float                       # 0..1
func setup(cfg: Dictionary) -> void     # density_gain, rise_time_s, fog_density, color (+ новые ключи CVW-3 — с _doc в configs/game.json)
func update(density: float, dt: float) -> void   # density — К3 (плотность рисуемого облака у камеры); цель clamp(density × gain, 0, 1), выход — экспонента rise_time_s
func apply(env: Environment) -> void    # смешивает исходный туман окружения с мглой по amount
```

Метаданные окружения (стык с дымкой облаков): пока `amount > 0`, `apply` держит `env.get_meta("fog_base")` = `{"enabled": bool, "density": float, "color": Color, "sky_affect": float}` — туман окружения **до** мглы; при `amount = 0` и возврате исходных параметров метаданные удаляются. `cloud_layer._update_light`: есть `fog_base` → дымку облаков (`fog_color`, `fog_density` шейдера) считает по нему, как при `enabled`/без мглы; нет — как сейчас.

Инварианты:
- `amount = 0` → параметры тумана окружения и дымки облаков побитно те же, что без мглы (вид вне облака не меняется);
- непрерывность по `amount`: каждый параметр, который `apply` пишет в `env` (включая вклад тумана в небо: `fog_sky_affect`, включение `fog_enabled`), — непрерывная функция `amount`, равная исходной при `amount = 0`; скачок вида неба при `amount → 0+` отсутствует (критерий в карточке CVW-3);
- `amount = 1` → видимость как в v1 (`fog_density` мглы, небо в мгле, `fog_sky_affect` → 1);
- дымка других облаков от мглы не зависит (метаданные `fog_base`).

Контрактный тест — `tests/game/test_game_logic.gd::test_cloud_whiteout` (фильтр `test_game_logic`: `--filter` — подстрока имени файла теста) и `tests/game/test_cloud_whiteout_view.gd` (CVW-3, фильтр `cloud_whiteout_view`: инварианты выше). Изменение интерфейса или инвариантов — только координатор, версия +1.

## CVW-К3. Плотность рисуемого облака у камеры (v1)
Владелец — CVW-4. Потребитель — `scripts/game/game.gd` → `CloudWhiteout.update` (К2).

```
# scripts/atmosphere/cloud_layer.gd (class CloudLayer)
func visible_density_at(p: Vector3) -> float   # 0..1; −1.0 — облака не рисуются (нет слоя, выключены, нет выбранных объектов ещё не было)
```

- Считает плотность в точке `p` по облакам, которые сейчас **рисуются** (выбранные для отрисовки объекты с их центром, размером, стадией и затуханиями — те же величины, что уходят в шейдер), той же формой, что `cloud_density` в `scripts/atmosphere/cloud_common.gdshaderinc` (крупная форма; мелкий шум эрозии можно опустить — в README отклонение); нормировка 0..1 как у `Atmosphere.cloud_density_at`, чтобы `density_gain` сохранял смысл.
- Вне всех рисуемых облаков — 0 (в том числе в просвете слоя, где грубое поле > 0).
- Цена — одна точка на кадр на главном потоке, без выделений памяти в цикле; без обращений к GPU.
- `game.gd`: `d = visible_density_at(cam)`; `d < 0` (облака не рисуются) → запасной путь `air.cloud_density_at(cam)` (грубое поле, как в v1).

Контрактный тест — `tests/atmosphere/test_cloud_visible_density.gd` (фильтр `cloud_visible_density`): в центре рисуемого облака ≥ 0,5; вне облаков 0; облака не рисуются → −1.
