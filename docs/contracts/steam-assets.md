---
type: "contract"
status: "active"
module: "steam-assets"
updated: "2026-10-05"
summary: "Контракты модуля steam-assets: инвентарь сборки (SA-К1), лицензии и атрибуции в сборке (SA-К2), формат ASSETS.md (SA-К3), ассеты страницы Steam (SA-К4)."
related: ["docs/plan/steam-assets.md", "ASSETS.md"]
contracts: [{"id": "SA-К1", "version": 1}, {"id": "SA-К2", "version": 1}, {"id": "SA-К3", "version": 1}, {"id": "SA-К4", "version": 1}]
---
# Контракты модуля steam-assets

План — `docs/plan/steam-assets.md`. Менять — только через координатора модуля (версия +1, что изменилось, уведомить потребителей, их правка в том же шаге). Контрактный тест — `tests/contracts/test_steam_assets_contracts.gd` (без сети и GPU; новые проверки задач — в отдельных файлах `tests/contracts/test_steam_assets_contracts_<задача>.gd`, фильтр `steam_assets_contracts` подхватит).

Главное правило модуля (решение пользователя 05.10.2026): **всё, что входит в сборку игры (itch и Steam), должно разрешать коммерческое использование**; NC и «только для личного использования» в сборке запрещены.

## SA-К1. Инвентарь сборки (v1)
Владелец: SA-1. Потребители: SA-3 (ASSETS.md), SA-4 (лицензии в сборке), выпуск версии (проверка перед сборкой).
- `tools/release/build_inventory.py [--preset Linux|Windows|macOS|all] [--out DIR] [--check]` — Python 3 из системы (только стандартная библиотека), без сети и GPU, < 2 мин. Пишет `DIR/<preset>.json` (по умолчанию `build/inventory/`, не в git).
- Что считается сборкой: файлы проекта, которые экспорт Godot кладёт в `.pck` по `export_presets.cfg` (`export_filter`, `include_filter`, `exclude_filter`, каталоги с `.gdignore` исключены), + файлы рядом с исполняемым файлом (то, что копирует `tools/build.sh`: `configs/`, библиотеки GDExtension и их зависимости — `libdd3d`, `air_onnx`, ONNX Runtime, VC++ runtime), + сам движок (шаблон экспорта Godot). Эмуляция фильтров сверяется один раз с настоящим экспортом (`--export-pack` и список файлов) — расхождения в отчёте SA-1.
- JSON: `{"version": 1, "preset": "Linux", "commit": "<sha>", "items": [ {"path": "res://… | <exe>/… | engine", "kind": "pck|beside_exe|engine", "bytes": int, "assets_md": "<раздел ASSETS.md> | own | null", "license": "<колонка «Лицензия» или MIT (own)>", "commercial_ok": true|false|null, "attribution": bool} ]}`. `path` — по одному файлу (не шаблоны). `own` — собственный код и данные проекта (`*.gd`, `*.gdshader`, `*.tscn`, `*.tres`, `configs/`, `locale/`, `project.godot` и т. п. — список шаблонов в начале скрипта, с комментарием).
- Лицензия файла — из строки `ASSETS.md`, чей шаблон в колонке «Файл» совпал с путём (правила совпадения — SA-К3). `commercial_ok`: `true` — CC0, CC-BY*, OFL, MIT, BSD, Apache, ODbL, лицензия Copernicus DEM, «собственный», «—» (сгенерировано нами); `false` — NC, «личн», «non-commercial», «personal»; иначе `null` (неизвестно). `attribution`: `true` для CC-BY*, ODbL, OFL, MIT, BSD, Apache, Copernicus и строк с «атрибуц».
- `--check`: код 1 и список, если есть файл сборки без строки `ASSETS.md` и не `own`, или `commercial_ok != true`; иначе 0 и строка `INVENTORY OK files=<n> bytes=<n>`.
- Инвариант: каждый файл сборки — ровно в одном `item`; после SA-3 `--check` проходит на всех пресетах.

## SA-К2. Лицензии и атрибуции в сборке (v1)
Владелец: SA-4. Потребители: `tools/build.sh` (одна строка вызова; файл правит и модуль steam, ST-3), модуль steam (строка GodotSteam, ST-10), экран «Об игре» (`scripts/ui/assets_credits.gd`, `about_screen.gd`).
- Полные тексты лицензий — `licenses/<имя>.txt` в корне репозитория (UTF-8): например `MIT-deltaplan.txt` (= `LICENSE`), `MIT-godot.txt`, `godot-COPYRIGHT.txt` (сторонние компоненты движка), `OFL-1.1.txt`, `CC-BY-4.0.txt`, `CC0-1.0.txt`, `ODbL-1.0.txt`, `copernicus-dem.txt`, `onnxruntime-ThirdPartyNotices.txt`, `MIT-debug_draw_3d.txt`, … Имена — латиницей, `[A-Za-z0-9._-]+`.
- Строка `ASSETS.md`, требующая текста лицензии, ссылается на него в колонке «Лицензия» ссылкой Markdown `[…](licenses/<имя>.txt)` (или на уже существующий файл лицензии ассета, например `addons/…/LICENSE`).
- `tools/release/third_party_notices.py --out <каталог сборки> [--preset P]` (стандартная библиотека Python) пишет рядом с исполняемым файлом:
  - `THIRD_PARTY_NOTICES.txt` (UTF-8, LF; англ. заголовки, пункты как в ASSETS.md): название и версия игры, лицензия кода проекта (MIT), затем по разделам ASSETS.md, входящим в сборку, строки «что — источник — лицензия — атрибуция»;
  - `licenses/` — все тексты, на которые ссылаются строки разделов, входящих в сборку (и `licenses/` Godot).
- `tools/build.sh` вызывает его после экспорта для каждого пресета (одна строка рядом с копированием `configs/`).
- Экран «Об игре» показывает все строки разделов ASSETS.md, входящих в сборку, и тексты лицензий (как сейчас — `AssetsCredits`).
- Строки только для Steam-сборки: в колонке «Где используется» — пометка `(только Steam)`; `third_party_notices.py --preset` с `steam` в имени их включает, иначе — пропускает. Строку GodotSteam (MIT, + распространяемые библиотеки Steamworks SDK) добавляет модуль steam (ST-10) в раздел «Движок и библиотеки» с текстом в `licenses/`.
- Инварианты: каждая строка входящего в сборку раздела с `attribution = true` (SA-К1) есть и в `THIRD_PARTY_NOTICES.txt`, и в тексте «Об игре»; каждый упомянутый `licenses/*.txt` существует; без сети.

## SA-К3. Формат ASSETS.md (v1)
Владелец: SA-3. Потребители: `AssetsCredits` (экран «Об игре»), `build_inventory.py` (SA-К1), `third_party_notices.py` (SA-К2), модуль steam (ST-10 — строка GodotSteam).
- Фиксирует то, что уже разбирает `AssetsCredits.parse_tables`: разделы `## <название>`, под ними таблицы Markdown `| … |`, первая строка — заголовки, строка `|---|` пропускается.
- Таблицы разделов, входящих в сборку: ровно 5 колонок `Файл | Что | Источник | Лицензия | Где используется`. Колонка «Лицензия» не пустая (`—` — сгенерировано нами процедурно, без сторонних материалов).
- Раздел **не** входит в сборку, если в его названии есть «не вход» (например «Сайт проекта (site/, не входит в игру)»). Остальные — входят.
- В разделах, входящих в сборку, в колонке «Лицензия» запрещены: `NC`, «некоммерч», «non-commercial», «personal», «личн» (решение пользователя 05.10.2026). Пометка `⚠ NC` больше не используется.
- Шаблоны путей в колонке «Файл»: каждый токен в обратных кавычках, похожий на путь, — шаблон относительно корня проекта; `*` — любые символы в имени, `<x>` — один сегмент пути, `{a,b,c}` — варианты, `01…08` — числовой диапазон с той же шириной; токены `user://…` и `$…` — не файлы сборки (данные, скачиваемые на машине игрока). Новый раздел «Движок и библиотеки» — Godot, GDExtension-библиотеки, ONNX Runtime, VC++ runtime (Windows), godot-cpp.

## SA-К4. Ассеты страницы Steam (v1)
Владелец: SA-6 (капсулы и иконки), SA-5 (скриншоты), SA-7 (иконки ачивок). Потребители: пользователь (загрузка в Steamworks после регистрации), модуль steam (`steam/partner/README.md`, ST-10 — ссылка на иконки ачивок).
- Каталог `steam/store/` с `.gdignore` (в сборку не попадает; `steam/partner/` — модуля steam, не трогать). Размеры — по [Steamworks: Graphical Assets](https://partner.steamgames.com/doc/store/assets) на 05.10.2026:

| Файл | Размер, px | Формат | Steam |
|---|---|---|---|
| `capsule_header.jpg` | 920×430 | JPEG | Header Capsule |
| `capsule_small.jpg` | 462×174 | JPEG | Small Capsule |
| `capsule_main.jpg` | 1232×706 | JPEG | Main Capsule |
| `capsule_vertical.jpg` | 748×896 | JPEG | Vertical Capsule |
| `page_background.jpg` | 1438×810 | JPEG | Page Background (необяз.) |
| `library_capsule.jpg` | 600×900 | JPEG | Library Capsule |
| `library_header.jpg` | 920×430 | JPEG | Library Header Capsule |
| `library_hero.png` | 3840×1240 | PNG | Library Hero (без текста и логотипа) |
| `library_logo.png` | 1280×≤720 или ≤1280×720 (одна сторона ровно) | PNG RGBA, прозрачный фон | Library Logo |
| `shortcut_icon.png`, `shortcut_icon.ico` | 256×256 | PNG / ICO | Shortcut Icon (иконка клиента) |
| `app_icon.jpg` | 184×184 | JPEG | App (Community) Icon |
| `event_cover.jpg` | 800×450 | JPEG | Event Cover |
| `event_header.jpg` | 1920×622 | JPEG | Event Header (необяз.) |
| `screenshots/NN_<имя>.jpg` | 1920×1080 (16:9) или больше, ≥ 5 шт. | JPEG q90 | Screenshots |
| `achievements/<API_NAME>.jpg`, `<API_NAME>_locked.jpg` | 256×256 | JPEG | иконки ачивок (открыта / закрыта) |

- `API_NAME` — ключи ачивок из `configs/achievements.json` модуля steam (контракт S6, `docs/contracts/steam.md` на ветке `feature/steam`); набор иконок = набор ачивок.
- Капсулы (кроме hero) содержат название игры (логотип) и ничего больше текстового (правила Steam: без наград, цитат, «скидка»); hero — без текста и логотипа; всё — кадры из игры или наша графика, без сторонних материалов.
- Генерация — `tools/store/make_store_assets.py` (Pillow) из исходных кадров `steam/store/src/*.jpg` (JPEG q92, 3840×2160) и `assets/logo.png`, `assets/icon.png`; повторный запуск даёт те же файлы. `steam/store/README.md` — что куда загружать в Steamworks.

## История
- v1 (05.10.2026) — заведены до первого исполнителя.
