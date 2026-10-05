---
type: "plan"
status: "active"
module: "steam"
updated: "2026-10-05"
summary: "План модуля steam: сетевая игра через Steam (лобби, друзья, транспорт), Rich Presence, 16 ачивок, ник Steam как имя пилота, настройки в Steam Cloud; без Steam игра работает как сейчас."
related: ["docs/contracts/steam.md", "docs/guide/net-protocol.md", "docs/plan/multiplayer.md"]
---
# План модуля steam — подготовка игры к Steam

Ветка `feature/steam`, копия `~/deltaplan-steam`, код задач `ST`. Контракты стыков — `docs/contracts/steam.md`.

## Цель
1. Сетевая игра через Steam: лобби, друзья (приглашения, вход к другу), совместная игра — поверх существующего сетевого кода (протокол `docs/guide/net-protocol.md` не меняется, Steam — лобби и транспорт).
2. Rich Presence: что пилот делает (место, на старте/в полёте/сел, сетевая игра).
3. Ачивки (16 штук, список ниже).
4. Игра запущена не из Steam (itch.io, ручная сборка) — Steam-часть неактивна, игра работает как сейчас, без ошибок и без зависимости от Steam-клиента.
5. Ник Steam — имя пилота по умолчанию (если пилот имя не задавал).
6. Настройки — в Steam Cloud.

Цель — Godot 4.7.2, Windows и Linux; macOS — если не дорого (бинарники GodotSteam есть, проверить негде).

## Решения пользователя (не обсуждаются)
- 05.10: регистрации в Steamworks пока нет: App ID, ачивки в кабинете, Cloud — заглушки (тест на App ID 480 Spacewar), место под настоящие значения — регистрация позже.
- 05.10: GodotSteam — выбран, альтернативы не исследовать.
- 05.10: ассеты под Steam (иконки, капсулы, страница магазина) — не в этом модуле, их ведёт другой координатор. Иконки ачивок — тоже там; здесь — только API-имена, тексты и условия.
- 05.10 (шлюз 1, Q1): 18 ачивок утверждены; добавить одиночные (азарт для взрослых пилотов, сеть может быть непопулярна; итог ~30–35): карта (ступени по местам, все континенты — через «Популярные места» или свою точку), погода (взлёт в грозу, в шквальный ветер — по факту модели погоды, без подсказок о безопасности), пасхалки (орёл, шары — скрытые в Steam, в публичных текстах не упоминать), спуск (2 км потери высоты за полёт). Дополненный список — короткий шлюз до ST-6.
- 05.10 (шлюз 1б, Q7): дополнение утверждено и ещё 2 — «Посадка на воду» (обычная) и «К столу» — посадка в лагерь у старта (скрытая, шуточная); итого 37.
- 05.10: порядок — сейчас всё на заглушках (App ID 480), приложение в Steamworks пользователь не заводит; после модуля onnx — регистрация, затем подготовка к тестам в Steam (настоящий App ID, ачивки/присутствие/облако в кабинете, ключи тестерам).
- 05.10: macOS в Steam — да (сборка macOS Steam входит в выпуск); ручную проверку на macOS и Windows сделает друг пользователя — ST-10 описывает сценарий ручной проверки для обеих платформ.
- 05.10 (Q2): отдельные пресеты Steam и itch, в itch GodotSteam нет.
- 05.10 (Q3): лобби — только друзья и приглашения.
- 05.10 (Q4): в itch ачивки считаются молча локально.
- 05.10 (Q5): Steam Cloud — Auto-Cloud (S7 → версия 1 в ST-9).
- 05.10 (Q6): библиотеки GodotSteam — и в сборку macOS, без проверки.

## Архитектура (контракты — `docs/contracts/steam.md`)
- **SteamService** (автозагрузка) — единственное место, где трогается синглтон `Steam` из GodotSteam. Активен только в сборке для Steam (пресет с меткой `steam`) или с аргументом `--steam`; нет расширения, клиента или инициализации → «неактивен», все методы — безвредные заглушки. Контракт S1.
- **Достижения**: `AchievementTracker` считает условия по событиям полёта (контракт S2 — события игры), хранит прогресс локально, разблокирует через SteamService. Логика ачивок от Steam не зависит (тестируется без Steam).
- **Rich Presence**: `SteamPresence` переводит состояние игры (S3) в ключи присутствия; файл локализации токенов для кабинета Steamworks — в репозитории.
- **Сеть**: лобби Steam (друзья, приглашения через оверлей, «вход к другу») + транспорт Steam Networking Messages, по которому идут те же кадры `Envelope` (proto3 JSON). У хозяина лобби — встроенный сервер игры (`local_server.gd`), к которому Steam-пиры подключаются через мост. Контракт S4 (пиры), S5 (лобби).
- **Имя пилота**: пусто в настройках → ник Steam (S1).
- **Steam Cloud**: рекомендация ST-1 — Auto-Cloud (без кода): корень `All OSes` + переопределения `WinAppDataRoaming/Deltaplan`, `LinuxXdgDataHome/Deltaplan`, `MacAppSupport/Deltaplan` (в проекте уже `custom_user_dir_name="Deltaplan"`); `user://configs/` разделить на общее (имя, управление, язык) и локальное для машины (графика). Remote Storage API на 480 работает, но квота Spacewar 4 КиБ.

## Итоги ST-1 (05.10, `docs/research/steam_godotsteam.md`, `tools/research/steam/`)
- GodotSteam GDExtension 4.22.1 (`v4.22.1-gde`, Steamworks SDK 1.65), MIT; репозиторий на Codeberg; архив 27 МБ, sha256 закреплён в `tools/research/steam/fetch_godotsteam.sh`; грузится в Godot 4.7.2.
- Доступ — только `Engine.get_singleton("Steam")` в `Object`, вызовы `.call()`, константы `.get()` (S1.1). `steamInitEx`: 0 — успех, 1 — прочее, 2 — нет клиента, 3 — клиент устарел. `run_callbacks()` каждый кадр. `restartAppIfNecessary` не вызывать.
- Без расширения — `has_singleton` false; расширение без `libsteam_api` — ERROR в логе, не грузится; без клиента — `status=2`.
- Сеть: Networking Messages (`sendMessageToUser`, `receiveMessagesOnChannel`, сигналы `network_messages_session_request/failed`), кадр 2 КБ надёжным на канале 0 проходит; лобби create/join на 480 работают; вход по приглашению — сигнал `join_requested(lobby_id, steam_id)` (`lobby_join_requested` нет); закрытая игра запускается с `+connect_lobby <id>`; значение данных лобби < 8192 байт.
- Rich Presence: ключ ≤ 63 байт, значение ≤ 255, планировать ≤ 20 ключей; `.vdf` формата `lang/<язык>/tokens`.
- Ачивки: на 480 только ачивки Spacewar; логику тестировать без Steam; массовой загрузки в кабинет нет — таблица для ручного ввода.
- Сборка: два набора пресетов — Steam (`custom_features=steam`) и itch (`exclude_filter` + `addons/godotsteam/*`: в экспорте нет библиотек, замер `export_check.sh`); `addons/godotsteam/` — в `.gitignore`. Первый `--import` проекта с расширением падает SIGABRT при выходе (импорт выполнен; обход — импортировать дважды).
- Не проверено: два аккаунта (лобби/сеть/оверлей/`+connect_lobby`), токены присутствия, свои ачивки, Auto-Cloud, загрузка на Windows/macOS, условия Steamworks SDK Access Agreement.

## Задачи

### ST-1. Исследование GodotSteam (dp-researcher)
- Скоуп: актуальная версия GodotSteam (GDExtension) для Godot 4.7.2, лицензия; бинарники Win/Linux/macOS, размер; как подключать и как собирать игру без Steam (отдельный пресет экспорта или одна сборка, инертная без клиента); поведение без клиента Steam и без библиотек; App ID 480: что работает (лобби, P2P, Rich Presence, ачивки Spacewar, Cloud); Steam Networking Messages в GodotSteam (API, сигналы, relay); Rich Presence (ключи, локализация токенов); Steam Cloud — Auto-Cloud против Remote Storage API; что нужно от пользователя в Steamworks (регистрация, App ID, загрузка ачивок/токенов присутствия, Cloud-квота), какие файлы можно подготовить заранее.
- Прототип вне игры: временный проект Godot 4.7.2 headless с GodotSteam — загрузка расширения, инициализация без клиента/с клиентом (если клиент запущен и вошёл), отсутствие расширения.
- Результат: `docs/research/steam_godotsteam.md` (frontmatter research), `tools/research/steam/` (README, `fetch_godotsteam.sh` — скачивание закреплённой версии с sha256 в `addons/godotsteam/`, `probe.sh` — прототип), без бинарников в git.
- Приёмка: `dp docs check` чист; `probe.sh` печатает `STEAM_PROBE loaded=… init=…`; в документе — версия, лицензия, ответы на вопросы скоупа, рекомендация по сборке и по Cloud.
- Оценка: 0,5–1 день.

### ST-2. SteamService, конфиг, имя пилота из Steam (dp-engineer, Sonnet)
- Скоуп: контракт S1 целиком: `scripts/steam/steam_service.gd` (автозагрузка), `configs/steam.json`, аргументы `--steam`/`--no-steam`, разбор `+connect_lobby`, имя пилота по умолчанию (S1.5) в `UserSettings` и подсказка в поле настроек; тесты.
- Зависит от: ST-1 (имя синглтона, коды инициализации).
- Приёмка: контрактные тесты S1 (проверки формы S1.4 и S1.5 дописаны в `test_steam_contracts.gd`); все тесты `net`, `ui` проходят; игра без расширения: `--smoke` без ошибок и `steam: inactive (no_extension)` в выводе; с расширением без `--steam`: `inactive (no_feature)`; с `--steam` без запущенного клиента: `inactive (init_failed…)`, без `push_error`.
- Оценка: 0,5 дня.

### ST-3. Сборка со Steam и без (dp-engineer, Sonnet)
- Скоуп: `addons/godotsteam/` через `tools/steam/fetch_godotsteam.sh` (перенести из `tools/research/steam/`; бинарники не в git, каталог в `.gitignore`), пресеты экспорта «Linux Steam», «Windows Steam» (+ «macOS Steam» — по решению) с меткой `steam` и библиотеками GodotSteam; пресеты itch исключают GodotSteam целиком; `tools/build.sh linux-steam|windows-steam`; `steam_appid.txt` только для разработки (не в сборке Steam); `tools/check.sh` не требует GodotSteam. Имена пресетов Steam содержат «Steam» (steam-assets SA-К2 включает по ним строки «(только Steam)» в уведомления); в `tools/build.sh` steam-assets добавит вызов `third_party_notices.py` — конфликт при слиянии тривиальный. `steam/partner/` — с `.gdignore`. В `exclude_filter` новых пресетов Steam — то же, что у пресетов itch, включая `build/*` (steam-assets, коммит 42f3d4b6 на `feature/steam-assets`).
- Зависит от: ST-1, ST-2.
- Приёмка: сборка itch Linux: в каталоге нет `libsteam_api*`/`godotsteam*`, `--smoke` проходит; сборка Steam Linux: библиотеки на месте, `--smoke` без клиента → `inactive (init_failed…)`, код 0; Windows-сборки собираются (запуск не проверить — так и записать).
- Оценка: 0,5 дня.

### ST-4. Транспорт сети: подключаемые пиры (dp-engineer, Opus)
- Скоуп: контракт S4: `ws_peer.gd`, `loopback_peer.gd`, `NetClient` через пир и реестр схем, `LocalServer.Conn` с пиром и `attach_peer`; без Steam.
- Зависит от: ничего (можно сразу).
- Приёмка: все тесты `tests/net/` и `test_net_screen` проходят без правки ожиданий; новый контрактный тест S4.4 через loopback (Hello → CreateZone → JoinZone вторым клиентом → PilotState); `attach_peer` при `threaded=true`.
- Оценка: 1 день.

### ST-5. Поток событий полёта для ачивок (dp-engineer, Sonnet)
- Скоуп: контракт S2: `scripts/game/achievement_feed.gd`, подключение в `Game` (отрыв, 1 Гц, итог), источники `cloud_base_msl`, `sun_elev_deg`, ветра у старта, счёт других пилотов (боты, сеть); вызовы `Achievements.on_*` только если автозагрузка есть.
- Зависит от: ничего (контракт S2).
- Приёмка: тест формы S2 (ключи, типы, NAN вместо отсутствующего) на коротком полёте headless; ровно один `flight_finished` на полёт; выход в меню из полёта — без `flight_finished`.
- Оценка: 0,5–1 день.

### ST-6. Ачивки: трекер, конфиг, Steam (dp-engineer, Sonnet)
- Скоуп: контракт S6: `configs/achievements.json` (список ниже), автозагрузка `Achievements` (`scripts/steam/achievements.gd` или `scripts/game/`), правила по S2, `user://achievements.json`, разблокировка через SteamService, `tools/steam/partner_files.py` → `steam/partner/achievements.csv`.
- Зависит от: S2 (синтетический поток), ST-2 (для Steam-части; до него — против контракта S1).
- Приёмка: на каждую ачивку — тест «открывается» и «не открывается на пороге − ε» по синтетическому потоку; накопительные (места) переживают перезапуск; без Steam — ни одной ошибки; файл для кабинета генерируется и совпадает с конфигом.
- Оценка: 1 день.

### ST-7. Активность и Rich Presence (dp-engineer, Sonnet)
- Скоуп: контракт S3: автозагрузка `Activity`, запись из `main.gd`/`Game`, `scripts/steam/steam_presence.gd`, `steam/partner/rich_presence.vdf` (ru/en).
- Зависит от: ST-2.
- Приёмка: тест: последовательность меню → загрузка → старт → полёт → посадка → меню даёт ожидаемые `mode` и ключи Steam (на подставном `api()`); частота вызовов Steam ≤ 1/с; без Steam — ни одного обращения.
- Оценка: 0,5 дня.

### ST-8. Сеть через Steam: лобби, друзья, транспорт (dp-engineer, Opus)
- Скоуп: контракт S5 и Steam-пир S4.1: транспорт Steam (по итогам ST-1 — Networking Sockets P2P или Networking Messages), мост хозяина (`attach_peer`), лобби, приглашения, «Друзья в игре», вход по приглашению/из списка друзей/по `+connect_lobby`, ключи присутствия лобби; экран сетевой игры — кнопка «Пригласить друзей» и список друзей (только при активном Steam).
- Зависит от: ST-1, ST-2, ST-4, ST-7 (ключи присутствия; можно параллельно, стык — S3).
- Приёмка: тесты на подставном Steam-API (двое «клиентов» в одном процессе: лобби → пир → Hello/JoinZone/PilotState); UI без Steam не меняется (`test_net_screen`); ручной сценарий на двух аккаунтах Steam (App ID 480) — описан для пользователя (у агентов второго аккаунта нет).
- Оценка: 2 дня.

### ST-9. Steam Cloud (dp-engineer, Sonnet)
- Скоуп: по решению (S7): Auto-Cloud — стабильный каталог `user://` (`use_custom_user_dir`), список путей и корней для кабинета в `steam/partner/README.md`; или Remote Storage API — синхронизация набора S7 при старте/сохранении.
- Зависит от: ST-1, ответа пользователя.
- Приёмка: по выбранному способу (Auto-Cloud — пути в README совпадают с фактическим `user://` на Linux и Windows, тест на `OS.get_user_data_dir()`; API — тест на подставном API: новее в облаке → берём, новее локально → отправляем).
- Оценка: 0,25–1 день.

### ST-10. Документация и файлы для Steamworks (dp-writer, Sonnet)
- Стык с модулем steam-assets (`docs/contracts/steam-assets.md` на `feature/steam-assets`): строка GodotSteam в `ASSETS.md`, раздел «Движок и библиотеки», пометка «(только Steam)», MIT + распространяемые библиотеки Steamworks SDK, текст лицензии — `licenses/<имя>.txt` (SA-К2/SA-К3); иконки ачивок `steam/store/achievements/<API>.jpg` делает steam-assets по `configs/achievements.json` (SA-К4) — в `steam/partner/README.md` ссылка на них.
- Скоуп: `docs/guide/steam.md` (как устроено, как включить/выключить, тест на 480, ручной тест на двух аккаунтах), сценарий ручной проверки для друга пользователя на Windows и macOS (запуск сборки Steam, имя из Steam, присутствие, ачивка, лобби/приглашение, без Steam-клиента — тихо неактивна; простым языком, по шагам, с тем, что прислать в ответ), `steam/partner/README.md` — что сделать пользователю в Steamworks (регистрация, App ID → `configs/steam.json`, ачивки из csv, токены присутствия из vdf, Cloud, депо Linux/Windows), строка GodotSteam в `ASSETS.md`, CHANGELOG.
- Зависит от: ST-3, ST-6, ST-7, ST-8, ST-9.
- Оценка: 0,5 дня.

## Ачивки (утверждено пользователем 05.10, Q1)
Принципы: за то, что делает настоящий пилот (набор, маршрут, посадка, полёт в компании); без подсказок о безопасности; без пасхалок; пороги — в `configs/achievements.json`. Полёт засчитывается, если `flight_finished.kind == "landed"` (включая жёсткую посадку и аварию — если не сказано иначе).

| API | Название (ru / en) | Условие |
|---|---|---|
| ACH_FIRST_FLIGHT | Первый полёт / First Flight | оторвался и сел (оценка посадки `soft` или `hard`) |
| ACH_SOFT_LANDING | На ноги / On Your Feet | посадка `soft`, вертикальная < 0,5 м/с, горизонтальная < 3 м/с |
| ACH_TOP_LANDING | Обратно на старт / Top Landing | полёт ≥ 5 мин, посадка ≤ 300 м по горизонтали от точки отрыва и не ниже её на 30 м, не авария |
| ACH_ABOVE_LAUNCH | Выше старта / Above Launch | `height_gain_m` ≥ 100 |
| ACH_KILOMETER_UP | Километр вверх / Kilometer Up | `height_gain_m` ≥ 1000 |
| ACH_CLOUDBASE | Под базой / Cloudbase | в полёте `alt_msl` ≥ `cloud_base_msl` − 100 (кромка известна) |
| ACH_STRONG_CLIMB | Четвёрка / Strong Climb | `best_thermal_climb_ms` ≥ 4 |
| ACH_SOARING_15 | Удержался / Staying Up | полёт ≥ 15 мин |
| ACH_HOUR | Час в воздухе / One Hour Up | полёт ≥ 60 мин |
| ACH_RIDGE_LOW | Над склоном / Ridge Soaring | 10 мин подряд в воздухе на `agl` ≤ 300 м |
| ACH_XC_10 | Маршрут / Cross-Country | `distance_m` (по прямой от отрыва до посадки) ≥ 10 км |
| ACH_XC_50 | Полсотни / Fifty | `distance_m` ≥ 50 км |
| ACH_UPWIND | Против ветра / Upwind | ветер у старта ≥ 4 м/с, посадка ≥ 5 км против ветра от точки отрыва (проекция на направление «откуда дует») |
| ACH_EVENING | Вечерний / Evening Glass-Off | 20 мин полёта при высоте солнца < 10° |
| ACH_PLACES_5 | Путешественник / Traveller | полёты (с посадкой) с 5 разных мест — накопительная |
| ACH_TOGETHER | Вместе / Together | сетевая игра: полёт с посадкой, в зоне ≥ 1 живой пилот кроме себя |
| ACH_GAGGLE | В одном потоке / Gaggle | сетевая игра: 60 с подряд в спирали с набором (`vario` > 0,5) и ≥ 1 живой пилот рядом в наборе (`near_climbing_live` ≥ 1) |
| ACH_LAST_DOWN | Последний сел / Last One Down | полёт ≥ 10 мин, другие пилоты (боты или живые) отрывались — ≥ 3, в момент посадки ни один не в воздухе |

## Ачивки — дополнение (шлюз 1б, утверждено)
Одиночные, к 18 выше; утверждено пользователем 05.10 (Q7) с двумя добавленными — итого 38 (на шлюзе ошибочно названо 35/37: в таблице 18 пунктов, а не 17; утверждались пункты списка), из них 4 скрытые. Континент — по координатам точки отрыва (Европа, Азия, Африка, Северная Америка, Южная Америка, Австралия и Океания; Антарктида не считается). «Посадка» — `kind == "landed"`, авария тоже считается, если не сказано иначе.

| API | Название (ru / en) | Условие |
|---|---|---|
| ACH_PLACES_10 | Десять стартов / Ten Launches | полёты с 10 разных мест (копится) |
| ACH_PLACES_25 | Двадцать пять стартов / Twenty-Five Launches | 25 разных мест (копится) |
| ACH_CONTINENTS_3 | Через океан / Overseas | полёты с 3 континентов (копится) |
| ACH_CONTINENTS_ALL | Все континенты / Every Continent | полёты со всех 6 континентов (копится) |
| ACH_XC_100 | Сотня / Hundred | `distance_m` ≥ 100 км |
| ACH_HOURS_3 | Три часа / Three Hours | полёт ≥ 3 ч |
| ACH_AIRTIME_10H | Налёт / Logbook | суммарно ≥ 10 ч в воздухе (копится) |
| ACH_WINGS_5 | Пять крыльев / Five Wings | полёты на 5 разных крыльях (копится) |
| ACH_ALT_5000 | Пять тысяч / Five Thousand | в полёте `alt_msl` ≥ 5000 м |
| ACH_HIGH_LAUNCH | Высокогорье / High Launch | взлёт с высоты ≥ 3000 м над морем и посадка |
| ACH_DESCENT_2000 | С горы / Downhill | `launch_alt_msl − land_alt_msl` ≥ 2000 м |
| ACH_STORM | Под наковальней / Under the Anvil | взлёт в грозовой день (`cb_chance` ≥ 0,5), полёт ≥ 10 мин и посадка |
| ACH_STRONG_WIND | Шквал / Gale | взлёт при ветре у старта ≥ 10 м/с (36 км/ч) и посадка |
| ACH_OVERCAST | Серый день / Grey Day | облачно (`sky == "overcast"`), набор ≥ 300 м над стартом |
| ACH_WINTER | Мороз / Frost | температура у старта ≤ 0 °C, полёт ≥ 10 мин |
| ACH_EAGLE (скрытая) | Орёл / Eagle | пасхалка `eagle` ближе 100 м |
| ACH_BALLOONS (скрытая) | Шары / Balloons | пасхалка `balloon` или `balloon_festival` ближе 150 м |
| ACH_GLORIA (скрытая) | Глория / Glory | видна глория (пасхалка `gloria`) |
| ACH_WATER_LANDING | Посадка на воду / Splashdown | посадка на воду (`land_surface == "water"`) — добавлено пользователем (Q7) |
| ACH_CAMP_LANDING (скрытая) | К столу / Dinner Is Served | посадка в лагерь у старта: `land_camp_m` ≤ 10 м — добавлено пользователем (Q7), шуточная |

Для них поток S2 расширен до версии 3 (`lat/lon`, `temp_c`, `cb_chance`, `sky`, `eggs`, `land_surface`, `land_camp_m`).

## Волны
1. Сейчас (без решений пользователя): ST-1 (идёт), ST-4, ST-5.
2. После ST-1: ST-2; затем ST-3, ST-6, ST-7 параллельно.
3. После ST-4, ST-2: ST-8; после ответа по Cloud — ST-9; в конце — ST-10.

## Шлюз 1 — вопросы пользователю
1. Список ачивок (выше) — оставить/убрать/поменять пороги?
2. Сборки: отдельные пресеты Steam (GodotSteam внутри, метка `steam`) и itch (без GodotSteam вовсе) — рекомендация; или одна сборка для всех.
3. Лобби: только друзья + приглашения (рекомендация, круг маленький) или ещё публичный список всех открытых зон Deltaplan.
4. Ачивки без Steam (itch): считать молча локально (рекомендация — при переходе в Steam откроются) / не считать / показать список в игре (отдельная задача).
5. Steam Cloud: Auto-Cloud (без кода, настраивается в кабинете при регистрации; рекомендация, если ST-1 подтвердит) или Remote Storage API (код, проверяем на 480).
6. macOS: положить библиотеки GodotSteam в сборку macOS без проверки (дёшево) или не делать.

## Что нужно от пользователя (позже, при регистрации)
Steamworks: регистрация (Steam Direct), App ID → `configs/steam.json`; ачивки — из `steam/partner/achievements.csv` (+ иконки от направления ассетов); токены присутствия — `steam/partner/rich_presence.vdf`; Cloud (квота, пути — по ST-9); депо Linux/Windows; ручной тест сети на двух аккаунтах.

## Риски
- Лобби и P2P не проверить одним аккаунтом — нужен ручной тест пользователя (два компьютера/аккаунта); агентам — подставной Steam-API.
- На App ID 480 свои ачивки и токены присутствия не работают — проверка по логам/подставному API до регистрации.
- Совместимость GodotSteam с Godot 4.7.2 (ST-1).
- Рефакторинг транспорта (ST-4) задевает рабочую сетевую игру — приёмка по всем тестам `tests/net/`.
