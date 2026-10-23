extends Node
## Буксировка со статической лебёдки в игре (TW-10, docs/contracts/tow.md → TW-К5/К6/К7/К8): TowSession на
## Glider («Маятник», крыло sport, шаг 1/120 с, ровная земля y = 0), выбор полосы в Game, боты в воздухе над полосой,
## действие tow_release в controls.json. Без сети и рельефа из файлов.

const Sim := preload("res://tests/flight/pendulum/pendulum_sim.gd")
const DT := 1.0 / 120.0
const N := 81
const STEP := 25.0

var failures: PackedStringArray = []


func check(cond: bool, msg: String = "") -> void:
	if not cond:
		failures.append("check failed: " + msg)


static func flat(_x: float, _z: float) -> float:
	return 0.0


## Пилот-испытатель: бег после W, в воздухе — удержание тангажа (как tests/contracts/test_tow_k5.gd).
class Run:
	extends RefCounted
	var g: Glider
	var s: TowSession
	var th0 := 0.0
	var t := 0.0
	var w_at := 1.0
	var run_on := false
	var flat_fn := func(_x: float, _z: float) -> float: return 0.0

	func _init(host: Node, length_m := 1000.0, models := true) -> void:
		var ref := Sim.make("sport")
		Sim.reset(ref)
		th0 = ref.theta
		g = Glider.new()
		g.setup("sport", 0.0)
		g.model = Sim.make("sport")
		g.set_ground_fn(flat_fn)
		g.reset_on_ground(Vector3.ZERO, 0.0)
		s = TowSession.new()
		host.add_child(s)
		var site := {
			"start_pos": Vector3.ZERO,
			"end_pos": Vector3(0.0, 0.0, -length_m),
			"heading_deg": 0.0,
		}
		s.setup(g, flat_fn, site, "winch_static", models)

	func step(release := false) -> void:
		var w := t >= w_at
		run_on = run_on or w
		var c := Sim.input(0.0, 0.0)
		c.run = run_on and g.phase() != "flying"
		if g.phase() == "flying":
			c.pitch = clampf(-0.2 * rad_to_deg(g.model.theta - th0), -1.0, 1.0)
		g.set_input(c)
		s.step(DT, w, release)
		g.step(DT)
		t += DT

	func alt() -> float:
		return g.model.pilot_position.y

	func dispose() -> void:
		s.queue_free()
		g.free()


func _plane() -> Terrain:
	var data := PackedFloat32Array()
	data.resize(N * N)
	data.fill(100.0)
	var t := Terrain.new()
	t.location_id = ""
	t.layers = [HeightLayer.from_heights("plane", N, N, STEP, -1000.0, -1000.0, data)]
	return t


func test_idle_before_w() -> void:
	# (1) до W 10 с: натяжение 0, пилот на месте, трос лежит
	var r := Run.new(self)
	r.w_at = 1.0e9
	var x0: Vector3 = r.g.model.pilot_position
	var tmax := 0.0
	for i in int(10.0 / DT):
		r.step()
		tmax = maxf(tmax, r.g.model.link_tension_n)
	check(tmax == 0.0 and r.s.line.tension_n == 0.0, "до W натяжение 0: %.1f Н" % tmax)
	check(r.s.line.phase == "idle", "фаза idle: %s" % r.s.line.phase)
	check(r.g.model.pilot_position.distance_to(x0) < 0.05, "пилот на месте")
	r.s._process(0.0)
	check(r.s.rope_view.is_shown(), "трос лежит и виден")
	check(r.s.winch_node != null and r.s.release_node != null, "модели лебёдки и отцепа загружены")
	check(r.s.winch_pos.distance_to(Vector3(0.0, 0.0, -1000.0)) < 0.01, "лебёдка в конце полосы: %s" % r.s.winch_pos)
	r.dispose()


func test_w_takeoff_and_climb() -> void:
	# (2) W + бег: отрыв ≤ 20 с, высота растёт, натяжение ниже слабого звена
	var r := Run.new(self)
	var t_air := -1.0
	var tmax := 0.0
	for i in int(60.0 / DT):
		r.step()
		tmax = maxf(tmax, r.g.model.link_tension_n)
		if t_air < 0.0 and r.g.phase() == "flying":
			t_air = r.t
	print("    отрыв %.1f с, высота через 60 с: %.0f м, фаза %s, T max %.0f Н" % [t_air, r.alt(), r.s.line.phase, tmax])
	check(t_air > 0.0 and t_air <= 20.0, "отрыв ≤ 20 с: %.1f" % t_air)
	check(r.alt() > 60.0, "высота растёт: %.0f м" % r.alt())
	check(tmax < 1250.0, "T ниже слабого звена: %.0f Н" % tmax)
	check(r.s.is_attached(), "трос в силе")
	r.dispose()


func test_release_free_flight() -> void:
	# (3) tow_release: сила снята, полёт продолжается, трос step_free до reeled_in, купол следует за концом
	var r := Run.new(self)
	for i in int(60.0 / DT):
		r.step()
	var h0 := r.alt()
	r.step(true)
	r.step()
	check(r.s.ended_reason == "pilot" and not r.s.is_attached(), "отцеп: %s" % r.s.ended_reason)
	check(r.g.model.link_tension_n == 0.0 and r.g.model.external_force_n == Vector3.ZERO, "сила снята")
	r.s._process(0.0)
	check(r.s.drogue_node.visible, "купол виден после отцепа")
	var d_max := 0.0
	var i := 0
	while not r.s.line.reeled_in and r.t < 600.0:
		r.step()
		i += 1
		if i % 120 == 0:
			r.s._process(0.0)
			if r.s.drogue_node.visible:
				d_max = maxf(d_max, r.s.drogue_node.transform.origin.distance_to(r.s.line.end_pos))
	r.s._process(0.0)
	check(r.s.line.reeled_in, "трос выбран за %.0f с" % r.t)
	check(d_max < 0.01, "купол следует за концом: %.3f м" % d_max)
	check(not r.s.drogue_node.visible and not r.s.rope_view.is_shown(), "после выбора купол и трос скрыты")
	check(Sim.finite(r.g.model) and r.g.phase() == "flying", "полёт продолжается, модель конечна")
	check(r.alt() > h0 - 150.0, "высота не потеряна сразу: %.0f → %.0f" % [h0, r.alt()])
	r.dispose()


func test_models_and_no_session() -> void:
	# (4) без tow_kind сессии нет, в Game путь старта прежний
	var t := _plane()
	t.location = {
		"start_sites":
		[
			{"id": "a", "name": "A", "lat": 0.0, "lon": 0.0, "heading_deg": 0.0,
			"tow": {"kinds": ["winch_static"], "runway_length_m": 300.0, "runway_width_m": 40.0}},
			{"id": "b", "name": "B", "lat": 0.0, "lon": 0.0, "heading_deg": 20.0},
			{"id": "c", "name": "C", "lat": 0.0, "lon": 0.0, "heading_deg": 0.0,
			"tow": {"kinds": ["aerotow"], "runway_length_m": 400.0, "runway_width_m": 40.0}},
		]
	}
	t._build_sites()
	var g := Game.new()
	g.terrain = t
	g.glider = Glider.new()
	g.glider.setup("sport", 0.0)
	g.settings = FlightSettings.defaults()
	g.settings.site_id = "a"
	g.settings.tow_kind = ""
	check(not g._choose_tow_start(), "tow_kind пусто — буксировки нет")
	g._make_tow_session()
	check(g.tow_session == null and g._tow_site.is_empty(), "сессия не создаётся")
	g.settings.tow_kind = "aerotow"
	check(g._choose_tow_start(), "aerotow на площадке только с лебёдкой — старт с буксировкой (TA-К2)")
	g.settings.tow_kind = "winch_static"
	g.settings.site_id = "b"
	check(g._choose_tow_start(), "площадка без tow — старт с буксировкой (TA-К2)")
	check(g._start_heading == 20.0 and absf(float(g._tow_site.width_m) - Game.TOW_DEFAULT_WIDTH_M) < 0.01, "курс площадки, ширина по умолчанию")
	g.settings.site_id = "a"
	check(g._choose_tow_start(), "площадка a — старт с лебёдки")
	check(g._start_heading == 0.0 and g._start_pos.distance_to(Vector3(0.0, 100.0, 0.0)) < 0.5, "старт в начале полосы: %s" % g._start_pos)
	g._make_tow_session()
	check(g.tow_session != null, "сессия создана")
	if g.tow_session != null:
		check(absf(g.tow_session.rope_length_m() - 300.0) < 0.5, "трос = min(1000, полоса 300): %.1f" % g.tow_session.rope_length_m())
		var o := g._tow_bots_opts()
		check(absf(float(o.agl_m) - 0.35 * 300.0) < 0.5, "высота отцепа ботов 35 %% троса: %s" % o.agl_m)
		g.tow_session.queue_free()
		g.tow_session = null
	# aerotow (TW-10b): площадка c — полоса 400 м, трос 80 м, буксировщик впереди, боты на высоте первого буксира
	g.settings.tow_kind = "aerotow"
	g.settings.site_id = "c"
	check(g._choose_tow_start(), "площадка c — старт с тележки")
	g._make_tow_session()
	check(g.tow_session != null and g.tow_session.is_aerotow(), "сессия aerotow создана")
	if g.tow_session != null:
		check(absf(g.tow_session.rope_length_m() - 80.0) < 0.5, "трос 80 м: %.1f" % g.tow_session.rope_length_m())
		check(g.glider.phase() == "dolly", "пилот на тележке: %s" % g.glider.phase())
		var o2 := g._tow_bots_opts()
		check(absf(float(o2.agl_m) - 300.0) < 0.5, "высота отцепа ботов 300 м: %s" % o2.agl_m)
		check(absf(float(o2.ahead_m[1]) - 320.0) < 0.5, "боты над всей полосой 400 м: %s" % [o2.ahead_m])
		g.tow_session.queue_free()
	g.glider.free()
	g.free()
	t.free()


func test_bots_in_air_over_runway() -> void:
	# боты на буксирном месте — все в воздухе над полосой на высоте отцепа
	var b := BotPilots.new()
	b.visuals_enabled = false
	var start := Vector3(0.0, 0.0, 0.0)
	b.setup({
		"air_fn": func(_p: Vector3) -> Vector3: return Vector3.ZERO,
		"ground_fn": flat,
		"start": start,
		"heading_deg": 0.0,
		"count": 4,
		"tow_air": {"agl_m": 350.0, "ahead_m": [200.0, 800.0], "lateral_m": 20.0},
	})
	check(b.agents.size() == 4, "4 бота")
	for a in b.agents:
		var p: Vector3 = a.model.position
		check(a.is_airborne(), "бот %d в воздухе" % a.id)
		check(absf(p.y - 350.0) < 30.0, "высота ≈ отцепа: %.0f" % p.y)
		check(p.z < -150.0 and p.z > -850.0 and absf(p.x) <= 25.0, "над полосой: %s" % p)
	b.free()


func test_release_action_in_controls() -> void:
	# (5) tow_release в controls.json: клавиша не конфликтует, кнопка геймпада свободна
	var c: Dictionary = Config.get_config("controls")
	var keys: Dictionary = c.keys
	check(keys.has("tow_release") and keys.has("tow_release_doc"), "tow_release и _doc есть")
	var key: String = keys.tow_release[0]
	for a: String in keys:
		if a.ends_with("_doc") or a == "tow_release":
			continue
		check(not (key in keys[a]), "клавиша %s не занята действием %s" % [key, a])
	# не встроенные ui_* Godot (Space/Enter/стрелки): иначе отцеп жмёт кнопку HUD с фокусом
	var ev := InputEventKey.new()
	ev.keycode = OS.find_keycode_from_string(key)
	check(ev.keycode != KEY_NONE, "клавиша %s распознана" % key)
	for a: StringName in InputMap.get_actions():
		if String(a).begins_with("ui_"):
			check(not InputMap.action_has_event(a, ev), "клавиша %s не в %s" % [key, a])
	var btn: Dictionary = c.gamepad.action_buttons
	check(btn.has("tow_release"), "кнопка геймпада tow_release")
	for a: String in btn:
		if a != "tow_release":
			check(int(btn[a]) != int(btn.tow_release), "кнопка не совпадает с %s" % a)
	check(int(btn.tow_release) != int(c.gamepad.run_button) and int(btn.tow_release) != int(c.gamepad.pull_full_button), "кнопка не run/pull_full")


const MAIN_SCENE := preload("res://scenes/main.tscn")


## Проводка Game.tick: W (InputMap) запускает трос, tow_release снимает силу. Место — подставная полоса от старта
## площадки (рельеф Аскарово не ровный: проверяется только проводка, не набор).
func test_game_tick_wiring() -> void:
	var main: Node = MAIN_SCENE.instantiate()
	(main as Node).set("opts", LaunchOptions.parse(PackedStringArray(["--autostart"])))
	add_child(main)
	var game: Game = main.get_node("Game")
	for i in 600:
		if main.get("state") == 2:
			break
		await get_tree().process_frame
	check(main.get("state") == 2, "автостарт — в полёте")
	game.process_mode = Node.PROCESS_MODE_DISABLED
	check(game.tow_session == null, "без tow_kind сессии нет")
	var st := game.get_start()
	var h := deg_to_rad(float(st.heading_deg))
	var p0: Vector3 = st.position
	var p1 := p0 + Vector3(sin(h), 0.0, -cos(h)) * 600.0
	p1.y = game.terrain.height_at(p1.x, p1.z)
	game._tow_site = {"start_pos": p0, "end_pos": p1, "heading_deg": float(st.heading_deg), "width_m": 35.0}
	game.settings.tow_kind = "winch_static"
	game._make_tow_session()
	game.restart()
	check(game.tow_session != null and game.tow_session.line.phase == "idle", "трос лежит, фаза idle")
	for i in 240:
		game.tick(DT)
	check(game.tow_session.line.phase == "idle" and game.tow_session.line.tension_n == 0.0, "без W 2 с — ничего")
	Input.action_press("run")
	for i in 120:
		game.tick(DT)
	Input.action_release("run")
	check(game.tow_session.line.phase == "idle", "Shift без W трос не запускает")
	Input.action_press("walk_forward")
	for i in 240:
		game.tick(DT)
	check(game.tow_session.line.phase != "idle", "после W трос пошёл: %s" % game.tow_session.line.phase)
	Input.action_release("walk_forward")
	Input.action_press("tow_release")
	await get_tree().physics_frame
	game.tick(DT)
	Input.action_release("tow_release")
	check(not game.tow_session.is_attached(), "tow_release отцепил: %s" % game.tow_session.line.state)
	game.restart()
	check(game.tow_session.is_attached() and game.tow_session.line.phase == "idle", "«Ещё раз» — трос снова лежит")
	# точка с карты: лес на полосе вычищается кругами вдоль оси (review TW-10)
	var n0 := game.terrain.get_start_clearings().size()
	game._start_pos = p0
	game._start_heading = float(st.heading_deg)
	game._clear_tow_runway()
	var cl := game.terrain.get_start_clearings()
	check(cl.size() > n0, "поляна-полоса добавлена: %d → %d" % [n0, cl.size()])
	if cl.size() > n0:
		var far: Vector3 = cl[cl.size() - 1]
		check(Vector2(far.x - p0.x, far.z - p0.z).length() >= 500.0, "поляна тянется вдоль полосы: %s" % far)
	main.queue_free()
	await get_tree().process_frame
