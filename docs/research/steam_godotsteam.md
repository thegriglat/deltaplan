---
type: "research"
status: "closed"
module: "steam"
updated: "2026-10-05"
summary: "GodotSteam GDExtension 4.22.1 для Godot 4.7.2: версия, MIT, безопасная проверка синглтона Steam, init-коды, Networking Messages, лобби, Rich Presence, ачивки, Cloud, сборка Steam/itch, macOS"
related: []
conclusion: "Берём GDExtension 4.22.1 (MIT, Steamworks 1.65); одна кодовая база, расширение подключается только в пресете с меткой steam, itch-сборка без аддона; Cloud — Auto-Cloud на 4 файла user://; всё в GDScript через Engine.get_singleton(\"Steam\")"
data: "tools/research/steam/"
applied_in: "контракты steam S1/S4/S5 и задачи ST-2…ST-10 (план docs/plan/steam.md)"
---
# GodotSteam для Deltaplan: что проверено и что рекомендуем

Задача ST-1 модуля steam. Решение пользователя: GodotSteam выбран, альтернативы не рассматриваются; регистрации в Steamworks нет, тесты — на App ID 480 (Spacewar). Все команды воспроизведения и сырые выводы — `tools/research/steam/` (README, `out/`). Что **проверено запуском**, а что **взято из документации** (и потому могло устареть) — помечено: «замер» / «док.».

## Итог и рекомендации

1. **Пакет**: GodotSteam **GDExtension 4.22.1** (Steamworks SDK 1.65, Godot 4.4+), MIT. Загружается в Godot 4.7.2 (замер). Модульная ветка (`gs4221-templates`, свой движок) не нужна и тяжелее (шаблоны 300–480 МБ).
2. **Доступ из кода**: ни одного упоминания идентификатора `Steam` в тексте скриптов — только `Engine.has_singleton("Steam")` и `Engine.get_singleton("Steam")` с вызовами через `.call("метод", …)` / `.get("КОНСТАНТА")` (замер: иначе разбор скрипта без расширения падает). Это и есть единственное место для `SteamService` (контракт S1).
3. **Сборка**: одна кодовая база; расширение лежит в `addons/godotsteam/` (скачивается скриптом, в git не коммитим). Сборка для Steam — пресет с `custom_features="steam"` без исключений; сборка для itch — пресет с `exclude_filter="addons/godotsteam/*"` (замер: в экспорте нет ни `.so`/`.dll`, ни `libsteam_api`, `Steam` не загружается). Одна общая сборка тоже безопасна технически (замер), но тащит `libsteam_api` в сборку не для Steam и лицензионный вопрос с Valve — не рекомендуется.
4. **Сеть**: Steam Networking Messages подходит под наши кадры (JSON ≤ ~2 КБ, 10 Гц): лимит сообщения 512 КиБ, надёжность — флагом, канал — целое число. Нужны `initRelayNetworkAccess()`, `acceptSessionWithUser` по сигналу, опрос `receiveMessagesOnChannel` каждый кадр.
5. **Приглашения**: лобби + оверлей (`activateGameOverlayInviteDialog`), вход к другу — сигнал `join_requested`, а при закрытой игре Steam запускает её с `+connect_lobby <id>` (`getLaunchCommandLine`).
6. **Rich Presence**: `setRichPresence("steam_display", "#Токен")` + файл токенов `.vdf` в кабинете; лимиты — ключ 63, значение 255 байт, ключей 20 (док.) / 30 (константа SDK 1.65) — проектируем под 20.
7. **Cloud**: **Auto-Cloud** на несколько файлов `user://` (меньше кода, нет зависимости от API); Remote Storage API — только если понадобится выбирать, что синхронизировать, из игры. Настройки — только в кабинете (квота, пути).
8. **macOS**: расширение универсальное (`x86_64`+`arm64`), экспорт с Linux проходит и кладёт `.dylib` в `Contents/Frameworks` (замер); нотаризация для Steam не обязательна, Apple Developer Program — 99 USD в год (док. Apple, не проверено).

## Версия, лицензия, состав, размер

| Что | Значение |
|---|---|
| Репозиторий | https://codeberg.org/godotsteam/godotsteam (бывший GitHub `GodotSteam/GodotSteam` теперь только зеркало релизов-шаблонов) |
| Релиз | `v4.22.1-gde`, 2026-09-04; предыдущий `v4.22-gde` (2026-08-22), 4.21-gde (2026-07-30) |
| Требования | Godot 4.4+ (`compatibility_minimum = "4.4"` в `godotsteam.gdextension`); с 4.7.2 работает (замер) |
| Steamworks SDK | 1.65 (таблица совместимости в README аддона: SDK 1.65 ↔ GodotSteam 4.21+) |
| Архив | 27 290 405 байт, sha256 `2b12b349…bfa8f` (закреплён в `fetch_godotsteam.sh`) |
| Лицензия | MIT (`addons/godotsteam/license.md`).  |
| Библиотеки Valve | `libsteam_api.so` / `steam_api64.dll` / `libsteam_api.dylib` — Steamworks SDK, условия — Steamworks SDK Access Agreement; в публичный репозиторий не класть, в itch-сборку не класть |

Размеры в экспорте (замер, release):

| Платформа | Файл расширения | Библиотека Steam | Итого |
|---|---|---|---|
| Linux x86_64 | `libgodotsteam.linux.template_release.x86_64.so` 4,59 МБ | `libsteam_api.so` 0,39 МБ | ~5,0 МБ |
| Windows x86_64 | `libgodotsteam.windows.template_release.x86_64.dll` 3,96 МБ | `steam_api64.dll` 0,32 МБ | ~4,3 МБ |
| macOS universal | `libgodotsteam.macos.template_release.universal.dylib` 6,08 МБ (после подписи) | `libsteam_api.dylib` 0,46 МБ | ~6,5 МБ |

Экспорт кладёт библиотеки **рядом с исполняемым файлом** (Linux/Windows) и в `Contents/Frameworks` (macOS) — не в `.pck` (замер, `out/export_check.txt`). В архиве есть ещё Android, `linux32`, `win32`, `linuxarm64` — в экспорт не идут.

## Безопасная проверка наличия расширения (вопрос 1)

Класс называется **`Steam`**, это синглтон-движковый объект (`ClassDB`-класс `Steam`, `get_class() == "Steam"`). Проверка:

```gdscript
var steam: Object = null
func _init() -> void:
    if Engine.has_singleton("Steam"):
        steam = Engine.get_singleton("Steam")
```

Замер (`probe.sh`, `out/probe.txt`):

| Вариант | Результат |
|---|---|
| Расширение есть, клиента Steam нет | `loaded=true`, `steamInitEx` → `{"status": 2, "verbal": "Cannot create IPC pipe to Steam client process.  Steam is probably not running."}`; игра не падает |
| Расширения нет вовсе | `Engine.has_singleton("Steam") == false`; скрипт без идентификатора `Steam` разбирается и работает, `exit=0` |
| Аддон есть, но потеряна `libsteam_api.so` | в логе три строки `ERROR: Can't open GDExtension dynamic library …`, `loaded=false`, `exit=0` — игра жива |
| Клиент Steam запущен и залогинен | `steamInitEx(480)` → `status=0`; `getPersonaName`, `getSteamID`, `loggedOn()==true` (ник и id в репозиторий не сохраняем) |

Особенности, о которых надо знать:

- **Нельзя** писать `Steam.xxx` напрямую в скрипте, который грузится без расширения: идентификатор `Steam` не объявлен — ошибка разбора (в Godot 4 `Engine.get_singleton` возвращает `Object`; вызовы — через `call`/`get`, константы — через `steam.get("NETWORKING_SEND_RELIABLE_NO_NAGLE")`). Обёртка `SteamService` скрывает это от остальных скриптов.
- Если проект ни разу не импортирован (нет `.godot/extension_list.cfg`), синглтон не загружается даже при наличии аддона. Экспортированная сборка берёт список расширений из `.pck`, поэтому там проблемы нет.
- Первый `godot --headless --import` свежего проекта с расширением завершается SIGABRT при выходе (импорт к этому моменту записан), второй запуск чистый. Для CI — импортировать дважды и не считать первый код возврата.

## Инициализация и callbacks (вопрос 2)

- `steamInitEx(app_id := 0, embed_callbacks := false) -> Dictionary` с ключами `status` и `verbal`. Коды (константы `STEAM_API_INIT_RESULT_*`, замер по `api_dump.json`): **0** — успех, **1** — прочая ошибка, **2** — нет клиента Steam (замер: именно он на машине без Steam), **3** — клиент устарел. `steamInit()` возвращает только bool, `get_steam_init_result()` возвращает последний словарь.
- App ID: аргумент `steamInitEx(480)` (ставит переменные окружения `SteamAppId`/`SteamGameId`), либо `steam_appid.txt` рядом с исполняемым файлом (для тестов; **в сборку для Steam не класть**), либо настройки проекта `steam/initialization/app_id` (док. GodotSteam). В `configs/steam.json` (план) — наш способ. Без клиента код результата всё равно 2 (замер с `app_id=0`).
- `Steam.run_callbacks()` нужно вызывать **каждый кадр** в автозагрузке, которая не ставится на паузу (док.: на паузе колбэки не приходят). Альтернатива — `embed_callbacks=true` в `steamInitEx`; в 4.14 был сломан, поэтому берём явный `run_callbacks()` из `_process`.
- Выключение: `steamShutdown()` есть (замер по списку методов); `isAPIInitialized` отдельного метода нет — состояние держим сами.
- Проверка владения: `isSubscribed()`, `isSubscribedFromFamilySharing()`, `isSubscribedFromFreeWeekend()` — экран «купите игру» не делаем (док. предупреждает о Family Share).
- **`restartAppIfNecessary(app_id)`** (метод есть): для сборки Steam вызывать **до** `steamInitEx`; `true` означает «выйти, Steam перезапустит игру через клиент». Пока нет собственного App ID, вызывать нельзя (с 480 игра будет перезапускаться как Spacewar!). Рекомендация: не вызывать совсем — игра бесплатная/добровольная и без защиты от копирования; запуск вне Steam просто даёт `status=2` и «Steam неактивен».

## Steam Networking Messages (вопрос 3)

Методы и сигналы сняты из расширения (`api_dump.json`), смысл — из документации.

| API | Сигнатура (замер) | Замечание |
|---|---|---|
| отправка | `sendMessageToUser(remote_steam_id: int, data: PackedByteArray, flags: int, channel: int) -> int` | результат `RESULT_OK=1`, `RESULT_NO_CONNECTION=3` (сессия закрыта и нет флага `NETWORKING_SEND_AUTORESTART_BROKEN_SESSION=32`); подтверждения доставки нет — отвечать должен пир |
| приём | `receiveMessagesOnChannel(channel: int, max_messages: int) -> Array` | элементы: `payload` (PackedByteArray), `size`, `identity` (Steam ID отправителя), `channel`, `flags`, `connection`, `message_number`, `time_received`; опрашивать каждый кадр |
| сессии | `acceptSessionWithUser(id)`, `closeSessionWithUser(id)`, `closeChannelWithUser(id, ch)`, `getSessionConnectionInfo(id, get_connection, get_status)` | `get_status` даёт ping, `local_quality`, `bytes_out_per_second`, очередь |
| сигналы | `network_messages_session_request(remote_steam_id)`, `network_messages_session_failed(reason, remote_steam_id, connection_state, debug_message)` | на запрос — `acceptSessionWithUser` (или первый же `sendMessageToUser` в ответ принимает неявно); тайм-аут простоя сессии отдельного сигнала не даёт |
| реле | `initRelayNetworkAccess()`, `getRelayNetworkStatus()`, сигнал `relay_network_status(available, ping_measurement, available_config, available_relay, debug_message)` | Steam Datagram Relay включается сам; вызвать `initRelayNetworkAccess()` при старте Steam-режима |
| массовая | `sendMessages(connection_handle, messages: Array, flags, delete_failed_messages)` | это Networking Sockets (с 4.21 новый параметр); для Messages не нужна |

Флаги (константы, замер): `NETWORKING_SEND_UNRELIABLE=0`, `NETWORKING_SEND_NO_NAGLE=1`, `NETWORKING_SEND_NO_DELAY=4`, `NETWORKING_SEND_RELIABLE=8`, `NETWORKING_SEND_RELIABLE_NO_NAGLE=9`, `NETWORKING_SEND_UNRELIABLE_NO_DELAY=5`, `NETWORKING_SEND_AUTORESTART_BROKEN_SESSION=32`. 

**Размер**: `MAX_STEAM_PACKET_SIZE = 524288` (512 КиБ) на сообщение; Steam сам фрагментирует и собирает, и для надёжных, и для ненадёжных. Наш кадр (JSON ≤ ~2 КБ) помещается одним сообщением с огромным запасом, а при 10 Гц и пире это ≈20 КБ/с на пира — ничтожно.

**Рекомендация транспорта** (для S4/ST-8): канал `0` — управление/рукопожатие (`RELIABLE_NO_NAGLE`), канал `1` — позиции (`UNRELIABLE_NO_DELAY`, устаревшее кадр можно терять), кадры `Envelope` как есть, текст JSON → UTF-8 → `PackedByteArray`. Декодировать только `JSON.parse_string`, не `bytes_to_var_with_objects` (риск выполнения кода — предупреждение документации GodotSteam). Порядок: надёжные на одном канале приходят ровно один раз и по порядку; между каналами порядка нет.

Проверка «самому себе» (`live.sh`): петля работает, кадр 2020 байт дошёл целиком (раздел «Что проверено на App ID 480»). Реальную связь двух аккаунтов одним аккаунтом проверить нельзя — нужен ручной тест пользователя.

## Лобби, приглашения, вход к другу (вопрос 4)

Методы (замер; все приняты расширением): `createLobby(lobby_type, max_members)` (асинхронно, сигнал `lobby_created(connect, lobby_id)`, `connect==1` успех), `joinLobby(lobby_id)` → `lobby_joined(lobby, permissions, locked, response)`, `leaveLobby`, `setLobbyData(lobby, key, value)` / `getLobbyData`, `setLobbyMemberData` / `getLobbyMemberData(lobby, user_id, key)`, `getNumLobbyMembers`, `getLobbyMemberByIndex`, `getLobbyOwner`, `setLobbyJoinable`, `setLobbyMemberLimit`, `setLobbyType`, `requestLobbyList` (+ `addRequestLobbyList*Filter`) → сигнал `lobby_match_list(lobbies)`, сигналы `lobby_data_update(success, lobby_id, member_id)`, `lobby_chat_update(lobby_id, changed_id, making_change_id, chat_state)` (вход/выход участников), `lobby_kicked`.

Типы (`LOBBY_TYPE_*`): `PRIVATE=0`, `FRIENDS_ONLY=1`, `PUBLIC=2`, `INVISIBLE=3`, `PRIVATE_UNIQUE=4`. Лимиты (док. + константы): участников ≤ **250**; ключ данных ≤ `MAX_LOBBY_KEY_LENGTH = 255`, значение < `CHAT_METADATA_MAX = 8192` байт (замер: 8192 байта отклонено, предел 8191).

Приглашение и вход:

- Пригласить: `activateGameOverlayInviteDialog(lobby_id)` (оверлей со списком друзей) или `inviteUserToLobby(lobby_id, steam_id)`. Оверлей в запуске из редактора может не работать — только в собранной игре из клиента Steam (README аддона).
- Принять, **игра запущена**: сигнал **`join_requested(lobby_id, steam_id)`** (так в GodotSteam называется `GameLobbyJoinRequested_t`; сигнала `lobby_join_requested` в 4.22.1 **нет**) → сами вызываем `joinLobby`.
- Принять, **игра закрыта**: Steam запускает её с аргументом **`+connect_lobby <64-битный id лобби>`**. Читать из `OS.get_cmdline_args()` (или `getLaunchCommandLine()`), искать `+connect_lobby`. Документация Valve просит реализовать `GetLaunchCommandLine` ради подавления предупреждения клиента — достаточно вызвать его при старте.
- Альтернатива через Rich Presence: ключ `connect` = `"+connect_lobby <id>"` даёт кнопку «Присоединиться» в списке друзей; при запущенной игре приходит сигнал `join_game_requested(user, connect)`.
- Список лобби друзей: `getFriendCount` / `getFriendByIndex` / `getFriendGamePlayed(id)` → словарь с полем `lobby` (для видимых лобби).
- С обеих сторон нужна одна и та же сборка: лобби в других App ID не видны.

## Rich Presence (вопрос 5)

Вызов: `setRichPresence(key, value) -> bool`, `clearRichPresence()`, чтение — `getFriendRichPresence(steam_id, key)`, `getFriendRichPresenceKeyCount`, сигнал `friend_rich_presence_update(steam_id, app_id)`.

- Особые ключи: **`steam_display`** — имя токена локализации (иначе текст в списке друзей не показывается); `steam_player_group` / `steam_player_group_size` — группировка игроков; `connect` — командная строка «присоединиться»; `status` — старый вариант.
- Лимиты (замер: константы расширения): ключ ≤ **63**, значение ≤ **255** байт (константы `MAX_RICH_PRESENCE_KEY_LENGTH=64`, `MAX_RICH_PRESENCE_VALUE_LENTH=256` включают нулевой байт: замер — 256 байт значения отклонено), ключей `MAX_RICH_PRESENCE_KEYS = 30` (SDK 1.65; страница ISteamFriends ещё говорит про 20 — проектировать под **20**; замер: принято 28). Превышение — `false`.
- Токены: имя начинается с `#`, буквы/цифры/подчёркивание; подстановки `%ключ%` (ключ из букв, цифр, `_`, `:`), вложенная локализация `{#Status_%gamestatus%}`; нет токена в языке — фолбэк на английский; нет английского или не задан ключ подстановки — **ничего не показывается**.
- Файл для кабинета (Steamworks → Edit Steamworks Settings → Community → Rich Presence), `.vdf`, по языкам, можно все языки в одном файле (грузятся только присутствующие; после загрузки нужно **опубликовать** изменения):

```
"lang"
{
	"english"
	{
		"tokens"
		{
			"#Status_InMenu"    "In the menu"
			"#Status_Flying"    "Flying: %site%"
			"#Status_Multi"     "Flying together (%players% pilots)"
		}
	}
}
```

  (в документации GodotSteam показан вариант с `"Language" "english"` и `"Tokens"` — кабинет принимает формат Valve выше; проверить загрузкой нельзя без регистрации).
- Проверка результата: https://steamcommunity.com/dev/testrichpresence (после входа в Steam; нужен загруженный файл токенов своего App ID). **На 480 свои токены не загрузить** — проверка только вызовом `setRichPresence` (возвращает `true`) и чтением своих ключей (`live.sh`).

## Ачивки и статистика (вопрос 6)

- API (замер): `setAchievement(name)`, `getAchievement(name)` (**возвращает словарь** `{ret, achieved}`), `clearAchievement(name)` (только для тестов), `storeStats()`, `setStatInt/Float`, `getStatInt/Float`, `indicateAchievementProgress(name, current, max)` (всплывающее «прогресс»), `getNumAchievements`, `getAchievementName(i)`, `getAchievementDisplayAttribute(name, "name"|"desc"|"hidden")`, `getAchievementAndUnlockTime`, `resetAllStats(achievements_too)`. Сигналы `user_stats_stored(game_id, result, user_id)`, `user_achievement_stored(game_id, group_achieve, name, current, max)`, `user_stats_received`.
- С SDK 1.61 клиент сам подтягивает статистику на старте: `requestCurrentStats()` и сигнала `current_stats_received` **нет** (замер: метода нет) — `steamInitEx`, затем сразу `setAchievement`.
- `setAchievement` меняет состояние только в памяти; на сервер уходит `storeStats()` (после серии изменений, не на каждый кадр). Сигнал `user_achievement_stored` подтверждает.
- Прогресс-ачивки: в кабинете у ачивки задаётся «Progress Stat» (статистика INT/FLOAT/AVGRATE) и значение разблокировки — ачивка откроется сама, когда статистика достигнет значения. Для нас проще: считать условие в игре (`AchievementTracker`) и вызывать `setAchievement`; статистика — только чтобы показывать полоску прогресса в Steam (`setStatInt` + `storeStats`).
- Что задаётся в кабинете для каждой ачивки: API Name (строка, регистр важен), Display Name, Description (локализуются), Hidden, иконки «получена» и «не получена» (картинки), Progress Stat, Min/Max. Лимит: по умолчанию **100** ачивок на игру. Названия и иконки — для всех возрастов (правило Valve).
- Формата массовой загрузки в кабинет нет (ввод через форму; Valve выгружает схему сама). Подготовить заранее можно таблицу `api_name, display_name_en, display_name_ru, desc_en, desc_ru, hidden, progress_stat, progress_max` — по ней вводить руками (план: `steam/partner/achievements.csv`, ST-10). Иконки ведёт другой координатор.
- **На App ID 480 свои ачивки не заведёшь**: у Spacewar свои — `ACH_WIN_ONE_GAME`, `ACH_WIN_100_GAMES`, `ACH_TRAVEL_FAR_ACCUM`, `ACH_TRAVEL_FAR_SINGLE` (док. Valve) и статистики `NumGames`, `NumWins`, `NumLosses`, `FeetTraveled`, `MaxFeetTraveled`, `AverageSpeed`. Разблокировка чужой ачивки меняет настоящий профиль тестировщика — **в проверках не делали**; `getAchievement`/`getStatInt` читать можно. Вывод: логику ачивок тестируем без Steam (контракт S2, подставной API), в Steam — после регистрации.

## Steam Cloud: Auto-Cloud против Remote Storage (вопрос 7)

Что у нас пишется в `user://` (`grep` по `scripts/`): `configs/` (настройки), `records.json`, `last_flight.json`, `recent_places.json`, `tasks/`, плюс **кеши** (`terrain_cache`, `map_cache`, `air_nn/model.onnx`, `atmo_fingerprint.txt`) — кеши в Cloud не нужны. Пути `user://`: при `config/use_custom_user_dir=true` и `custom_user_dir_name="Deltaplan"` (наш проект; замер) это

| ОС | Каталог |
|---|---|
| Windows | `%APPDATA%\Deltaplan\` (то есть `AppData\Roaming\Deltaplan`) |
| Linux | `$XDG_DATA_HOME/Deltaplan/` (замер: при заданном `XDG_DATA_HOME`; иначе `~/.local/share/Deltaplan/`) |
| macOS | `~/Library/Application Support/Deltaplan/` (док. Godot) |

| | Auto-Cloud | Remote Storage API (`fileWrite`/`fileRead`) |
|---|---|---|
| Код | не нужен; только настройка в кабинете | `fileWrite(name, PackedByteArray, size)`, `fileRead(name, size) → {ret, buf}`, `fileExists`, `fileDelete`, `getFileCount`, `getQuota`, `isCloudEnabledForApp/Account` (замер: все есть и работают на 480) |
| Где файлы | обычные файлы в `user://`, Steam синхронизирует при запуске/выходе игры | Steam хранит копию в своей папке; свои обычные файлы нужно дублировать |
| Гибкость | пути-маски, корни по ОС | полный контроль, но всё руками (в т.ч. конфликты) |
| Предел файла | — (см. квоту) | 100 МиБ на запись (`MAX_CLOUD_FILE_CHUNK_SIZE`) |
| Квота | в кабинете: байт на пользователя и число файлов | та же |
| Риск для нас | настройки, зависящие от машины (видео, разрешение), поедут на другой ПК — файл `configs/` надо разделить на «общее» и «локальное» | то же + код |

Auto-Cloud в кабинете: Steamworks → App Admin → Cloud → «Steam Auto-Cloud». Корень (Root) — из списка (`WinAppDataRoaming`, `LinuxXdgDataHome`, `MacAppSupport`, …), подкаталог и маска файлов (+ флаг «рекурсивно»). Для переносимости между ОС — **один корень «All OSes» + Root Overrides** для каждой ОС (иначе файлы разделятся по платформам): `WinAppDataRoaming` / `Deltaplan` и переопределения для `LinuxXdgDataHome` / `Deltaplan` и `MacAppSupport` / `Deltaplan`. Квоту и число файлов нужно задать обязательно (иначе секция Auto-Cloud не открывается), потом **опубликовать**.

**Рекомендация**: Auto-Cloud на: `records.json`, `last_flight.json`, `recent_places.json`, `tasks/*.json`, общие настройки (после разделения `configs/` на общее/локальное). Кеши и модели не синхронизировать. Квота: 1 МиБ и 20 файлов — с запасом. Код для Cloud в Auto-Cloud не нужен; в игре — переключатель «использовать Steam Cloud» через `setCloudEnabledForApp` (по требованию Valve — только по явному выбору пользователя).

**Cloud на 480 работает** через Remote Storage API (замер: запись/чтение/удаление, квота 4 КиБ); Auto-Cloud на 480 не настроить.

## Сборка со Steam и без (вопрос 8)

Эксперимент `export_check.sh`: временный проект с аддоном, три пресета Linux release, плюс Windows и macOS (состав). Результаты (`out/export_check.txt`):

| Пресет | Состав экспорта | Запуск |
|---|---|---|
| `steam`: метка `steam`, фильтров нет | `game.pck`, исполняемый, `libgodotsteam…release…so`, `libsteam_api.so` | `loaded=true`, `init=2` (клиента нет), `OS.has_feature("steam")==true` |
| `plain`: `exclude_filter="addons/godotsteam/*"` | `game.pck`, исполняемый (библиотек **нет**) | `loaded=false`, ошибок нет |
| `noexcl`: фильтров нет, метки нет | как `steam` | `loaded=true`, `init=2`, `has_feature("steam")==false` |
| Windows (steam) | `game.exe`, `game.pck`, `libgodotsteam.windows.template_release.x86_64.dll`, `steam_api64.dll` | — (запустить нельзя) |
| macOS (steam, universal, ad-hoc подпись) | `.app/Contents/Frameworks/libsteam_api.dylib`, `libgodotsteam.macos.template_release.universal.dylib`; зип собирается на Linux | — |

Вывод для ST-3:

- **Рекомендуемая схема**: два набора пресетов (Linux/Windows/macOS × «itch» и «steam»). «itch» — как сейчас, плюс `exclude_filter` дополняется `addons/godotsteam/*` (в существующих пресетах `exclude_filter="tests/*, tools/*, docs/*, site/*, data/terrain/reference/*"`). «steam» — `custom_features="forced_dd3d,steam"`, без исключения аддона. Метка `steam` управляет `SteamService`: активен, если `OS.has_feature("steam")` или аргумент `--steam` **и** синглтон загружен. Файлы `steam_appid.txt` в сборку не класть.
- Аддон-каталог `addons/godotsteam/` должен быть в `.gitignore` (и `*.uid` его скриптов — по правилам репозитория); перед экспортом Steam-пресета запускать `fetch_godotsteam.sh` (идемпотентно, sha256).
- Запуск Steam-сборки вручную без клиента: `steamInitEx` → 2, сервис «неактивен», игра обычная.
- Единая сборка для всех (пресет без исключений) технически безопасна (строка `noexcl`), но кладёт распространяемые библиотеки Valve в сборку не для Steam; условия SDK Access Agreement тут не проверены — поэтому рекомендуем разные пресеты.
- Редактор и debug-экспорт берут `template_debug`-библиотеку, release-экспорт — `template_release` (замер: в `--export-release` в каталоге лежит именно release-вариант).

## macOS (вопрос 8)

- Бинарники универсальные (`osx/*.dylib`, `x86_64+arm64`), в экспорте Godot лежат в `Contents/Frameworks` (замер); подпись при `codesign/codesign=1` ad-hoc выполняется самим Godot (размер dylib после экспорта вырос на ~110 КБ — подписи).
- Для игры, доставляемой через Steam, Gatekeeper обычно не срабатывает (нет атрибута карантина), поэтому нотаризация формально не обязательна; для arm64 подпись (хотя бы ad-hoc) обязательна. Для настоящей подписи Developer ID и нотаризации нужен Apple Developer Program — **99 USD/год** (док. Apple; не проверено, так как macOS-машины нет). Текущий macOS-пресет игры уже `codesign=1`, `notarization=0`.
- Для macOS в Steam нужно отдельное депо с `.app` (задача сборки/депо, не ST-1).
- Проверить загрузку расширения на macOS на этой машине нельзя.

## Что проверено на App ID 480

Источники — `tools/research/steam/out/` (`probe.txt`, `probe_with_client.txt`, `live.txt`). Клиент Steam на этой машине запущен не всё время (его запускал пользователь); результаты с клиентом получены в окна, когда он работал.

Запуск `live.sh` при работающем клиенте (`out/live.txt`, 2026-10-05), App ID 480, один аккаунт. Ничего необратимого: ачивки и статистика только читались, Rich Presence очищен, Cloud-файл удалён, лобби закрыто.

| Область | Результат (замер) |
|---|---|
| Инициализация | `steamInitEx(480)` → `status=0`; `getLaunchCommandLine()` пуст; `isSubscribed()==true`; `getAppBuildId()==0`; язык интерфейса `russian` |
| Rich Presence | `setRichPresence` → `true` для обычного ключа и для `steam_display` с неизвестным токеном; ключ 65 байт → `false`; значение 257 → `false`; **значение 256 байт → `false`** (предел фактически **255**, 256 с нулевым байтом); чтение своего ключа `getFriendRichPresence(me, key)` вернуло записанное; после `clearRichPresence()` ключей 0. Принято 28 ключей из 42 попыток (`getFriendRichPresenceKeyCount` показал 44 — считает и служебные ключи клиента), т.е. потолок в районе 30, а не 20; проектируем под ≤ 20 |
| Ачивки | у 480 пять: `ACH_TRAVEL_FAR_ACCUM`, `ACH_TRAVEL_FAR_SINGLE`, `ACH_WIN_100_GAMES`, `ACH_WIN_ONE_GAME`, `NEW_ACHIEVEMENT_0_4`; **`getAchievement(name)` возвращает словарь** `{"ret": bool, "achieved": bool}` (для несуществующей ачивки `ret=false`); `getStatInt("NumGames")` читается сразу после init |
| Cloud (Remote Storage API) | **работает**: `isCloudEnabledForAccount/ForApp` → `true`; `getQuota()` → `{total_bytes: 4096, available_bytes: 4096}` (у Spacewar квота всего 4 КиБ); `fileWrite` → `true`, `fileExists` → `true`, `fileRead(name, 15)` → `{ret: 15, buf: [...]}`, `fileDelete` → `true`, `getFileCount` 0 → 0. Auto-Cloud на 480 проверить нельзя (настраивается в кабинете) |
| Лобби | `createLobby(PRIVATE, 4)` → сигнал `lobby_created(1, id)` (id вида 1097…, 17 цифр); `setLobbyData`/`getLobbyData` — работает; **значение 8192 байт отклонено (`false`), значит предел 8191**; `setLobbyMemberData` возвращает `null` (void), `getLobbyMemberData` → записанное; `getNumLobbyMembers==1`, владелец — я; сигналы `lobby_joined` (создатель входит сам) и `lobby_data_update` приходят |
| Networking Messages «себе» | кадр 2020 байт (JSON ≈2 КБ), `sendMessageToUser(me, …, RELIABLE_NO_NAGLE, 0)` → `1`; пришли `network_messages_session_request` (для себя) и сообщение `receiveMessagesOnChannel(0)`: `size=2020`, `identity` — мой id, `flags=8` (надёжное), `channel=0`; затем `network_messages_session_failed(reason=0, state=4 "The remote host closed the connection")` — артефакт петли на себя. Реальная связь двух машин, реле и задержка **не проверены** |

Вывод: на 480 проверяются вызовы лобби, Cloud API, Rich Presence (ключи), чтение ачивок и петля Networking Messages; не проверяются: свои ачивки и токены (нужен свой App ID), приглашения, оверлей, двухстороннее соединение.

## Что нужно от пользователя в Steamworks

1. Регистрация партнёра Steamworks (Steam Direct, взнос **100 USD** за приложение — док. Valve, не проверялось), налоговая и банковская анкеты; на это уходит время.
2. App ID приложения → `configs/steam.json` (место под значение — по плану).
3. Загрузить в кабинет: токены присутствия (`.vdf`, раздел выше; после загрузки — Publish); ачивки и статистики (вручную по таблице; иконки — от направления ассетов); Cloud: квота (байт и число файлов), Auto-Cloud корни + переопределения ОС (раздел выше) — и всё это **опубликовать**.
4. Депо и билды (Linux/Windows/macOS) — `steamcmd`, отдельная задача.
5. Ручной тест сети и лобби на двух аккаунтах/компьютерах: одним аккаунтом это не проверить.

Что можно подготовить заранее без регистрации: `rich_presence.vdf`, `achievements.csv`, перечень Cloud-путей и маски, `configs/steam.json` с заглушкой, `.gitignore` для `addons/godotsteam/`, пресеты экспорта.

## Не проверено (честно)

- Лобби с двумя аккаунтами, реальный обмен Networking Messages между машинами, оверлей приглашений, `+connect_lobby`: требует второго аккаунта/клиента и собранной игры из Steam.
- Загрузка файла токенов Rich Presence и отображение в списке друзей: нужен собственный App ID.
- Auto-Cloud: настраивается только в кабинете своего App ID.
- Windows и macOS: загрузка расширения не запускалась (нет ОС), проверен только состав экспорта.

## Источники

- GodotSteam: https://codeberg.org/godotsteam/godotsteam (релиз `v4.22.1-gde`), документация https://godotsteam.com (исходники https://codeberg.org/godotsteam/godotsteam-docs: tutorials `initializing`, `networking_messages`, `rich_presence`, `stats_achievements`, `friends_lobbies`; classes `networking_messages`, `remote_storage`, `matchmaking`).
- Steamworks: https://partner.steamgames.com/doc/features/enhancedrichpresence, `/doc/api/ISteamFriends` (SetRichPresence, Rich Presence Localization, GameLobbyJoinRequested_t), `/doc/api/ISteamMatchmaking`, `/doc/api/ISteamNetworkingMessages`, `/doc/api/ISteamRemoteStorage`, `/doc/features/cloud`, `/doc/features/achievements`, `/doc/features/multiplayer/matchmaking` (страницы читаются без входа; прочитаны 2026-10-05).
- Воспроизведение: `tools/research/steam/README.md`.
