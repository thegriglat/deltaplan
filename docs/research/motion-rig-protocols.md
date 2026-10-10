---
type: "research"
status: "active"
module: "motion-rig"
updated: "2026-10-10"
summary: "Протоколы платформ подвижности DOF Reality H-серии: что реально принимает вход от «неизвестной» игры (Sim Racing Studio API, UDP 33001), что нет (SimTools, FlyPT Mover); выбор формата пакета"
related: []
conclusion: "Делаем один формат: бинарный UDP-пакет Sim Racing Studio API v102 (236 байт, порт 33001, MIT). SimTools и FlyPT Mover не имеют общего UDP-входа без собственного плагина/кода"
data: "нет"
applied_in: "docs/contracts/motion-rig.md"
---
# Протоколы платформ подвижности (DOF Reality H2/H3/H4R/H6)

Вопрос: как отдать движение дельтаплана из Godot на платформу DOF Reality H4R (4 оси: pitch, roll, yaw, heave) так, чтобы игроку не писать код. Сначала искали generic UDP у SimTools и FlyPT Mover; оказалось, что у производителя есть свой открытый вход. Что не нашлось или не проверено — в конце.

## Что управляет H-серией сейчас

- DOF Reality поставляет платформы с **Sim Racing Studio (SRS)**; FAQ производителя называет SRS программой управления, обновления под новые игры в лицензии: https://dofreality.com/faq/ (FAQ 5, 38). Отдельное «DOF Reality Motion/Professional» не найдено.
- Поддержка SimTools у DOF Reality прекращена в 2023 (со слов пользователя форума, из первых рук не проверено): https://www.xsimulator.net/community/goto/post?id=258427 . Старый переход SimTools → SRS подтверждает пост 2020: https://xsimulator.net/community/goto/post?id=201527 . Но H3 с SimTools у людей работает (через SMC3-контроллер).
- Контроллер H2/H3 — стандартный SMC3; SimHub имеет пресет под контроллер H4: https://manual.simhubdash.com/motion-addon/supported-controllers (про DOF в этом списке — в другой странице, https://manual.simhubdash.com/motion-addon/readme-2 ). У SimHub есть generic UDP только как **выход** на контроллер, не вход.
- Для своих приложений SDK: FAQ 20 — «Unity3D, Unreal, Python → SRS»; репозиторий https://gitlab.com/simracingstudio/srsapi (MIT). Под Linux SRS не работает (FAQ 27).

## Таблица: софт → вход для неизвестной игры

| Софт | Вход для своей игры | Формат | Источник |
|---|---|---|---|
| SRS (родной для DOF) | **SRS API**: UDP на порт 33001 (меняется в config.ini SRS), включить Setup → Telemetry → Capture Telemetry | бинарная структура C, 236 байт, header `api`, версия 102 | https://gitlab.com/simracingstudio/srsapi , https://gitlab.com/simracingstudio/srsapi/-/wikis/Getting-started-with-Unity3D-and-SRS |
| SimTools 2.x | Нет общего UDP-входа: для каждой игры нужен свой Game Plugin (dll), который сам парсит строку; плагины пишут сообщество | пример: текст `S:`…`:E`, поля через `:`, порядок Roll, Pitch, Heave, Yaw, Sway, Surge, Extra1–3; градусы (±180), heave/sway/surge в g, опц. угловые скорости рад/с | https://xsimulator.net/community/goto/post?id=138412 , https://www.xsimulator.net/community/marketplace/sensor-udp-plugin-testing-tool.248 |
| SimTools 3 | не найдено | — | — |
| FlyPT Mover | Общего UDP-источника в документации нет; разработчик сказал, что «generic hook source» в работе, не реализован. Есть готовые источники игр (Aerofly UDP 4321, Condor 2 UDP 55278, IL-2 UDP 4321, DCS Lua, X-Plane, MSFS SimConnect), источник SimTools помечен «в работе». Имитировать чужой формат (Codemasters CM3) возможно | — | https://www.flyptmover.com/mover-3-5/sources , https://www.flyptmover.com/mover-3-5/sources/games , https://xsimulator.net/community/goto/post?id=249706 |

Знаки и величины FlyPT Mover для авиасимов (какие поля шлёт X-Plane/Condor) в документации не найдены; единицы «одинаковые для всех источников», но детали не раскрыты.

## Решение

**Делаем один формат: SRS API v102.** Причины: (1) это штатный вход ПО самого производителя H-серии, игроку нужен только включённый Capture Telemetry; (2) готовый, MIT, есть примеры C#/Python/Unity; (3) SimTools для DOF не поддерживается, а для него нужен чужой dll-плагин; (4) FlyPT Mover не принимает произвольный UDP. Фильтры, washout, масштабы — в SRS, мы шлём физические величины. Отдельный текстовый формат «SimTools-стиля» не делаем; если понадобится SimTools или Mover, это отдельная задача (плагин или эмуляция SRS-пакета).

## Формат пакета (UDP, little-endian, нативное выравнивание C)

Порт по умолчанию 33001 (localhost; broadcast допустим). Источник: README и main.py репозитория srsapi. Без pack(1) размер 236 байт: после `version` — 1 байт выравнивания, после `location` — 2 байта.

| # | Поле | Тип | Значение для дельтаплана |
|---|---|---|---|
| 1 | api_mode | char[3] | `api` |
| 2 | version | uint32 | 102 |
| 3 | game | char[50] | `Deltaplan` |
| 4 | vehicle_name | char[50] | `Hang glider` |
| 5 | location | char[50] | название места старта |
| 6 | speed | float | скорость воздушная/путевая (SRS сам определяет единицы); по README — «wind speed» |
| 7 | rpm, max_rpm | float, float | 0, 0 |
| 8 | gear | int32 | 0 |
| 9 | pitch | float | градусы, ±180 |
| 10 | roll | float | градусы, ±180 |
| 11 | yaw | float | градусы, ±180 (курс) |
| 12 | lateral_velocity | float | поперечная скорость (для traction loss), диапазон -10…10 по README, -2…2 по Python |
| 13 | lateral_acceleration (sway) | float | g |
| 14 | vertical_acceleration (heave) | float | g |
| 15 | longitudinal_acceleration (surge) | float | g |
| 16 | suspension_travel ×4 | float | 0 |
| 17 | wheel_terrain ×4 | uint32 | 0 |

Частота: примеры шлют каждый кадр (Unity `Update`); нормативной частоты и задержек в источниках нет. Практика: 60 Гц (кадр) и выше, лишнего не нужно — не проверено.

## Что неясно и не проверено

- **Знаки** (что положительно у pitch/roll/surge/sway/heave) в документации SRS API не заданы. Unity-пример шлёт углы поворота `rigidbody.rotation.eulerAngles` (мировые!) и предупреждает, что нужен перевод в углы транспорта. Нужно проверить на железе или у игрока; до того — pitch вверх носом +, roll на правое крыло +, ускорения в осях тела в g с ожидаемым знаком проверить в SRS «Telemetry».
- Ускорение: «heave 1 g в покое или 0» (с гравитацией или без) не описано.
- Единицы speed, разброс диапазонов в README и Python.
- Содержимое страниц DOF Knowledge Base (Freshdesk) и supported-games не читалось; в SimTools 3 generic UDP и формат SimTools-источника FlyPT не найдены.
- Поддержка yaw и heave в SRS для H4R не проверена. SRS работает только на Windows: если игра на Linux, SRS на другом ПК в той же сети (UDP на его IP).

## Что настраивает игрок (SRS)

1. Установить SRS (≥1.43.2), подключить платформу, выбрать профиль H4R.
2. Setup → Telemetry → включить Capture Telemetry.
3. В игре указать IP ПК с SRS (127.0.0.1, если на одном) и порт 33001; при смене порта изменить `config.ini` SRS.
4. В SRS подобрать масштабы и washout по осям; игра ничего не фильтрует.

SimTools / FlyPT Mover: поддерживаются только если появятся плагин или эмуляция формата — в этой версии не заявляются.
