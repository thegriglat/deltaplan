---
type: "contract"
status: "active"
module: "popular-places"
updated: "2026-10-11"
summary: "Контракты модуля popular-places: файл каталога стартов дельтаплана в игре (PP-К1) и интерфейс данных/окна «Популярные места» в меню полёта (PP-К2)."
related: ["docs/plan/popular-places.md"]
contracts: [{"id": "PP-К1", "version": 3}, {"id": "PP-К2", "version": 1}]
---
# Контракты модуля popular-places

План — `docs/plan/popular-places.md`. Менять — только через координатора (версия +1, что изменилось, уведомить
потребителей). Контрактный тест — `tests/contracts/test_popular_places_contracts.gd` (без сети и GPU; фильтр
`popular_places`).

## PP-К1. Файл каталога стартов (v3)
Владелец: PP-2 (настоящий файл), PP-1 (тестовый). Потребители: `PopularPlaces` (PP-К2), контрактный тест.
- Настоящий каталог — `res://data/places/hg_takeoffs.json` (путь — `configs/ui.json` → `popular_places_path`).
  Файла нет — каталог пуст, кнопка «Популярные места» скрыта. Тестовый — `res://tests/ui/fixtures/hg_takeoffs_test.json`
  (в сборку не входит: `tests/*` исключены из экспорта). **Тестовых мест в `data/` нет.**
- UTF-8 JSON, объект:
  `{"format": "deltaplan.hg_takeoffs", "version": 1, "source": String (откуда и лицензия, напр. «© OpenStreetMap contributors, ODbL 1.0»), "fetch_date_utc": String (дата выгрузки OSM), "countries": {<код>: {"en": String, "ru": String}}, "takeoffs": [<старт>…]}`.
- Старт: `{"id": String, "name": String, "lat": float, "lon": float, "country": String, "ele": float|null, "orientation": [String…]}`:
  - `id` — `^(node|way|relation)/\d+$` (объект OSM), `builtin/<место>/<старт>` (встроенное место игры) или `manual/<место>/<старт>` (v3: старт, которого нет в
    OSM, — вписан вручную в `tools/places/manual_takeoffs.json`, поля как у старта OSM), уникален;
  - `name` — как в OSM (`name`), может быть пустым `""` (тогда в окне — запасная подпись с координатами);
  - `lat` ∈ [−90, 90], `lon` ∈ [−180, 180] — градусы WGS84, точка старта;
  - `country` — ISO 3166-1 alpha-2 заглавными (`^[A-Z]{2}$`), ключ есть в `countries`; `""` — страна неизвестна
    (море, спорные территории) — в окне отдельная группа в конце;
  - `ele` — м над уровнем моря из OSM (`ele`), ∈ [−500, 9000], `null` — нет данных;
  - `orientation` — при каком ветре работает старт: направления из
    `N NNE NE ENE E ESE SE SSE S SSW SW WSW W WNW NW NNW` (заглавные, без повторов, порядок как в OSM);
    `[]` — нет данных. Разбор сырых `free_flying:site_orientation`/`direction` (`"N;NE"`, `"SW-W"`, градусы) — в
    конвертере PP-2, нераспознанное отбрасывается.
- Встроенное место (v2, 10.10.2026; `tools/places/add_builtin_places.py` берёт старты из `configs/locations/*.json`) —
  старт с тремя доп. полями: `location` (id встроенного места), `site` (id его старта), `heading_deg` (направление
  разбега, как в конфиге места); `orientation` — один румб, ближайший к `heading_deg`. Выбор такого места в меню
  ставит `settings.location_id/site_id` и снимает точку (`pick_*`) — грузится встроенное место с точным стартом.
- `countries[код]` — названия страны: `en` и `ru` непустые (из OSM `name:en`/`name:ru` границ admin_level=2);
  в `countries` нет кодов, которых нет у стартов.
- Инварианты: `takeoffs` непустой; файл детерминирован (один вход → те же байты); порядок стартов в файле не важен (сортирует `PopularPlaces`).

## PP-К2. Данные и окно «Популярные места» (v1)
Владелец: PP-1. Потребители: `scripts/ui/flight_setup_screen.gd`, тесты `tests/ui/test_popular_places.gd`,
контрактный тест, кадр скриншота.
- `PopularPlaces` (`scripts/ui/popular_places.gd`, `class_name PopularPlaces`, `RefCounted`, только static):
  - `load_catalog(path: String) -> Dictionary` → `{"countries": Dictionary, "takeoffs": Array}`; нет файла или
    неверный формат — `{"countries": {}, "takeoffs": []}` + `push_warning`, без падения;
  - `lang() -> String` — `"ru"`, если язык интерфейса русский (`TranslationServer.get_locale()` начинается с `ru`),
    иначе `"en"`;
  - `country_name(catalog: Dictionary, code: String, lang: String) -> String` — `countries[code][lang]` → `en` →
    сам код; `code == ""` → `tr("places_country_unknown")`;
  - `group_by_country(catalog: Dictionary, lang: String) -> Array` → `[{"code": String, "name": String, "count": int, "places": Array}]`:
    страны по алфавиту названия на языке `lang` (без учёта регистра), группа `""` — последней; места внутри —
    по алфавиту `display_name`; сумма `count` = числу стартов;
  - `search(places: Array, query: String) -> Array` — подстрока в `display_name` без учёта регистра, `ё` = `е`,
    пробелы по краям запроса не считаются; пустой запрос — все места в том же порядке; порядок результатов —
    как во входе;
  - `display_name(p: Dictionary) -> String` — `name`, а при пустом — `tr("places_unnamed") % [lat, lon]`;
  - `orientation_text(p: Dictionary) -> String` — направления на языке интерфейса через запятую (ключи перевода
    `compass_*`; для 16 румбов — свои ключи), `[]` → `""`.
- `PopularPlacesWindow` (`scripts/ui/popular_places_window.gd`, `Control`): `open(catalog: Dictionary)`; сигналы
  `place_chosen(place: Dictionary)` (словарь старта PP-К1, окно закрывается) и `closed` (отмена). Уровни: список
  стран («<страна> — <n>»); места страны (название, высота «<h> м» или «—», ориентация — если есть); поле поиска
  над списком: на уровне стран ищет по всем странам (в строке результата — страна), внутри страны — по этой стране;
  «Назад» к странам; «Отмена».
- `flight_setup_screen.gd`: кнопка `tr("setup_popular_places")` в ряду с `setup_pick_on_map`; свойство
  `popular_places_path: String` (по умолчанию из `configs/ui.json` → `popular_places_path`, тесты подставляют
  тестовый файл до `_ready`); каталог пуст — кнопка скрыта. Выбор места: `settings.pick_lat/pick_lon` = `lat/lon`
  старта, `_pick_elev_m = NAN`, `_update_pick_label()` — тот же путь, что точка с карты и «Недавние места»
  (загрузка — квадрат с центром в точке, `load_location_latlon`; game.gd не меняется). На «Готово» в «Недавние
  места» идёт название места (непустое `name`) вместо обратного геокодера; выбор другим способом это название
  сбрасывает.
- Инвариант экрана: прямоугольник окна целиком внутри видимой области при 1280×720, 1920×1080, 2560×1440 и
  640×800; списки — в `ScrollContainer` (прокрутка, а не рост окна); кнопки «Назад»/«Отмена» всегда видны.
- Тексты — ключи `locale/ui.csv` (ru, en), простым языком; подсказок о безопасности нет.

## История
- v3 (11.10.2026) — ручные старты `manual/…` (нет в OSM): `tools/places/manual_takeoffs.json`, добавляет `add_builtin_places.py`; первые — Юца (Пятигорск), южный и западный склоны.
- v2 (10.10.2026) — старты встроенных мест (Алтай, Онгудай, Аскарово, Аушкуль) в каталоге: id `builtin/…`, поля `location`, `site`, `heading_deg`; отдельный список «Старт» на экране убран.
- v1 (05.10.2026) — заведены до первого исполнителя.
