---
type: "research"
status: "active"
module: "haze-humidity"
updated: "2026-10-21"
summary: "Сетка 700 гПа (HH2 v2): ЗАГЛУШКА до CDS — T из таблицы upper_air.temp_c, Z 3000 м, 165 байт; конвейер ERA5 готов, не запускался"
related: ["docs/contracts/haze-humidity.md", "docs/plan/haze-humidity.md", "tools/research/haze_humidity/dew_point/README.md"]
conclusion: "data/climate/upper_air_1deg.bin записан как заглушка (year0=year1=0): поведение игры не меняется. Реальные T700/Z700 ERA5 — после ключа CDS."
data: "data/climate/upper_air_1deg.bin"
applied_in: []
---
# Воздух 700 гПа: сетка 1° (HH-1b) — заглушка до CDS

## Состояние
**Это заглушка, не климатология.** Ключа CDS нет (ответ пользователя на Q3, 2026-10-21), прямое чтение ARCO-ERA5 для
700 гПа оказалось слишком медленным (скрипты `fetch.py`/`aggregate.py` написаны, данные не скачаны). По контракту
HH2 v2 («Заглушка до CDS») файл содержит:
- `year0 = year1 = 0`; читатель (HH-4) обязан писать в лог «HH2: заглушка до CDS»;
- T во всех ячейках — `configs/weather_model.json → upper_air.temp_c` по месяцам (−16.5 … 2.5 °C);
- Z во всех ячейках — 3000 м (`upper_air.z_msl_m`).
Поведение игры не меняется: этот воздух уже сейчас единый для мира.

## Файл
`data/climate/upper_air_1deg.bin`, HH2 v2: 360×180×12, int16, brotli q11, заголовок 64 байта. **Размер 165 байт**
(raw 3 110 400; константные поля сжимаются почти в ноль). Масштабы: `t_scale 0.01`, `t_offset −15.0` °C;
`z_scale 0.1`, `z_offset 2000.0` м. Диапазоны: T −16.5…2.5 °C, Z 3000…3000 м. Пропусков нет.
Контрактный тест Godot (`test_upper_air_format`) должен проходить без пропуска.

## Источник и атрибуция (для будущей реальной сетки)
ERA5 (Hersbach et al. 2020, QJRMS 146:1999), Copernicus Climate Change Service, лицензия CC-BY-4.0 (данные ERA5 в CDS —
лицензия Copernicus, допускающая использование с атрибуцией; уточнить при шлюзе волны 1 в `ASSETS.md`). Заглушка
ERA5 не содержит. Годы реальной сетки: 1991–2020, сроки 00 и 12 UTC (среднее гасит суточную гармонику), как HH-1.

## Что не сделано (ждёт ключа CDS)
- Реальные T700/Z700 и `t700_sd.npz` (σ среднесуточной T700, ключ `sd_k`, 12×180×360 float16): **не созданы**. Колонка
  `t700_sd_k` в `sites.csv` пуста. `t700_grid_c`/`z700_grid_m` в `sites.csv` равны таблице (заглушка), отклонения 0.
- Объём и время скачивания — не измерены. Оценка по HH-1 (Td, ARCO, ≈1,5 ч, ≈4 ГБ сырых на 30 лет) для T и Z 700 гПа
  по порядку величины такая же; через CDS «monthly means by hour of day» — 30 запросов по 12 мес. × 2 срока, ожидаемо
  минуты–десятки минут по очереди CDS (не проверено).

## Воспроизведение
```
cd tools/research/haze_humidity/upper_air
python -m venv ~/data/haze_humidity/venv && ~/data/haze_humidity/venv/bin/pip install numpy brotli
~/data/haze_humidity/venv/bin/python bake.py --stub && ~/data/haze_humidity/venv/bin/python sites.py --stub   # заглушка
```
Реальная сетка после ключа (`pip install cdsapi xarray netcdf4`, `~/.cdsapirc`):
```
python fetch_cds.py 1991 2020 && python aggregate_cds.py && python bake.py && python sites.py
# σ суточной T700: fetch.py (ARCO, суточные 00+12 UTC; pip install zarr gcsfs) + aggregate.py -> t700_sd.npz
```
`fetch_cds.py` и `aggregate_cds.py` **не запускались** (нет ключа, не тестированы); имена датасета и полей —
по документации CDS из общих знаний, возможна правка при первом запуске. `fetch.py`/`aggregate.py` (ARCO) —
написаны ранее, тоже без полного прогона. При реальной сетке пересмотреть диапазоны/масштабы (Z до ~5300 м вне
инварианта z_m ∈ [2000, 3500] контракта — для 700 гПа типично 2700–3200 м, проверить).
