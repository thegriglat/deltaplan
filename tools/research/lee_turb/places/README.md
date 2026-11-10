---
type: "research"
status: "active"
module: "lee-turb"
area: "air"
updated: "2026-11-09"
summary: "Места Perdigão и Askervein (W5, вне git), случаи W8 для dp-stand, станции в кадре места, пересъёмка, ограничения."
applied_in: ""
related: ["docs/plan/lee-turb.md", "docs/contracts/lee-turb.md", "tests/fixtures/wind/README.md", "docs/contracts/rust-wind/fixtures-tolerances.md"]
conclusion: "Рельеф игры в местах сходится с мачтами: Perdigão медиана −1,3 м, максимум 9,9 м (29 мачт); Askervein после привязки по рельефу −1,4 / 3,8 м (41 станция), но привязка отчёта к OSGB сдвинута на 226 м; U10 игровой модели для U100 данных — 4,37 м/с (Perdigão), 8,04 м/с (RS)."
data: "~/data/lee_turb/places/{perdigao,askervein}.json+.bin (вне git, 12,2 МБ каждое); cases/*.json, stations.csv"
---
# Места Perdigão и Askervein для стенда (LT-4)

Места и случаи для `dp-stand` по модели игры (поле Пикара 400 м + окно 50 м + болтанка), чтобы сверять `σ_u, σ_w` за гребнем с
измерениями. Места — формат W5/W8 (`tests/fixtures/wind/README.md`, `docs/contracts/rust-wind/fixtures-tolerances.md`); в git лежат
только случаи, таблица станций и скрипты, растры — `~/data/lee_turb/places/` (по 12,2 МБ).

| файл | что |
|---|---|
| `export_place.gd` + `.tscn` | Godot: `Terrain.load_point(lat, lon)` (путь игры: Copernicus GLO-30 25 м, WorldCover, реки) → `AirPlaceData.from_terrain` → `<site>.json/.bin` и `<site>_stations.csv` (станции в кадре места) |
| `make_stations_in.py` → `stations_in.csv` | широта/долгота и высота земли станций: Perdigão — `tools/research/cases/perdigao/out/masts.csv` (ETRS89→WGS84) и `towers_layout.csv`; Askervein — локальная сетка отчёта → OSGB36 → WGS84 (Хелмерт) + сдвиг по рельефу (ниже) |
| `make_cases.py` | `cases/perdigao_sw.json`, `cases/perdigao_ne.json`, `cases/askervein_tu03b.json`, `stations.csv`, `stations_check.md` |
| `calibrate_u10.py` | подбор U10 притока: MEAN модели (`--model formula`) на опорной мачте = данные |
| `stations.csv` | `site,case,station,lat,lon,x_game,z_game,ground_game_m,ground_asl_m` — 98 строк (28 + 29 мачт Perdigão по случаям, 41 станция Askervein) |

## Места
| | Perdigão | Askervein |
|---|---|---|
| центр запроса | 39,7098° с. ш., 7,7370° з. д. (между грядами tse04 и tse13) | 57,1908° с. ш., 7,3738° з. д. (вершина HT) |
| ключ места игры (центр привязан к сетке 0,05°) | `pt_+39.700_-007.750` | `pt_+57.200_-007.350` |
| сетка | 1601 × 1601, 25 м, 40 × 40 км (гряды и 3 км по ветру в обе стороны — внутри поля 400 м и окна 50 м) | то же |
| дата, пояс | 27.04, UTC+1 | 03.10, UTC |
| старт `start_sites[0]` | tse04 (гребень ЮЗ-гряды) | HT |
| время сборки (Godot, сеть, холодный кеш) | 144 с | 123 с |

## Случаи (W8, version 1, одно время `t = 0`)
| случай | ветер откуда | U10 притока, м/с | опора | фокус окна | точек |
|---|---|---|---|---|---|
| `perdigao_sw` | 225° (измерено на tse04 100 м: 216,5°) | 4,37 | U100 tse04 = 8,82 м/с | tse04 | 83 |
| `perdigao_ne` | 45° (измерено на tse13 100 м: 60,7°) | 4,37 | U100 tse13 = 8,79 м/с | tse13 | 84 |
| `askervein_tu03b` | 210° | 8,04 | S(RS, 10 м) = 8,895 м/с | HT | 69 |

- Точки — станции на высотах приборов над землёй **модели** (`y = ground_game + высота`); подписи — `extra.point_labels` (`tse04_100m`);
  уровни Perdigão — из `data/perdigao/cases/*_windowmean.csv`, Askervein — из `askervein_validation1.txt`. Теги точек — `mast`.
- Условия — preset-словарь: `sky: overcast`, `cirrus_cover: 1`, `thermal_mode: static` без статичных термиков, `thermal_duty`,
  `background_sink_ms`, `convective_turbulence_ms`, `cb_chance`, `wave_strength` = 0, ветер — набегающий поток (скорость на 10 м).
  Часы: SW 11, NE 19 (середина окна 17–19 UTC +1), Askervein 13. Сид 4001 / 4002 / 4003. `generator` — коммит копии при съёмке.
- **U10 — подобранный**, а не взятый из измерений: профиль игры `U10·(z/10)^0,24` + поле Пикара даёт на опорной мачте 5,7 м/с при
  U10 3,12 (значение решателя `tools/research/cases`), поэтому `calibrate_u10.py` подбирает U10, при котором MEAN модели на опорной
  точке равен данным (невязка ≤ 2 %: tse13 8,792 при 8,79; RS 8,893 при 8,895; tse04: 8,995 при U10 4,447, на 4,37 по наклону ≈ 8,8 при 8,82, последний прогон не делался). Модель по U10 нелинейна
  (U100: 5,74 → 9,72 при U10 3,12 → 4,80), поэтому секущей, не пропорцией.
- Направление Perdigão — по заданию 225° / 45° (ось, перпендикулярная грядам); измеренное на опорной мачте — 216° / 61° (`extra.wdir_measured`).
  Для сверки с измерениями по направлению (поворот потока в долине) это 9° и 15° разницы — решает потребитель (меняется `wind_from_deg`).
- Нейтраль «как у решателя γ = 0» в игре не задаётся ключом: небо overcast + пелена 1 гасят прогрев на порядок, остальные источники выключены;
  стратификацию выводит `Weather` места по часу и дате (в вечернем NE-случае 19 ч возможна слабая устойчивость). Что именно получилось —
  сверять по `dp-stand decompose`.

## Рельеф против мачт (проверка места)
`ground_game_m − ground_asl_m` по мачтам (`stations_check.md`):
- Perdigão: 29 мачт, медиана −1,3 м, среднее −1,5 м, максимум по модулю 9,9 м (rsw08), |Δ| ≤ 10 м у всех 29.
- Askervein: 41 станция, медиана −1,4 м, среднее −1,5 м, максимум 3,8 м (ANE20), |Δ| ≤ 10 м у всех 41.

**Привязка Askervein.** Локальная сетка отчёта принята за OSGB36 без буквы квадрата (E = X, N = 800 000 + Y; HT → 57,19° с. ш., 7,37° з. д.).
Без поправки станции стояли на 226 м в стороне от своих высот: (игра − данные) медиана −22,5 м, максимум по модулю 71,7 м (ASW35 на склоне), RMS 38 м.
Поиск сдвига и поворота станций по растру игры (минимум RMS высот по 41 станции, шаг 5 м): поворот 0°, сдвиг E −112 м, N −197 м
(`ASK_DE`, `ASK_DN` в `make_stations_in.py`) → RMS 1,5 м, максимум 3,3 м. Причина расхождения не выяснена (старая локальная сетка или
привязка DSM); поправка опирается на рельеф, т. е. подгоняет положение станций под модель — для сверки болтанки положение относительно холма важнее,
чем абсолютные координаты. Станции RS (4,75 м) на ровном месте высоту почти не фиксируют.

## Пересъёмка
```
mkdir -p ~/data/lee_turb/places
python3 tools/research/lee_turb/places/make_stations_in.py                          # stations_in.csv
XDG_DATA_HOME=~/.cache/dp-xdg/<копия> .dpcli/dpcli lock cpu lt4 -- godot --headless --path . \
  res://tools/research/lee_turb/places/export_place.tscn -- --site=perdigao        # и --site=askervein, ~2–3 мин каждое, нужна сеть
python3 tools/research/lee_turb/places/make_cases.py                                # cases/*.json, stations.csv
python3 tools/research/lee_turb/places/calibrate_u10.py --iters 2                   # проверка/подбор U10 (~6 мин на итерацию трёх случаев)
```
Первый запуск в копии — `godot --headless --path . --import`. Рельеф и покров кешируются игрой (`user://terrain_cache`, `user://locations/<ключ>`);
повторная съёмка того же места — без сети. Проверка стендом:
`cargo run -q --release --manifest-path rust/Cargo.toml -p dp-stand -- sample --mode mean --case tools/research/lee_turb/places/cases/perdigao_sw.json --place ~/data/lee_turb/places/perdigao.json`
(модель `--model formula` считает поле: первый ответ ≈ 2–3 мин, `--timeout 900`).

## Ограничения
- **25 м против 10 м.** Игра строит рельеф на сетке 25 м из Copernicus GLO-30 (30 м, DSM — с кронами) со сглаживанием σ = 0,8 клетки; в лесу
  сглаживание сильнее (`SmoothStage`). Гряды Perdigão (высота ~200 м, длина склона ~700 м) разрешены, но уступы и вырубки на 10 м — нет; у
  `terrain10.npz` исследования (шаг 10 м) та же основа, но без игрового сглаживания.
- **Лес и z0 — из класса поверхности** (`cls`: WorldCover 2021, мода 3×3), а не из измеренного полога (эвкалипт 20–25 м, сосна ≤ 15 м, пятнами):
  z0 класса, смещения нулевой плоскости нет. Мачты внутри леса (tse12, rsw) видят ветер у земли, который модель не разрешает.
- Дата одна на место (Perdigão — 27.04 для обоих случаев, влияет только на солнце); климат места в заголовке (`loc.climate`) не записан — формат без него
  читается, погода берёт запасные значения конфига.
- Askervein — холм 120 м на 30-метровом DSM: вершина HT 123 м (растр) против 124,6 м (данные), крутизна склона занижена.
- Мачты Perdigão — только те, что есть в `*_windowmean.csv` случая (28 в SW, 29 в NE из 59 известных).
- Данные Perdigão и Askervein — `tools/research/data/*/README.md` (лицензии, цитирование); DEM — Copernicus GLO-30 © DLR/Airbus/ЕС/ESA, покров — ESA WorldCover 2021 CC BY 4.0.
