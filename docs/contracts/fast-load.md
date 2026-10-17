---
type: "contract"
status: "active"
module: "fast-load"
area: "perf"
updated: "2026-10-17"
summary: "Быстрая загрузка: кеш поля воздуха на диске (FL-К1), общие данные места (FL-К2), формат замера загрузки (FL-К3)."
related: ["docs/plan/fast-load.md", "docs/contracts/training-island.md", "docs/contracts/perf.md", "docs/research/air_field_cache.md"]
contracts: [{"id": "FL-К1", "version": 2}, {"id": "FL-К2", "version": 1}, {"id": "FL-К3", "version": 1}]
---
# Контракты модуля fast-load

Контрактные тесты — `tests/contracts/test_fast_load_k<n>.gd` (фильтр `fast_load_k<n>`), каждый пишет задача-владелец; меняются только вместе
с контрактом (версия +1, через координатора). Правило потоков — `docs/contracts/perf.md` PF-К4: рабочий поток работает на снимке или
данных только для чтения, дерево сцены не трогает, общих данных не пишет; результат подменяется на главном потоке целиком; устаревший
результат отбрасывается; при выходе задача дожидается.

## FL-К1. Кеш поля воздуха на диске — версия 2

- Владелец: FL-2. Потребители: `AirRuntime` (`scripts/atmosphere/air_model/air_runtime.gd`), `Game._load_air_field`
  (`scripts/game/game.gd`, пропуск этапа «wind»), `SettingsPanel` (настройка размера), FL-5 (термики после подачи поля из кеша), FL-11 (замер).
- Код кеша — `scripts/atmosphere/air_field_cache.gd` (класс `AirFieldCache`), **не** в `scripts/atmosphere/air_model/`: файлы этой папки входят
  в `AirBakedField.code_hash()`.
- Место: `user://air_cache/`. Запись = `<имя>.json` (заголовок) + `<имя>.bin` (тело) **в формате TI-К3 v3** (`AirBakedField.save` /
  `read_header` / `load_file`; формат TI-К3 не меняется), `<имя>` = первые 16 hex sha256 от канонического JSON ключа (ключи по алфавиту).
  Заголовок дополнительно несёт `"cache": 1` и `"status"` расчёта (`ok` | `not_converged` | `previous_pass`) — только для журнала.
- Ключ (`key` заголовка; поле берётся только при **точном** совпадении):
  `format` (номер формата кеша, 1), `place` (`loc.id` встроенного места или `LocationCache.key_for` точки), `center` (lat/lon места),
  `data_hash` (`AirBakedField.place_hash(dir)` папки места), `start` (x, z центра окон, округл. 0,01 м), `domain_dx`, `window_dx`,
  `month`, `day`, `cond` — условия `AirRuntime.conditions_of` с округлением: `hour` — до слота пересчёта (`recompute_game_min`, 15 мин),
  `u10` 0,01 м/с, `wdir` 0,1°, `t_max` 0,1 °C, `sky`, `wind_ref`. Прочие входы, от которых зависит поле, если найдутся в коде, — тоже в ключ
  (перечислить в отчёте).
- `model_hash` заголовка = `AirBakedField.model_hash()` (в экспорте — из `res://data/air_model_hash.txt`, `tools/build.sh`); не совпал,
  хеша кода нет, файл не читается или `load_file` вернул null → запись удаляется, `push_warning`, поле считается заново.
- Что кладётся: поле, которое игра приняла после расчёта при загрузке места (в т. ч. `not_converged`, `previous_pass`). Не кладётся:
  аналитический ветер (`fallback`, таймаут без поля), поле без GPU, запечённое поле (TI-К3), пересчёты в полёте.
- Порядок поиска в `load_field`: запечённое (TI-К3) → кеш → расчёт. Попадание: чтение в `WorkerThreadPool` (как `_load_baked`), подача как
  у запечённого — `_cur`/`_cur_key`, `meta.cond`, источники термиков; этапа «Рассчитываем ветер» нет; дальше обычный фоновый пересчёт.
  Публичное: `AirRuntime.cache_ready() -> bool` (поле взято из кеша, по аналогии с `baked_ready()`), `AirRuntime.cache_enabled := true`.
- Запись: снимок массивов `AirFieldSet` (PackedArray, не меняются после подачи) → упаковка, zstd и запись в `WorkerThreadPool`; временный файл +
  переименование; главный поток не блокируется > 100 мс; выход из игры дожидается записи.
- LRU: `user://air_cache/index.json` = `{"version":1, "entries": {"<имя>": {"bytes": N, "used": <unix, с>}}}`, пишется атомарно; при попадании
  `used` обновляется; после записи, пока сумма `bytes` > лимита, удаляется запись с наименьшим `used`. Нет или испорчен `index.json` →
  восстановить по файлам папки (`used` = время изменения). Файлы без пары и временные — удаляются.
- Лимит: `configs/atmosphere.json → air_cache.max_mb` (по умолчанию 200), ключ машины (`UserSettings.LOCAL_KEYS`, `user://local/configs`);
  0 — кеш выключен (ни чтения, ни записи). Настройка — `SettingsPanel`, вкладка «Игра», ползунок 0–2000 МБ, шаг 50; строки в `locale/ui.csv`.
- Инварианты: поле из кеша против посчитанного: |Δ| ≤ 0,01 м/с по u, v, w (float16, ветер до 12 м/с), остальные каналы — в пределах float16;
  одна запись ≈ 6 МБ; повреждённая запись никогда не роняет игру.
- v2 (2026-10-17, находка FL-17): источники термиков (`AirThermals.build`) из поля, взятого из кеша, **бит-в-бит** равны источникам из
  посчитанного поля при том же сиде мира (на Онгудае было 3074 против 3072, `phi_hash` разный) — иначе в сети ведущий и клиент с разным
  состоянием кеша получат разные термики. Каналы и поля `meta`, от которых зависят источники, хранятся без потерь (float32, дтип массива
  в заголовке TI-К3 уже задаётся по массиву — формат TI-К3 не меняется); ключ `format` кеша → 2 (старые записи — промах). Размер записи — в отчёт.

## FL-К2. Общие данные места — версия 1

- Владелец: FL-4. Потребители: `WorldClearings.build_for`, `VillagePlacer.plan`, `WorldObjects` (OSM, дома), `WorldLink.link`, FL-6
  (`OsmLayer.build` и дома в рабочем потоке), FL-10 (порции во время этапа ветра).
- Класс `PlaceData` (`scripts/world_objects/place_data.gd`, RefCounted), создаётся **один раз на загрузку места** в `WorldLink.link` до маски
  просек; хранится в мета `Terrain` `"place_data"` (как `"built_patches"`), сбрасывается со сменой рельефа.
- Поля (после сборки — только чтение, безопасны для рабочих потоков):
  `location_id: String`, `dir: String` (папка места), `layers: Array[HeightLayer]` (те же объекты, что `Terrain.layers`, без повторного
  чтения webp), `patches: BuiltPatches` (экземпляр из мета `Terrain`), `osm: OsmData` (`OsmData.load_for` — один раз за загрузку),
  `house_plan: Array` (один план `VillagePlacer.plan` **с домами OSM**: `osm_houses = osm.buildings`), функция высоты
  `height_at(x: float, z: float) -> float` по `layers` без обращения к узлам сцены (потокобезопасна).
- Правило: потребители берут высоты, OSM, участки застройки и план домов только из `PlaceData`; повторное чтение `meta.json`, webp слоёв,
  `osm_tiles.json`, тайлов OSM или повторный `VillagePlacer.plan` за одну загрузку — нарушение контракта.
- Ключ кеша `VillagePlacer` — из устойчивых данных (`loc_key`, `AirBakedField.place_hash(dir)` или иной хеш данных места, число домов OSM),
  а не `get_instance_id()`; повторный вызов с теми же данными в том же процессе — попадание.
- Без живого рельефа (превью, инструменты) `WorldClearings.build_for(location_id)` собирает `PlaceData` из файлов сам — тоже по одному чтению
  каждого источника.

## FL-К3. Итог замера загрузки — версия 1

- Владелец: FL-1. Потребители: FL-11, шлюзы, отчёт главной.
- Сценарий `tools/research/load_profile/measure.sh <тег> <ong|pt> <n> [--air-cache=keep|clear|off]` (зонд без разметки кода),
  сводка `measure.py` → `tools/research/load_profile/<тег>.json`:
  `{"version":1, "tag", "commit", "date", "machine": {"load_avg_start", "load_avg_end"}, "runs": [{"place": "ong"|"pt", "run": i,
  "air_cache": "none"|"miss"|"hit", "to_flying_s", "terrain_loaded_s", "stages": {"<этап>": с}, "load_max_gap_ms", "load_gaps_over_1s": n,
  "exit": код}], "median": {"<place>/<air_cache>": {"to_flying_s", "load_max_gap_ms", "stages": {...}}}}`.
- `load_max_gap_ms` — наибольший интервал кадров от нажатия «Лететь» до полёта (строки `[gap]` зонда); `air_cache` — `none` до FL-2,
  после — `miss` (папка `user://air_cache` профиля очищена перед запуском) или `hit` (запись есть).
- Места: `ong` = `--location=ongudai`, `pt` = `--latlon=-27.7176,-48.7799`; погода по умолчанию автостарта (12:00, 3 м/с, ясно, 26 °C);
  профили `~/.cache/dp-xdg/loadprof-ong`, `loadprof-pt` (место уже в кеше); окно 1280×720, звук Dummy.
- `compare.py <до>.json <после>.json` → таблица md (медианы, разница, %).
