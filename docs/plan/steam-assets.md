---
type: "plan"
status: "active"
module: "steam-assets"
updated: "2026-10-05"
summary: "План модуля steam-assets: лицензии всего, что в сборке, под платную продажу в Steam; подложка карты без бесплатных серверов OSM/OpenTopoMap; атрибуции в игре и файлом рядом с exe; ассеты страницы Steam."
related: ["docs/contracts/steam-assets.md", "ASSETS.md", "docs/plan/offline_world_data.md", "docs/contracts/start-map.md"]
---
# План модуля steam-assets — ассеты и лицензии для Steam

Ветка `feature/steam-assets`, копия `~/deltaplan-steam-assets`. Журнал — `docs/plan/steam-assets/` (`dp status steam-assets`). Контракты — `docs/contracts/steam-assets.md` (SA-К1…SA-К4).

## Цель
Игра продаётся в Steam ($5), на itch — бесплатно, код открыт. Всё, что входит в сборку, должно разрешать коммерческое использование; обязательные атрибуции — в игре и файлом рядом с exe; страница Steam — готовые файлы (капсулы, иконки, скриншоты) к регистрации.

## Решения пользователя (не обсуждаются)
- 05.10: схема распространения — код открыт; itch бесплатно; Steam платно, $5. Всё в сборке — с коммерческим использованием.
- 05.10: настоящие названия крыльев и производителей оставляем (не переименовывать); абзац о торговых марках в «Об игре» — отдельная ветка `feature/about-trademarks`.
- 05.10: регистрации в Steamworks нет — всё для кабинета готовим файлами.
- 05.10: описание для Steam и посты продвижения — не в этом модуле (позже отдельно).
- 05.10: подложку карты не заменять, только соблюдать правила серверов (SA-2 → SA-8).
- 05.10: VC++ runtime — DLL из VC\\Redist по лицензии Visual Studio Community автора (Q1 = А, SA-9).
- 05.10: тексты — «проект с открытым кодом», без «некоммерческий» и без упоминания продажи/бесплатности.
- 05.10: скриншоты для Steam не делать (SA-5 снята) — позже вместе с описанием.
- **VC++ runtime: вариант А через msvc-wine (vsdownload.py --accept-license, лицензия VS Build Tools принята пользователем), скачивание вне репозитория, 4 DLL из VC/Redist/MSVC/<ver>/x64/Microsoft.VC14x.CRT** (2026-10-05) — решение пользователя 07:22, уточнение Q1

## Что найдено при разборе (координатор, 05.10)
- В ASSETS.md пометок ⚠ NC нет; правило «проект некоммерческий, NC допустимы» устарело → SA-3.
- `export_filter="all_resources"`: в `.pck` попадает **всё** в проекте, кроме `tests/ tools/ docs/ site/ data/terrain/reference/` и каталогов с `.gdignore` (+ `include_filter`: `data/**`, `*.onnx`, `configs/**` …). ASSETS.md может не покрывать всё — нужен инвентарь по файлам (SA-1).
- Рядом с exe — нативные библиотеки: `air_onnx` + ONNX Runtime 1.30.0 (MIT, к ней `ThirdPartyNotices`), 4 DLL VC++ runtime (Windows; условия распространения Microsoft), `libdd3d` (MIT), godot-cpp (MIT), сам Godot (MIT + `COPYRIGHT.txt` сторонних компонентов). В ASSETS.md раздела про движок и библиотеки нет.
- `data/air_nn/model.onnx` (12 МБ) — в сборке; происхождение обучающих данных в ASSETS.md не записано.
- Тексты «некоммерческий»: `locale/ui.csv` `about_intro` («Некоммерческий проект» / «A non-commercial project»), `configs/world.json` `map_picker.user_agent` («non-commercial open source»).
- Подложка карты: `configs/world.json → map_picker.basemaps` — `tile.openstreetmap.org` и OpenTopoMap (контракт start-map SM-К1 v2); инвариант пользователя — на карте видны названия населённых пунктов, `start_zoom ≥ 11`.
- В ASSETS.md строка OpenTopoMap содержала `\|` — ломала таблицу и экран «Об игре» (5 колонок); исправлено координатором (`·`), контрактный тест SA-К3 это ловит.
- Скачивание в игре Terrarium (AWS Open Data) и WorldCover (ESA, S3) — открытые данные с коммерческим использованием и атрибуцией; проверить в SA-1.

## Задачи

### SA-1. Аудит лицензий сборки и инвентарь (dp-researcher, Sonnet)
- Скоуп: `tools/release/build_inventory.py` по SA-К1 (эмуляция фильтров экспорта + одна сверка с настоящим `--export-pack`); `docs/research/steam_license_audit.md` (frontmatter research): по группам — что, лицензия, коммерческое использование, атрибуция, есть ли строка в ASSETS.md; выборочная проверка первоисточников (sounds/LICENSES.md, freesound-страницы CC-BY, MakeHuman/MPFB, ambientCG, Kenney, Copernicus DEM, Terrarium/Mapzen-список, WorldCover, ODbL, OFL, ONNX Runtime, VC++ runtime, debug_draw_3d, godot-cpp, Godot), **происхождение `model.onnx`** (на каких рельефах/данных обучена, чьи данные), сгенерированные звуки (чем сгенерированы, лицензия модели и её выходов), файлы в сборке без строки ASSETS.md, история ASSETS.md (удалённые строки NC — убраны ли файлы), тексты «некоммерческий» в игре/README/сайте. Итог — список правок: что, почему, в какую задачу (SA-3/SA-4/новая).
- Не трогать: ASSETS.md, код игры, `export_presets.cfg` (правки — предложить в отчёте).
- Приёмка: `dp docs check` чист; `python3 tools/release/build_inventory.py --preset all` → коды 0, JSON по SA-К1; в документе — таблица групп, решение по каждому `commercial_ok != true`, ответ про `model.onnx` и VC++ runtime.

### SA-2. Подложка карты: соответствие правилам серверов тайлов (dp-researcher, Sonnet)
- Решение пользователя 05.10: подложку (tile.openstreetmap.org, OpenTopoMap) **не заменять**; своя подложка из Terrarium + WorldCover — запасной вариант, не в работу.
- Скоуп: `docs/research/steam_tile_policy.md` — проверка кода игры по OSM Tile Usage Policy и условиям OpenTopoMap: честный User-Agent, видимая атрибуция, кэш на диске и срок, без массовой предзагрузки, лимит параллельных запросов, адрес сервера в конфиге; таблица «пункт правил → как в коде → соответствует → правка». Код не правит.
- Приёмка: `dp docs check` чист; документ есть. Правки — задача SA-8.

### SA-3. ASSETS.md под новую схему (dp-writer, Sonnet) — после SA-1; правки — аудит п. 8, пункты 1–6, 14
- Скоуп: правила в шапке ASSETS.md (NC и «личное» запрещены для всего в сборке; сайт и исследования — отдельно), раздел «Движок и библиотеки», правки строк по аудиту, ссылки на тексты `licenses/*.txt` (SA-К2 — тексты кладёт SA-4; если SA-4 позже — ссылки по списку из контракта), тексты «некоммерческий» (`about_intro` ru/en, `user_agent`).
- Приёмка: `build_inventory.py --preset all --check` → 0; тесты `steam_assets_contracts`, `assets_credits` → 0 упало; `dp docs check` чист.

### SA-4. Атрибуции в игре и файл лицензий рядом с exe (dp-engineer, Sonnet) — после SA-1; аудит п. 8, пункты 7, 9, 13; `exclude_filter` += `build/*`
- Скоуп: SA-К2: `licenses/*.txt`, `tools/release/third_party_notices.py`, одна строка в `tools/build.sh`, проверка экрана «Об игре» (все обязательные атрибуции видны), контрактный тест `tests/contracts/test_steam_assets_contracts_sa4.gd`.
- Приёмка: сборка Linux (`tools/build.sh linux`) кладёт `THIRD_PARTY_NOTICES.txt` и `licenses/` рядом с exe; тест: каждая строка с атрибуцией — в тексте «Об игре» и в файле; `steam_assets_contracts` → 0 упало.

### SA-5. Скриншоты для Steam — СНЯТА (решение пользователя 05.10: скриншоты позже вместе с описанием)
- Скоуп: готовыми инструментами `tools/shots` (в первую очередь `itch_shot`): 8–10 кадров 1920×1080 из игры (полёт, старт, облака/термики, разные места, прибор, сеть — без отладочного интерфейса) + 3 кадра 3840×2160 без интерфейса (фон для капсул и hero). Сырые — `/home/greg/deltaplan/build/screenshots/SA-5/`; отобранные — `steam/store/screenshots/NN_<имя>.jpg` (q90) и `steam/store/src/*.jpg` (q92), `steam/store/.gdignore`.
- Приёмка: размеры и количество по SA-К4 (скрипт проверки), пасхалок в кадре нет.

### SA-6. Капсулы и иконки (dp-engineer, Sonnet)
- Исходный кадр — `assets/ui/menu_background.jpg` (3840×2160, собственный) до появления скриншотов; генератор принимает любые кадры 3840×2160 из `steam/store/src/`, замена фона позже — перезапуском.
- Скоуп: `tools/store/make_store_assets.py` (Pillow) по SA-К4: все капсулы, library hero/logo/capsule/header, shortcut icon (PNG+ICO 256), app icon 184, event cover/header; `steam/store/README.md` (что куда грузить). Визуально — не больше двух попыток.
- Приёмка: скрипт воспроизводит файлы; размеры и форматы точно по SA-К4 (скрипт проверки); пользователь смотрит файлы на шлюзе.

### SA-7. Иконки ачивок: промпты и скрипт генерации (dp-researcher, Sonnet) — запуск на GPU позже
- Решение пользователя 05.10: сейчас только промпты (единый стиль) и скрипты (пакетно, детерминированно, seed); генерация — на локальной NVIDIA (RTX 4070 SUPER, 12 ГБ), когда GPU освободится; модель — с лицензией, разрешающей коммерческое использование результата (не FLUX.1-dev и прочие NC), запись в ASSETS.md. Список ачивок (~30–35) — из финального `configs/achievements.json` модуля steam.
- Скоуп: SA-К4 v3: `tools/store/achievement_icons.py`, `tools/store/achievements/prompts.json` (по черновику 18 ачивок из плана steam + подставной `tools/store/achievements/fixture_achievements.json` в формате S6), `tools/store/achievements/README.md` (выбор модели — сравнение лицензий, VRAM, как поставить и запустить), строка в ASSETS.md.
- Приёмка: `--dry` на подставном конфиге → `ICONS PLAN ok=18 missing=0`; модель и ревизия закреплены, лицензия разрешает коммерческое использование (URL); без GPU не запускается.
- Сделано 05.10 (этап 1): FLUX.1-schnell (Apache-2.0, ревизия закреплена), nf4 + выгрузка на CPU, 18 промптов. На GPU не проверено.
- Этап 2 (новая задача, после финального `configs/achievements.json` и освобождения GPU): пользователю — вход в Hugging Face и принятие условий страницы FLUX.1-schnell (модель gated); дописать промпты новых ачивок (`--dry` покажет missing), запуск под `dp lock gpu`, просмотр пользователем.

### SA-8. Подложка карты: правки по правилам серверов (dp-engineer, Sonnet) — после SA-2
- Скоуп — по списку правок SA-2 (User-Agent без «non-commercial», атрибуция, кэш и т. п.); контракт start-map SM-К1 — версия +1 через координатора, если меняется формат конфига.

### SA-9. VC++ DLL из официального VC Redist; инвентарь `<exe>/…` (dp-engineer, Sonnet) — после SA-3
- Решение пользователя 05.10 (Q1 = А): автор принимает лицензию бесплатной Visual Studio Community/Build Tools, DLL — из `VC\Redist`, не из колеса PyPI.
- Скоуп: `native/air_onnx/build.sh` и README (источник DLL, версия, sha256, согласие с лицензией явно); `tools/release/build_inventory.py` — шаблоны `<exe>/…` (SA-К3 v2), лицензия Microsoft разрешена.
- Приёмка: `build_inventory.py --preset all --check` → INVENTORY OK; в build.sh нет ссылки на PyPI.

## Итог на 05.10
- Приняты и влиты: SA-1 (аудит), SA-2 (правила серверов тайлов), SA-3 (ASSETS.md), SA-4 (licenses/, THIRD_PARTY_NOTICES рядом с exe), SA-6 (капсулы, иконки), SA-7 этап 1 (промпты и генератор иконок ачивок), SA-8 (User-Agent, паузы, параллельность тайлов), SA-9 (VC++ из Redist, инвентарь `<exe>/`), SA-10 (Redist через msvc-wine; DLL совпали побайтно). SA-5 снята.
- SA-11: промпты под финальные 38 ачивок (steam ba0145fa) — `--dry` ok=38.
- Открыто: SA-7 этап 2 — генерация на GPU (после освобождения GPU; вход HF и условия FLUX.1-schnell — пользователю); скриншоты и описание — позже, вне модуля; macOS-архив без THIRD_PARTY_NOTICES (если macOS будет раздаваться).

## Волны
1. SA-1, SA-2, SA-6 (параллельно).
2. SA-3, SA-4 (после SA-1). Шлюз 1 — вопросы аудита (если будут) и просмотр капсул.
3. SA-7 (промпты и скрипт сейчас; генерация — после финального списка ачивок и освобождения GPU), SA-8 (после SA-2).

## Шлюз 1 — вопросы пользователю (готовятся)
1. ~~VC++ runtime~~ — отвечено 05.10: А (SA-9).
2. `points.png` в корне главной копии (не в git) попадает в сборку, если собирать из главной копии; `build/*.json` тоже — SA-4 исключает `build/*`.
2. Капсулы и иконки — посмотреть файлы (после SA-6).

## Риски
- `tools/build.sh` правит и модуль steam (ST-3) — у нас одна строка, конфликт слияния тривиальный.
- Список ачивок модуля steam ещё на шлюзе — SA-7 ждёт.
- Бинарники страницы Steam в git: только финальные JPEG/PNG (~15–25 МБ всего), сырые кадры — вне git.
