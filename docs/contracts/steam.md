---
type: "contract"
status: "active"
module: "steam"
updated: "2026-10-05"
summary: "Контракты модуля steam: SteamService и заглушка «Steam нет» (S1), поток событий полёта для ачивок (S2), активность игры и Rich Presence (S3), транспорт сети с подключаемыми пирами (S4), лобби Steam и адресация (S5), описание ачивок и локальный прогресс (S6), Steam Cloud (S7)."
related: ["docs/plan/steam.md", "docs/guide/net-protocol.md"]
contracts: [{"id": "S1", "version": 1}, {"id": "S2", "version": 1}, {"id": "S3", "version": 1}, {"id": "S4", "version": 1}, {"id": "S5", "version": 1}, {"id": "S6", "version": 1}, {"id": "S7", "version": 0}]
---
# Контракты модуля steam

Внутренний документ. План — `docs/plan/steam.md`. Контрактный тест — `tests/contracts/test_steam_contracts.gd` (координатор завёл проверки версий и S1.1; задачи-владельцы дописывают проверки формы своего стыка). Менять — только через координатора модуля: версия +1, что изменилось, потребители правятся в том же шаге.

Общее: единицы СИ (м, м/с, с), углы — градусы; мир Godot: X — восток, Y — вверх, −Z — север (как в `docs/guide/net-protocol.md`). Время — секунды. Steam ID — 64-битное целое; в строках и данных лобби — десятичной строкой.

## S1. SteamService — единственная точка доступа к Steam (версия 1)

Владелец — ST-2. Потребители — ST-3 (сборка), ST-6 (ачивки), ST-7 (присутствие), ST-8 (сеть), имя пилота (`UserSettings`).

Автозагрузка `SteamService` (`scripts/steam/steam_service.gd`, `extends Node`), регистрируется в `project.godot` после `Config`.

**S1.1. Разбор без расширения.** Ни один `.gd` в `scripts/`, `scenes/`, `tests/` не обращается к глобальному идентификатору `Steam` (нет `Steam.` вне комментариев и строк) и не объявляет типы GodotSteam. Синглтон берётся только в `scripts/steam/steam_service.gd`: `Engine.has_singleton("Steam")` → `Engine.get_singleton("Steam")` в переменную `Object`, вызовы — через неё. Остальные файлы `scripts/steam/*` получают его через `SteamService.api()`. Без расширения все скрипты разбираются и игра работает как до модуля (проверка — контрактный тест, сканирует файлы).

**S1.2. Когда Steam активен.** `is_active() == true` тогда и только тогда, когда одновременно:
1. сборка для Steam: `OS.has_feature("steam")` (пресеты экспорта Steam, ST-3) **или** аргумент пользователя `--steam` (разработка, тест на 480);
2. нет аргумента `--no-steam` и `configs/steam.json → enabled != false`;
3. синглтон `Steam` есть;
4. инициализация с `app_id` из `configs/steam.json` прошла успешно.
Любое невыполненное условие — неактивен, одна строка `print` с причиной (`steam: inactive (<причина>)`), без `push_error`/`push_warning`. Сборка itch и ручная сборка без `--steam` не трогают Steam вообще (даже если клиент запущен). `SteamAPI_RestartAppIfNecessary` не вызывается.

**S1.3. Конфиг** `configs/steam.json`: `{"enabled": true, "app_id": 480, "_doc": "480 — Spacewar для тестов; заменить на App ID игры после регистрации в Steamworks"}`. Настоящий App ID — только правкой этого числа (и файлов для кабинета, S6/S3).

**S1.4. Интерфейс** (неактивен — значения в скобках, вызовы ничего не делают):
```
signal activated()                         # один раз, когда стал активен (в _ready)
func is_active() -> bool                   # (false)
func inactive_reason() -> String           # "" если активен; иначе "no_feature" | "disabled" | "no_extension" | "init_failed: <текст>"
func api() -> Object                       # синглтон Steam (null) — только для scripts/steam/*
func app_id() -> int                       # из конфига, и неактивным тоже
func steam_id() -> int                     # (0)
func persona_name() -> String              # ник Steam ("")
func language() -> String                  # язык игры в Steam, "russian"/"english"/… ("")
func launch_lobby_id() -> int              # лобби из аргумента запуска +connect_lobby <id> (0) — для S5
```
`run_callbacks` — в `_process` самого сервиса; сигналы GodotSteam подключают модули `scripts/steam/*` к `api()`.

**S1.5. Имя пилота по умолчанию.** `UserSettings.pilot_name()`: пусто (после `strip_edges`) в `net.pilot_name` → `SteamService.persona_name()`, обрезанный до `PILOT_NAME_MAX`, если не пусто → иначе `tr("net_pilot_name_default")`. Ник Steam в настройки не записывается. Поле имени в настройках показывает его подсказкой (placeholder).

## S2. Поток событий полёта для ачивок (версия 1)

Владелец — ST-5 (игра шлёт). Потребитель — ST-6 (`AchievementTracker`). Трекер о Game/Glider ничего не знает — только эти словари; тесты трекера — на синтетическом потоке.

Источник — объект `AchievementFeed` (`scripts/game/achievement_feed.gd`), создаётся `Game` на полёт; сигналы пробрасываются в автозагрузку `Achievements` (ST-6) вызовом `Achievements.on_flight_started(ctx)`, `on_flight_sample(s)`, `on_flight_finished(fin)`. Без `Achievements` (тесты игры) — вызовов нет.

**`flight_started(ctx)`** — в момент отрыва (`glider.took_off`):

| ключ | тип | смысл |
|---|---|---|
| `place_key` | String | устойчивый ключ места: `"<location_id>/<site_id>"`, для точки с карты — `"pick/<lat 3 знака>,<lon 3 знака>"` |
| `wing` | String | путь крыла из `FlightSettings.wing` |
| `net` | bool | сетевая игра (`Game.net != null`) |
| `launch_pos` | Vector3 | точка отрыва, мир, м |
| `launch_alt_msl` | float | высота отрыва над уровнем моря, м |
| `wind_ms` | float | ветер у старта на высоте 10 м, м/с (NAN — неизвестен) |
| `wind_from_deg` | float | откуда дует, градусы по компасу (0 — с севера, 90 — с востока; NAN) |

**`flight_sample(s)`** — 1 Гц, пока в воздухе:

| ключ | тип | смысл |
|---|---|---|
| `t` | float | время от отрыва, с |
| `pos` | Vector3 | мир, м |
| `alt_msl`, `agl` | float | высота над морем и над рельефом, м |
| `vario` | float | вертикальная скорость, м/с (вверх +), как у прибора |
| `circling` | bool | спираль (как в `FlightStats`: ≥ 8°/с не меньше 3 с) |
| `cloud_base_msl` | float | нижняя кромка кучевых над пилотом/в районе, м (NAN — облаков нет или неизвестно) |
| `sun_elev_deg` | float | высота солнца, градусы (NAN — неизвестна) |
| `others_airborne` | int | сколько других пилотов (живых и ботов) сейчас в воздухе |
| `near_climbing_live` | int | сколько **живых** других пилотов в пределах 200 м по горизонтали с вариометром > 0,5 м/с (по их последним состояниям; не сетевая игра — 0) |

**`flight_finished(fin)`** — по `Game.flight_ended`: все ключи `info` из `flight_ended` (контракт `FlightStats.summary` + `LandingJudge`: `grade`, `vertical_speed_ms`, `horizontal_speed_ms`, `flight_time_s`, `distance_m`, `height_gain_m`, `best_thermal_climb_ms`, `finish_reason`, …) плюс:

| ключ | тип | смысл |
|---|---|---|
| `kind` | String | `"landed"` \| `"takeoff_failed"` (как в `flight_ended`) |
| `land_pos` | Vector3 | точка посадки, мир, м |
| `land_alt_msl` | float | м |
| `others_total` | int | сколько других пилотов (живые + боты) отрывались за этот полёт |
| `others_airborne` | int | сколько из них в воздухе в момент посадки |
| `live_peers` | int | живых пилотов в зоне в момент посадки, кроме себя (не сеть — 0) |

Инварианты: `flight_started` раньше любых `flight_sample`; `flight_finished` — ровно один раз на `flight_started` (выход в меню из полёта без посадки — `flight_finished` не шлётся, полёт не засчитывается); неизвестное — NAN, а не 0.

## S3. Активность игры и Rich Presence (версия 1)

Владелец — ST-7. Потребители — `SteamPresence` (ST-7), лобби (ST-8: ключи `connect`, группа).

Автозагрузка `Activity` (`scripts/core/activity.gd`): `func set_state(d: Dictionary)`, `func state() -> Dictionary`, `signal changed`. Пишут `scenes/main.gd` (меню/загрузка/пауза/итог) и `Game` (фаза пилота) — только при смене значения. Ключи:

| ключ | значения |
|---|---|
| `mode` | `"menu"` \| `"loading"` \| `"launch"` (стоит/идёт/разбег) \| `"flying"` \| `"landed"` \| `"paused"` |
| `place` | отображаемое имя места на языке игры (`tr` ключа места или `RecentPlaces.display_name`), `""` в меню |
| `net` | bool — в сетевой зоне |
| `zone_code` | String, `""` вне зоны |
| `peers` | int — живых пилотов в зоне вместе с собой (вне зоны 0) |
| `alt_msl` | int, м, только в `flying` (для текста «на 1850 м»); обновлять не чаще раза в 10 с и при изменении ≥ 50 м |

`SteamPresence` (`scripts/steam/steam_presence.gd`) переводит в ключи Steam (лимит Steam — не чаще раза в секунду, только изменившиеся ключи): `steam_display` = `#St_<Mode>` или `#St_<Mode>_Net` (токены `#St_Menu`, `#St_Loading`, `#St_Launch`, `#St_Flying`, `#St_Landed`, `#St_Paused` и `_Net`-варианты; в тексте токенов — `%place%`, `%alt%`, `%peers%`), `place`, `alt`, `peers`; при лобби (S5) — `steam_player_group` = id лобби, `steam_player_group_size` = `peers`, `connect` = `+connect_lobby <id лобби>`; вне лобби эти три ключа очищаются. Файл токенов для кабинета — `steam/partner/rich_presence.vdf` (english + russian). На App ID 480 токены не загружены — проверка только через чтение своих ключей.

## S4. Транспорт сети: подключаемые пиры (версия 1)

Владелец — ST-4. Потребители — ST-8 (Steam-транспорт и мост хозяина), существующие тесты `tests/net/`. Протокол (`net.proto`, proto3 JSON) **не меняется**: Steam везёт те же текстовые кадры.

**S4.1. Пир** (утиный тип, `RefCounted`) — одно соединение, кадры — строки UTF-8 (одна строка = один `Envelope`):
```
const CONNECTING := 0, OPEN := 1, CLOSING := 2, CLOSED := 3   # как WebSocketPeer.State
func poll() -> void
func get_state() -> int
func pop_text() -> Variant          # следующий принятый кадр String или null
func send_text(text: String) -> Error
func close(code: int = 1000) -> void
func get_close_code() -> int        # -1 пока не закрыт
```
Реализации: `scripts/net/ws_peer.gd` (обёртка над `WebSocketPeer`, клиент и принятый сервером), `scripts/net/loopback_peer.gd` (пара пиров в памяти для тестов: `static func pair() -> Array`), Steam-пир — ST-8.

**S4.2. Клиент.** `NetClient` работает только через пир. Адрес → пир через реестр:
```
NetClient.register_transport(scheme: String, factory: Callable)   # factory(address: String) -> пир или null
```
Встроенная схема — `ws`/`wss` (и адрес без схемы — как сейчас, `make_url`). ST-8 регистрирует `steam` при активном Steam: адрес `steam:<steam_id64>` — хозяин лобби. Нет фабрики для схемы — `error("CONNECT_FAILED", …)` как при недоступном сервере. Поведение (Hello/Welcome, ping, повторы 1/2/4 с, сигналы) — без изменений.

**S4.3. Встроенный сервер.** `LocalServer.Conn` держит пир S4.1 вместо `WebSocketPeer`. Новый метод:
```
func attach_peer(peer, label: String) -> int    # принять внешнее соединение (уже OPEN или CONNECTING); id соединения, -1 если сервер не запущен
```
Принятое через `attach_peer` проходит тот же путь, что принятое по TCP (Hello первым, таймауты, `ERROR_*`, зоны, пересылка). Потоки: `attach_peer` и методы пира безопасно вызывать из главного потока при `threaded=true` (мьютекс сервера); пир, отданный серверу, сервер и опрашивает. `zones_info()`, LAN-объявления — как были.

**S4.4. Инварианты.** Все тесты `tests/net/` проходят без правок своих ожиданий; трафик и частоты — как в `docs/guide/net-protocol.md`; контрактный тест: клиент ↔ `LocalServer` через `loopback_peer` проходят Hello → CreateZone → JoinZone вторым клиентом → PilotState пересылается.

## S5. Лобби Steam и адресация (версия 1)

Владелец — ST-8. Потребители — ST-7 (ключи присутствия), UI сетевой игры.

- Хозяин: зона на встроенном сервере (`NetZone.host_local`) + при активном Steam — лобби «только друзья», до 16 участников. Данные лобби (строки): `dp` = `"1"` (метка игры), `dp_ver` = версия игры (как `Hello.gameVersion`), `dp_zone` = код зоны, `dp_host` = Steam ID хозяина, `dp_name` = имя пилота хозяина, `dp_place` = имя места.
- Вход: приглашение (оверлей), «Присоединиться» в списке друзей (`connect` из S3), аргумент запуска `+connect_lobby <id>` (`SteamService.launch_lobby_id()`), список «Друзья в игре» на экране сетевой игры → вступить в лобби → `dp_ver` ≠ своей → отказ `version_mismatch` без подключения; иначе `NetClient` по адресу `steam:<dp_host>` → `JoinZone{dp_zone}`.
- Хозяин закрыл зону → выходит из лобби; участник вышел из зоны → выходит из лобби.
- Steam-пиры и LAN/WebSocket-пиры в одной зоне допустимы (сервер один).
- `NetUiBackend` получает (неактивный Steam — пустые/false): `steam_available() -> bool`, `invite_friends()`, `friends_zones() -> Array` (`{lobby_id, friend_name, zone_code, place, same_version}`), `connect_and_join_lobby(lobby_id: int, name: String)`, сигнал `friends_changed`; фальшивый бэкенд тестов — тоже.

## S6. Ачивки: описание и локальный прогресс (версия 1)

Владелец — ST-6. Потребители — ST-10 (файлы для кабинета, документация), отдел ассетов (иконки по `api`).

- `configs/achievements.json`: `{"version": 1, "achievements": [{"api": "ACH_FIRST_FLIGHT", "name": {"ru": …, "en": …}, "desc": {"ru": …, "en": …}, "hidden": false, "rule": {…}}]}`; `api` — `^ACH_[A-Z0-9_]+$`, уникален; `rule` — тип и пороги из раздела «Ачивки» плана (пороги — числа в конфиге, не в коде).
- Прогресс — `user://achievements.json`: `{"version": 1, "unlocked": {"<api>": <unix_s>}, "places": [place_key…], "flights": <int>}`. Трекер работает и без Steam (молча, без UI); при активном Steam — `setAchievement` + `storeStats` при разблокировке и при старте игры для всех локально открытых (идемпотентно).
- `steam/partner/achievements.csv` (генерирует скрипт `tools/steam/partner_files.py` из конфига): `api,name_en,desc_en,name_ru,desc_ru,hidden` — для ручного ввода в кабинет.
- На App ID 480 свои ачивки не существуют: разблокировка проверяется на заглушке/логе, не в Steam.

## S7. Steam Cloud (версия 0) — до решения по итогам ST-1

Набор файлов для облака: `user://configs/*.json`, `user://recent_places.json`, `user://records.json`, `user://achievements.json`, `user://last_flight.json`, `user://tasks/`. Кэши (`terrain_cache`, `map_cache`, `air_nn`) — никогда. Способ (Auto-Cloud или Remote Storage API) — после ST-1 и ответа пользователя; тогда версия 1.
