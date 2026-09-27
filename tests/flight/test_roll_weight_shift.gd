extends TestCase
## Крен в режиме «смещение веса» (controls.roll_control_mode = weight_shift, FR-5): ввод —
## положение пилота в трапеции, крыло устойчиво по крену. Держишь смещение — установившийся
## крен; центр — крыло выравнивается; переложение 45→45 за 2–3 с; радиус виража V²/(g·tgφ).
## Клавиша X «в центр» — в обоих режимах; режим «как раньше» — tests/flight/test_roll.gd.

const Sim := preload("res://tests/flight/flight_sim.gd")
const WINGS: Array[String] = ["training", "kingpost", "sport"]
const TMP_DIR := "user://test_roll_mode_cfg"


## Ввод в режиме «смещение веса».
static func ws(pitch: float = 0.0, roll: float = 0.0) -> ControlInput:
	var c := Sim.input(pitch, roll)
	c.weight_shift = true
	return c


## Смещение веса, держащее крен want_deg: упреждение по модели + пропорционально ошибке.
static func hold_input(m: FlightModel, want_deg: float, pitch: float = 0.0) -> ControlInput:
	var t := m.telemetry
	var ff := m.roll_input_for_bank(deg_to_rad(want_deg), t.airspeed)
	var e := want_deg - (t.bank_deg + rad_to_deg(m.roll_rate) * 0.3)
	return ws(pitch, clampf(ff + e / 10.0, -1.0, 1.0))


static func run_holding(m: FlightModel, seconds: float, want_deg: float) -> void:
	for i in int(round(seconds / Sim.DT)):
		m.step(Sim.DT, hold_input(m, want_deg), Callable(), Callable())


## Время переложения из −45° в +45° на скорости трима, с.
static func reversal_time(m: FlightModel) -> float:
	m.reset_in_air(Vector3(0, 3000, 0), 0.0)
	Sim.run_for(m, 3.0, ws())
	m.bank = deg_to_rad(-45.0)
	m.roll_rate = 0.0
	var inp := ws(0.0, 1.0)
	var t := 0.0
	while m.bank < deg_to_rad(45.0) and t < 10.0:
		m.step(Sim.DT, inp, Callable(), Callable())
		t += Sim.DT
	return t


## Время выравнивания (|крен| < 3°) после 2 с полного смещения и возврата в центр, с.
static func level_time(m: FlightModel) -> float:
	m.reset_in_air(Vector3(0, 3000, 0), 0.0)
	Sim.run_for(m, 3.0, ws())
	Sim.run_for(m, 2.0, ws(0.0, -1.0))
	var t := 0.0
	while absf(m.telemetry.bank_deg) > 3.0 and t < 20.0:
		m.step(Sim.DT, ws(), Callable(), Callable())
		t += Sim.DT
	return t


func test_roll_reversal_time() -> void:
	for w in WINGS:
		var t := reversal_time(Sim.make(w))
		check(t >= 2.0 and t <= 3.0, "%s: переложение 45→45 за %.2f с" % [w, t])


func test_shift_rolls_wing_in() -> void:
	for w in WINGS:
		var m := Sim.make(w)
		m.reset_in_air(Vector3(0, 3000, 0), 0.0)
		Sim.run_for(m, 3.0, ws())
		Sim.run_for(m, 1.0, ws(0.0, -1.0))
		var b1 := m.telemetry.bank_deg
		Sim.run_for(m, 1.0, ws(0.0, -1.0))
		var b2 := m.telemetry.bank_deg
		var msg := "%s: смещение влево — крен растёт: %.0f° → %.0f°" % [w, b1, b2]
		check(b1 < -10.0 and b2 < b1 - 5.0, msg)


func test_center_levels_wing() -> void:
	var times := {}
	for w in WINGS:
		var t := level_time(Sim.make(w))
		times[w] = t
		check(t >= 1.5 and t < 5.0, "%s: в центре крыло выровнялось за %.1f с" % [w, t])
	check(times.training < times.kingpost, "учебное выравнивается быстрее мачтового")
	check(times.kingpost < times.sport, "мачтовое выравнивается быстрее спортивного")


func test_center_flies_straight_in_new_direction() -> void:
	var m := Sim.make("training")
	m.reset_in_air(Vector3(0, 3000, 0), 0.0)
	Sim.run_for(m, 3.0, ws())
	Sim.run_for(m, 2.0, ws(0.0, 1.0))
	Sim.run_for(m, 8.0, ws())
	var h0 := m.telemetry.heading_deg
	check(h0 > 10.0 and h0 < 170.0, "повернули вправо на %.0f°" % h0)
	Sim.run_for(m, 10.0, ws())
	var dh := wrapf(m.telemetry.heading_deg - h0, -180.0, 180.0)
	check(absf(dh) < 3.0, "в центре летит прямо: курс ушёл на %.1f° за 10 с" % dh)
	check(absf(m.telemetry.bank_deg) < 1.0, "крен у нуля: %.1f°" % m.telemetry.bank_deg)


func test_held_shift_gives_steady_bank() -> void:
	for w in WINGS:
		var m := Sim.make(w)
		m.reset_in_air(Vector3(0, 3000, 0), 0.0)
		Sim.run_for(m, 30.0, ws(0.0, 1.0))
		var b1 := m.telemetry.bank_deg
		Sim.run_for(m, 10.0, ws(0.0, 1.0))
		var b2 := m.telemetry.bank_deg
		check(b2 >= 30.0 and b2 <= 50.0, "%s: полное смещение — крен %.0f°" % [w, b2])
		approx(b2, b1, 1.0, "%s: крен установился, спирали нет" % w)
		var h := Sim.make(w)
		h.reset_in_air(Vector3(0, 3000, 0), 0.0)
		Sim.run_for(h, 30.0, ws(0.0, 0.5))
		var bh := h.telemetry.bank_deg
		check(bh > b2 * 0.35 and bh < b2 * 0.75, "%s: половина смещения — крен %.0f°" % [w, bh])


func test_heavier_at_speed() -> void:
	var m := Sim.make("kingpost")
	var slow := m.roll_authority(m.trim_speed())
	var fast := m.roll_authority(m.trim_speed() * 1.5)
	check(fast < slow * 0.75, "на 1,5·V_трим смещение слабее: %.2f против %.2f" % [fast, slow])


func test_turn_radius() -> void:
	for bank_deg in [20.0, 30.0, 40.0]:
		var m := Sim.make("kingpost")
		m.reset_in_air(Vector3(0, 3000, 0), 0.0)
		m.bank = deg_to_rad(bank_deg)
		run_holding(m, 15.0, bank_deg)
		var h0 := m.heading
		var n := 240
		var vh := 0.0
		var bank := 0.0
		for i in n:
			m.step(Sim.DT, hold_input(m, bank_deg), Callable(), Callable())
			vh += m.telemetry.groundspeed
			bank += m.telemetry.bank_deg
		vh /= n
		bank /= n
		approx(bank, bank_deg, 1.0, "регулятор держит крен %.0f°" % bank_deg)
		var omega := wrapf(m.heading - h0, -PI, PI) / (n * Sim.DT)
		var r_sim := vh / omega
		var r_th := vh * vh / (Units.G * tan(deg_to_rad(bank)))
		approx(r_sim, r_th, r_th * 0.03, "радиус виража при крене %.0f°" % bank_deg)
		check(omega > 0.0, "крен вправо — поворот вправо (курс растёт)")


func test_turn_increases_speed_and_sink() -> void:
	var m := Sim.make("sport")
	var straight: Vector2 = Sim.settle(m, 0.0)
	m.reset_in_air(Vector3(0, 3000, 0), 0.0)
	m.bank = deg_to_rad(45.0)
	run_holding(m, 30.0, 45.0)
	var n := 1.0 / cos(deg_to_rad(m.telemetry.bank_deg))
	approx(m.telemetry.airspeed / straight.x, sqrt(n), 0.03, "в вираже скорость ×√n")
	approx(-m.telemetry.vario / straight.y, pow(n, 1.5), 0.1, "в вираже снижение ×n^1,5")


## InputController без правок пилота из user:// (инверсия тангажа, чувствительность).
static func _controller() -> InputController:
	var ic := InputController.new()
	ic.reload_config()
	var cfg: Dictionary = ic._cfg.duplicate(true)
	cfg.invert_pitch = false
	cfg.keyboard.sensitivity = 1.0
	ic._cfg = cfg
	return ic


## Клавиатура → InputController → модель (смещение веса): A держит смещение, X — «в центр».
func test_keyboard_shift_and_center_key() -> void:
	var ic := _controller()
	ic.roll_mode = "weight_shift"
	ic.on_ground = false
	ic._was_on_ground = false
	var m := Sim.make("training")
	m.reset_in_air(Vector3(0, 3000, 0), 0.0)
	Sim.run_for(m, 3.0, ws())
	var fly := func(seconds: float) -> void:
		for i in int(round(seconds / Sim.DT)):
			m.step(Sim.DT, ic.update(Sim.DT), Callable(), Callable())
	Input.action_press("roll_left")
	fly.call(0.3)
	var mid := ic.control.roll
	fly.call(1.7)
	check(mid > -0.9 and mid < -0.2, "A: смещение нарастает плавно (%.2f за 0,3 с)" % mid)
	approx(ic.control.roll, -1.0, 0.01, "A держим — вес до упора влево")
	var b := m.telemetry.bank_deg
	check(b < -20.0, "крен влево %.0f°" % b)
	Input.action_release("roll_left")
	fly.call(0.5)
	check(absf(ic.control.roll) < 0.2, "отпустил — вес пружиной в центр: %.2f" % ic.control.roll)
	# снова влево, потом X: вес и трапеция сразу плавно в нейтраль, крыло выравнивается
	Input.action_press("roll_left")
	Input.action_press("pitch_pull_in")
	fly.call(2.0)
	Input.action_release("roll_left")
	Input.action_release("pitch_pull_in")
	Input.action_press("center")
	fly.call(0.25)
	Input.action_release("center")
	check(absf(ic.control.roll) < 0.4, "X: крен в центр за 0,25 с: %.2f" % ic.control.roll)
	check(absf(ic.control.pitch) < 0.4, "X: трапеция в нейтраль: %.2f" % ic.control.pitch)
	var t := 0.0
	while absf(m.telemetry.bank_deg) > 3.0 and t < 10.0:
		m.step(Sim.DT, ic.update(Sim.DT), Callable(), Callable())
		t += Sim.DT
	check(t < 4.0, "после X крыло выровнялось за %.1f с" % t)
	approx(ic.control.roll, 0.0, 0.01, "вес в центре")
	ic.free()


## Режим «как раньше»: отпустил A — крен держится; X — крыло плавно в горизонт.
func test_rate_mode_center_key_levels_wing() -> void:
	var ic := _controller()
	ic.roll_mode = "rate"
	ic.on_ground = false
	ic._was_on_ground = false
	var m := Sim.make("sport")
	ic.telemetry_fn = func() -> Telemetry: return m.telemetry
	m.reset_in_air(Vector3(0, 3000, 0), 0.0)
	Sim.run_for(m, 3.0, Sim.input())
	var fly := func(seconds: float) -> void:
		for i in int(round(seconds / Sim.DT)):
			var c: ControlInput = ic.update(Sim.DT)
			check(not c.weight_shift, "режим rate — ControlInput.weight_shift = false")
			m.step(Sim.DT, c, Callable(), Callable())
	Input.action_press("roll_right")
	fly.call(1.0)
	Input.action_release("roll_right")
	fly.call(3.0)
	var b := m.telemetry.bank_deg
	check(b > 20.0, "как раньше: отпустил — крен держится (%.0f°)" % b)
	Input.action_press("center")
	fly.call(0.1)
	Input.action_release("center")
	var t := 0.0
	while absf(m.telemetry.bank_deg) > 2.0 and t < 10.0:
		m.step(Sim.DT, ic.update(Sim.DT), Callable(), Callable())
		t += Sim.DT
	check(t < 5.0, "как раньше: X выровнял крыло за %.1f с" % t)
	fly.call(3.0)
	check(absf(m.telemetry.bank_deg) < 2.0, "и крыло летит прямо: %.1f°" % m.telemetry.bank_deg)
	approx(ic.control.roll, 0.0, 0.05, "ручка крена в нейтрали")
	ic.free()


## По умолчанию — «смещение веса»; настройки сохраняют выбор в user-конфиг.
func test_roll_mode_setting() -> void:
	var txt := FileAccess.get_file_as_string("res://configs/controls.json")
	var res: Variant = JSON.parse_string(txt)
	check(
		String(res.get("roll_control_mode", "")) == "weight_shift", "по умолчанию — смещение веса"
	)
	var sp: SettingsPanel = load("res://scenes/ui/settings_panel.tscn").instantiate()
	sp._ready()  # вне дерева: собрать панель без add_child (раннер занят детьми)
	sp.config_dir = TMP_DIR
	(sp.get("_roll_mode") as OptionButton).select(0)
	check(sp.save(), "записалось")
	var c := UserSettings.read_json(TMP_DIR.path_join("controls.json"))
	check(String(c.get("roll_control_mode", "")) == "rate", "режим крена сохранён")
	for f in ["controls.json", "audio.json", "game.json", "atmosphere.json", "world.json"]:
		DirAccess.remove_absolute(TMP_DIR.path_join(f))
	DirAccess.remove_absolute(TMP_DIR)
	sp.queue_free()
