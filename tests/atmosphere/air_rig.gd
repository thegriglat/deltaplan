extends RefCounted
## Воздух для тестов через фасад W2 v4 (docs/contracts/rust-wind/facade.md): место из функций
## (AirPlaceData.from_functions), условия-эталон, статические термики, фокус, ожидание READY и
## шаги времени. Заменяет прежние set_ground/set_wind/set_thermal_mode/add_static_thermal/step
## (удалены в RW-12x). Без поля Пикара: условия — эталон погоды, не прогноз.
##
## Параметры make(o): cond (условия W5 целиком, вместо preset/over — например прогноз), preset ("weather/medium"), over (ключи пресета поверх), ground (x, z -> высота,
## по умолчанию 0), moist (x, z -> 0..1, по умолчанию 1), half (полуразмер места, м), spacing (шаг, м),
## start_at (с: состояние на этот момент, W2 start_at), statics (Array из [x, z, сила, радиус]), mode (0 dynamic, 1 static, 2 both; по умолчанию 1 при
## statics, иначе 0), seed, focus (Vector3), advance (с игрового времени после READY, по умолчанию 1).

const LOC := {
	"id": "rig",
	"center_lat": 51.5,
	"center_lon": 86.5,
	"utc_offset_h": 6.0,
	"month": 7,
	"day": 15,
}


static func flat(_x: float, _z: float) -> float:
	return 0.0


static func one(_x: float, _z: float) -> float:
	return 1.0


## Эталон погоды: пресет + ключи поверх.
static func preset(base: String = "weather/medium", over: Dictionary = {}) -> Dictionary:
	return Config._deep_merge(Config.get_config(base), over)


## Атмосфера в состоянии READY (или как есть, если за отведённое время не дошла). Освобождает вызывающий.
static func make(o: Dictionary = {}) -> Atmosphere:
	var a := Atmosphere.new()
	a.visuals_enabled = false
	a.deterministic = true
	a.configure(Config.get_config("atmosphere"))  # конфиг визуальных слоёв (cfg)
	a.configure(int(o.get("seed", 7)))
	var cond: Dictionary = o.get("cond", {})
	if cond.is_empty():
		cond = {"preset": preset(String(o.get("preset", "weather/medium")), o.get("over", {}))}
	if o.has("start_hour"):
		cond["start_hour"] = float(o.start_hour)
	a.set_conditions(cond)
	var statics := PackedFloat32Array()
	for s: Array in o.get("statics", []):
		for v: float in s:
			statics.append(v)
	var mode := int(o.get("mode", 1 if not statics.is_empty() else 0))
	a.set_static_thermals(statics, mode)
	var focus: Vector3 = o.get("focus", Vector3(0.0, 300.0, 0.0))
	a.set_focuses(PackedVector3Array([focus]), PackedFloat32Array([1.0]))
	var half := float(o.get("half", 5000.0))
	var spacing := float(o.get("spacing", 100.0))
	var n := int(round(2.0 * half / spacing)) + 1
	var place := AirPlaceData.from_functions(
		o.get("ground", flat), o.get("moist", one), LOC, -half, -half, spacing, n, n
	)
	a.load_place(place)
	if o.has("start_at"):
		a.start_at(float(o.start_at))  # состояние на момент t (W2 start_at), затем READY
	wait_ready(a)
	var dt := float(o.get("advance", 1.0))
	if dt > 0.0:
		a.advance_to(a.time_s + dt)
	return a


## До READY: пампим и отдаём время потокам крейта; false — не дошла.
static func wait_ready(a: Atmosphere, max_ms: int = 60000) -> bool:
	var t0 := Time.get_ticks_msec()
	while not a.is_ready() and Time.get_ticks_msec() - t0 < max_ms:
		if int(a.status().state) == Atmosphere.STATE_FAILED:
			return false
		a.pump(4000)
		OS.delay_usec(1000)
	return a.is_ready()


## Продвинуть воздух на secs шагами по step_s (как прежние step в цикле).
static func run(a: Atmosphere, secs: float, step_s: float = 1.0) -> void:
	var t_end := a.time_s + secs
	while a.time_s + 1.0e-9 < t_end and a.is_ready():
		a.advance_to(minf(a.time_s + step_s, t_end))


## Один шаг dt от текущего времени.
static func step(a: Atmosphere, dt: float) -> void:
	a.advance_to(a.time_s + dt)
