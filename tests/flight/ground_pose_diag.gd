extends Node
## FB-3: диагностика крыла стоя на земле — тангаж (начальный, размах, период за 10 с) и курс,
## оба режима управления («Смещение веса» — FlightModel + GroundRun, «Маятник» — PendulumModel +
## PendulumGround), без ввода и с вводом мыши, штиль / встречный / боковой ветер, ровно и склон.
##
## Запуск (без окна, ~1 мин):
##   godot --headless --path . res://tests/flight/ground_pose_diag.tscn -- [--csv=файл.csv]
##       [--wings=training,sport]
## Строка CSV на случай. Мышь: «mouse_hold» — смещение мыши 0,3 хода от себя и держит
## (bar_return_to_center_per_s = 0: трапеция держит последнее положение мыши); «mouse_jitter» —
## дрожь руки на мыши: сумма синусоид 0,4–2,7 Гц, ±0,04 хода (≈ ±20 px при 1080p).

const FS := preload("res://tests/flight/flight_sim.gd")
const PS := preload("res://tests/flight/pendulum/pendulum_sim.gd")
const DT := 1.0 / 120.0
const T_STAND := 10.0
const SLOPE_DEG := 15.0

var _csv: FileAccess
static var _t := 0.0  ## время случая для порывов, с


func _ready() -> void:
	var path := "user://fb3_ground_pose.csv"
	var wings := ["training", "sport"]
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--csv="):
			path = a.substr(6)
		elif a.begins_with("--wings="):
			wings = a.substr(8).split(",")
	_csv = FileAccess.open(path, FileAccess.WRITE)
	_csv.store_line(
		"mode,wing,ground,wind,input,theta0_deg,theta_min_deg,theta_max_deg,p2p_deg,period_s,"
		+ "p2p_last5_deg,theta_end_deg,heading_end_deg,phase_end,failed"
	)
	for mode in ["fm", "pd"]:
		for w: String in wings:
			for ground in ["flat", "slope"]:
				for wind in ["calm", "head5", "head5_slope", "cross5", "gust5"]:
					if ground == "flat" and wind == "head5_slope":
						continue
					for inp in ["none", "mouse_hold", "mouse_jitter"]:
						_run(mode, w, ground, wind, inp)
	_csv.close()
	print("FB3 diag done: ", ProjectSettings.globalize_path(path))
	get_tree().quit(0)


static func _ground_fn(ground: String) -> Callable:
	if ground == "flat":
		return func(_x: float, _z: float) -> float: return 0.0
	var k := tan(deg_to_rad(SLOPE_DEG))
	return func(_x: float, z: float) -> float: return k * z  # вниз на север (−Z)


## Ветер (скорость воздуха, оси игры). Пилот смотрит на север (−Z): встречный — воздух на юг (+Z).
static func _air_fn(wind: String) -> Callable:
	match wind:
		"head5":
			return func(_p: Vector3) -> Vector3: return Vector3(0.0, 0.0, 5.0)
		"head5_slope":
			var a := deg_to_rad(SLOPE_DEG)
			return func(_p: Vector3) -> Vector3: return Vector3(0.0, 5.0 * sin(a), 5.0 * cos(a))
		"cross5":
			return func(_p: Vector3) -> Vector3: return Vector3(-5.0, 0.0, 0.0)  # с востока
		"gust5":
			# встречный 5 м/с с вертикальными порывами σw ≈ 0,7 м/с (у земли σw ≈ 1,25 u*, u* ≈ 0,5)
			return func(_p: Vector3) -> Vector3:
				var w := 0.6 * sin(TAU * 0.3 * _t) + 0.5 * sin(TAU * 0.8 * _t + 1.0) + 0.4 * sin(TAU * 1.7 * _t + 2.0)
				return Vector3(0.0, w, 5.0)
	return Callable()


static func _pitch_in(inp: String, t: float) -> float:
	match inp:
		"mouse_hold":
			return 0.3
		"mouse_jitter":
			return 0.04 * (
				0.5 * sin(TAU * 0.4 * t) + 0.3 * sin(TAU * 1.3 * t + 1.0)
				+ 0.2 * sin(TAU * 2.7 * t + 2.0)
			)
	return 0.0


func _run(mode: String, w: String, ground: String, wind: String, inp: String) -> void:
	var gf := _ground_fn(ground)
	var af := _air_fn(wind)
	var m: Variant
	if mode == "fm":
		m = FS.make(w)
	else:
		m = PS.make(w)
	m.reset_on_ground(Vector3(0.0, 0.0, 0.0), 0.0)
	var c := ControlInput.new()
	c.weight_shift = true
	var th: PackedFloat64Array = []
	var n := int(round(T_STAND / DT))
	var theta0 := NAN
	var failed := ""
	for i in n:
		var t := i * DT
		_t = t
		c.pitch = _pitch_in(inp, t)
		m.step(DT, c, af, gf)
		if m.mode == FlightModel.Mode.FAILED:
			failed = String(m.takeoff_failure)
			break
		var deg: float = rad_to_deg(m.theta)
		if i == 0:
			theta0 = deg
		th.append(deg)
	var lo := INF
	var hi := -INF
	var lo5 := INF
	var hi5 := -INF
	var mean := 0.0
	for i in th.size():
		lo = minf(lo, th[i])
		hi = maxf(hi, th[i])
		mean += th[i]
		if i * DT >= T_STAND - 5.0:
			lo5 = minf(lo5, th[i])
			hi5 = maxf(hi5, th[i])
	mean /= maxf(th.size(), 1)
	# период — по пересечениям среднего за последние 8 с
	var cross: Array[float] = []
	var m8 := 0.0
	var k0 := int(2.0 / DT)
	for i in range(k0, th.size()):
		m8 += th[i]
	m8 /= maxf(th.size() - k0, 1)
	for i in range(k0 + 1, th.size()):
		if (th[i - 1] - m8) * (th[i] - m8) < 0.0 and absf(hi5 - lo5) > 0.05:
			cross.append(i * DT)
	var period := NAN
	if cross.size() >= 3:
		period = 2.0 * (cross[-1] - cross[0]) / (cross.size() - 1)
	var line := "%s,%s,%s,%s,%s,%.2f,%.2f,%.2f,%.2f,%.2f,%.2f,%.2f,%.1f,%s,%s" % [
		mode, w, ground, wind, inp, theta0, lo, hi, hi - lo, period, hi5 - lo5,
		th[-1] if th.size() > 0 else NAN, rad_to_deg(m.heading), m.phase(), failed
	]
	_csv.store_line(line)
	print(line)
