---
type: "research"
status: "active"
module: "bar-mouse"
area: "game"
updated: "2026-10-23"
summary: "Захват мыши в Godot 4.7.2: Windows и X11 — сырые отсчёты, Wayland и macOS — с ускорением ОС; брать screen_relative"
related: ["docs/contracts/bar-mouse.md", "docs/plan/bar-mouse.md"]
conclusion: "Для BM-К1 брать InputEventMouseMotion.relative. Windows (WM_INPUT) и X11 (XI_RawMotion) отдают отсчёты без ускорения ОС; Wayland отдаёт ускоренный dx (dx_unaccel игнорируется), macOS — ускоренный NSEvent.deltaX с усечением до целого. Единица «px» в BM-К1 — отсчёты мыши точно только на Windows/X11; на Wayland/macOS зависит от настройки скорости указателя ОС и масштаба экрана."
data: "числа не измерялись; всё из исходников Godot 4.7.2-stable по строкам тега"
---
# Сырой ввод мыши при захвате в Godot 4.7.2

Вопрос BM-2 (модуль bar-mouse): даёт ли `InputEventMouseMotion.relative` при `MOUSE_MODE_CAPTURED` сырые отсчёты мыши без ускорения ОС (контракт BM-К1 принимает «px» = отсчёты). Метод: чтение исходников тега `4.7.2-stable` (`https://github.com/godotengine/godot/blob/4.7.2-stable/<файл>#L<строка>`; лицензия движка MIT). Godot не запускался, на железе не мерялось: что делает ОС _внутри_ вызова API (macOS, Wayland-композитор) — по документации протокола/API, помечено «не из кода Godot».

## Итог

| Платформа | Источник в Godot | Ускорение ОС в `relative`? | Единица `relative` | HiDPI-множитель |
|---|---|---|---|---|
| Windows | `WM_INPUT`/`RAWINPUT`, `lLastX/lLastY` | **Нет.** «Повышенная точность установки указателя» не действует (сырые данные устройства) | отсчёты устройства (счёты HID), целые | нет |
| Linux X11 | XInput2 `XI_RawMotion`, `raw_values` | **Нет** (raw_values — до ускорения Xorg/libinput) | отсчёты устройства, double → усечение до целого | нет |
| Linux Wayland | `zwp_relative_pointer_v1`, поле `dx`/`dy` | **Да, если композитор ускоряет** (`dx_unaccel`/`dy_unaccel` Godot отбрасывает) | логические пиксели композитора × масштаб окна | `×fractional_scale` или `×buffer_scale` |
| macOS | `NSEvent.deltaX/deltaY` + `CGAssociateMouseAndMouseCursorPosition(false)` | **Да** (кривая скорости указателя системы; не из кода Godot) | точки × `max_scale`, усечение до целого | `×screen_get_max_scale()` (1 или 2) |

Рекомендация: для BM-К1 — **`relative`** (в проекте равен `screen_relative`, см. ниже). Обход нужен только для Wayland и macOS и только как деградация единиц (подробно в разделе «Обход»).

## Windows

- Захват: `_set_mouse_mode_impl` для CAPTURED ставит `ClipCursor`, `SetCursorPos` в центр, `SetCapture` и вызывает `_register_raw_input_devices` ([display_server_windows.cpp#L283-L289](https://github.com/godotengine/godot/blob/4.7.2-stable/platform/windows/display_server_windows.cpp#L283)). Регистрация — `RegisterRawInputDevices` для мыши (usage page 0x01, usage 0x02) и клавиатуры, `dwFlags = 0`, цель — окно или фокус клавиатуры ([L362-L395](https://github.com/godotengine/godot/blob/4.7.2-stable/platform/windows/display_server_windows.cpp#L362)). При успехе `use_raw_input = true`; при неудаче — `false`.
- Чтение: `process_raw_input()` ([L4354](https://github.com/godotengine/godot/blob/4.7.2-stable/platform/windows/display_server_windows.cpp#L4354)) вычитывает очередь `GetRawInputBuffer` перед насосом сообщений; запасной путь — `WM_INPUT` ([L5870](https://github.com/godotengine/godot/blob/4.7.2-stable/platform/windows/display_server_windows.cpp#L5870)). Движение — `_get_raw_mouse_motion`: для `MOUSE_MOVE_RELATIVE` берутся `lLastX, lLastY` без обработки ([L4256-L4258](https://github.com/godotengine/godot/blob/4.7.2-stable/platform/windows/display_server_windows.cpp#L4256)).
- Почему нет ускорения: `RAWMOUSE.lLastX/lLastY` — данные устройства до обработки указателя Windows; кривая «Повышенная точность установки указателя» (ускорение указателя) применяется только к экранному курсору/`WM_MOUSEMOVE`. Это поведение Win32, из кода Godot оно видно косвенно: в CAPTURED с `use_raw_input` `WM_MOUSEMOVE` **отбрасывается** ([L6280-L6282](https://github.com/godotengine/godot/blob/4.7.2-stable/platform/windows/display_server_windows.cpp#L6280)), событие строится из raw ([L4312-L4313](https://github.com/godotengine/godot/blob/4.7.2-stable/platform/windows/display_server_windows.cpp#L4283): `set_relative(p_relative)`, `set_relative_screen_position(p_relative)`).
- Граничные случаи: (1) устройство с `MOUSE_MOVE_ABSOLUTE` (RDP, виртуальные машины, планшет) — относительное значение считается из экранной позиции и `old_x/old_y` ([L4259-L4279](https://github.com/godotengine/godot/blob/4.7.2-stable/platform/windows/display_server_windows.cpp#L4259)), т. е. это уже _не_ отсчёты мыши, а пиксели экрана. (2) Если `RegisterRawInputDevices` не удалась, `use_raw_input = false` — тогда `WM_MOUSEMOVE` не отбрасывается и значения идут от курсора с ускорением (см. условия [L5995](https://github.com/godotengine/godot/blob/4.7.2-stable/platform/windows/display_server_windows.cpp#L5995), [L6547](https://github.com/godotengine/godot/blob/4.7.2-stable/platform/windows/display_server_windows.cpp#L6547)); на практике регистрация почти не падает. (3) Больше 512 сырых событий за кадр — хвост суммируется в одно событие ([L4368](https://github.com/godotengine/godot/blob/4.7.2-stable/platform/windows/display_server_windows.cpp#L4368), [L4405-L4410](https://github.com/godotengine/godot/blob/4.7.2-stable/platform/windows/display_server_windows.cpp#L4405)), сумма сохраняется. При `Input.use_accumulated_input = true` (по умолчанию) суммируется всё за кадр ([L4372](https://github.com/godotengine/godot/blob/4.7.2-stable/platform/windows/display_server_windows.cpp#L4372)); сумма отсчётов не теряется.
- Вывод: **отсчёты мыши, целые, без ускорения ОС**. Мышь с 8 кГц и высоким DPI даёт много отсчётов — «px» в BM-К1 корректны.

## Linux X11

- Захват: `XGrabPointer` + `XWarpPointer` в центр окна ([display_server_x11.cpp#L584-L598](https://github.com/godotengine/godot/blob/4.7.2-stable/platform/linuxbsd/x11/display_server_x11.cpp#L584)).
- Сырой источник: на корневое окно подписка на `XI_RawMotion` для `XIAllMasterDevices` ([L7297](https://github.com/godotengine/godot/blob/4.7.2-stable/platform/linuxbsd/x11/display_server_x11.cpp#L7297)). Обработчик берёт `raw_event->raw_values` для осей 0 и 1 ([L4971-L4997](https://github.com/godotengine/godot/blob/4.7.2-stable/platform/linuxbsd/x11/display_server_x11.cpp#L4971)); в XI2 `raw_values` — значения валюаторов устройства до ускорения/трансформации сервера (`valuators` — после; Godot берёт именно `raw_values`).
- Относительное устройство: `xi.relative_motion = raw_pos` — **присваивание, не суммирование** ([L5068](https://github.com/godotengine/godot/blob/4.7.2-stable/platform/linuxbsd/x11/display_server_x11.cpp#L5068)); абсолютное (планшет): разность × множитель разрешения (`+=`, [L5063-L5065](https://github.com/godotengine/godot/blob/4.7.2-stable/platform/linuxbsd/x11/display_server_x11.cpp#L5063)).
- Событие `InputEventMouseMotion` собирается в `MotionNotify` (позиция — от X-сервера, но `rel = xi.relative_motion`, [L5507-L5511](https://github.com/godotengine/godot/blob/4.7.2-stable/platform/linuxbsd/x11/display_server_x11.cpp#L5507)), затем обнуляется ([L5517-L5518](https://github.com/godotengine/godot/blob/4.7.2-stable/platform/linuxbsd/x11/display_server_x11.cpp#L5517)); в CAPTURED пустое движение пропускается ([L5486](https://github.com/godotengine/godot/blob/4.7.2-stable/platform/linuxbsd/x11/display_server_x11.cpp#L5486)).
- Нюансы, влияющие на точность (из кода, не измерялось):
  1. `Point2i rel` — **усечение до целого** ([L5507](https://github.com/godotengine/godot/blob/4.7.2-stable/platform/linuxbsd/x11/display_server_x11.cpp#L5507)): для мышей с дробными `raw_values` (редко; обычно целые счёты) дробная часть теряется без накопления остатка.
  2. Если между двумя `MotionNotify` придут несколько `XI_RawMotion`, у относительных устройств сохранится **только последнее** (присваивание). `MotionNotify` на X-сервере с курсором приходит на каждый шаг, поэтому на практике потерь мало, но при просадке кадров/на высокой частоте опроса они возможны. Для штанги это означает занижение, а не смещение (всегда потеря, не прибавка). Оценить долю потерь без железа нельзя — **uncertain**.
  3. Дубль-фильтр `raw_event->time == last_relative_time` с равными значениями ([L5049](https://github.com/godotengine/godot/blob/4.7.2-stable/platform/linuxbsd/x11/display_server_x11.cpp#L5049)) — известный обход дублей XInput.
- Вывод: **отсчёты мыши без ускорения ОС** (Xorg/libinput accel profile не применяется к `raw_values`), целочисленные, возможна редкая потеря при нескольких raw-событиях за один `MotionNotify`.
- XWayland (X11-сборка в сессии Wayland): сырые события формирует XWayland из relative-pointer композитора; ускорение зависит от композитора — **не из кода Godot, не проверено**. По умолчанию в Wayland-сессии Godot 4.7 использует собственный бэкенд Wayland (см. ниже), если не задан `--display-driver x11`.

## Linux Wayland

- Захват: `MOUSE_MODE_CAPTURED` → `PointerConstraint::LOCKED` ([display_server_wayland.cpp#L497-L499](https://github.com/godotengine/godot/blob/4.7.2-stable/platform/linuxbsd/wayland/display_server_wayland.cpp#L497)): `zwp_locked_pointer_v1`.
- Относительное движение: обработчик `_wp_relative_pointer_on_relative_motion(..., dx, dy, dx_unaccel, dy_unaccel)` использует **только `dx, dy`** ([wayland_thread.cpp#L3055-L3064](https://github.com/godotengine/godot/blob/4.7.2-stable/platform/linuxbsd/wayland/wayland_thread.cpp#L3055)); `dx_unaccel/dy_unaccel` не читаются. По протоколу `relative-pointer-unstable-v1` `dx/dy` — движение с ускорением композитора, `*_unaccel` — без (протокол, не код Godot).
- Событие: `mm->set_relative(pd.relative_motion * scale)` ([L2151](https://github.com/godotengine/godot/blob/4.7.2-stable/platform/linuxbsd/wayland/wayland_thread.cpp#L2151)), `scale` = дробный масштаб окна (`wp_fractional_scale`) или целый `buffer_scale` ([L4015-L4023](https://github.com/godotengine/godot/blob/4.7.2-stable/platform/linuxbsd/wayland/wayland_thread.cpp#L4015)). Значения **double** (дробные, не усечены); `screen_relative` = `relative` ([L2153](https://github.com/godotengine/godot/blob/4.7.2-stable/platform/linuxbsd/wayland/wayland_thread.cpp#L2153)).
- Ускорение зависит от композитора: GNOME/KDE применяют профиль libinput (adaptive по умолчанию — ускорение есть; «flat» — нет). Движение `dx` тогда зависит от скорости руки, не только от пути мыши. Масштаб: на 125–200 % `relative` растёт ×1,25…×2 при том же пути мыши.
- Присваивание `pd.relative_motion = …` ([L3061-L3062](https://github.com/godotengine/godot/blob/4.7.2-stable/platform/linuxbsd/wayland/wayland_thread.cpp#L3061)), а не `+=`: если за один `wl_pointer.frame` придёт несколько relative-событий, учтётся последнее — как в X11, потеря возможна; **uncertain**.
- Вывод: «px» ≠ отсчёты мыши; единица зависит от профиля ускорения композитора и масштаба.

## macOS

- Захват: `CGAssociateMouseAndMouseCursorPosition(false)` + `CGWarpMouseCursorPosition` в центр окна ([display_server_macos.mm#L1240-L1254](https://github.com/godotengine/godot/blob/4.7.2-stable/platform/macos/display_server_macos.mm#L1240)).
- Событие: `mouseMoved:` берёт `[event deltaX]`, `[event deltaY]` ([godot_content_view.mm#L524](https://github.com/godotengine/godot/blob/4.7.2-stable/platform/macos/godot_content_view.mm#L524)) и строит `relativeMotion = Vector2i(delta.x, delta.y) * screen_get_max_scale()` ([L552-L554](https://github.com/godotengine/godot/blob/4.7.2-stable/platform/macos/godot_content_view.mm#L552)); `relative` = `screen_relative`.
- Ускорение: `NSEvent.deltaX/Y` — дельты окна-сервера в точках, которые macOS уже прогнала через кривую скорости указателя («Скорость отслеживания» в настройках; кривая нелинейная). Сырых счётов мыши Godot на macOS не использует (нет IOHID/`GCMouse`, `kCGMouseEventDeltaX` тоже ускоренный) — **утверждение об ускорении из документации Apple/практики SDL, не из кода Godot**.
- Нюанс (из кода): `Vector2i(delta.x, delta.y)` — **усечение float до целого ДО умножения на масштаб** ([L552](https://github.com/godotengine/godot/blob/4.7.2-stable/platform/macos/godot_content_view.mm#L552)). `deltaX` на macOS дробный (особенно на медленном движении при ускорении); значения |δ| < 1 превращаются в 0 и теряются без накопления остатка — медленное точное движение штанги «залипает» и недоучитывается. Затем ×`display_max_scale` (максимум `backingScaleFactor` среди экранов, [display_server_macos.mm#L1508-L1514](https://github.com/godotengine/godot/blob/4.7.2-stable/platform/macos/display_server_macos.mm#L1508), [L3688](https://github.com/godotengine/godot/blob/4.7.2-stable/platform/macos/display_server_macos.mm#L3688)): на Retina при масштабе 2 `relative` кратно 2 и всегда чётное.
- Вывод: «px» в `relative` на macOS = ускоренные точки, усечённые, ×2 на Retina; чувствительность зависит от системной скорости указателя.

## `relative` и `screen_relative`

- Движок хранит оба поля; платформы заполняют их **одним значением** (`set_relative(r)`; `set_relative_screen_position(r)`): Windows [L4312-L4313](https://github.com/godotengine/godot/blob/4.7.2-stable/platform/windows/display_server_windows.cpp#L4312), X11 [L5559-L5560](https://github.com/godotengine/godot/blob/4.7.2-stable/platform/linuxbsd/x11/display_server_x11.cpp#L5559), Wayland [L2151-L2153](https://github.com/godotengine/godot/blob/4.7.2-stable/platform/linuxbsd/wayland/wayland_thread.cpp#L2151), macOS [L553-L554](https://github.com/godotengine/godot/blob/4.7.2-stable/platform/macos/godot_content_view.mm#L553).
- Различие появляется при передаче события во вьюпорт: `Viewport::_make_input_local` применяет `get_final_transform().affine_inverse()` ([viewport.cpp#L1467-L1480](https://github.com/godotengine/godot/blob/4.7.2-stable/scene/main/viewport.cpp#L1467)); `InputEventMouseMotion::xformed_by` преобразует **`relative`** линейной частью `p_xform.basis_xform` ([input_event.cpp#L992](https://github.com/godotengine/godot/blob/4.7.2-stable/core/input/input_event.cpp#L992)), а `screen_relative` оставляет как есть ([L993](https://github.com/godotengine/godot/blob/4.7.2-stable/core/input/input_event.cpp#L993)). Преобразование — растяжение (`stretch_transform`, масштаб контента) и трансформация канвы. Итого: `relative` — в координатах viewport (после растяжения), `screen_relative` — в пикселях окна/экрана.
- Накопление событий за кадр суммирует оба поля независимо ([input_event.cpp#L1073-L1074](https://github.com/godotengine/godot/blob/4.7.2-stable/core/input/input_event.cpp#L1073); включено `Input.use_accumulated_input = true` по умолчанию, [input.cpp#L1549-L1551](https://github.com/godotengine/godot/blob/4.7.2-stable/core/input/input.cpp#L1549)).
- Проект: `project.godot` — `window/size/viewport_width=1600`, `viewport_height=900`, `window/stretch/aspect="expand"`, `window/stretch/mode` не задан (= `disabled`, `stretch_transform` = единичная), `use_accumulated_input` не менялся. Скриптов, меняющих `content_scale_*` окна, в `scripts/` нет (`grep` по `mouse_mode` нашёл только `Input.mouse_mode` в `game.gd`, `input_controller.gd`, `camera_rig.gd`). Значит в штатной настройке `relative == screen_relative`.
- Для штанги нужен именно «путь мыши», а не координаты вьюпорта: если когда-нибудь включат растяжение (`canvas_items`/`viewport`) или `content_scale_factor ≠ 1`, `relative` масштабируется вместе с окном, и контракт «размер окна в расчёт не входит» нарушится. `screen_relative` от этого не зависит. Поэтому **безопаснее читать `screen_relative`**: сегодня значения те же, а при смене растяжения BM-К1 не поломается. Оба поля на HiDPI-платформах (Wayland, macOS) уже несут множитель масштаба экрана (см. таблицу) — `screen_relative` его не снимает.
- Уточнение к BM-К1: в контракте записано «`relative` … при выключенном растяжении = пиксели экрана = отсчёты мыши». Верно для Windows/X11, неверно для Wayland (масштаб, ускорение композитора) и macOS (ускорение, ×max_scale, усечение). Это замечание для координатора (контракт не менять самому).

## Обход и рекомендации для BM-К1

1. Читать `event.screen_relative` вместо `relative` (одинаково сегодня, устойчиво к растяжению). `Input.use_accumulated_input` не трогать.
2. Windows, X11: обход не нужен.
3. Wayland: средствами Godot 4.7.2 `dx_unaccel` недоступен — нужна правка движка (читать `dx_unaccel`) или совет пилоту выбрать в ОС плоский профиль мыши (GNOME: «Mouse Acceleration → Flat»; KDE: «Ускорение указателя → Плоский»). Альтернатива — запустить через XWayland с `--display-driver x11` (сырые значения зависят от композитора, **не проверено**).
4. macOS: движок сам ускорение не снимает. В коде игры можно лишь компенсировать масштаб (`DisplayServer.screen_get_max_scale()`; в Godot 4 есть) — но не усечение и не кривую. Совет пилоту: поставить «Скорость отслеживания» в середину/минимум; штанга при этом использует множитель `bar_sensitivity` как подгонку.
5. Для всех платформ слайдер «Чувствительность штанги» должен остаться: он единственный способ подогнать ход под нелинейность ОС и DPI. Подсказка «≈ N см (800 DPI)» из BM-К1 правдива только для Windows/X11; на Wayland/macOS стоит добавить оговорку (или скрыть подсказку на этих платформах: `OS.get_name()`, `DisplayServer.get_name()`).
6. Проверка железом (вне объёма BM-2, нужна платформа): сделать мышь 1000 отсчётов по линейке на стол, посчитать сумму `screen_relative` в `_unhandled_input` на каждой ОС при разной скорости движения — линейность суммы от скорости подтверждает отсутствие ускорения. Тест предложен, не выполнялся.

## Допущения и границы

- Читались исходники тега 4.7.2-stable, а не бинарник; эффекты ОС (Win32 raw input, XI2 `raw_values`, протокол relative-pointer, кривая macOS) — по документации платформ.
- Номера строк относятся к тегу 4.7.2-stable на 2026-10-23.
- Ничего не измерялось: оценки потерь (X11/Wayland — присваивание вместо суммы; macOS — усечение) качественные.
- Не рассмотрены: Android/iOS, веб, джойстик/тачпад, мышь через RDP/VNC (Windows даёт абсолютные координаты, см. выше), игровые мыши с драйверным ускорением в прошивке.

## Источники

- Godot 4.7.2-stable, файлы: `platform/windows/display_server_windows.cpp`, `platform/linuxbsd/x11/display_server_x11.cpp`, `platform/linuxbsd/wayland/wayland_thread.cpp`, `platform/linuxbsd/wayland/display_server_wayland.cpp`, `platform/macos/display_server_macos.mm`, `platform/macos/godot_content_view.mm`, `core/input/input_event.cpp`, `core/input/input.cpp`, `scene/main/viewport.cpp` (<https://github.com/godotengine/godot/tree/4.7.2-stable>, MIT).
- Microsoft, Raw Input: <https://learn.microsoft.com/windows/win32/inputdev/raw-input>; `RAWMOUSE`: <https://learn.microsoft.com/windows/win32/api/winuser/ns-winuser-rawmouse>.
- XInput 2.0, `XIRawEvent`: <https://www.x.org/releases/current/doc/inputproto/XI2proto.txt>.
- Wayland, `relative-pointer-unstable-v1`: <https://wayland.app/protocols/relative-pointer-unstable-v1>.
- Apple, `NSEvent.deltaX`: <https://developer.apple.com/documentation/appkit/nsevent> (свойство `deltaX`); `CGAssociateMouseAndMouseCursorPosition`: <https://developer.apple.com/documentation/coregraphics> (Quartz Display Services).
