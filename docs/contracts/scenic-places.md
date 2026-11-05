---
type: "contract"
status: "active"
module: "scenic-places"
area: "game"
updated: "2026-11-05"
summary: "Красивые места: формат списка и каталога мест (SCP-К1), проверка места по рельефу (SCP-К2), окно и выбор в «Полёт…» (SCP-К3)."
related: ["docs/plan/scenic-places.md", "docs/contracts/popular-places.md"]
contracts: [{"id": "SCP-К1", "version": 1}, {"id": "SCP-К2", "version": 1}, {"id": "SCP-К3", "version": 1}]
---
# Контракты модуля scenic-places

План — `docs/plan/scenic-places.md`. Менять — только координатор (версия +1, что изменилось, уведомить потребителей).
Контрактный тест формата — `python3 tools/places/test_scenic_places_contract.py` (без сети и Godot; проверяет
тестовый файл, все файлы `tools/places/scenic/*.json` и каталог `data/places/scenic_places.json`, если они есть).

## SCP-К1. Файл мест (v1)
Владельцы: SCP-1…3 (списки по регионам `tools/places/scenic/<регион>.json`), сборка каталога
(`res://data/places/scenic_places.json`, путь — `configs/ui.json → scenic_places_path`; появляется только после
утверждения списка пользователем, шлюз плана). Тестовый — `res://tests/ui/fixtures/scenic_places_test.json`
(в сборку не входит). Потребители: проверка SCP-К2, `ScenicPlaces` (SCP-К3), контрактный тест.
- UTF-8 JSON, объект: `{"format": "deltaplan.scenic_places", "version": 1, "countries": {<код>: {"en": String, "ru": String}}, "places": [<место>…]}`.
- Место: `{"id", "country", "name_en", "name_ru", "kind", "lat", "lon", "heading_deg", "agl_m", "view_lat", "view_lon", "why_en", "why_ru"}`, других полей нет:
  - `id` — `^[a-z]{2}/[a-z0-9-]+$` (код страны строчными / латиница через дефис), уникален во всех файлах;
  - `country` — ISO 3166-1 alpha-2 заглавными, ключ есть в `countries`; в `countries` нет лишних кодов;
  - `name_en`, `name_ru` — непустые, ≤ 60 символов; общепринятое название места (Википедия);
  - `kind` — одно из `mountain canyon lake coast volcano glacier valley fjord desert island`;
  - `lat` ∈ [−90, 90], `lon` ∈ [−180, 180] — WGS84, **точка старта в воздухе** (она же центр загружаемого
    места: детальный рельеф 40 км вокруг неё, фон 160 км);
  - `heading_deg` ∈ [0, 360) — курс полёта на вид, градусы от севера по часовой (как
    `FlightSettings.start_heading_deg`);
  - `agl_m` ∈ [50, 2000] — высота старта над рельефом в точке старта, м;
  - `view_lat`, `view_lon` — что показываем (вершина, середина озера, устье каньона); от точки старта ≤ 15 км,
    пеленг на неё отличается от `heading_deg` не больше чем на 30°;
  - `why_en`, `why_ru` — непустые, ≤ 140 символов: чем место красиво в игре (рельеф, вода, снег, лес).
- Только природные пейзажи (решение 2026-11-05): предмет вида — рельеф и вода, не здания, не города, не
  культовые сооружения; водопады и прочее мельче 25 м (шаг детального рельефа) — не предмет.
- По стране — 5–10 мест (в каталоге и в сумме по файлам регионов; тестовый файл — без этого правила).
- Инварианты: `places` непустой; файл детерминирован (места по `id`, ключи `countries` по алфавиту, отступ 1,
  `ensure_ascii=False`); запись — во временный файл и переименование.

## SCP-К2. Проверка места по рельефу (v1)
Владелец: SCP-1 (`tools/places/check_scenic_places.py`). Потребители: SCP-2, SCP-3, приёмка, таблица для пользователя.
- `python3 tools/places/check_scenic_places.py <файл>… [--table <out.md>]` — для каждого места формат SCP-К1 и
  рельеф по Terrarium (`https://s3.amazonaws.com/elevation-tiles-prod/terrarium/{z}/{x}/{y}.png`, z11, кэш
  `~/.cache/dp-places/terrarium/`, в репозиторий не идёт; высота = R·256 + G + B/256 − 32768, м).
- Проверки места (порог — провал):
  1. данные есть: тайлы у старта и вида скачались, высоты конечны;
  2. вид внутри места: расстояние старт→вид ≤ 15 км, |пеленг − `heading_deg`| ≤ 30°;
  3. запас высоты на прямой по курсу: для d = 0…5000 м шагом 100 м
     `h0 + agl_m − d/10 ≥ ground(d) + 50` (h0 — рельеф в точке старта; качество 10 — с запасом к штилю);
  4. рельеф даёт вид: max − min рельефа в радиусе 5 км вокруг вида ≥ 100 м;
  5. по стране 5–10 мест; `id` уникальны во всех файлах.
- Вывод: строка на место `<id> OK|FAIL <причины>` с числами (h0, max ground на пути, перепад у вида, расстояние,
  пеленг), итог последней строкой `checked <N>, failed <M>`; код выхода 0 только при `failed 0`.
- `--table` — таблица Markdown для пользователя: страна, название RU, тип, чем красиво (RU), координаты старта,
  курс, высота, ссылка на карту (`https://www.openstreetmap.org/?mlat=<lat>&mlon=<lon>#map=12/<lat>/<lon>`).

## SCP-К3. Окно «Красивые места» и выбор (v1)
Владелец: SCP-4. Потребители: `scripts/ui/place_pick_row.gd`, тесты `tests/ui/test_scenic_places.gd`,
контрактный тест `tests/contracts/test_scenic_places_contracts.gd` (фильтр `scenic_places`).
- `ScenicPlaces` (`scripts/ui/scenic_places.gd`, `class_name ScenicPlaces`, `RefCounted`, только static):
  `load_catalog(path) -> Dictionary` (`{"countries": {}, "places": []}` + `push_warning` при отсутствии или
  неверном формате, без падения); `group_by_country(catalog, lang) -> Array` (`[{"code","name","count","places"}]`,
  страны по алфавиту названия на языке `lang`, места — по названию); `name(p, lang)`, `why(p, lang)` — поле
  `_ru`/`_en` по языку (`PopularPlaces.lang()`).
- Окно `ScenicPlacesWindow` (`scripts/ui/scenic_places_window.gd`): `open(catalog)`; сигналы `place_chosen(place)`
  (словарь места SCP-К1, окно закрывается) и `closed`. Уровни: страны («<страна> — <n>») → места страны (название,
  тип, чем красиво); «Назад», «Отмена»; списки в `ScrollContainer`; окно целиком в экране при 1280×720,
  1920×1080, 2560×1440, 640×800 (как PP-К2).
- `PlacePickRow`: кнопка `tr("setup_scenic_places")` сразу после «Популярные места»; каталог пуст или файла нет —
  кнопка скрыта. Выбор места: `settings.pick_lat/pick_lon = lat/lon`, `settings.set_exact_start(lat, lon, heading_deg)`,
  `picked_place_name = name` на языке интерфейса (идёт в «Недавние места»); выбор другим способом (карта,
  «Популярные», «Недавние») — снимает выбор красивого места.
- Старт в воздухе над видом (`agl_m`, без разбега, курс `heading_deg`) — через постановку старта модуля
  air-start-menu; стык добавится версией 2 после контракта air-start-menu. В v1 выбор ставит только точку и курс.
- Тексты — ключи `locale/ui.csv` (ru, en). Окно «Популярные места» (PP-К2) не меняется.

## История
- v1 (2026-11-05) — первая версия.
