# Что сделать в Steamworks при регистрации

Каталог не входит в сборку игры (`.gdignore`). Подробности устройства — `docs/guide/steam.md`, контракты — `docs/contracts/steam.md` (S6 ачивки, S3 присутствие, S7 облако). Всё, что можно было подготовить заранее, здесь уже лежит: файлы ниже вносятся в кабинет вручную (массовой загрузки ачивок нет).

Что не проверено: условия и цены Valve взяты из исследования `docs/research/steam_godotsteam.md` (в частности, взнос 100 USD за приложение — по документации Valve, не проверялось); кабинет разработчика агентам недоступен, поэтому порядок экранов и названия полей могут отличаться.

## Порядок

1. **Регистрация партнёра (Steam Direct).** Анкеты: налоговая, банковская, подтверждение личности; на это уходит время. Взнос за приложение — 100 USD (по документации Valve). Перед работой с библиотеками прочитать и принять **Steamworks SDK Access Agreement**: в сборки Steam кладутся распространяемые библиотеки SDK (`libsteam_api.so`, `steam_api64.dll`, `libsteam_api.dylib`); условия соглашения агентами не читались.
2. **App ID.** После создания приложения вписать его число в `configs/steam.json` (`app_id`; сейчас 480 — тестовый Spacewar). Файл копируется в сборки рядом с игрой, папка `configs/`.
3. **Ачивки** — Steamworks → App Admin → Stats & Achievements. Для каждой строки `steam/partner/achievements.csv` создать ачивку: `api` → API Name (точно как в файле, например `ACH_FIRST_FLIGHT`), `name_en`/`desc_en` → английские название и описание, `name_ru`/`desc_ru` → русские (добавить язык), `hidden` = 1 → отметить «Hidden» (0 — обычная). Иконки: `steam/store/achievements/<API>.jpg` (получена) и `<API>_locked.jpg` (серая) размером 256×256 — их делает отдельное направление (контракт SA-К4, генератор `tools/store/`); в этой копии каталога `steam/store/achievements/` ещё нет — проверить наличие перед загрузкой. Файл csv обновляется скриптом `tools/steam/partner_files.py` из `configs/achievements.json` — вручную не править. Затем опубликовать.
4. **Присутствие (Rich Presence).** Steamworks → Community → Rich Presence (локализация): загрузить `steam/partner/rich_presence.vdf` (английский и русский; формат Valve `lang/<язык>/tokens`; проверить загрузкой можно только с настоящим App ID) и опубликовать. Токены: `#St_Menu`, `#St_Loading`, `#St_Launch`, `#St_Flying`, `#St_Landed`, `#St_Paused` и варианты `_Net`; подстановки `%place%`, `%alt%`, `%peers%`.
5. **Облако (Auto-Cloud)** — App Admin → Cloud. Задать квоту (в `steam/partner/auto_cloud.json`: 100 файлов и 10 485 760 байт = 10 МиБ; без квоты секция не открывается) и включить Steam Auto-Cloud. Корень — «All OSes» с переопределениями по системам, подкаталог везде `Deltaplan`:

   | Система | Корень Steam | Подкаталог |
   |---|---|---|
   | Windows | `WinAppDataRoaming` | `Deltaplan` |
   | Linux | `LinuxXdgDataHome` | `Deltaplan` |
   | macOS | `MacAppSupport` | `Deltaplan` |

   Маски внутри этого подкаталога (из `auto_cloud.json`):

   | Подкаталог | Маска | Вложенные |
   |---|---|---|
   | `configs` | `*.json` | да |
   | (корень) | `recent_places.json` | нет |
   | (корень) | `records.json` | нет |
   | (корень) | `achievements.json` | нет |
   | (корень) | `last_flight.json` | нет |
   | `tasks` | `*` | да |

   Кэши (`terrain_cache`, `map_cache`, `air_nn`), отладочные файлы и машинные настройки (`local/`) в облако не идут. Опубликовать. Работу Auto-Cloud проверить на двух компьютерах: до регистрации не проверялась.
6. **Депо и сборки.** Три депо — Linux, Windows, macOS; собирать `tools/build.sh linux-steam`, `windows-steam`, `macos-steam` (каталоги `build/<платформа>-steam`; перед сборкой скрипт скачивает GodotSteam командой `tools/steam/fetch_godotsteam.sh`). В каждой сборке должны лежать библиотеки GodotSteam и Steamworks для этой системы (на macOS — внутри `.app`); проверка — `tools/steam/check_builds.sh`. Загрузка билдов — `steamcmd` (не описана здесь, отдельная работа). Запуск Windows- и macOS-сборок Steam не проверялся.
7. **Страница магазина.** Графика — `steam/store/` (таблица «какой файл в какое поле» в `steam/store/README.md`).
8. **Проверка.** Ручной тест на двух аккаунтах и сценарий для друга-тестера на Windows и macOS — `docs/guide/steam.md`, раздел «Ручные проверки». Ключи для тестеров выдаются в кабинете после создания приложения.
