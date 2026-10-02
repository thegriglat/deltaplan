---
type: "guide"
status: "active"
module: "instruments"
updated: "2026-10-03"
summary: "Приборы и звук вариометра — Instrument3D: экран смотрит в локальную +Z, верх — +Y, начало — центр корпуса, хомут сзади снизу."
related: []
---
# Приборы и звук вариометра

Требования: FR-21…FR-25 (приборы, никакого HUD), FR-23/FR-28 (звук вариометра), NFR-7 (числа в конфигах).
Конфиги: `configs/instruments.json` (фильтр, экран, карта, корпус, оверлей), `configs/audio.json → vario_audio` (звук).

## Состав

| Файл | Что |
|---|---|
| `scripts/instruments/vario.gd` — `Vario` (RefCounted) | обработка сигнала: инерция датчика, среднее, качество, время полёта, расстояние, след |
| `scripts/instruments/instrument_display.gd` — `InstrumentDisplay` (Control) | рисует экран (`_draw`) в стиле транфлективного LCD |
| `scripts/instruments/flight_instrument.gd` — `FlightInstrument` + `scenes/instruments/flight_instrument.tscn` | прибор: Vario + экран в SubViewport → текстура |
| `scripts/instruments/instrument_3d.gd` — `Instrument3D` + `scenes/instruments/instrument_3d.tscn` | корпус в 3D для кабинного вида |
| `scripts/instruments/instrument_overlay.gd` — `InstrumentOverlay` + `scenes/instruments/instrument_overlay.tscn` | картинка прибора в углу экрана для внешних камер |
| `scripts/audio/vario_synth.gd` — `VarioSynth` (RefCounted) | синтез звука (чистая математика, тестируется) |
| `scripts/audio/vario_audio.gd` — `VarioAudio` (Node) | AudioStreamGenerator + дозаполнение буфера в `_process` |
| `scenes/instruments/instrument_preview.tscn` | стенд: синтетический термик, звук, 3D-корпус, оверлей |
| `assets/fonts/` | DSEG7 Classic (цифры, OFL 1.1, © keshikan), Noto Sans Mono Condensed Bold (подписи, кириллица, OFL 1.1, © The Noto Project Authors) |

## API

```gdscript
# Vario
vario.setup(cfg := {})                  # пусто — Config.get_config("instruments")
vario.update(t: Telemetry, dt)          # каждый шаг физики
vario.update_raw(vario_ms, dt)          # только вертикальная скорость (тесты)
vario.vario_ms, average_ms, glide_ratio (INF = «--»), altitude_msl_m, altitude_agl_m,
airspeed_ms, groundspeed_ms, heading_deg, track_deg, flight_time_s, in_flight,
distance_from_takeoff_m, takeoff_position, track: PackedVector2Array (x, z)

# FlightInstrument
instrument.update(t: Telemetry, dt := -1)   # dt по умолчанию — шаг физики
instrument.get_texture() -> ViewportTexture
instrument.set_page(i) / next_page() / get_page() / page_count()   # 5 страниц, сигнал page_changed
instrument.set_task([{name, position: Vector3, radius_m}], active := 0)   # set_turnpoints — синоним
instrument.set_task_state(tracker.get_state())   # соревнование: стр. 3–4 по гоулу, {} — выкл
instrument.set_sound_settings(vario_audio.get_settings()); request_setting(k, v) → settings_requested
instrument.get_wind() -> WindEstimator, get_task() -> InstrumentTask
instrument.get_vario() -> Vario
instrument.reset()                          # новый полёт

# Instrument3D / InstrumentOverlay
x.update(t), x.set_page(i), x.use_instrument(fi: FlightInstrument)  # общий прибор, свой отключается
x.instrument                                                         # встроенный FlightInstrument

# VarioAudio
audio.set_vario(ms), audio.set_volume_db(db), audio.set_enabled(on), audio.get_skips()
```

### Подключение в главной сцене (для интегратора)

```gdscript
glider.telemetry_updated.connect(func(t):
    instrument3d.update(t)
    vario_audio.set_vario(instrument3d.instrument.get_vario().vario_ms))
overlay.use_instrument(instrument3d.instrument)  # один SubViewport на оба вида
overlay.visible = camera_mode != "cockpit"       # в кабине прибор видно на трапеции
```

`Instrument3D`: экран смотрит в локальную +Z, верх — +Y, начало — центр корпуса, хомут сзади снизу.
Повесить на базовую штангу трапеции чуть наклонив к пилоту.

Звук берёт **отфильтрованное** значение (`Vario.vario_ms`) — как у реального прибора, писк и цифры совпадают.

## Вариометр
- Инерция датчика — фильтр 1-го порядка с точной дискретизацией (`1 − exp(−dt/τ)`), не зависит от шага.
  τ = 0,7 с (`vario.filter_time_constant_s`), реальные приборы 0,5–1 с.
- Среднее — как у настоящих приборов: изменение высоты за окно / окно (интегратор), окно 25 с
  (`average_window_s`), до заполнения окна — по тому, что есть.
- Качество — пройденное по земле / потерянная высота за `glide_window_s`; в наборе «--».
- Полёт начинается при отрыве (`on_ground = false`) и воздушной скорости > `track.takeoff_min_airspeed_kmh`.
  Время полёта, точка взлёта, расстояние и след считаются от этого момента.

## Экран — планшет (FR-25)
Один полётный компьютер-планшет на центре базовой штанги, как Kobo с XCSoar: e-ink 6", портрет 3:4
(`screen.width_px × height_px`, по умолчанию 720×960), монохром высокой контрастности, перерисовка 10 Гц
(SubViewport в режиме UPDATE_ONCE — рендер только при новых данных). Поля как InfoBox у XCSoar:
подпись слева сверху, единицы справа, значение крупно. Стиль сегментного LCD включается в конфиге
(`digits_font` = DSEG7, `ghost_digits` = true).

Страницы (клавиши 1–5 привязывает главная сцена → `set_page(0..4)`, сигнал `page_changed`):
1. **ПОЛЁТ** — сегментная шкала вариометра ±5 м/с (среднее — треугольник), ВАРИО, СРЕДНЕЕ, КАЧ, ВЫСОТА,
   НАД ЗЕМЛ, ВРЕМЯ, ВОЗД, ПУТЕВ, КУРС, ПУТЬ (стрелка + румб).
2. **КАРТА** — след, взлёт, цилиндры задания (активный жирно), дельтаплан, север, масштаб, автомасштаб
   (след + цель); термики не показываются (FR-22).
3. **ВЕТЕР** — роза (север вверху) со стрелкой ветра и курсом; откуда/скорость, встречная составляющая,
   метод оценки; текущее и требуемое качество, расстояние до цели и высота прибытия (без цели — «--»).
4. **ЗАДАНИЕ** — список пунктов (активный ▶, радиус, расстояние) или «нет задания»; звук вариометра:
   вкл/выкл, громкость, пороги, звучание (пресет). Изменение — `request_setting(key, value)` → сигнал
   `settings_requested` наверх; применяет главная сцена.

5. **ЦЕНТРОВКА** — помощник центровки (как у XCSoar): крыло в центре носом вверх, вокруг — диаграмма подъёма
   по сторонам круга относительно курса, стрелка «сдвинь круг сюда», среднее за круг, направление виража,
   сторона сильного подъёма. На прямой — «нет кружения».

### Соревнование (set_task_state)
`instrument.set_task_state(tracker.get_state())` — состояние `TaskTracker` (scripts/tasks/). С ним:
- стр. 3: «ДО ГОУЛА» — оставшаяся оптимизированная дистанция, «КАЧ ТРЕБ» — требуемое качество до гоула
  от трекера, прибытие — на высоту гоула; «ЦЕЛЬ: <следующий пункт> → гоул»;
- стр. 4: строка статуса (старт через мм:сс / старт открыт / ранний старт / гонка ч:мм:сс / ESS / ГОУЛ),
  пройденные пункты отмечены «√», активный — «▶»;
- стр. 2: активный пункт выделен (активный индекс — `instrument_active`).
`set_task_state({})` — гонки нет, прибор считает по геометрии до активного пункта.

### Помощник центровки (ThermalAssistant)
Только данные прибора: отфильтрованный вариометр своего датчика и курс; атмосфера не читается.
- Кружение: сглаженная скорость разворота ≥ `min_turn_rate_dps` (8°/с) не меньше `circling_confirm_s` (4 с).
- В вираже (в системе воздуха) крыло находится относительно центра круга по пеленгу курс − 90° (вправо)
  или курс + 90° (влево) — снос ветром не мешает, термик сносится вместе с воздухом.
- Задержка датчика: замер относится к курсу τ секунд назад (τ = постоянная фильтра вариометра,
  `sensor_lag_s` = −1). Без этого сильная сторона «уезжает» по кругу на τ·ω (тест: 25°/с → заметная ошибка).
- Замеры за последние 1,5 круга по 36 секторам; первая гармоника даёт сторону и силу асимметрии.
- Стрелка сдвига — `show_shift_arrow`, порог `shift_min_ms`. Масштаб диаграммы — `plot_range_ms`.

Классы: `InstrumentDisplay` (общие помощники рисования), `InstrumentPageFlight/Map/Wind/Task/Thermal` (страницы),
`WindEstimator`, `InstrumentTask`, `ThermalAssistant`.

### Оценка ветра (WindEstimator)
Только из того, что есть у настоящего прибора, — истинный ветер из атмосферы не читается.
- **По кругам** (как circling wind у XCSoar): за полный вираж (≥ 360°, разворот ≥ 6°/с в одну сторону)
  векторы путевой скорости GPS лежат на окружности радиусом = воздушная скорость, её центр — ветер
  (МНК Каса). Круг с невязкой > 1,5 м/с отбрасывается (болтанка). Новый круг входит с весом 0,6.
- **По курсу** на прямых: ветер = путевая скорость − воздушная скорость (горизонтальная) по курсу,
  сглаживание 40 с; к оценке по кругам подмешивается с весом 0,3.
- Показ «откуда дует» (0° — северный). Оценка старше 10 мин — «нет данных».

### Глиссада (InstrumentTask)
Требуемое качество = расстояние до края цилиндра / (высота − высота земли у цели − запас 150 м).
Высота прибытия = высота − высота цели − расстояние / текущее качество. Без учёта ветра и поляры
(MacCready) — это следующий шаг, если понадобится.

### Корпус 3D (Instrument3D)
Грузит `mount_3d.model_path` (`assets/models/instrument.glb`), ищет меш `Screen` (UV 0..1 = весь экран)
и кладёт на него текстуру. Если экран в модели смотрит в −Z, модель разворачивается, чтобы экран смотрел
в +Z (к пилоту). Нет модели или меша — корпус из примитивов (планшет 118×160×12 мм).

## Вариометр 1990-х (FR-25a)
`VarioDisplay90s` (`scenes/instruments/vario_90s.tscn`) — отдельный прибор на стойке трапеции,
обобщённый дизайн без марок: сегментный LCD без подсветки. Дуга из сегментов ±5 м/с, 0 вверху, в центре
цифровой вариометр, внизу высота крупно, по бокам среднее и время. Свой `Vario` с датчиком медленнее
(τ 1 с, среднее 20 с). API: `update(t)`, `get_texture()`, `get_vario()`, `reset()`. Модель корпуса —
агент models (`assets/models/vario_90s.glb`). Звук к нему — `VarioAudio` с пресетом `classic_90s`.

## Звук вариометра
Пресеты звучания (`vario_audio.presets`, выбор — `preset` или `VarioAudio.set_preset(name)`); громкость и
пороги — общие настройки пилота. По умолчанию — `classic_90s`.

**classic_90s** — обобщённый звук 1990-х (docs/research/vario_sounds.md): частый писк 700 → 2000 Гц,
2 → 11 писков/с, скважность 50 %; меандр (нечётные гармоники) + резонанс пьезо 3,2 кГц; гудок 650 → 380 Гц.

**xctracer** — таблица тонов XC Tracer (формат `tone=варио,частота Гц,период мс,скважность %`):

| м/с | Гц | период, мс | писков/с | скважность |
|---|---|---|---|---|
| 0,1 | 400 | 600 | 1,7 | 50 % |
| 1,16 | 550 | 552 | 1,8 | 52 % |
| 2,67 | 763 | 483 | 2,1 | 55 % |
| 4,24 | 985 | 412 | 2,4 | 58 % |
| 6 | 1234 | 332 | 3,0 | 62 % |
| 8 | 1517 | 241 | 4,1 | 66 % |
| 10 | 1800 | 150 | 6,7 | 70 % |

API звука: `set_vario`, `set_preset`, `get_preset`, `get_preset_names`, `set_thresholds`, `set_volume_db`,
`set_enabled`, `get_settings()` (для страницы 4 планшета).

Между точками — линейная интерполяция. Снижение ниже −2,5 м/с — непрерывное гудение 400 → 220 Гц (−2,5 → −10 м/с).
Между порогами — тишина. Гистерезис 0,05 м/с.

Как сделано без щелчков:
- фаза генератора (волновая таблица, нечётные гармоники — тембр пьезопищалки) непрерывна между буферами;
- огибающая писка: линейный ход 6/8 мс + S-форма (smoothstep);
- частота скользит (τ 30 мс), период и скважность фиксируются в начале каждого писка;
- лёгкий подъём частоты внутри писка на 4 % (`climb_chirp_pct`, 0 — ровный тон);
- результат синтеза не зависит от нарезки буфера (проверено тестом побитово).

Буфер 0,12 с дозаполняется в `_process`. Проверено на стенде: 0 пропусков при 165, 60, 30 и даже 12 FPS
(пропуски бывают только при загрузке сцены, когда звук ещё молчит). Синтез 22 050 Гц стоит ~2 % одного ядра.

## Тесты и стенд
```
godot --headless --path . res://tests/run_tests.tscn -- --filter=instruments
VARIO_WAV_DIR=/путь godot --headless --path . res://tests/run_tests.tscn -- --filter=instruments   # + WAV-примеры
xvfb-run -a godot --path . --rendering-method gl_compatibility res://scenes/instruments/instrument_preview.tscn \
    -- --screenshot=/путь/instr.png --page=1 --warmup_s=240 --quit_after_s=2 --skips_report
```
Стенд: Tab/Пробел — страница; 1…9 — подъём N м/с; «−» — −3 м/с; 0 — снова синус.

# Звуки полёта (FR-28)

Компонент `FlightAudio` (`scripts/audio/flight_audio.gd`, сцена `scenes/audio/flight_audio.tscn`).
Логика — `FlightSoundMix` (RefCounted, тесты `tests/audio/`), нода только держит плееры и шины.
Алгоритмы — `docs/research/sounds.md` §3; все числа и пути к файлам — `configs/audio.json → flight`.

## API
```gdscript
flight_audio.update(t: Telemetry, extra := {})  # каждый шаг физики
# extra (всё необязательно): phase "standing"/"walking"/"running"/"flying"/"landed",
#   stall_amount 0..1, turbulence 0..1, sideslip_deg, load_factor (иначе 1/cos(крен)),
#   ground_wind_ms (ветер у земли), surface "grass"/"gravel"
flight_audio.play_landing(result)   # {grade: "soft"|"hard"|"crash", vertical_speed_ms} от планера
flight_audio.play_step(surface := "")  # обычно шаги идут сами по темпу бега
flight_audio.play_carabiner()
flight_audio.set_enabled(on)
```
Подключение: `glider.telemetry_updated → flight_audio.update(t, {"phase": glider.phase(), ...})`,
`glider.landed → flight_audio.play_landing`.

## Слои
| Слой | Шина | Громкость / тон |
|---|---|---|
| rush, rumble, wires (синтез) | Wind | ∝ V^n от v_ref 40 км/ч, с пределами; pitch ∝ V; тросы включаются 25→40 км/ч; бафтинг + болтанка + сваливание |
| ears, fast (записи) | Wind | кроссфейд: уши 5→20 и уход 35→50 км/ч; скоростной поток 55→80 км/ч |
| ФНЧ шины Wind | — | срез 800 + 60·V Гц (до 16 кГц) |
| панорама шины Wind | — | скольжение/20° · 0,6 |
| wing (гул паруса) | Effects | ∝ q·n_z |
| luff + хлопки | Effects | малая скорость (26→33 км/ч) или сваливание; хлопки — пуассон λ = 3 Гц · s² |
| скрипы каркаса | Effects | пуассон по перегрузке (1,15→1,8) и болтанке, только в полёте |
| шаги, дыхание, одышка | Effects | шаг = длина шага / путевая скорость; дыхание нарастает за 4 с бега; одышка после остановки/посадки |
| посадка | Effects | набор файлов по оценке, громкость ± по вертикальной скорости |
| луг, птицы, трава, порывы, колокольчики | Ambient | затухание по AGL 20→150 м (колокольчики 50→400 м), трава/порывы ∝ ветер у земли |

Громкость сглаживается (τ 0,2 с); луп ниже −60 дБ останавливается и потом стартует со случайного места.

## Аудиошины
`scenes/audio/bus_layout.tres`: Master ← Vario, Wind (ФНЧ → панорама → компрессор −6 дБ, 2:1), Effects, Ambient.
Интегратору: в `project.godot` → `[audio] buses/default_bus_layout="res://scenes/audio/bus_layout.tres"`.
Без этого `FlightAudio` сам создаёт недостающие шины при запуске (`create_missing_buses`).
Вариометр — на шине Vario (`vario_audio.bus`), поверх потока.

## Стенд
`scenes/audio/flight_audio_preview.tscn`: карабин → шаг → разбег → взлёт → 30–80 км/ч, виражи, болтанка →
сваливание → посадка → одышка (70 с). Запись в WAV:
```
godot --headless --audio-driver Dummy --path . res://scenes/audio/flight_audio_preview.tscn -- --record=/путь/flight.wav
```
Проверка записи: 80 км/ч громче 38 км/ч на ~10 дБ, пик −5,5 dBFS (запас для вариометра), без клиппинга.
