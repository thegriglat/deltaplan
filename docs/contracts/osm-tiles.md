---
type: "contract"
status: "active"
module: "osm-tiles"
updated: "2026-10-10"
summary: "Контракты osm-tiles: мировая сетка 20 км (O1), файл тайла (O2), потоки и кодировка (O3), фрагменты и склейка регионов (O4), CLI упаковщика (O5), сводка stats (O6), манифест (O7), оркестратор и его состояние (O8), клиент в игре (O9)."
related: ["docs/plan/osm-tiles.md", "docs/plan/osm_vector_pack.md", "docs/plan/no-osm.md", "docs/contracts/osm-any.md"]
contracts: [{"id": "O1", "version": 1}, {"id": "O2", "version": 1}, {"id": "O3", "version": 1}, {"id": "O4", "version": 1}, {"id": "O5", "version": 1}, {"id": "O6", "version": 1}, {"id": "O7", "version": 1}, {"id": "O8", "version": 2}, {"id": "O9", "version": 1}]
---
# Контракты модуля osm-tiles

План — `docs/plan/osm-tiles.md`. Менять — только через координатора модуля: версия +1, что изменилось,
уведомить потребителей, их правка в том же шаге. Основа — замер и прототип `docs/plan/osm_vector_pack.md` §9
и `tools/research/osm_pack/build_tiles20.py`, `build_pilot20.py` (эталон; кодировка O3 = эталонная, кроме
отмеченных «отличие от эталона»).

Контрактные тесты: Rust — `cargo test` в `tools/osm_tiles/packer` (O1–O7: золотые значения сетки, круг
«закодировал → прочитал», заголовок, манифест); Python — `tools/osm_tiles/tests/` (независимый декодер
`tools/osm_tiles/read_tile.py` по этому документу читает образцы, которые пишет Rust); GDScript —
`tests/contracts/test_osm_tiles_contracts.gd` (O1 по золотой таблице, O2/O3 — декодер игры на образце, O9).
Общие образцы: `tests/contracts/osm_tiles/grid_golden.json`, `tests/contracts/osm_tiles/sample_v1.dpt` +
`sample_v1.json` (ожидаемый разбор).

Код: упаковщик — Rust-крейт `tools/osm_tiles/packer` (бинарь `osmtiles`), схема — `tools/osm_tiles/proto/osm_tiles.proto`,
оркестратор — `tools/osm_tiles/world.py` (+ `regions.py`), Python 3 только stdlib. Клиент — `scripts/world_objects/osm/`.

## O1. Мировая сетка 20 км — версия 1
Владелец: OT-1 (`grid.rs`). Потребители: упаковщик, оркестратор (через `osmtiles cover`), клиент (GDScript), сверка.

Константы (f64): `R = 6371008.8` м; `M = π·R/180` (= 111 195,080 м на градус); `DLAT = 0.18`; `T = 20000`.
- Пояс: `j = floor(lat / DLAT)`, `lat` ограничена `[−90, 90)` (90 → пояс 499); `j ∈ [−500, 499]`.
- В поясе: `latc = (j + 0.5)·DLAT`; `kx = M·cos(latc·π/180)`; `ky = M`; `n(j) = max(1, floor(360·kx / T))`;
  `dlon(j) = 360 / n(j)`.
- Тайл: `lon` приводится к `[−180, 180)`; `i = clamp(floor((lon + 180) / dlon), 0, n − 1)`.
- Юго-западный угол: `lon0 = −180 + i·dlon`, `lat0 = j·DLAT`.
- Координаты тайла (м, f64): `x = (lon − lon0)·kx` (восток), `y = (lat − lat0)·ky` (север). Обратно:
  `lon = lon0 + x/kx`, `lat = lat0 + y/ky`. Ширина `W = dlon·kx` ∈ [20 000; 20 500) м (у полюсов больше),
  высота `H = DLAT·M = 20 015,11` м. Проекция — равнопромежуточная по широте центра пояса: на краю пояса
  истинный масштаб по x отличается на `cos(lat)/cos(latc) − 1` (60° — ±0,27 %); это граница модели.
- Соседи 3×3 `neighbors(lat, lon)`: для `jj` = j−1, j, j+1 (снизу вверх; вне `[−500, 499]` — пропуск):
  `ic = clamp(floor((lon+180)/dlon(jj)), 0, n(jj)−1)`, столбцы `(ic−1, ic, ic+1) mod n(jj)` (запад → восток,
  через антимеридиан по кругу); повторы убираются с сохранением порядка. Покрывает квадрат ±20 км вокруг точки.
  Индекс `i` в соседнем поясе другой (шаг другой) — только эта функция, не `i±1`.
- Антимеридиан: линия режется там, где соседние вершины различаются по долготе больше чем на 180°.
- Ключ тайла: `(j, i)`, строка `"j,i"` в JSON; путь — O2.
- Детерминизм: пояс и индекс считаются ровно этими операциями в f64. Золотая таблица
  `tests/contracts/osm_tiles/grid_golden.json` (генерирует OT-1 эталонным Python): `n(j)` всех 1000 поясов
  и ≥ 300 точек `(lat, lon) → (j, i, x, y)` + `neighbors` для ≥ 20 точек (экватор, 43°, 60°, 80°,
  антимеридиан, полюс); x, y — допуск 1e−6 м.

## O2. Файл тайла — версия 1
Владелец: OT-1. Потребители: упаковщик (запись), `finalize`, `stats`, `dump`, манифест, клиент.

Почему так: protobuf — правило проекта для записей (`.proto` в репозитории); массивы — внутри `bytes`.
Весь protobuf сжат одним кадром zstd (потоки по отдельности давали бы ≈ 15 кадров × 10–20 Б заголовков на
тайл, а большинство тайлов планеты почти пустые). Внешний заголовок нужен клиенту: Godot `decompress()`
для zstd требует размер результата.

**Контейнер** (little-endian), 16 байт заголовка + один кадр zstd:
| смещение | тип | поле |
|---|---|---|
| 0 | 4 Б | магия `"DPOT"` |
| 4 | u16 | версия контейнера = 1 |
| 6 | u16 | флаги: бит 0 — фрагмент (O4); остальные 0 |
| 8 | u32 | `raw_len` — длина protobuf после распаковки (≤ 64 МиБ) |
| 12 | u32 | 0 (резерв) |
| 16 | … | кадр zstd (с контрольной суммой содержимого); итоговые тайлы — уровень 19, фрагменты — 3 |

**Схема** `tools/osm_tiles/proto/osm_tiles.proto` (proto3, `package deltaplan.osmtiles;`):
```proto
message OsmTile {
  uint32 format_version = 1;     // = 1 (версия O3)
  sint32 j = 2;
  uint32 i = 3;
  uint32 n = 4;                  // n(j) — проверка сетки
  int64 osm_timestamp = 5;       // unix с, самая поздняя метка источников (0 — неизвестно)
  repeated string sources = 6;   // id регионов: фрагмент — один; итоговый тайл — внёсшие данные, по алфавиту
  repeated Stream streams = 7;   // не больше одного на вид, по возрастанию kind; пустые не пишутся
}
message Stream {
  Kind kind = 1;
  uint32 count = 2;              // число объектов в data
  bytes data = 3;                // кодировка O3
  bytes ids = 4;                 // только во фрагментах (O4); в итоговом тайле пусто
}
enum Kind {
  KIND_UNSPECIFIED = 0; ROADS = 1; TRACK = 2; BUILDINGS = 3; POWERLINE = 4; POWER_TOWER = 5;
  AERIALWAY = 6; AEROWAY = 7; VERTICAL = 8; RAIL = 9; PEAK = 10; PASS = 11; NAMES = 12;
  RIVER = 13; CANAL = 14;
}
```
Rust — `prost` (+ `protox` в `build.rs`, системный `protoc` не нужен). Неизвестный `kind` клиент пропускает.
Тайл без объектов — файла нет (клиент: 404/нет файла = пустой тайл).

**Путь:** `<корень>/v1/<j>/<i>.dpt` (`j` — со знаком, десятичное: `v1/240/1038.dpt`, `v1/-12/7.dpt`);
фрагменты — `<frag-dir>/<j>/<i>/<region>.frag`. Смена версии O2/O3 → новый префикс `v2/`.

## O3. Потоки и кодировка — версия 1
Владелец: OT-1 (кодер/декодер), OT-2 (отбор и геометрия). Потребители: клиент, `stats`, сверка.

**Общее.** `varint` — LEB128 без знака; `zz(v) = (v << 1) ^ (v >> 63)`; точки — пары `zz(x − lx), zz(y − ly)`,
`lx = ly = 0` в начале потока и **переносятся между объектами** потока. Координаты — целые метры O1,
округление половин к чётному (`round_ties_even`, как `numpy.rint`). Порядок объектов: линии и точки — по
`(тип OSM, id, номер части)`, тип: узел 0 < путь 1 < отношение 2; дома — по Мортону (O3.BUILDINGS), затем id.
Тайлу принадлежат: линии — клипованные по прямоугольнику тайла части; полигоны и точки — по тайлу центроида
(центроид в градусах), без клипа (координаты могут выходить за `[0, W]×[0, H]`).

**Линия** (после клипа): проекция O1 → упрощение Дугласа — Пекера ε = 1,0 м → округление → удалить подряд
идущие повторы → оставить, если ≥ 2 точек. Длины для O6 — по итоговым точкам.

**Числа из тегов** `num(s)`: первое слово, `,` → `.`, без хвоста `m`; не число → нет.

### ROADS, TRACK — дороги
Отбор: путь с `highway`. ROADS — классы (код): `motorway` 0, `trunk` 1, `primary` 2, `secondary` 3,
`tertiary` 4, `motorway_link` 5, `trunk_link` 6, `primary_link` 7, `secondary_link` 8, `tertiary_link` 9,
`unclassified` 10, `residential` 11, `living_street` 12, `road` 13. TRACK — `highway=track`, класс =
`tracktype` (`grade1..5` → 1..5, иначе 0) (отличие от эталона: там класс один). Остальное (`service`, `path`,
`footway`, …) не берётся.
Объект: `varint класс`; `байт флаги` (бит 0 — есть ширина, бит 1 — есть полосы, бит 3 — тоннель
`tunnel ∈ {yes, building_passage, culvert}`, бит 4 — мост `bridge` есть и не `no`); если бит 0 —
`varint round(width·10)` (дм); если бит 1 — `varint int(lanes)`; `varint число_точек`; точки.

### BUILDINGS — дома-прямоугольники
Отбор: `building=*` кроме `no`; путь-полигон или мультиполигон-отношение (каждый полигон — свой дом с id
отношения); площадь полигона (м², O1, с дырами) ≥ **50**; меньше 1 м² — брак. Минимальный по площади
ориентированный прямоугольник (вращающиеся калиперы, как GEOS `minimum_rotated_rectangle`).
Порядок: `morton(min(max(x,0)>>6, 1023), min(max(y,0)>>6, 1023))` (10 бит, x — чётные биты), затем id.
Объект: `zz(x − rx)`, `zz(y − ry)` (центр прямоугольника, м; `rx, ry` переносятся), `varint w2` (короткая
сторона, 0,5 м: `round(2w)`), `varint l2` (длинная, 0,5 м), `varint угол` (направление длинной стороны,
градусы от оси +x (восток) против часовой, `round(...) mod 180`), `varint hq·2 + lv` (`hq = round(2·высота)`,
высота — `num(height)`, иначе `num(building:levels)·3`, иначе 0; `lv = 1`, если из этажей), `varint тип`.
Типы: `yes` 0, `house` 1, `apartments` 2, `residential` 3, `commercial` 4, `industrial` 5, `retail` 6,
`garage` 7, `garages` 8, `shed` 9, `detached` 10, `terrace` 11, `church` 12, `school` 13, `roof` 14,
`office` 15, `hotel` 16, `warehouse` 17, `farm` 18, `barn` 19, `hut` 20, `cabin` 21, `service` 22,
`public` 23, `civic` 24, `construction` 25, прочее 26.

### Потоки объектов для пилота — общая запись
`varint класс`; `байт флаги`; `varint h`; `varint число_точек`; точки (точка — 1, линия — ≥ 2, кольцо — ≥ 3,
замыкание неявное). Отбор и приоритет — как эталон `build_pilot20.py` (узел: `power=tower` → ветряк →
вершина → седловина/перевал → `man_made` → аэродром-точка; первый подходящий).
| Поток | Отбор | Класс | Флаги | h |
|---|---|---|---|---|
| POWERLINE | путь `power=line\|minor_line` | line 0, minor_line 1 | бит 0 — minor | 0 |
| POWER_TOWER | узел `power=tower` | 0 | 0 | 0 |
| AERIALWAY | путь `aerialway=*` кроме `pylon`, `station` | cable_car 0, gondola 1, chair_lift 2, mixed_lift 3, drag_lift 4, t-bar 5, j-bar 6, platter 7, rope_tow 8, magic_carpet 9, zip_line 10, goods 11, прочее 12 | 0 | 0 |
| AEROWAY | узел `aeroway=aerodrome\|airstrip\|helipad` (точка); путь `aeroway=runway` (линия); площадь (замкнутый путь / мультиполигон) `aerodrome\|airstrip\|helipad` (внешнее кольцо, упрощение 1 м, тайл центроида) | точка: aerodrome 0, airstrip 1, helipad 2; runway 3; кольцо: aerodrome 4, airstrip 5, helipad 6 | 0 | 0 |
| VERTICAL | узел `man_made=mast\|tower\|chimney`; `power=generator` + `generator:source=wind` | mast 0, tower 1, chimney 2, wind 3 | бит 0 — `tower:type=communication` (отличие: в эталоне отдельный поток comm) | `round(num(height))`, нет — 0 |
| RAIL | путь `railway=rail\|narrow_gauge` | rail 0, narrow_gauge 1 | биты 3/4 — тоннель/мост, как у дорог | 0 |
| PEAK | узел `natural=peak` | 0 | бит 0 — есть `name` (в NAMES) | `max(0, round(num(ele)))` |
| PASS | узел `natural=saddle` или `mountain_pass=yes` | saddle 0, mountain_pass 1 | бит 0 — есть `name` | как у PEAK |
| RIVER | путь `waterway=river` | 0 | бит 0 — есть `name` | 0 |
| CANAL | путь `waterway=canal` | 0 | бит 0 — есть `name` | 0 |
(Флаги и классы — отличие от эталона только в значениях, байты те же.)

### NAMES — имена вершин и перевалов
Тег `name` (без переводов). Порядок: имена объектов PEAK с битом 0 в порядке потока, затем PASS с битом 0.
Запись: `varint длина`, UTF-8. `count` = число имён (= числу объектов с битом 0).

## O4. Фрагменты и склейка регионов — версия 1
Владелец: OT-2 (`pack`, `finalize`). Потребители: оркестратор.

Регион обрабатывается независимо; тайл получает данные от всех регионов, чей `.poly` (Geofabrik, с буфером)
пересекает прямоугольник тайла: `S(t)`. Каждый объект, лежащий в тайле, лежит в полигоне какого-то региона —
этот регион входит в `S(t)` (тайлы, которые не пересекают полигон региона, `pack` не пишет: так протянутые
«полные пути» соседа не создают лишних тайлов). Морские объекты вне всех полигонов теряются (принято).
- **Фрагмент** — файл O2 с флагом «фрагмент», zstd 3, `sources = [region]`, у каждого потока заполнено `ids`:
  `count` записей `zz(key − prev_key)`, `key = id·4 + тип` (узел 0, путь 1, отношение 2), `prev_key = 0` в начале
  потока; у NAMES `ids` — ключи их вершин/перевалов. Объект с несколькими частями (клип, мультиполигон) — одна
  запись `ids` на часть с одинаковым ключом.
- **Склейка** (`finalize`) тайла из фрагментов регионов `S(t)` (отсутствующий файл = регион без данных здесь):
  объекты группируются по `(поток, key)`; если ключ есть в нескольких фрагментах — берётся группа с
  наибольшим числом точек, при равенстве — из региона с меньшим id по алфавиту; затем сортировка O3,
  кодирование, `ids` пусто, `sources` — регионы с данными (части нарезки O8 v2 `<id>__p<n>` пишутся как `<id>`, без повторов). Один фрагмент — та же процедура (снимает `ids`).
- Итог — чистая функция фрагментов: те же входы → побайтно тот же файл (zstd 19 однопоточно на тайл).

## O5. CLI упаковщика `osmtiles` — версия 1
Владелец: OT-1 (`dump`, `stats`, `cover`, `manifest`), OT-2 (`pack`, `finalize`). Потребители: оркестратор,
сверка, пользователь. Код выхода: 0 — успех, 1 — ошибка (сообщение в stderr), 2 — неверные аргументы.
`--threads N` у всех тяжёлых команд: по умолчанию — все логические ядра (`rayon`); прогресс — строками в stderr.
- `osmtiles pack --input <pbf> --region <id> [--poly <file.poly>] --frag-dir <dir> [--tmp <dir>]
  [--threads N] [--report <file.json>]` — фрагменты O4 для тайлов с данными (и, если дан `--poly`,
  пересекающих полигон). Внутри может вызывать `osmium` (фильтр тегов, координаты узлов); временные файлы —
  в `--tmp` (по умолчанию рядом с `--frag-dir`), удаляются в конце. В конце атомарно (tmp + rename) —
  `<frag-dir>/<region>.pack.json`: `{region, input, input_bytes, osm_timestamp, tiles: [[j, i, objects], …],
  seconds: {стадия: с}, seconds_total, peak_rss_mb, cpu_cores_avg: {стадия: среднее число занятых ядер}}`.
  Повторный запуск перезаписывает (идемпотентно).
- `osmtiles finalize --frag-dir <dir> --out <корень> --list <file> [--threads N] [--report <file.jsonl>]` —
  строки `--list`: `j i region1 [region2 …]`; на каждый тайл — O4, запись `<корень>/v1/<j>/<i>.dpt` атомарно;
  нет объектов — файла нет (существующий удаляется). Фрагменты не удаляет. `--report` — строка на тайл
  `{j, i, bytes, sha256, objects}` (`bytes = 0` — пустой).
- `osmtiles cover --poly <file.poly>` — в stdout `j i` тайлов, пересекающих полигон (формат `.poly` Osmosis:
  кольца, `!` — дыра).
- `osmtiles stats --tiles <корень> [--zstd-per-stream] [--only <file со строками "j i">]` — JSON O6 в stdout.
- `osmtiles dump <file>` — разбор файла O2 в JSON (`header`, поля OsmTile, у потоков — объекты O3 в виде
  словарей) — отладка и тесты.
  Вид (уточнение v1 по OT-1, до потребителей; канонический — его сверяют декодеры Python и GDScript с
  `sample_v1.json`): поток `{kind, count, objects, ids}`; координаты абсолютные (дельты раскрыты), `pts` —
  `[[x, y], …]`; дороги/track — `{cls, width_dm|null, lanes|null, tunnel, bridge, pts}`; дома — `{x, y, w2, l2,
  angle, hq, lv, type}`; остальные потоки — `{cls, flags, h, pts}`; `names` — список строк. Ключи — по алфавиту.
- `osmtiles manifest --tiles <корень> --sources <sources.json> --out <файл.pb>` — O7.

## O6. Сводка `stats` — версия 1
Владелец: OT-1. Потребитель: сверка с эталоном (OT-3), отчёты.
```json
{"schema": "osmtiles-stats/1", "n_tiles": 80, "file_bytes_total": 12345,
 "tiles": {"240,1038": {"file_bytes": 829000,
           "streams": {"roads": {"count": 1, "raw": 2, "zstd": 3, "len_km": 4.5}, "...": {}}}},
 "totals": {"roads": {"count": 0, "raw": 0, "zstd": 0, "len_km": 0.0}}}
```
Имена потоков — `Kind` строчными: `roads, track, buildings, powerline, power_tower, aerialway, aeroway,
vertical, rail, peak, pass, names, river, canal`. `raw` — длина `data`; `zstd` — `data`, сжатое отдельно zstd 19
(только с `--zstd-per-stream`, иначе нет поля); `len_km` — у линейных потоков (roads, track, powerline,
aerialway, rail, river, canal; у aeroway — только runway).
Соответствие эталону (`tools/research/osm_pack/results/`): roads/track ← `tiles20_*.json` `streams_raw|zstd`,
`n_road_parts`, `len_km` (эталон — длина до упрощения); buildings ← `brect_ge50`, `n_ge["50"]`; потоки для
пилота ← `pilot20_slovenia.json` `count|zstd` (`power_tower` ← `tower`, `names` ← `names`).

## O7. Манифест — версия 1
Владелец: OT-1. Потребители: заливка в R2 (вне модуля), оркестратор. `<корень>/v1/manifest.pb`, protobuf
(в том же `.proto`):
```proto
message TileManifest {
  uint32 format_version = 1;     // = 1
  int64 created_unix = 2;
  repeated Source sources = 3;   // по id
  repeated TileEntry tiles = 4;  // по (j, i)
  uint64 total_bytes = 5;
}
message Source { string region = 1; string url = 2; string md5 = 3; int64 osm_timestamp = 4; uint64 pbf_bytes = 5; }
message TileEntry { sint32 j = 1; uint32 i = 2; uint32 bytes = 3; bytes sha256 = 4; }  // sha256 файла .dpt, 32 Б
```
`sources.json` — список объектов с теми же полями. Манифест строится по файлам на диске (истина — файлы).

## O8. Оркестратор `world.py` и регионы — версия 2
v2 (10.10, по замеру OT-2: пик памяти `pack` до 5,2× размера `.pbf` → canada 6,5 ГБ ≈ 34 ГБ > 31 ГБ ОЗУ):
регион с `.pbf` > `--max-region-gb` перед `pack` режется одним проходом `osmium extract --strategy smart -c
<config>` на `k = ceil(размер / лимит)` частей — прямоугольники по долготе (границы — по долготе, общие для
всех поясов, иначе части не покрывают регион), высота — bbox `.poly` региона; часть — регион
`<id>__p<n>` (`.poly` = прямоугольник, `cover` части = cover(прямоугольник) ∩ cover(регион)), исходная выгрузка
удаляется после разрезки, дальше — как обычный регион (склейка O4 снимает дубли путей на швах).
Потребители: OT-6 (реализация), OT-12.
Владелец: OT-5 (`regions.py`), OT-6 (`world.py`). Потребитель — пользователь.
- `python3 tools/osm_tiles/world.py run --work <dir> --out <корень> [--regions id1,id2 | --all]
  [--max-region-gb 2.0] [--keep-free-gb 20] [--threads N]`; `… status --work <dir>`; `… plan --work <dir>
  [--max-region-gb]` (только набор регионов и покрытие). Повторный `run` с тем же `--work` продолжает.
- **Набор регионов** (`regions.py`, файл `<work>/regions.json`, замораживается при первом `plan`):
  из `https://download.geofabrik.de/index-v1.json` — дерево по `parent`; узел берётся целиком, если его
  `.osm.pbf` ≤ `--max-region-gb` или у него нет детей; иначе — его дети, если они покрывают узел (площадь
  объединения детей ≥ 99 % площади узла по `.poly`), иначе узел целиком с предупреждением. Сборные регионы,
  пересекающие другие ветви (`dach`, `alps`, `britain-and-ireland`, `us` и т. п.), не берутся. Запись:
  `{id, parent, url, poly_url, md5_url, pbf_bytes (HEAD), tiles: число тайлов cover}`.
  Уточнения по OT-5 (v1, до потребителей): `id` — id Geofabrik с `/` → `_` (`us_alabama`), исходный — `index_id`;
  корни-континенты целиком не берутся; узел, больше чем на 40 % лежащий в другом выбранном, убирается;
  пустой `.poly` Geofabrik заменяется геометрией индекса; в `regions.json` ещё `oversize_exceptions` (регионы
  > лимита, неделимые — canada 6,5 ГБ, france 5,1 ГБ, japan, united-kingdom, italy, brazil), `composites`,
  `overlaps_listed` (пары соседей, чьи `.poly` перекрываются > 1 % — допустимо: склейка O4 убирает дубли);
  пересчёт покрытия без перекачки — `regions.py plan --work … --osmtiles … --recompute-cover`.
- **Покрытие:** `<work>/cover/<id>.txt` = `osmtiles cover`; `S(t)` — из всех файлов cover.
- **Состояние** `<work>/state.json` (замена tmp + rename после каждого перехода):
  `{"schema": "osmtiles-state/1", "out": "...", "regions": {"<id>": {"status": "planned|downloading|downloaded|packing|packed|done|failed",
  "bytes_done": 0, "etag": "", "md5": "", "attempts": 0, "error": ""}}}`; готовые тайлы — дописываемый
  `<work>/finalized.jsonl` (строка `{j, i, bytes, sha256}`); журнал — `<work>/log.jsonl`
  (`{t, event, region?, …}`). После `done` выгрузка и фрагменты региона удалены.
- **Шаги:** скачать (`Range` + `If-Range` по ETag, докачка; проверка md5 из `<url>.md5`, 3 попытки) →
  `pack` → тайлы, у которых все регионы `S(t)` в `packed|done`, — `finalize` пачками → дописать
  `finalized.jsonl` → удалить фрагменты этих тайлов → регион `done`. Выгрузка удаляется сразу после `pack`
  (статус `packed`; уточнение по OT-6). Следующий регион
  качается, пока пакуется текущий (свободное место ≥ размер выгрузки × 3 + `--keep-free-gb`, иначе ждать).
  Регион в `packing` при перезапуске пакуется заново. С `--regions` тайлы со соседями вне списка
  склеиваются из имеющихся (в журнал — `partial`). В конце — `manifest`.
- **Прогресс** (stdout, одна строка с `\r`): `регион 37/412 germany-bayern · скачано 12,3/80,1 ГБ ·
  упаковано 36 · тайлов 51 234 (1,42 ГБ) · ETA 3 ч 12 мин`; Ctrl-C — выход, состояние на диске.

## O9. Клиент в игре — версия 1
Владелец: OT-8 (загрузка, разбор, `OsmData`). Потребители: OT-9 (дороги, реки/каналы, ж/д, просеки, палатки),
OT-10 (вершины/перевалы с подписями, ЛЭП, мачты, канатки, аэродромы), OT-11 (дома). Основа — удалённый клиент
(коммиты e8fe4ba4, 4493cfec, 9c810727: `OsmData`, `OsmLayer`, `RoadMesher`, `PowerLinePlanner`, стыки в
`WorldObjects`, `WorldClearings`, палатки); Overpass, заборы, поля, landuse, имена посёлков — не возвращаются.

**Конфиг** `configs/osm_tiles.json`: `{"base_url": "<URL корня без /v1>", "timeout_s": 5.0, "enabled": true,
"max_parallel": 9, "height_rule": {…}}`. URL тайла — `<base_url>/v1/<j>/<i>.dpt` (O2). Пока R2 нет —
`base_url` пустой → стадия сразу `missing` без сети. Переопределение без правки конфига — переменная окружения
`DELTAPLAN_OSM_TILES_URL`. `base_url` (или переменная) может быть локальным каталогом (абсолютный путь или
`file://…`): тайлы читаются оттуда напрямую (нет файла = 404), без HTTP — для тестовой сборки.

**Стадия сборки места** `OsmTilesStage` (`scripts/terrain/build/osm_tiles_stage.gd`, интерфейс OA-К3, последняя
стадия): `neighbors(center_lat, center_lon)` (O1) → недостающих в кеше тайлов — параллельные запросы (`HttpLog`,
до `max_parallel`), общее ожидание ≤ `timeout_s`; 200 → `user://osm_tiles/v1/<j>/<i>.dpt` (атомарно), 404 →
метка `<i>.none` (пустой тайл); каждый запрос — `ctx.net_requests += 1`. Пишет в папку места
`osm_tiles.json`: `{"tiles": [[j, i, "ok"|"none"|"missing"], …]}`. Хоть один `missing` (таймаут, сеть, 5xx,
битый файл) → стадия возвращает `ERR_UNAVAILABLE` → место `missing: ["osm_tiles"]` (OA-К4), следующий
запуск догружает только её. `ctx.offline` → только кеш. Кеш общий для всех мест, тайл из кеша не
перекачивается (новые данные — новая версия `v2`). Тесты — только с временным `XDG_DATA_HOME`; HTTP — через
подстановку `http_hook` (как `RasterTileLoader`) или локальный сервер в тесте.

**Разбор** `OsmTileReader` (`scripts/world_objects/osm/osm_tile_reader.gd`): `static func read(bytes:
PackedByteArray) -> Dictionary` — проверка заголовка O2, `bytes.decompress(raw_len, FileAccess.COMPRESSION_ZSTD)`,
protobuf вручную (varint, поля по номерам), потоки O3 → словарь `{j, i, n, streams: {"roads": [...], …}}` в
координатах тайла. Ошибка формата — пустой словарь + строка в лог. Вызывается не в главном потоке.

**`OsmData`** (`scripts/world_objects/osm_data.gd`, восстановлен): `static func from_tiles(tile_dicts: Array,
center_lat: float, center_lon: float, half_m: float) -> OsmData` и `static func load_for(place_dir: String,
center_lat, center_lon, half_m) -> OsmData` (читает `osm_tiles.json` и кеш; нет тайлов — пустой `OsmData`, не
null). Перевод: тайл (x, y) → (lat, lon) по O1 → `TerrainGeo.latlon_to_local` (x — восток, z — юг, м места);
объекты вне `±half_m` (с запасом 200 м) отбрасываются, линии — клипуются. Угол дома: из O3 (от востока против
часовой, север вверх) в соглашение `BuildingPlacer` — так же, как переводил прежний `OsmStage`
(`git show e8fe4ba4^:scripts/terrain/build/osm_stage.gd`). Поля (м места):
- `roads: Array` — `{t: String (highway-класс OSM; track → "track"), p: PackedVector2Array, w: float (м, 0 —
  нет), lanes: int, tunnel: bool, bridge: bool, grade: int (у track)}` — `t` совпадает с ключами
  `world_objects.json → roads.classes` старого `RoadMesher`;
- `rivers: Array` — `{t: "river"|"canal", named: bool, p}`; `rail: Array` — `{t, tunnel, bridge, p}`;
- `buildings: Array` — `[x, z, w, l, угол_град, высота_стен_м, крыша 0|1]` (формат `BuildingPlacer`), высота
  и крыша — по `height_rule` ниже;
- `power: Array` — `{minor: bool, p}`; `towers: PackedVector2Array`; `aerialways: Array` — `{t: String, p}`;
  `aeroways: Array` — `{t: String, kind: "point"|"line"|"area", p}`; `verticals: Array` — `{t: "mast"|"tower"|
  "chimney"|"wind", comm: bool, x, z, h}`;
- `peaks: Array`, `passes: Array` — `{x, z, ele: float (NAN — нет), name: String ("" — нет)}`;
- `attribution: String` = `"© OpenStreetMap contributors"`, если есть хоть один объект, иначе `""`; `tiles_ok: int`,
  `tiles_missing: int`, `load_time_s: float`.

**Высота дома** (одно правило, параметры — `configs/osm_tiles.json → height_rule`, этаж 3 м): есть `height` →
она; есть этажи → этажи × 3; иначе по типу O3 и площади следа `A = w·l` (м²):
| Группа типов | Этажей | Крыша |
|---|---|---|
| `shed, garage, garages, hut, cabin, roof, service, construction` | 1 | 0 (двускатная) |
| `house, detached, terrace, farm, barn` | 2 | 0 |
| `industrial, warehouse` | высота 8 м | 1 (плоская) |
| `apartments, residential, hotel, office` | A < 300 → 3; < 800 → 5; < 2000 → 9; иначе 12 | 1 |
| `commercial, retail, public, civic, school, church` и прочее (26) | A < 600 → 2; иначе 3 | 1 |
| `yes` | A < 200 → 2 (крыша 0); < 600 → 4; < 2000 → 9; иначе 3 (большой низкий — склад/центр) | 1 |
(Высота стен = этажи × 3 м; крыша из правила, если нет своей. Правило не подбирается по картинке.)

**Дома OSM и процедурные:** пятно застройки (`BuiltPatches`), в котором есть хоть один дом OSM (центр
прямоугольника внутри пятна), процедурных домов не получает; остальные пятна — как сейчас (`VillagePlacer`).
Дома OSM вне пятен ставятся всегда. Препятствия — `BuildingPlacer` → `building_obstacles`, как раньше.

**Подписи вершин и перевалов:** тот же `Label3D`, что подпись бота (`BotGlider._build_name_tag` /
`_update_name_tag`, `configs/bots.json → names`) — вынести создание и обновление в общий помощник и вызывать из
обоих мест, новый стиль не делать. Текст: `"<имя> <ele> м"` (`ele` округлённая, если есть), без имени — подписи нет.

**Совместимость кадра zstd:** итоговый тайл — один кадр без словаря, уровень 19, с контрольной суммой; окно при
известном размере ≤ 2^23 ≤ `compression/formats/zstd/window_log_size` Godot (27). Проверка — контрактный тест
игры читает `sample_v1.dpt` и сверяет с `sample_v1.json`.
