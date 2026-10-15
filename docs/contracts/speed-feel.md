---
type: "contract"
status: "active"
module: "speed-feel"
area: "flight"
updated: "2026-10-15"
summary: "Стыки ощущения скорости: тряска → камера (К1), поток → ленточка (К2), скорость → тон тросов (К3), тангаж крыла → голова (К4)."
related: ["docs/plan/speed-feel.md"]
contracts: [{"id": "SPF-К1", "version": 2}, {"id": "SPF-К2", "version": 1}, {"id": "SPF-К3", "version": 1}, {"id": "SPF-К4", "version": 1}]
---
# Контракты модуля speed-feel

План — `docs/plan/speed-feel.md`. Менять — только через координатора (версия +1, что изменилось, уведомить потребителей).
Контрактные тесты — по файлу на стык (параллельные задачи не правят один файл): `tests/contracts/test_speed_feel_k1.gd` … `…_k4.gd` (headless, без сети и GPU; каждый проверяет заголовок своего раздела с версией в этом документе — регулярка `(?m)^## (SPF-К\d)\. .* \(v(\d+)\)\s*$`, как `tests/contracts/test_control_bar_contracts.gd`). Пишет владелец стыка.

Общее для всех стыков: физика полёта (`scripts/flight/flight_model.gd`, силы, модель крыла) не меняется — только визуальный и звуковой отклик; никаких игровых условностей (FOV, размытие, полосы скорости) и сообщений игроку.

## SPF-К1. Тряска крыла `buzz` → кабинная камера (v2)
Владелец: SPF-2 (`scripts/flight/glider_visual.gd`, `configs/flight.json → visual.buzz`). Потребители: `scripts/game/camera_rig.gd` (`_shake`: `buzz × cockpit.shake.follow`, без изменений), руки на штанге в `glider_visual.gd` (`bar_grip − buzz`).
v2 (2026-10-15, по SPF-1): амплитуда без множителя скорости (скорость уже в физике), остался только сдвиг частот; ключ `speed_ratio_range` убран.
- `GliderVisual.buzz: Vector3` — смещение крыла с трапецией относительно пилота, м, оси визуала; `|buzz| ≤ visual.buzz.max_m` всегда (предел сохраняется).
- Вход — без смены сигнатуры: `set_flight(airspeed_ms: float, stall_amount: float, turbulence: float)` (воздушная скорость, м/с; болтанка 0..1 = `FlightModel.load.jitter / sail.turbulence_full_g`) и перегрузка `FlightModel.load` (`load_factor`, `load_raw`). `set_flight` дополнительно запоминает `airspeed_ms` для тряски.
- V_trim — `FlightModel.trim_speed()` модели родителя-`Glider` (м/с, с поправкой на массу и плотность). Нет модели (бот без `Glider`, тесты визуала) или V_trim ≤ 0 → r_f = 1, поведение как до модуля.
- Амплитуда — **без множителя скорости**: все её члены (`turbulence_m × болтанка`, `load_m_per_g`, толчок) идут от `FlightModel.load`, где Δn ∝ V уже есть (замер SPF-1 §1: `load.jitter` на ≈ 2·V_трим в 2,0–3,1 раза больше, ∝ V^1,2–1,5); умножение на V/V_трим было бы двойным счётом.
- Частоты: каждая частота `freqs_hz[i]` умножается на r_f = clamp(V / V_trim, `freq_ratio_range[0]`, `freq_ratio_range[1]`) — новый ключ `visual.buzz.freq_ratio_range` (с `_doc`), по умолчанию [0,7, 2,0]: частота встречи с порывами ∝ V (порывы `GustSpectrum` заморожены в пространстве — SPF-1 §1, гипотеза Тейлора); верх 2,0 держит max(freqs_hz)·r_f ≤ 15 Гц (≥ 4 кадра на период при 60 кадр/с, как у ленточки). Фаза каждой составляющей **накапливается** (∫2πf dt), при смене скорости скачков фазы нет.
- Инвариант: болтанка 0, перегрузка 1 g (|n−1| ≤ `load_deadzone_g`, `load_raw = load_factor`) → `buzz = 0` при любой скорости.
- Инвариант: при r_f = 1 тряска совпадает с тряской до модуля (те же амплитуды и частоты).

## SPF-К2. Поток у узла → трепет ленточки (v1)
Владелец: SPF-3 (`scripts/instruments/telltale_model.gd`, `configs/instruments.json → telltale`). Потребители: `scripts/instruments/telltale.gd` (отрисовка по `dirs`), `tests/instruments/test_telltale.gd`.
- Интерфейс без изменений: `setup(cfg)`, `step(dt, w)` (w — поток относительно точки крепления, мир, м/с), `snap(w)`, `equilibrium(w)`, `direction()`, `dirs`, `flutter_angle` (текущая амплитуда трепета у хвоста, рад).
- Новое поле `flutter_hz: float` — частота трепета, применённая на этом шаге, Гц (после ограничения отображения).
- Физическая частота: f = St · s / L_ref, s = |w| (м/с); St и L_ref — ключи `flutter_strouhal`, `flutter_ref_len` (определение длины — как в источнике SPF-1 п. 3; источник — в `_doc`).
- Отображение: `flutter_hz ≤ flutter_max_hz ≤ 15` Гц (≥ 4 кадра на период при 60 кадр/с, без стробоскопа); что происходит выше предела (например, амплитуда видимых колебаний убывает как у размытого движения) — решает SPF-3, записывает в `docs/guide/telltale.md`.
- Свойства, проверяемые тестом (постоянный поток, установившееся состояние):
  1. `flutter_hz(s)` не убывает на s ∈ [0, 25] м/с;
  2. `flutter_angle(25) < flutter_angle(8)` — на большой скорости лента вытянута и мелко дрожит, на малой полощется;
  3. 12 и 25 м/с различимы: `flutter_hz(25) ≥ 1,3 · flutter_hz(12)` или `flutter_angle(25) ≤ 0,7 · flutter_angle(12)`;
  4. равновесное направление (`equilibrium`, средняя линия) не меняется — существующие тесты `test_telltale` проходят.

## SPF-К3. Воздушная скорость → эоловый тон тросов (v1)
Владелец: SPF-4 (`scripts/audio/wire_tone.gd` — новый, `scripts/audio/flight_audio.gd`, `scripts/audio/flight_sound_mix.gd`, `configs/audio.json → flight.airflow`). Потребители: `FlightAudio` (плеер), `tests/audio/test_flight_sound_mix.gd`.
- `class_name WireTone extends RefCounted` (headless, без нод):
  - `setup(cfg: Dictionary, mix_rate: float, seed_value: int = 0) -> void` — cfg = `flight.airflow.wire_tone`;
  - `set_airspeed(v_ms: float) -> void` — воздушная скорость, м/с;
  - `frequencies() -> PackedFloat32Array` — текущие частоты тросов f_i = St · V / d_i, Гц;
  - `fill(frames: int) -> PackedVector2Array` — стерео-кадры, |сэмпл| ≤ 1, без громкости микса (громкость — `volume_db` плеера по `FlightSoundMix`).
- Конфиг `flight.airflow.wire_tone`: `strouhal` (≈ 0,2), `diameters_m` (по SPF-1 п. 4), параметры полос и огибающей — каждый с `_doc` и источником.
- Тросы с f_i > 0,45 · mix_rate не звучат; V ниже порога включения → тишина (нули).
- `FlightSoundMix.compute()["wires"]: Vector2(дБ, pitch)` — ключ сохраняется, pitch = 1 (частоту задаёт `WireTone`); громкость растёт со скоростью; инвариант: при V ∈ [30, 90] км/ч `wires.x < rush.x` (тише общего шума ветра), при 30 км/ч не ниже `silence_db`.
- Файл-луп `wires` из `flight.airflow.files` убран; воспроизведение — `AudioStreamGenerator` на шине ветра, как вариометр (`scripts/audio/vario_audio.gd`).

## SPF-К4. Тангаж крыла → голова в кабине (v1)
Владелец: SPF-5 (`scripts/game/camera_rig.gd`, `configs/camera.json → cockpit`; read-only метод в `scripts/flight/flight_model.gd`). Потребители: кабинная камера; `tests/game/test_camera_bar_look.gd`, `tests/ui/test_helmet_fov.gd`, `tests/flight/pendulum/test_pendulum_visual.gd` (не ломаются).
Решение пользователя Q1 (вариант B, 2026-10-15): голова медленно следует за тангажом крыла относительно трима на долю 0,3, тряску не повторяет. Обоснование — `docs/research/speed-feel.md` §2, §5.
- `FlightModel.trim_pitch() -> float` — тангаж киля θ_трим в установившемся планировании на `trim_speed()` при текущих массе и плотности, рад (та же формула, что в `reset_in_air`: γ из `steady_glide`, α из `_alpha_for_cl`); чистая функция, состояние модели не меняет, физика полёта не меняется.
- θ_крыла — тангаж продольной оси крыла (−Z базиса цели камеры) над горизонтом, рад.
- Тангаж головы: p = `head_pitch_follow` · (θ_крыла − θ_трим), сглаженный экспонентой с постоянной `head_pitch_follow_s`, затем ограниченный ±`head_pitch_max_deg`. Ключи `cockpit.head_pitch_follow` = 0,3 (диапазон 0,1–0,5), `cockpit.head_pitch_follow_s` = 2,0 с (медленно: ниже 1 Гц голову держат зрение и воля, не рефлексы), `cockpit.head_pitch_max_deg` — каждый с `_doc` и источником.
- Голова: `Basis(UP, курс) · Basis(BACK, −доля крена) · Basis(RIGHT, p)`; + p — нос вверх. `look_down_deg`, взгляд мышью/клавишами, «взгляд на прибор» — поверх, как сейчас.
- Тряска (`buzz`, `cockpit.shake`) в p не входит: p считается только из базиса цели (крыло без визуальной тряски).
- Нет модели у цели (не `Glider`, бот, тест) → θ_трим = 0 и p = 0 (как до модуля). `snap()` / телепорт → сглаживание сбрасывается сразу на целевое p.
- Инварианты: на триме p = 0 (кадр как до модуля); `head_pitch_follow` = 0 → кадр как до модуля; при Δθ = −15° установившемся p → −4,5° (± 0,2°).
