---
type: "guide"
status: "active"
module: "air-model"
area: "air"
updated: "2026-10-15"
summary: "Как подать поле из файла, снять срезы и включить F3; числа выборки (AM-05) и замер травы и ряби по полю (WF-10)."
related: ["docs/guide/air-model.md"]
---

# Отладка поля: файл, срезы, F3, трава по полю

## Отладка: полёт на поле из файла
Вместо расчёта при загрузке поле можно подать из файла — аргумент `--air-field=<путь>` (`.json` + `.bin`),
его читает `Atmosphere` один раз за запуск:
```bash
cd tools/research/air3d
PY=../heat_ca/.venv/bin/python
F=tools/research/air3d/out/fields   # поля прикидки (вне git)
$PY to_game_field.py $F/W100_h13_U3_d180.npz $F/W100_noheat_U3_d180.npz fields/game/kayancha_w100_h13_U3_d180
cd ../../..
godot --path . -- --location=ongudai --wind=3 --from=180 --hour=12 \
  --air-field=tools/research/air3d/fields/game/kayancha_w100_h13_U3_d180.json
```
Поле прикидки — окно 100 м 6,4 × 6,4 км у Каянчи (64 × 64 × 62, 5 МБ), 13:00, южный 3 м/с;
ветер игры надо задать тот же (поле его не подстраивает). Вне окна — аналитика.

## Числа (AM-05)
- Выборка на аналитических массивах: постоянное поле — ошибка 0; линейное — 4,8·10⁻⁷ м/с;
  лог-профиль у земли — до 10⁻⁴; вес края монотонен, шаг ≤ 0,01 на 1 м; NaN во входе → конечно.
- Каянча, поле прикидки (фикстура 16 × 16 × 40 у старта), 50 м над землёй сетки:
  `air_velocity_at` = (−0,563; 0,076; −2,455) м/с = поле (u, w_mech, −v) до 10⁻⁴; w_conv 0,103
  (пилоту не отдаётся); сумма 0,18 м/с совпадает с «подъёмом у старта на 50 м» прикидки
  (`agl_slice`, 0,178). Через край окна на высоте 2400 м — изменение ≤ 0,03 м/с на 5 м.
- Время `air_velocity_at` (способ базы AM-00: Каянча, 75 м, 100 000 вызовов в точке):
  без поля 14,8 мкс, с полем 20,4 мкс (×1,37; база AM-00 — 14,3 мкс). По сетке 6400 точек в
  окне поля: 16,8 → 25,4 мкс (×1,5). `tools/bench/air_velocity_bench.gd`.

## Отладка: срезы и F3 (AM-10)
- **Карта фаз (F4, AP-20):** `WindFieldDebug` — в углу экрана область 400 м, клетка — цвет фазы с наибольшим весом
  (`AirRuntime.phase_map`: A зелёный, B жёлтый, C синий, D коричневый, F оранжевый, G фиолетовый, H серый), белая точка —
  пилот; текстура ny×nx собирается раз на новое поле, выключено — ничего не считается.
- **Срезы (WF-09):** `tools/wind_field/dump_slices.gd` + `.tscn` — headless-инструмент, без окна.
  Читает поле из файла (`WindField.load_file`, тот же формат, что `--air-field`) и рисует три PNG:
  два горизонтальных среза (20 и 200 м AGL; цвет — разгон |Gₕ|/U₀ − 1, редкая сетка стрелок
  направления) и один вертикальный вдоль ветра через точку (цвет — w/U₀, тонкие изолинии θ′
  каждые 0,15 К, силуэт рельефа снизу). Термики поверх вертикального среза — по желанию
  (`--location=<id>`): текущая модель термиков через `Atmosphere.thermals_near` (жёлтые
  треугольники по силе) — **не термики из среднего поля 1** (AM-07 делает это параллельно;
  подпись на срезе так и говорит). Запуск:
  ```bash
  godot --headless --path . res://tools/wind_field/dump_slices.tscn -- \
    --field=tools/research/air3d/fields/game/kayancha_w100_h13_U3_d180.json \
    --out=tools/research/air3d/out/slices --name=kayancha --wind=3 --from=180 --hour=13 \
    [--point=x,y,z] [--location=ongudai] [--extra_out=build/screenshots --extra_prefix=03]
  ```
  Точка среза по умолчанию — проба `*_agl10` из meta поля (обычно старт), иначе центр поля.
  На срезе Каянчи видны разгон и подъём над бровкой перевала (полоса подъёма/спада у земли) и
  явная полоса ускорения над седловиной на 200 м AGL. Вертикальный срез рисует и `<имя>.json`
  (полуширина, высота, шкала w, θ′-шаг, место/час/ветер) — `tools/wind_field/annotate_slice.py`
  (PIL) накладывает по нему оси (км / м), шкалу цвета w (м/с) и заголовок: GDScript headless без
  окна текст не рисует, PNG остаётся голой заливкой без подписей до этого шага.
  ```bash
  python3 tools/wind_field/annotate_slice.py \
    tools/research/air3d/out/slices/kayancha_vertikal_vdol_vetra.png --out build/screenshots/04_....png
  ```
- **F3 в игре:** отдельный узел `WindFieldDebug` (`scripts/atmosphere/wind_field_debug.gd`),
  добавлен в `scenes/game/game.tscn` рядом с `Game` (без правок `game.gd`) — по нажатию F3 строит
  `MultiMesh` стрелок горизонтального ветра (`Atmosphere.air_velocity_at` — та же выборка, что у
  пилота) в сетке вокруг пилота (радиус/шаг/высоты — экспорты узла), цвет — вертикаль (подъём —
  красный, опускание — синий, как у F5); подпись в углу экрана — «поле» или «аналитика»
  (`is_air_field_on`). Повторное F3 — выключить: `_process` останавливается, `MultiMesh` и надпись
  скрыты — без выборок и перестроений, ноль влияния на FPS. F3 — действие `debug_wind_field` (`configs/controls.json` → `debug.keys`).
  Скриншот-инструмент (нужно окно): `tools/shots/wind_field_shot.gd` — как `cloud_shadow_shot.gd`
  (автостарт полёта, ждёт FLYING), включает F3 вызовом `WindFieldDebug._toggle()` и снимает кадр
  (`--shot`), либо меряет среднее GPU-время кадра `RenderingServer` за `--gpu=N` кадров (общий
  кадр окна — для сравнения с полем и без, не только трава/вода). Пример:
  ```bash
  XDG_DATA_HOME=$(mktemp -d) godot --path . --audio-driver Dummy --resolution 1920x1080 \
    res://tools/shots/wind_field_shot.tscn -- --autostart --bots=0 --location=ongudai \
    --site=kayancha_south --wind=3 --from=180 --hour=13 \
    --air-field=tools/research/air3d/fields/game/kayancha_w100_h13_U3_d180.json \
    --out=build/screenshots --tag=kayancha --shot --preset=high
  ```
- **Трава и рябь на воде по полю (WF-10):** `TerrainWind` (`scripts/terrain/terrain_wind.gd`)
  раз в `field_tex_interval_s` (configs/world.json → wind_visual) строит 2D-текстуру RGF (u, v
  горизонтали нижнего слоя поля, `AirFieldSet.sample`) вокруг камеры и передаёт всем материалам
  (`field_wind_tex`/`field_wind_origin`/`field_wind_size_m`); источник поля — сам `Atmosphere`,
  передан через `WorldLink.link` → `Terrain.set_wind_sources(…, field_src)` (duck typing:
  `is_air_field_on()`/`air_field`, без правок `atmosphere.gd`). В шейдерах —
  `scripts/terrain/terrain_wind.gdshaderinc` (`grass_wind`, per-blade трава) и
  `scripts/terrain/terrain_main.gdshaderinc` (`water_wind`, рябь) берут `field_wind_tex` по месту (xz)
  вместо общего `wind_vec`, когда `field_wind_size_m > 0`; без поля или вне текстуры — как раньше.
  Замер (Каянча, «Высокий», окно 1920×1080, среднее GPU-время кадра за 150 кадров,
  `tools/shots/wind_field_shot.gd --gpu=150`, `flock /tmp/heat_ca_gpu.lock`): с полем 9,09 мс
  (два прогона: 9,087 и 9,093), без поля 8,991 мс — Δ ≈ 0,10 мс (трава и рябь воды вместе, в
  бюджете ≤ 0,2 мс; замер по всему кадру окна — трава и вода в нём лишь часть общей стоимости).
