---
type: "research"
status: "closed"
module: "motion-rig"
area: "game"
updated: "2026-10-15"
summary: "SimHub не читает SRS и DPMR; путь — «External sim integration» (simdef + UDP 55 байт заголовка, бета, Windows); не реализовано."
related: ["docs/research/motion-rig-protocols.md", "docs/guide/motion-rig.md", "docs/contracts/motion-rig.md"]
conclusion: "SRS v102 и DPMR SimHub не читает. Минимальный путь — третий формат вывода «SimHub external»: своё описание игры (.simdef) + UDP-пакет 55 байт заголовка и поля по порядку simdef на 127.0.0.1:порт из simdef, ≥60 Гц, без плагина и SDK. Оценка: 1-2 дня (формат + simdef, сгенерированный в редакторе SimHub, + проверка на Windows). Риск: функция в бете, Windows-only, не проверено на живом SimHub"
data: "нет"
applied_in: "не применено: в scripts/motion_rig/ только форматы srs и generic (DPMR), вывода SimHub нет"
---
# SimHub: что нужно, чтобы игра работала

> Состояние на main (2026-10-15): вывод для SimHub не реализован — в `scripts/motion_rig/` только форматы `srs` и `generic` (DPMR). Спецификация ниже — вход для будущей задачи.

Вопрос: у нас есть форматы `srs` (Sim Racing Studio API v102, UDP 33001) и `generic` (DPMR, 64 байта). Владелец DOF Reality: «couldn't get it to run with my SimHub». Что нужно для SimHub (Motion, ShakeIt, Wind). Исследование по веб-источникам, без запуска SimHub (у нас нет Windows-стенда): всё, что ниже помечено «выведено», взято из чужого кода, а не из официальной спецификации.

## 1. Короткий ответ

- SimHub **не** принимает пакет SRS API v102 и **не** принимает DPMR. Общего «generic UDP» входа в документации не нашлось. Для каждой игры SimHub нужно описание (definition) и свой набор читалок; поиск по официальному мануалу и вики такого общего входа не показал (отрицательный результат: «не нашёл», а не «точно нет»).
- Есть **официальный путь для сторонних игр: «External sim integration»** (бета, SimHub 9.11.5 и новее): файл описания `*.simdef` + бинарный UDP-пакет, который шлёт сама игра (или внешний «экстрактор»). Плагин на C# и SDK для этого не нужны. Источник: https://manual.simhubdash.com/external-sim-integration
- «Притвориться» авиасимом не годится: X-Plane, MSFS и Condor читаются встроенными читалками из своих API (см. п. 4), а не общим форматом.
- Рекомендация: добавить третий формат вывода `simhub` (см. п. 6). Это 1-2 дня работы и один тест на Windows с SimHub у пользователя.

## 2. Что говорит официальный мануал (External sim integration)

Источник: https://manual.simhubdash.com/external-sim-integration (прочитано целиком, но схема simdef и раскладка пакета там не приведены, они восстановлены из примеров, п. 3).

- Бета: «Some breaking changes in the telemetry contract may still occur». Нужен SimHub 9.11.5+.
- `*.simdef` описывает: имя, иконку, UniqueId; процесс для автоопределения (имя без `.exe`); формат телеметрии (порт UDP по умолчанию, набор полей). Обычно поставляется вместе с игрой.
- Объявлять нужно только те поля, которые игра реально отдаёт: от набора объявленных полей зависят доступные функции.
- Пакет: бинарный UDP с заголовком для идентификации. Редактор определений в SimHub (включается в настройках, Global, game definition authoring) генерирует код отправки на C# и C++ (кнопка «copy demo code»), там же «Telemetry Receiver Tester» для проверки приёма.
- Частота: «SimHub requires a minimum of 60Hz data for a correct fidelity».
- Регистрация: файл `%localappdata%\SimHub\ExternalSims\Registrations\{UniqueId}.shlink` с абсолютным путём к `.simdef` (имя файла = UniqueId; в тексте мануала встречается и `.simlink`, расширение расходится, проверить на живом SimHub), либо, запасной вариант, положить `.simdef` в `%localappdata%\SimHub\ExternalSims\Definitions\<Имя>\`. Затем игру надо выбрать в списке игр SimHub.
- Необязательный «экстрактор»: внешний процесс, который SimHub сам запускает и останавливает (поля `UseExtractorProcess`, `ExtractorProcessCommand` в simdef). Нужен только если игра не умеет слать пакет сама.

## 3. Спецификация пакета (ВЫВЕДЕНА из кода сторонних проектов)

Источники (открытый код, оба сгенерированы редактором SimHub 9.11.x):
- Galactic Racer UEVR: https://github.com/elliotttate/galactic-racer-uevr-motion (файлы `src/SimHubGenerated.hpp`, `simhub/GalacticRacer.generated.cpp`, `simhub/GalacticRacer.simdef`). Игра шлёт пакет сама, без экстрактора.
- FlatOut 4 VR: https://github.com/Dteyn/FlatOut4VR-SimHub (MIT; `simdef/FlatOut4VR.simdef`, `docs/ARCHITECTURE.md`, `docs/FLATOUT-4-VR-TELEMETRY.md`). Экстрактор `extractor.exe`, SimHub запускает его сам.

Транспорт: UDP, одна датаграмма на кадр, на `127.0.0.1:DefaultUDPPort` (в примерах 20778 и 30777; порт задаёт simdef, у нас выберем свой). Порядок байт: little-endian, структура упакована (`#pragma pack(1)`, без выравнивания), размер пакета = 55 + сумма размеров объявленных полей (проверка в генераторе: `static_assert(sizeof == ExpectedPacketLength)`; пакет другой длины считаем отвергаемым, выведено).

Заголовок, 55 байт, одинаков у обоих примеров:

| Смещение | Тип | Поле | Смысл |
|---|---|---|---|
| 0 | u32 | GameSignature | должен совпасть с simdef |
| 4 | u32 | TelemetrySignature | идентичность схемы (игра + набор полей); значение даёт SimHub |
| 8 | u16 | LayoutMajorVersion | растёт при удалении/перестановке полей |
| 10 | u16 | LayoutMinorVersion | растёт при добавлении полей в конец |
| 12 | u64 | EmitterInstanceId | случайное, один раз на запуск, не 0 |
| 20 | u8 | PacketId | пока всегда 0 |
| 21 | u64 | PacketsCounter | монотонный счётчик пакетов; слать и на паузе |
| 29 | u8 | IsSessionRunning | 1 если сессия идёт |
| 30 | u8 | IsSessionPaused | 1 если пауза |
| 31 | u64 | SessionId | меняется при новой сессии, можно случайное |
| 39 | u8 | IsReplay | 1 если воспроизведение (Motion может отключаться) |
| 40 | u8 | IsUserInControl | 1 если пилот управляет |
| 41 | u8 | IsAIInControl | 0 |
| 42 | u8 | IsSpectator | 0 |
| 43 | f64 | SessionTimeSeconds | время сессии, с |
| 51 | u32 | PhysicsDiscontinuityCounter | +1 при разрыве физики (телепорт, рестарт, перемотка) |

Далее поля в **порядке списка `Fields` из simdef**, типы по `FieldType` (стандартные поля; f32 если не указано иное). Единицы и знаки взяты из комментариев сгенерированного кода SimHub:

| Поле | Тип | Единицы | Знак/смысл |
|---|---|---|---|
| YawDegrees | f32 | градусы | курс, 0 = север, плюс по часовой (90 = восток) |
| PitchDegrees | f32 | градусы | **плюс — нос ВНИЗ** (у нас нос вверх положителен: знак менять) |
| RollDegrees | f32 | градусы | плюс — наклон вправо |
| YawRateDegreesPerSecond | f32 | °/с | плюс — вправо (по часовой) |
| PitchRateDegreesPerSecond | f32 | °/с | плюс — нос вниз |
| RollRateDegreesPerSecond | f32 | °/с | плюс — вправо |
| LocalSurgeMs2 | f32 | м/с^2 | плюс — ускорение вперёд |
| LocalSwayMs2 | f32 | м/с^2 | плюс — вправо |
| LocalHeaveMs2 | f32 | м/с^2 | плюс — вверх, **без гравитации** |
| LocalVelocityForwardMps / LateralMps / UpMps | f32 | м/с | вперёд / вправо / вверх |
| VehiclePositionNorth / East / Up | f64 | м | мировая позиция |
| SpeedKmh, GroundSpeedKmh | f32 | км/ч | скорость (по воздуху / по земле) |

Остальные стандартные поля (двигатель, педали, передача, круги, подвеска) нам не нужны и не объявляются. Пользовательские поля (`CustomTelemetryField`, тип в `BinaryType`: 2 = u8, 6 = u32, 8 = f32 по примеру Galactic Racer) попадают в SimHub как свойства, но внутри не используются (мануал).

Соответствие нашим величинам (docs/contracts/motion-rig.md): наша боковая и продольная силы — удельная сила в осях тела, в SimHub ускорение «вперёд/вправо/вверх без гравитации». Для SimHub heave = удельная сила по вертикали минус 1 g (у нас уже так в формате `srs`, это то же), но знак «вверх» должен быть проверен на платформе: у нас положительный heave «прижимает к сиденью», то есть направлен вверх относительно тела, что совпадает; surge/sway такие же как у нас. Pitch и скорость тангажа — со сменой знака. Значения не подтверждены на железе, как и знаки surge/sway/heave в формате `srs`.

### Что не удалось узнать (не угадываем)

- **Алгоритм вычисления `GameSignature`/`TelemetrySignature`** не опубликован; мануал говорит «never change it, they are recomputed on load». Значит simdef надо один раз создать в редакторе SimHub на Windows, сохранить и взять оттуда числа и сгенерированный `SimHubGenerated.hpp`-аналог. Руками сигнатуры не считаем.
- Что значит `GameFamily: 1` в `TelemetryBehaviour` (в обоих примерах гоночные игры) и есть ли значение для авиации — не нашёл. Возможно, влияет на встроенные эффекты (кочки, ABS). Для самолётных/дельтапланных значений выставить в редакторе вручную.
- Полный список `FieldType` и какие из них реально читает SimHub Motion; нет официальной документации. Форум SimHub (undated): кросс-игровая часть Motion в старых версиях брала только yaw, pitch, roll, surge/sway/heave у кастомных протоколов были пустыми: https://www.simhubdash.com/community-2/simhub-support/ (поиск по теме «g seat»), https://www.simhubdash.com/community-2/simhub-support/g-seat/. Сейчас, по журналу изменений 9.11.21 (07.2026), есть эффекты для осей pitch/roll. Вывод: после реализации проверить на живом SimHub, что surge/sway/heave доходят.
- Что берёт Wind: официальной документации нет. По форумам (https://www.simhubdash.com/community-2/simhub-support/simhub-wind-fan-lag/) вентилятор следует скорости игры; можно предположить `SpeedKmh`. Для нашей игры заполнять `SpeedKmh` воздушной скоростью (для дельтаплана важно именно её, а не скорость земли).

## 4. Авиасимы в SimHub

Официальный список (https://www.simhubdash.com/supported-games/): Condor 2 и 3, DCS, Flight Simulator 2020 и 2024, IL-2 Sturmovik, X-Plane 10/11/12, Elite Dangerous (только Motion, чтение памяти), War Thunder и Aces of Thunder (с оговоркой: точных данных для motion нет). Это отдельные читалки внутри SimHub под API каждой игры (Condor 2 использует свой UDP-вывод, X-Plane свои датаграммы, MSFS SimConnect, DCS Lua-экспорт; конкретно как у каждой, не проверял). Подделать формат такой игры нельзя без их кода: он не опубликован (ответ разработчика на форуме: API чтения игр закрыт, SDK даёт выходные плагины: https://www.simhubdash.com/community-2/simhub/api-for-custom-modules/). Условия лицензии на «притворство» не проверены. Вывод: не делаем.

## 5. Альтернативы и почему не они

| Вариант | Что нужно | Оценка | Вердикт |
|---|---|---|---|
| External sim (simdef + UDP) | п. 3, простая упаковка структуры | 1-2 дня | **рекомендация** |
| Плагин SimHub на C# | Visual Studio 2022, WPF/C#, демо в `C:\Program Files (x86)\SimHub\PluginSdk` (`User.PluginSdkDemo`); https://github.com/SHWotever/SimHub/wiki/Plugin-and-extensions-SDKs. Плагин создаёт свои свойства и действия, но API чтения игр не публичный, т.е. подать данные в Motion через плагин нельзя (по ответу разработчика) | 1-2 недели и поддержка | не нужен |
| UDP-форвард от другого софта | UDP Relay в SimHub пересылает пакеты игры на другие порты, а не принимает чужие форматы | не решает | нет |
| Притвориться X-Plane/Condor | закрытые читалки | неизвестно | нет |
| Оставить SRS | у владельцев DOF Reality работает | 0 | для DOF Reality достаточно |

## 6. Рекомендация и что делать (KISS)

1. Добавить в игре формат `simhub` рядом с `srs` и `generic`: упаковать структуру (заголовок 55 байт + поля из таблицы), слать на `127.0.0.1:<порт из simdef>` (SimHub обычно на том же ПК; игра на Linux/Mac с SimHub на другом ПК пакет перешлёт сама по адресу из настроек), ≥60 Гц, и на паузе, и в наземных фазах, как сейчас у `srs`.
2. Единожды на Windows с SimHub: включить редактор определений, создать игру «Deltaplan» с полями Yaw, Pitch, Roll, три угловые скорости, Surge/Sway/Heave, три локальные скорости, SpeedKmh, GroundSpeedKmh (без позиций можно, но Motion от них, по-видимому, не зависит; не проверено), сохранить `Deltaplan.simdef`, скопировать сигнатуры и сгенерированный код как эталон структуры, добавить тест раскладки (размер, смещения) по сгенерированному коду.
3. Распространение: `Deltaplan.simdef` + иконка + `.shlink` (или `install.bat` по образцу FlatOut4VR: MIT), положить в `ExternalSims`. Игра может сама писать `.shlink` при включении вывода (по рекомендации мануала «rewrite at sim startup»), но только в Windows-сборке.
4. Игроку: SimHub 9.11.5+, включить игру Deltaplan в списке, в Motion/Wind выбрать её как источник; пакеты слать на `127.0.0.1:<порт>`. Настройки gain/washout в SimHub, как в SRS.
5. До реализации спросить у владельца DOF Reality, готов ли протестировать (нужен Windows со SimHub и платформой); без проверки на живом SimHub считаем формат непроверенным.

## 7. Лицензии и условия

- SimHub для личного использования бесплатен, платная лицензия «pay what you want» убирает ограничения (скорость вывода на Arduino, ШИМ и т.п.): https://www.simhubdash.com/get-a-license/. Motion — отдельный платный аддон (страница лицензии «Get Motion addon license», цену не нашёл): https://www.simhubdash.com/supported-games/. Условия коммерческого использования не нашёл.
- SDK: лицензионные условия на вики не указаны (https://github.com/SHWotever/SimHub/wiki/Plugin-and-extensions-SDKs). Для simdef-пути SDK не нужен.
- Образцы кода: FlatOut4VR-SimHub — MIT (https://github.com/Dteyn/FlatOut4VR-SimHub); у Galactic Racer UEVR лицензию не проверял. Сгенерированный редактором код SimHub — для сторонних игр, предполагается свободный; явного заявления не нашёл. Мы копируем только структуру (факты о формате), код пишем свой.
- SimHub — только Windows. Для игроков на Linux/macOS: SimHub на отдельном Windows-ПК в сети.

## 8. Чего не проверено

- Ничего не запускалось: ни SimHub, ни приём пакета. Раскладка выведена из двух сторонних сгенерированных файлов, одной версии генератора (9.11.x); поля, не показанные в примерах, не описаны.
- Мануал не раскрывает, какие поля читает Motion и Wind (см. п. 3).
- Расширение файла регистрации (`.shlink` или `.simlink`) расходится в мануале.
