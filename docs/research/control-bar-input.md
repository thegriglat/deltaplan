---
type: "research"
status: "closed"
module: "control-bar"
updated: "2026-10-10"
summary: "Как подключить самодельную трапецию (абсолютные оси ручки) к игре: готовые HID-решения, датчики, как Godot 4.5+ (SDL3) видит нестандартный джойстик"
related: []
conclusion: "Поддерживаем стандартный USB HID-джойстик без своего протокола: Godot 4.5+ отдаёт сырые оси неизвестного HID по индексу; самодельщики так и делают (Arduino Leonardo/Pro Micro, FreeJoy). Игре нужны только выбор устройства, оси, инверсия, калибровка."
data: "tools/research/control-bar/ не создавался; числа — из документации и исходников по ссылкам в тексте"
applied_in: "не применено: ждёт решения главной сессии по CB-2/CB-3"
---
# Трапеция как абсолютная ось: протоколы и готовые решения

Задача CB-1. Решение пользователя: эмулируем только положение ручки (вбок, вперёд-назад); разбег и остальное — клавиатура. Мышь даёт относительные смещения, поэтому для рамы нужен абсолютный путь — джойстик.

## Коротко

- **Рекомендация: поддерживаем стандартное USB HID-устройство «джойстик» (две оси), своего протокола и драйверов нет.** Вся сборка самодельщиков авиасимов держится на этом: плата показывается ПК как игровой контроллер, датчики — оси ([FlyAway](https://flyawaysimulation.com/ask/answers/build-diy-flight-simulator-joystick/)).
- Готовых DIY-трапеций дельтаплана и симуляторов, которые их поддерживают, **не найдено** (искали в вебе; ближайшее — самодельный контроллер для парапланерных игр на Arduino Micro и ползунковых потенциометрах: [jpralves.net](https://jpralves.net/post/2018/07/03/diy-controller-for-paragliding-games.html), и обсуждения рычагов в Condor: [1](https://condorsoaring.com/forums/viewtopic.php?p=158145), [2](https://condorsoaring.com/forums/viewtopic.php?p=60311)). Стандарта для трапеции нет — будем первыми, значит нужна простая сборка.
- Нужен ли модуль вообще: код `_apply_gamepad` уже читает две оси, так что минимум — не модуль, а небольшая вкладка настроек (ниже).

## Решения: интерфейс, цена, сложность

| Решение | Интерфейс к ПК | Цена / сложность | Источник |
|---|---|---|---|
| Arduino Leonardo / Pro Micro (ATmega32U4) + ArduinoJoystickLibrary | USB HID, проводной; оси X…Rz и др., до 16 бит, по умолчанию диапазон 0–1023 (надо задать `setXAxisRange`); LGPL-3.0 | единицы $, скетч из примера на 10 строк; встроенный АЦП 10 бит | [MHeironimus/ArduinoJoystickLibrary](https://github.com/MHeironimus/ArduinoJoystickLibrary) |
| MMJoy2 (те же платы 32U4, Teensy 2.0) | USB HID; до 8 осей, 10 бит встроенным АЦП или 12 бит с внешним MCP3204/3208; настройка утилитой JoySetup | готовая прошивка без кода, но проект старый, форумный (SimHQ/DCS) | [SimHQ](https://simhq.net/forum/ubbthreads.php/topics/3899342), [DCS-форум](https://forum.dcs.world/topic/99954-mmjoy) |
| FreeJoy (STM32F103 «Blue Pill») | USB HID; до 8 аналоговых осей, 12 бит на выходе, калибровка, сглаживание и мёртвая зона в самой прошивке; GPL-3.0 | плата ≈ $1–2, но шить ST-Link/UART и ставить конфигуратор | [FreeJoy-Team/FreeJoy](https://github.com/FreeJoy-Team/FreeJoy), [тема на форуме](https://forum.dcs.world/topic/223599-freejoy-joystick-controller-firmware-for-arm-stm32-boards) |
| Готовая плата Leo Bodnar BU0836 | USB HID, аналоговые входы под потенциометры (разрешение не проверялось), без программирования | дороже самоделок, но «подключил и работает»; её советуют в Condor-обсуждении | [Bergison](https://bergisons.simpit.info/tutorial_interface_potentiometers), [Condor](https://condorsoaring.com/forums/viewtopic.php?p=158145) |
| ESP32 BLE Gamepad (ESP32/S3/C3) | Bluetooth LE HID, режимы generic/XInput/SInput; MIT | дешёво, но Bluetooth: сопряжение, задержка, батарейка — для рамы не нужно | [lemmingDev/ESP32-BLE-Gamepad](https://github.com/lemmingDev/ESP32-BLE-Gamepad) |
| ESP32-S3 / S2 как проводной USB HID | USB HID через TinyUSB; в классе `USBHIDGamepad` оси int8 (8 бит, грубо), нужен свой дескриптор для 16 бит | лишняя возня по сравнению с Leonardo | [arduino-esp32 USBHIDGamepad.h](https://github.com/espressif/arduino-esp32/blob/master/libraries/USB/src/USBHIDGamepad.h) |
| vJoy (Windows), uinput (Linux) | виртуальный джойстик из программы на ПК, не для железа | нужны только если ввод идёт из другой программы; vJoy — только Windows | [vJoy](https://vjoystick.sourceforge.net), [uinput](https://docs.kernel.org/input/uinput.html) |

Вывод по vJoy/uinput: **не нужны** — реальное устройство и так HID. Для macOS отдельных драйверов тоже не нужно (проверено только по документации ESP32-BLE-Gamepad: macOS видит HID через IOHIDManager).

## Датчики

| Датчик | Выход | Заметки | Источник |
|---|---|---|---|
| Потенциометр (линейный/ползунковый) | аналог → АЦП платы | самый простой старт; износ контакта; ход ограничен механикой | [jpralves](https://jpralves.net/post/2018/07/03/diy-controller-for-paragliding-games.html), [FlyAway](https://flyawaysimulation.com/ask/answers/build-diy-flight-simulator-joystick/) |
| Магнитные датчики угла (в Condor-теме — от дроссельных заслонок) | аналог / PWM | бесконтактные, ресурс выше | [Condor](https://condorsoaring.com/forums/viewtopic.php?p=158145) |
| AS5600 (Холл, 12 бит = 4096 шагов на оборот) | аналог/PWM + I²C | бесконтактный; программируемый угол от 18° до 360° (можно «растянуть» ход ручки на весь диапазон); магнит на оси | [datasheet](https://www.infineon.com/assets/row/public/documents/24/49/infineon-as5600-datasheet-en.pdf) |

Разрешение в числах: 10 бит АЦП ATmega32U4 — 1024 шага; если рабочий ход рычага ≈ 60°, шаг ≈ 0,06° — для игры достаточно (дрожание лечит сглаживание в игре/прошивке). 12 бит нужны только при большом передаточном числе. Геометрию и ход реальной трапеции источники не дают — её задаёт рама автора.

## Godot 4.x на трёх ОС

- С Godot 4.5 на Windows, macOS и Linux джойстики идут через SDL3; старый свой код остался только для Android, iOS, Web ([документация](https://docs.godotengine.org/en/stable/tutorials/inputs/controllers_gamepads_joysticks.html)). В документации сказано, что нестандартные устройства (руль, педали, HOTAS) протестированы хуже.
- Для устройства, которое SDL **не считает геймпадом** (нет маппинга — типично для самодельного HID), `drivers/sdl/joypad_sdl.cpp` открывает его как сырой джойстик (`SDL_OpenJoystick`) и отдаёт Godot оси по индексу SDL, нормализуя в −1…1: `((v − MIN)/(MAX − MIN) − 0.5)·2` ([исходник](https://github.com/godotengine/godot/blob/master/drivers/sdl/joypad_sdl.cpp)). Значит `Input.get_joy_axis(dev, 0/1/…)` работает без маппинга; индексы осей приходят в порядке SDL (для HID — X, Y, Z, Rx, Ry, Rz, слайдеры; порядок для конкретной платы проверить на железе).
- Выходящие за `JoyButton::MAX` кнопки отбрасываются; перенумерованных осей Godot сам не делает — выбор осей должен быть в игре.
- Windows: не более 4 контроллеров одновременно (XInput-путь по документации); Linux: горячее подключение менее надёжно (опрос); macOS: ограничений в документации нет. Для BLE-геймпада системное сопряжение обязательно, дальше он виден как HID (по [ESP32-BLE-Gamepad](https://github.com/lemmingDev/ESP32-BLE-Gamepad) — на всех трёх ОС).
- Мёртвая зона по умолчанию в Godot 0,5 для действий — наш код читает `get_joy_axis` напрямую и применяет свою (`gamepad.deadzone`), поэтому она не мешает.

## Что уже есть в игре (только чтение)

`scripts/game/input_controller.gd::_apply_gamepad` берёт **первое** подключённое устройство, две оси по индексам `gamepad.roll_axis` / `pitch_axis` из `configs/controls.json`, мёртвая зона, `sensitivity`, `expo`, кнопка разбега. Инверсия тангажа общая (`invert_pitch`), инверсии крена нет. Не хватает для ручки: выбор устройства (имя/GUID вместо «первого» — в сборке может быть и обычный геймпад), инверсия по осям, **калибровка нейтрали и краёв** (самодельный датчик редко даёт ровно −1…+1 и 0 в нейтрали; экспонента и «стик возвращается в центр» для ручки не нужны), индикатор.

## Рекомендуемая сборка для инструкции

Arduino Pro Micro или Leonardo (ATmega32U4) + два потенциометра (или два AS5600 для бесконтактной версии) на осях крена и тангажа + скетч на ArduinoJoystickLibrary (`Joystick.setXAxisRange(0,1023)`, `setYAxisRange`, `setXAxis(analogRead(A0))`). Почему не FreeJoy/MMJoy: проще — один скетч и стандартная Arduino IDE; FreeJoy — запасной вариант без кодирования, если нужны калибровка и сглаживание в самой плате. Конкретный скетч — в инструкции (CB-3), здесь не проверялся на железе.

## Предложение по объёму (минимум)

Только вкладка в настройках игры, без отдельной подсистемы: список устройств (`Input.get_connected_joypads`, `get_joy_name`, `get_joy_guid`, обновление по `joy_connection_changed`), выбор устройства и осей крена/тангажа, инверсия каждой оси, мёртвая зона, кнопки «нейтраль» и «левый/правый/передний/задний край» (запоминаем сырые значения → линейная нормировка в −1…1), живой индикатор положения. Сохранение в `configs/controls.json` (`gamepad`). Это CB-2; CB-3 — только текст инструкции со скетчем, если пользователь одобрит. Кнопка разбега остаётся на клавиатуре/геймпаде.

## Что не проверено

Порядок и число осей конкретной платы в Godot 4.7 на всех ОС — только на железе; восприятие задержки/дрожания — тоже. ESP32 USB HID по оси — по заголовку класса, без чтения дескриптора.
