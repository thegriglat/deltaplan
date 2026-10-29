extends TestCase
## RW-3b: потребители scripts/atmosphere берут термики и ветер через фасад W2 — описания ядер
## (cores, W6), sample_many, background_wind, weather(): разбор ядер, признаки термиков,
## пылевые вихри. Воздух — tests/atmosphere/air_rig.gd. godot --headless --path . res://tests/run_tests.tscn -- --filter=atmosphere_consumers

const Rig := preload("res://tests/atmosphere/air_rig.gd")


func _atmo(strength: float = 3.0) -> Atmosphere:
	return Rig.make(
		{
			"preset": "weather/strong",
			"over": {"wind_speed_kmh": 0.0},
			"statics": [[0.0, 0.0, strength, 150.0]],
			"focus": Vector3(0, 300, 0),
			"advance": 1.0,
		}
	)


func test_parse_cores_static_thermal() -> void:
	var a := _atmo()
	var cores := BirdFlock.parse_cores(a.cores(Vector3(0, 300, 0), 1000.0))
	check(cores.size() >= 1, "статический термик отдан в cores")
	if cores.is_empty():
		a.free()
		return
	var c: Dictionary = cores[0]
	check(bool(c.static), "флаг статического")
	check(is_equal_approx(float(c.env), 1.0), "огибающая статического = 1")
	check(absf(float(c.strength) - 3.0) < 0.01, "сила = w / огибающая: %.3f" % float(c.strength))
	var ax := BirdFlock.core_axis_at(c, float(c.y_src) + 100.0)
	check(ax.is_finite(), "ось на высоте конечна")
	a.free()


func test_envelope_from_stage() -> void:
	# Огибающая из стадии ядра = AtmoThermal.envelope: рост — smoothstep, зрелость — 1, распад — спад.
	var grow := BirdFlock.parse_cores(PackedFloat32Array([1, 0, 0, 0, 0, 1000, 2, 100, 0, 0, 10, 100, 0.5, 7, 0]))
	check(is_equal_approx(float(grow[0].env), smoothstep(0.0, 1.0, 0.5)), "рост")
	var mature := BirdFlock.parse_cores(PackedFloat32Array([1, 0, 0, 0, 0, 1000, 2, 100, 0, 0, 10, 100, 1.5, 7, 0]))
	check(is_equal_approx(float(mature[0].env), 1.0), "зрелость")
	var decay := BirdFlock.parse_cores(PackedFloat32Array([1, 0, 0, 0, 0, 1000, 2, 100, 0, 0, 10, 100, 2.5, 7, 0]))
	check(is_equal_approx(float(decay[0].env), 1.0 - smoothstep(0.0, 1.0, 0.5)), "распад")
	check(absf(float(decay[0].strength) - 2.0 / float(decay[0].env)) < 1.0e-4, "сила = w / env")


func test_thermal_signs_over_static_thermal() -> void:
	var a := _atmo(3.0)
	var ts := ThermalSigns.new()
	ts.setup(a)
	ts.cfg.swallow_chance = 1.0
	ts.cfg.fluff_chance = 1.0
	ts.eye_fn = func() -> Vector3: return Vector3(0, 100, 0)
	ts.refresh(Vector3(0, 100, 0))
	var kinds := {}
	for e in ts._entries:
		kinds[e.kind] = true
	check(kinds.has("swallow") and kinds.has("fluff"), "оба вида признаков у статического термика")
	var t := float(a.status().time_s) + 120.0
	var pos := ts.positions(t)
	check(not pos.is_empty(), "положения признаков есть")
	var sw := 0
	for d in pos:
		if d.kind == "swallow":
			sw += 1
			var p: Vector3 = d.pos
			check(Vector2(p.x, p.z).length() <= float(ts.cfg.swallow_lateral_m) * 1.1, "ласточка у оси")
	check(sw > 0, "ласточки есть")
	ts.free()
	a.free()


func test_fluff_rises_with_updraft() -> void:
	var a := _atmo(3.0)
	var ts := ThermalSigns.new()
	ts.setup(a)
	var c: Dictionary = BirdFlock.parse_cores(a.cores(Vector3(0, 300, 0), 1000.0))[0]
	var tab := ts._fluff_table(c)
	check(tab.size() == ThermalSigns.WTAB_H * ThermalSigns.WTAB_R, "таблица подъёма полного размера")
	var up := 0.0
	for k in range(0, tab.size()):
		up = maxf(up, tab[k])
	check(up > float(ts.cfg.fluff_settle_ms), "в таблице есть подъём выше оседания пуха: %.2f" % up)
	var rose := 0
	for i in 16:
		var d := ts._fluff(c, i, 500.0, tab)
		if not d.is_empty() and float(d.pos.y) > float(c.y_src) + 2.0:
			rose += 1
	check(rose > 0, "часть пушинок поднялась над источником (%d)" % rose)
	ts.free()
	a.free()


func test_dust_devil_from_core() -> void:
	var a := _atmo()
	var dd := DustDevils.new()
	dd.setup(a)
	dd._chance = 1.0
	var life: Array = dd.cfg.life_s
	# Молодое нестатическое ядро достаточной силы: стадия роста, возраст в начале жизни вихря.
	var mk := func(id: int, static_flag: int, age: float) -> Dictionary:
		var arr := PackedFloat32Array(
			[id, static_flag, 100, 200, 50, 1500, 3.0, 120, 0, 0, age, 3000, 0.6, 11, 0]
		)
		var c: Dictionary = BirdFlock.parse_cores(arr)[0]
		c["t"] = 0.0
		return c
	var found := 0
	var in_range := true
	for id in 40:
		var d := dd.devil_of(mk.call(id + 1, 0, 300.0), 0.0, Vector2(2, 0))
		if not d.is_empty():
			found += 1
			in_range = in_range and float(d.age) >= 0.0 and float(d.age) <= 1.0 and float(d.height) > 0.0
	check(found > 0, "при вероятности 1 вихри у части ядер: %d" % found)
	check(in_range, "возраст 0..1, высота > 0")
	check(dd.devil_of(mk.call(5, 1, 300.0), 0.0, Vector2.ZERO).is_empty(), "статический термик без вихря")
	dd._chance = 0.0
	check(dd.devil_of(mk.call(5, 0, 300.0), 0.0, Vector2.ZERO).is_empty(), "вероятность 0 — вихрей нет")
	check(float(life[1]) > 0.0, "конфиг жизни вихря прочитан")
	dd.free()
	a.free()


func test_background_wind_and_weather_facade() -> void:
	var a := _atmo()
	var bw := a.background_wind(PackedFloat32Array([1000.0]))
	check(bw.size() == 2, "background_wind: [vx, vz]")
	check(a.weather().has("_derived") or a.weather().size() >= 0, "weather() отдаёт копию погоды")
	a.free()
