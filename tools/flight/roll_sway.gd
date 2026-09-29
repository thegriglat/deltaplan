extends Node
## Раскачка по крену в прямом полёте: старт в воздухе (Game.air_start_m, как --air-start) вдали
## от старта, синтетический пилот летит прямо, телеметрия (scripts/core/telemetry.gd) → метрики.
##
## Запуск (без окна, ~2–4 мин):
##   godot --headless --path . res://tools/flight/roll_sway.tscn -- [--secs=90] [--dist=1000]
##       [--agl=300] [--location=ongudai] [--site=kayancha_south] [--mass=85]
##       [--weathers=weak,medium,strong] (WEATHERS) [--wings=training,sport] [--csv=файл.csv]
##       [--dump=ряд.csv] [--dump_mode=weight_shift]   (по шагам: крен, курс, воздух —
##       прогон «hands» в этом режиме; при нескольких погодах/крыльях — последний)
##       [--large_scale=<м>]  подменить atmosphere.json → turbulence.large_scale_m (0 — один
##       масштаб, как до правки) — для таблицы «до/после»
##
## Матрица: погода × крыло × режим крена (rate / weight_shift) × пилот:
##   hands — руки нейтрально, крен не исправляет;
##   human — «как человек»: видит крен с задержкой HUMAN_DELAY_S, ручка против крена
##           (полный ход при HUMAN_FULL_DEG), мёртвая зона HUMAN_DEADBAND_DEG.
## Шагаем сами: воздух → ввод бота → планер (порядок Game.tick, без InputController —
## ввод бота прямо в ControlInput, режим крена — control.weight_shift).
##
## Метрики (после разгона WARMUP_S): крен — среднее, СКО, размах, max|крен|; период — пик
## спектра крена (0,02–2 Гц); курс — СКО отклонения от линейного тренда и СКО скорости рыскания;
## маятник — угол тела пилота к крылу (GliderVisual: asin(смещение/L), только от ручки — в модели
## полёта у маятника нет своей динамики); n — СКО мгновенной перегрузки (load_raw); p_air —
## СКО кренящей угловой скорости от разницы потоков на концах (то, что раскачивает крыло).
## Отдельно — отклик на толчок в спокойном воздухе: перерегулирование и период (затухание).

const DT := 1.0 / 120.0
const MAIN_SCENE := preload("res://scenes/main.tscn")
const WARMUP_S := 5.0
const HUMAN_DELAY_S := 0.3
const HUMAN_FULL_DEG := 30.0
const HUMAN_DEADBAND_DEG := 1.0
const MODES := ["rate", "weight_shift"]
const PILOTS := ["hands", "human"]
## Погоды для --weathers: прогноз [температура °C, ветер км/ч], ветер в лоб старту.
const WEATHERS := {
	"weak": [20.0, 7.0], "medium": [26.0, 11.0], "strong": [31.0, 18.0], "storm": [34.0, 14.0],
	"wave": [18.0, 36.0],
}
## Колонки таблицы: ключ метрики, заголовок, формат.
const COLS := [
	["bank_mean", "крен ср °", "%.1f"],
	["bank_sd", "СКО крена °", "%.2f"],
	["bank_p2p", "размах °", "%.1f"],
	["bank_abs_max", "max|крен| °", "%.1f"],
	["bank_period", "период с", "%.1f"],
	["hdg_sd", "СКО курса °", "%.1f"],
	["yaw_sd", "СКО рыск. °/с", "%.2f"],
	["yaw_turn_sd", "рыск. от крена °/с", "%.2f"],
	["hdg_jit", "рывки курса °", "%.2f"],
	["pend_max", "маятник max °", "%.1f"],
	["n_sd", "СКО n", "%.3f"],
	["pair_sd", "p_air СКО °/с", "%.2f"],
	["pair_period", "p_air период с", "%.1f"],
	["pair_calm_sd", "p_air без болт. °/с", "%.2f"],
	["gust_h_rms", "гориз. порыв м/с", "%.2f"],
	["agl_min", "AGL min м", "%.0f"],
]

var _args := {
	"secs": "90",
	"dist": "1000",
	"agl": "300",
	"location": "ongudai",
	"site": "kayancha_south",
	"mass": "85",
	"weathers": "weak,medium,strong",
	"wings": "training,sport",
	"csv": "",
	"dump": "",
	"dump_mode": "weight_shift",
	"large_scale": "",
}
var _rows: Array[Dictionary] = []


func _ready() -> void:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--") and a.contains("="):
			var kv := a.substr(2).split("=", true, 1)
			_args[kv[0]] = kv[1]
	if String(_args.large_scale) != "":
		# до/после: 0 — прежняя болтанка одного масштаба (atmosphere.json → turbulence)
		var tb: Dictionary = Config.get_config("atmosphere").turbulence
		tb.large_scale_m = float(_args.large_scale)
	_impulse_table()
	await _run_matrix()
	_print_table()
	get_tree().quit(0)


# ---------------------------------------------------------------- отклик на толчок


## Спокойный воздух, руки нейтрально, толчок по крену 20 °/с: максимум крена, перерегулирование
## (заброс через ноль / максимум) и период — показывают демпфирование самовыравнивания.
func _impulse_table() -> void:
	print("\n== толчок по крену 20 °/с, спокойный воздух, weight_shift, %s кг ==" % _args.mass)
	print("| крыло | max крен ° | заброс через 0 ° | заброс % | период с | ζ≈ |")
	print("|---|---|---|---|---|---|")
	for wing_id in String(_args.wings).split(","):
		var wing: Dictionary = Config.get_config("wings/" + wing_id)
		var pilot: Dictionary = Config.get_config("pilot").duplicate(true)
		pilot.mass_kg = float(_args.mass)
		var m := FlightModel.new()
		m.setup(wing, pilot)
		m.reset_in_air(Vector3(0, 2000, 0), 0.0)
		var c := ControlInput.new()
		c.weight_shift = true
		m.roll_rate = deg_to_rad(20.0)
		var peak := 0.0
		var under := 0.0
		var t_peak := 0.0
		var t_under := 0.0
		for i in int(20.0 / DT):
			m.step(DT, c, Callable(), Callable())
			var b := rad_to_deg(m.bank)
			if b > peak:
				peak = b
				t_peak = i * DT
			if b < under:
				under = b
				t_under = i * DT
		var ratio := -under / maxf(peak, 1.0e-6)
		var period := 2.0 * (t_under - t_peak) if under < -0.01 else NAN
		var zeta := 1.0
		if ratio > 1.0e-4:
			var ln := log(ratio)
			zeta = -ln / sqrt(PI * PI + ln * ln)
		print(
			(
				"| %s | %.1f | %.2f | %.0f | %s | %.2f |"
				% [
					wing_id,
					peak,
					under,
					100.0 * ratio,
					("%.1f" % period) if not is_nan(period) else "—",
					zeta
				]
			)
		)


# ---------------------------------------------------------------- матрица


func _run_matrix() -> void:
	var main: Node = MAIN_SCENE.instantiate()
	(main as Node).set("opts", LaunchOptions.new())
	(main.get("opts") as LaunchOptions).autostart = true  # не запоминать выбор в user://
	add_child(main)
	var game: Game = main.get_node("Game")
	for i in 1200:
		if game.settings != null:
			break
		await get_tree().process_frame
	game.process_mode = Node.PROCESS_MODE_DISABLED  # шагаем сами
	(main.get("opts") as LaunchOptions).air_start_m = float(_args.dist)
	(main.get("opts") as LaunchOptions).air_start_agl_m = float(_args.agl)
	for weather in String(_args.weathers).split(","):
		for wing in String(_args.wings).split(","):
			var s := FlightSettings.defaults()
			s.location_id = String(_args.location)
			s.site_id = String(_args.site)
			s.wing = "wings/" + wing
			var fc: Array = WEATHERS[weather]
			s.temperature_c = float(fc[0])
			s.wind_speed_kmh = float(fc[1])
			s.pilot_mass_kg = float(_args.mass)
			await main.call("_fly", s)
			if int(main.get("state")) != 2:
				push_error("roll_sway: не взлетели %s %s" % [weather, wing])
				continue
			for mode in MODES:
				for pilot in PILOTS:
					var r := _fly_straight(game, mode, pilot)
					r.merge({"weather": weather, "wing": wing, "mode": mode, "pilot": pilot})
					_rows.append(r)
					print(_row_text(r))
	main.queue_free()


## Один прогон: заново в воздух с того же места и с теми же часами атмосферы.
func _fly_straight(game: Game, mode: String, pilot: String) -> Dictionary:
	game.restart()
	game.air.set("time_s", 0.0)
	var m := game.glider.model
	var c := ControlInput.new()
	c.weight_shift = mode == "weight_shift"
	var delay_n := int(round(HUMAN_DELAY_S / DT))
	var seen: Array[float] = []
	var vcfg: Dictionary = Config.get_config("flight").visual
	var pcfg: Dictionary = Config.get_config("pilot")
	var body_l := Vector2(float(pcfg.visual.body_below_hang_m), float(pcfg.visual.body_back_m))
	var shift_m := float(vcfg.pilot_shift_m)
	var n_total := int(round((WARMUP_S + float(_args.secs)) / DT))
	var bank: PackedFloat32Array = []
	var hdg: PackedFloat32Array = []
	var yaw: PackedFloat32Array = []
	var yaw_turn: PackedFloat32Array = []
	var load_n: PackedFloat32Array = []
	var pend: PackedFloat32Array = []
	var p_air: PackedFloat32Array = []
	var p_air_calm: PackedFloat32Array = []
	var gust_h: PackedFloat32Array = []
	var prev_h := m.heading
	var hdg_unwrapped := 0.0
	var landed := false
	var dump: FileAccess = null
	var dump_this: bool = pilot == "hands" and mode == String(_args.dump_mode)
	if String(_args.dump) != "" and dump_this:
		dump = FileAccess.open(String(_args.dump), FileAccess.WRITE)
		if dump != null:
			dump.store_line("t,bank,heading,yaw,wx,wy,wz,p_air,airspeed,roll_in")
	var agl_min := INF
	for i in n_total:
		game.air.call("step", DT)
		var b := rad_to_deg(m.bank)
		seen.append(b)
		c.roll = 0.0
		if pilot == "human" and seen.size() > delay_n:
			var bd: float = seen[seen.size() - 1 - delay_n]
			if absf(bd) > HUMAN_DEADBAND_DEG:
				c.roll = clampf(-bd / HUMAN_FULL_DEG, -1.0, 1.0)
		if seen.size() > delay_n + 2:
			seen.pop_front()
		game.glider.set_input(c)
		game.glider.step(DT)
		if game.glider.phase() != "flying":
			landed = true
			break
		var dh := wrapf(m.heading - prev_h, -PI, PI)
		prev_h = m.heading
		hdg_unwrapped += rad_to_deg(dh)
		if i * DT < WARMUP_S:
			continue
		var t := m.telemetry
		agl_min = minf(agl_min, t.altitude_agl)
		bank.append(t.bank_deg)
		hdg.append(hdg_unwrapped)
		yaw.append(rad_to_deg(dh) / DT)
		yaw_turn.append(rad_to_deg(Units.G * tan(m.bank) / maxf(t.airspeed, 1.0)))
		load_n.append(m.load.load_raw)
		pend.append(rad_to_deg(asin(clampf(c.roll * shift_m / body_l.length(), -1.0, 1.0))))
		p_air.append(rad_to_deg(_p_air(m, game.glider.air_fn)))
		var w_full: Vector3 = game.air.call("air_velocity_at", m.position)
		if "turbulence_enabled" in game.air:
			game.air.set("turbulence_enabled", false)
			p_air_calm.append(rad_to_deg(_p_air(m, game.glider.air_fn)))
			var w_calm: Vector3 = game.air.call("air_velocity_at", m.position)
			game.air.set("turbulence_enabled", true)
			gust_h.append(Vector2(w_full.x - w_calm.x, w_full.z - w_calm.z).length())
		if dump != null:
			var w := t.velocity - t.air_velocity
			dump.store_line(
				(
					"%.4f,%.3f,%.3f,%.3f,%.3f,%.3f,%.3f,%.3f,%.3f,%.3f"
					% [
						i * DT,
						t.bank_deg,
						hdg[-1],
						yaw[-1],
						w.x,
						w.y,
						w.z,
						p_air[-1],
						t.airspeed,
						c.roll
					]
				)
			)
	return {
		"bank_mean": _mean(bank),
		"bank_sd": _sd(bank),
		"bank_p2p": _max(bank) - _min(bank),
		"bank_abs_max": maxf(absf(_max(bank)), absf(_min(bank))),
		"bank_period": _dominant_period(bank),
		"hdg_sd": _detrended_sd(hdg),
		"yaw_sd": _sd(yaw),
		"yaw_turn_sd": _sd(yaw_turn),
		"hdg_jit": _jitter_sd(hdg, 2.0),
		"pend_sd": _sd(pend),
		"pend_max": maxf(absf(_max(pend)), absf(_min(pend))),
		"n_sd": _sd(load_n),
		"pair_sd": _sd(p_air),
		"pair_period": _dominant_period(p_air),
		"pair_calm_sd": _sd(p_air_calm),
		"gust_h_rms": _rms(gust_h),
		"secs": bank.size() * DT,
		"agl_min": agl_min,
		"landed": landed,
	}


## Кренящая угловая скорость от воздуха — как FlightModel._step_air / _update_roll, рад/с.
static func _p_air(m: FlightModel, air_fn: Callable) -> float:
	var tip := m.right_dir() * cos(m.bank) - Vector3.UP * sin(m.bank)
	var half := 0.5 * m.span * float(m.flight.air_sampling.tip_fraction)
	var w_r := FlightModel.sample_air(air_fn, m.position + tip * half)
	var w_l := FlightModel.sample_air(air_fn, m.position - tip * half)
	return float(m.wing.air_roll_gain) * (w_l.y - w_r.y) / m.span


# ---------------------------------------------------------------- статистика


static func _mean(a: PackedFloat32Array) -> float:
	var s := 0.0
	for x in a:
		s += x
	return s / maxf(a.size(), 1)


static func _sd(a: PackedFloat32Array) -> float:
	var mu := _mean(a)
	var s := 0.0
	for x in a:
		s += (x - mu) * (x - mu)
	return sqrt(s / maxf(a.size(), 1))


static func _rms(a: PackedFloat32Array) -> float:
	var s := 0.0
	for x in a:
		s += x * x
	return sqrt(s / maxf(a.size(), 1))


static func _max(a: PackedFloat32Array) -> float:
	var r := -INF
	for x in a:
		r = maxf(r, x)
	return r


static func _min(a: PackedFloat32Array) -> float:
	var r := INF
	for x in a:
		r = minf(r, x)
	return r


## СКО отклонения от линейного тренда (курс: ровный разворот — не раскачка).
static func _detrended_sd(a: PackedFloat32Array) -> float:
	var n := a.size()
	if n < 2:
		return 0.0
	var sx := 0.0
	var sy := 0.0
	var sxx := 0.0
	var sxy := 0.0
	for i in n:
		sx += i
		sy += a[i]
		sxx += i * i
		sxy += i * a[i]
	var k := (n * sxy - sx * sy) / maxf(n * sxx - sx * sx, 1.0e-9)
	var b := (sy - k * sx) / n
	var s := 0.0
	for i in n:
		var e := a[i] - (k * i + b)
		s += e * e
	return sqrt(s / n)


## СКО отклонения от скользящего среднего за window_s, т. е. быстрые рывки (быстрее окна).
static func _jitter_sd(a: PackedFloat32Array, window_s: float) -> float:
	var w := int(round(window_s / DT))
	var n := a.size()
	if n <= w:
		return 0.0
	var acc := 0.0
	for i in w:
		acc += a[i]
	var s := 0.0
	var cnt := 0
	for i in range(w, n):
		var mid: float = a[i - w / 2]
		var e := mid - acc / w
		s += e * e
		cnt += 1
		acc += a[i] - a[i - w]
	return sqrt(s / maxf(cnt, 1))


## Период пика спектра (без тренда), с; сигнал прореживаем до 10 Гц.
static func _dominant_period(a: PackedFloat32Array) -> float:
	var step := int(round(0.1 / DT))
	var x: PackedFloat32Array = []
	for i in range(0, a.size(), step):
		x.append(a[i])
	var n := x.size()
	if n < 20:
		return NAN
	var mu := _mean(x)
	var best_f := 0.0
	var best_p := -1.0
	var f := 0.02
	while f <= 2.0:
		var re := 0.0
		var im := 0.0
		for i in n:
			var ph := TAU * f * i * 0.1
			var hann := 0.5 - 0.5 * cos(TAU * i / (n - 1))
			re += (x[i] - mu) * hann * cos(ph)
			im += (x[i] - mu) * hann * sin(ph)
		var p := re * re + im * im
		if p > best_p:
			best_p = p
			best_f = f
		f += 0.01 if f < 0.3 else 0.02
	return 1.0 / best_f


# ---------------------------------------------------------------- вывод


static func _row_text(r: Dictionary) -> String:
	var s := "| %s | %s | %s | %s |" % [r.weather, r.wing, r.mode, r.pilot]
	for c: Array in COLS:
		s += " " + (String(c[2]) % float(r[c[0]])) + " |"
	if r.landed:
		s += " сел раньше (%.0f с)" % float(r.secs)
	return s


func _print_table() -> void:
	var head := "| погода | крыло | режим | пилот |"
	var line := "|---|---|---|---|"
	for c: Array in COLS:
		head += " %s |" % c[1]
		line += "---|"
	print(
		(
			"\n== раскачка в прямом полёте: %s с, старт в воздухе %s м / %s м AGL =="
			% [_args.secs, _args.dist, _args.agl]
		)
	)
	print(head)
	print(line)
	var csv := PackedStringArray()
	for r in _rows:
		print(_row_text(r))
		var cells := PackedStringArray([r.weather, r.wing, r.mode, r.pilot])
		for c: Array in COLS:
			cells.append(str(r[c[0]]))
		csv.append(",".join(cells))
	if String(_args.csv) != "":
		var f := FileAccess.open(String(_args.csv), FileAccess.WRITE)
		if f != null:
			var keys := PackedStringArray(["weather", "wing", "mode", "pilot"])
			for c: Array in COLS:
				keys.append(String(c[0]))
			f.store_line(",".join(keys))
			for l in csv:
				f.store_line(l)
