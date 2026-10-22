---
type: "research"
status: "active"
module: "haze-humidity"
updated: "2026-10-22"
summary: "Сетка 700 гПа (HH2 v2): климатология ERA5 (CDS) 2011–2020, T и Z по месяцам, 1°, 1,38 МБ; σ T700 не посчитана (шлюз Q4, ждёт решения)"
related: ["docs/contracts/haze-humidity.md", "docs/plan/haze-humidity.md", "tools/research/haze_humidity/dew_point/README.md"]
conclusion: "data/climate/upper_air_1deg.bin — настоящая сетка (year0=2011, year1=2020). T700 по Алтаю в среднем на 1,2 °C холоднее таблицы (−3,6…+0,8), Δz_dry ≈ −200 м. t700_sd.npz — пустой (NaN): σ ждёт ответа пользователя по Q4."
data: "data/climate/upper_air_1deg.bin"
applied_in: []
---
# Воздух 700 гПа: сетка 1° (HH-1g)

## Состояние
- `data/climate/upper_air_1deg.bin` — **реальная климатология**, HH2 v2: 360×180×12, int16, brotli q11, заголовок 64 байта,
  `year0=2011`, `year1=2020`. Размер **1 379 274 байт** (≤ 2 МБ). Масштабы: T 0,01 °C (offset −15), Z 0,1 м (offset 2000).
- Диапазоны: **T −49,6…19,3 °C, Z 2452…3234 м** — внутри инварианта контракта z ∈ [2000, 3500] м, обрезки нет.
- **σ суточной T700 не посчитана.** `t700_sd.npz` существует (ключ `sd_k`, float16, 12×180×360), но целиком NaN; колонка
  `t700_sd_k` в `sites.csv` = nan. Причина: daily-statistics по лимиту стоимости CDS (400) — запрос на год×полугодие,
  20 запросов в общей очереди (каждый часы); по решению координатора (шлюз Q4, 2026-10-22) не запускалось до ответа
  пользователя (вероятно 2 года вместо 10). Скрипт готов: `python fetch_cds.py daily` (правка списка лет `YEARS`),
  затем `aggregate_cds.py` и `bake.py`/`sites.py` (σ сама заполнится).

## Источник и атрибуция
ERA5 (Hersbach et al. 2020, QJRMS 146:1999), Copernicus Climate Change Service (C3S) Climate Data Store,
набор `reanalysis-era5-pressure-levels-monthly-means`, лицензия Copernicus/CC-BY-4.0 (с атрибуцией: «Generated using
Copernicus Climate Change Service information»); строку занести в `ASSETS.md` при шлюзе волны 1.

## Метод
- Один запрос CDS: `monthly_averaged_reanalysis_by_hour_of_day`, temperature + geopotential, 700 гПа, 2011–2020 × 12 мес.,
  часы 00 и 12 UTC, `grid 1°×1°` (интерполяция CDS на 181×360 узлов), NetCDF 47 МБ (125 МБ в памяти). Очередь + выполнение:
  8788 с (≈2,4 ч, замок и очередь CDS).
- Ячейка 1° (центр на полуградусе) = среднее 4 соседних узлов; значение месяца = среднее по 10 годам и по двум срокам
  (00+12 UTC; гасит суточную гармонику, как в HH-1). Z = geopotential / 9,80665.
- Допущение: узловая интерполяция CDS вместо среднего по площади 0,25° → 1° (по решению о выборе агрегированных
  наборов); для гладкого поля 700 гПа разница мала, у крутого рельефа (Гималаи, Анды) 700 гПа ниже поверхности —
  там значения экстраполированы ERA5 (в игре не используются).

## Сверка с таблицей upper_air (`sites.csv`)
Среднее по году ΔT = T700(сетка) − T(таблица) и Δz_dry ≈ ΔT/(9,8 − 4,0) км:
| место | ΔT средн., °C | диапазон по месяцам | Δz_dry, м |
|---|---|---|---|
| Алтай (Чемал) | −1,17 | −3,6…+0,8 | −200 |
| Онгудай | −0,56 | −2,7…+1,4 | −100 |
| Аскарово | −0,33 | −2,2…+2,0 | −60 |
| Аушкуль | −1,07 | −3,0…+1,4 | −180 |
| Крым | +4,8 | +1,1…+8,6 | +820 |
| dry_darab (Иран) | +16,0 | +13,9…+17,8 | — |
| wet_cairns | +16,1 | +6,2…+26,8 | — |
Таблица upper_air подогнана под Алтай (T −16,5…2,5 °C); для других мест сетка сильно теплее — воздух над миром был единым.
Для HH-4 (эталоны `configs/weather/*` Алтая): сдвиг ~ −1…−3 °C (май −3,6) даёт Δz_dry до −600 м в отдельные месяцы,
в среднем год ≈ −200 м; решение по эталонам — контрактом координатора.

## Воспроизведение
```
cd tools/research/haze_humidity/upper_air
nohup setsid ~/data/haze_humidity/venv/bin/python fetch_cds.py monthly > ~/data/haze_humidity/upper_air_cds/fetch.log 2>&1 &   # ключ ~/.cdsapirc, замок cds.lock
~/data/haze_humidity/venv/bin/python aggregate_cds.py && ~/data/haze_humidity/venv/bin/python bake.py && ~/data/haze_humidity/venv/bin/python sites.py
```
(venv: numpy brotli xarray netcdf4 ecmwf-datastores-client). Сырой NetCDF — `~/data/haze_humidity/upper_air_cds/2011_2020.nc`
(вне репозитория). Устаревшие `fetch.py`/`aggregate.py` (ARCO) не используются: медленно.
