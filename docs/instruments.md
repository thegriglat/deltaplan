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
instrument.set_page(i) / next_page() / get_page() / get_page_count()   # 0 — вариометр, 1 — карта
instrument.set_turnpoints([{name, position: Vector3, radius_m}])
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

## Экран
Портретный 480×640 (`screen.*`), перерисовка 15 Гц (`update_hz`, SubViewport в режиме UPDATE_ONCE —
рендер только когда есть новые данные). Семисегментные цифры с бледными «погашенными» сегментами 8,
серо-зелёный фон, затемнение к краям — как транфлективный LCD Flytec/Skytraxx.

- **Страница 0 «ВАРИО»:** слева сегментный столбик ±5 м/с (подъём — сплошные сегменты, снижение — полые,
  треугольник — среднее), справа поля: ВАРИО (крупно), СРЕДНЕЕ, КАЧ, ВЫСОТА (MSL), НАД ЗЕМЛ (AGL),
  РАССТ (от взлёта), ВОЗД и ПУТЕВ (км/ч), КУРС, ПУТЬ (стрелка путевого угла + румб).
  Время полёта — в строке состояния.
- **Страница 1 «КАРТА»:** свой след, точка взлёта (квадрат), поворотные пункты-цилиндры с подписями,
  значок дельтаплана по курсу, стрелка севера, масштабная линейка, автомасштаб. Термики не показываются (FR-22).
  Ориентация `map.orientation`: `north_up` (по умолчанию) или `track_up`.

Геометрия раскладки полей (доли высоты рядов, отступы) — в коде `InstrumentDisplay`: это вёрстка, а не
параметры модели; всё, что может захотеть поменять пилот (цвета, шрифты, шкала, масштаб, размеры) — в конфиге.


## Звук вариометра
Кривые по умолчанию — таблица тонов XC Tracer (формат `tone=варио,частота Гц,период мс,скважность %`):

| м/с | Гц | период, мс | писков/с | скважность |
|---|---|---|---|---|
| 0,1 | 400 | 600 | 1,7 | 50 % |
| 1,16 | 550 | 552 | 1,8 | 52 % |
| 2,67 | 763 | 483 | 2,1 | 55 % |
| 4,24 | 985 | 412 | 2,4 | 58 % |
| 6 | 1234 | 332 | 3,0 | 62 % |
| 8 | 1517 | 241 | 4,1 | 66 % |
| 10 | 1800 | 150 | 6,7 | 70 % |

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
