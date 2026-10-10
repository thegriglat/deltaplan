---
type: contract
status: active
module: motion-rig
updated: 2026-10-10
summary: "Контракты модуля motion-rig: точка пилота в состоянии полёта (MR-К1), величины движения и знаки (MR-К1), пакет UDP (MR-К2), настройки (MR-К3)."
related: ["docs/plan/motion-rig.md", "docs/research/motion-rig-protocols.md"]
contracts: [{"id": "MR-К1", "version": 1}, {"id": "MR-К2", "version": 1}, {"id": "MR-К3", "version": 1}]
---
# Контракты модуля motion-rig

План — `docs/plan/motion-rig.md`. Менять — только через координатора (версия +1, что изменилось, уведомить потребителей).
Контрактный тест — `tests/contracts/test_motion_rig_contracts.gd` (headless, без сети и GPU): проверяет строки «## MR-К<n>. … (v<n>)»
этого файла, форму классов и полей ниже, разбор пакета по MR-К2.

## MR-К1. Точка пилота и величины движения (v1)
Владелец: MR-2. Потребители: отправка (MR-2), будущий маятник пилот–крыло (поставщик точки пилота), документация (MR-3).

**Единственный источник — точка пилота в `Telemetry`.** `FlightModel._update_telemetry` заполняет в `Telemetry`
(`scripts/core/telemetry.gd`) три поля, мировая система сцены (X восток, Y вверх, −Z север), единицы СИ:
- `pilot_position: Vector3` — м, точка подвески/тела пилота (сиденье платформы ↔ тело пилота);
- `pilot_velocity: Vector3` — м/с, скорость этой точки относительно земли (инерциальная система);
- `pilot_basis: Basis` — ориентация связанной системы пилота: локальная −Z — вперёд, +Y — вверх (от ног к голове/по стойке),
  +X — вправо.
Сейчас (одна материальная точка): `pilot_position = position`, `pilot_velocity = velocity`, `pilot_basis = telemetry.basis`
(`Basis.from_euler(Vector3(theta, -heading, -bank))`). С маятником эти три поля начнёт заполнять он — вывод не меняется.
Поправки на смещение головы от точки (ε×r, ω×(ω×r)) не вводятся: платформа сама поворачивает сиденье, вращательную
часть ускорения головы даёт её движение.

**Величины** — `class_name MotionSample extends RefCounted` (`scripts/motion_rig/motion_sample.gd`), считает
`class_name MotionSource extends RefCounted` (`scripts/motion_rig/motion_source.gd`) из последовательности
(`pilot_position`, `pilot_velocity`, `pilot_basis`, время `t` с) и только из неё:
- `MotionSource.push(tel: Telemetry, dt: float) -> void` — шаг физики (dt — шаг физики, с); `sample() -> MotionSample` —
  величины за интервал от прошлого `sample()` до текущего (среднее по интервалу = разность состояний / время интервала,
  без фильтров); `reset() -> void` — разрыв (старт, перезапуск, телепорт, снимок).
- Связанные оси пилота (авиационные): вперёд F = −Z_local, вправо R = +X_local, вверх U = +Y_local.
- `surge`, `sway`, `heave: float` — м/с², удельная сила f = a − g_vec в связанной системе: проекции на F, R, U.
  a = (v_k − v_{k−n}) / (n·dt) по `pilot_velocity`; g_vec = (0, −Units.G, 0). Знаки: разгон вперёд → surge > 0
  (сверх g·sin(pitch)); сила вправо (скольжение/внешняя сила вправо) → sway > 0; «давит в сиденье» → heave > 0.
  Ожидаемые значения в модели точки: установившееся планирование — a = 0, f = +g вверх, т. е. heave = g·cos(pitch),
  surge = g·sin(pitch) (≈ +1.1 м/с² при pitch ≈ 6.6°), sway = 0; координированный вираж с креном φ — sway ≈ 0,
  heave ≈ g/cos φ (центростремительное ускорение уже в наклоне силы); невесомость → все ≈ 0. Наклон g в осях
  тела входит в surge/sway/heave честно; его повторение каналом углов платформы — настройка софта платформы.
- `roll`, `pitch`, `yaw: float` — градусы, ориентация `pilot_basis`: yaw — курс проекции F на горизонт, 0 = север,
  по часовой (восток = 90), диапазон [0, 360); pitch — угол F над горизонтом, нос вверх > 0, [−90, 90];
  roll — поворот вокруг F, правое крыло вниз > 0, (−180, 180]: roll = atan2(−R.y, U.y).
  Для одной точки совпадают с `rad_to_deg(theta)`, `heading`, `bank` модели (контрактный тест).
- `roll_rate`, `pitch_rate`, `yaw_rate: float` — град/с, угловая скорость пилота в связанной системе за интервал
  (из относительного поворота B_{k−n}ᵀ·B_k / время): roll_rate — вокруг F, правое крыло вниз > 0; pitch_rate — вокруг R,
  нос вверх > 0; yaw_rate — вокруг U, нос вправо > 0. В Godot-осях: pitch_rate = ω_x, yaw_rate = −ω_y, roll_rate = −ω_z.
- `airspeed: float` — м/с, |`air_velocity`|; `air_lateral: float` — м/с, проекция `air_velocity` (воздушная скорость
  аппарата) на R (скольжение вправо > 0). Пока точка = ЦМ.
- `t: float` — с, время полёта (сумма dt с `reset()`); `on_ground: bool` — `Telemetry.on_ground` (для `generic`).
- `valid: bool` — false на первом `sample()` после `reset()`/создания (нет прошлого состояния): тогда ускорение и
  угловые скорости = 0, т. е. surge = sway = 0, heave = проекция +g на U; отправка такой пакет шлёт.
- Защита от телепорта: если |a| > 50·g на интервале — считается разрывом, как `reset()` (удар о землю < 50 g).
Инварианты: никакого сглаживания, ограничения, масштабирования и washout — это делает софт платформы.
Вне полёта (меню, пауза) `push` не вызывается, пакетов нет — приёмник сам уводит платформу в нейтраль по таймауту.

## MR-К2. Пакет UDP (v1)
Владелец: MR-2. Потребители: приёмник `tools/motion_rig/recv.py`, Sim Racing Studio (софт DOF Reality H-серии),
свои/самодельные приёмники, инструкция игроку (MR-3). Основание — `docs/research/motion-rig-protocols.md`
(SimTools 2/3 и FlyPT Mover общего UDP-входа не имеют, родной вход DOF Reality — SRS API).
- UDP, один датаграм = один `MotionSample` на адрес:порт из MR-К3; каждые N = max(1, round(physics_hz / rate_hz))
  шагов физики (величины — за эти N шагов по MR-К1). Два формата, выбор — `format` в MR-К3. Все числа little-endian.

### Формат `srs` — Sim Racing Studio API v102 (по умолчанию), 236 байт
Структура C с нативным выравниванием (репозиторий https://gitlab.com/simracingstudio/srsapi, MIT):

| смещение | поле | тип | значение |
|---|---|---|---|
| 0 | api_mode | char[3] | `api` (+1 байт выравнивания = 0) |
| 4 | version | uint32 | 102 |
| 8 | game | char[50] | `Deltaplan`, добито нулями |
| 58 | vehicle_name | char[50] | `Hang glider` |
| 108 | location | char[50] | название места старта (UTF-8, обрезать до 49 байт по границе символа), +2 байта выравнивания |
| 160 | speed | float32 | `airspeed`, км/ч |
| 164 | rpm, max_rpm | float32 ×2 | 0, 0 |
| 172 | gear | int32 | 0 |
| 176 | pitch | float32 | `pitch`, град |
| 180 | roll | float32 | `roll`, град |
| 184 | yaw | float32 | `yaw`, переведённый в (−180, 180], град |
| 188 | lateral_velocity | float32 | `air_lateral`, м/с (скольжение; в модели точки ≈ 0) |
| 192 | lateral_acceleration | float32 | `sway / G`, g |
| 196 | vertical_acceleration | float32 | `heave / G − 1`, g (перегрузка сверх 1 g: в установившемся полёте ≈ 0 — как у примеров SRS, где в покое 0) |
| 200 | longitudinal_acceleration | float32 | `surge / G`, g |
| 204 | suspension_travel | float32 ×4 | 0 |
| 220 | wheel_terrain | uint32 ×4 | 0 |

Знаки — как в MR-К1 (нос вверх, правое крыло вниз, вперёд, вправо, вверх — плюс); SRS их не документирует —
при обратном знаке инвертировать ось в SRS (инструкция MR-3). G = `Units.G`.

### Формат `generic` — свой, для самодельных и будущих приёмников, 64 байта
| смещение | поле | тип | значение |
|---|---|---|---|
| 0 | magic | char[4] | `DPMR` |
| 4 | version | uint32 | 1 |
| 8 | seq | uint32 | номер пакета с запуска отправки, +1 на пакет |
| 12 | flags | uint32 | бит 0 — `valid`, бит 1 — на земле (`Telemetry.on_ground`) |
| 16 | t | float32 | с, время полёта (сумма dt с `reset()`) |
| 20 | surge, sway, heave | float32 ×3 | м/с², удельная сила как в MR-К1 (горизонтальный полёт: heave ≈ +9.81) |
| 32 | roll, pitch, yaw | float32 ×3 | град, как в MR-К1 (yaw [0, 360)) |
| 44 | roll_rate, pitch_rate, yaw_rate | float32 ×3 | град/с, как в MR-К1 |
| 56 | airspeed | float32 | м/с |
| 60 | air_lateral | float32 | м/с |

Приёмник `tools/motion_rig/recv.py` (Python stdlib): `--port`, `--format srs|generic`, печать строкой и `--jsonl файл`
(строка на пакет: все поля по именам выше, `t_recv`); понимает оба формата; неверный размер/заголовок — строка-ошибка, не падение.

## MR-К3. Настройки (v1)
Владелец: MR-2. Потребители: панель настроек, отправка, инструкция игроку (MR-3).
- `configs/motion_rig.json` (слои `Config`): `enabled: bool = false`, `host: String = "127.0.0.1"`,
  `port: int = 33001` (SRS по умолчанию), `rate_hz: int = 60` (1…physics_hz), `format: String = "srs"` (`srs` | `generic`). Читать — `Config.value("motion_rig", "<ключ>")`.
- Ключи машинные (не облако Steam): в `UserSettings.LOCAL_KEYS` и `steam/partner/auto_cloud.json` → `local_keys`
  (тест S7 сверяет списки).
- UI: `scripts/ui/settings_panel.gd`, раздел «Платформа подвижности» / «Motion platform»: флажок «Вывод движения»,
  поле адреса `host:port`, частота (Гц), формат (`SRS (DOF Reality)` / `Generic`). Сохранение — `UserSettings.save_patch("motion_rig", …)`; применяется сразу,
  без перезапуска полёта. Неверный адрес — отправка выключена, без исключений и без падений.
- Выключено → сокет не создаётся, на шаг физики — ноль работы сверх одной проверки флага.
- Отправка не блокирует кадр: `PacketPeerUDP` (неблокирующий `put_packet`), ошибки отправки (нет приёмника) молча
  пропускаются; сколько-нибудь заметной работы в шаге физики нет (≤ ~10 мкс на пакет).
