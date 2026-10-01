extends TestCase
## Поле воздуха в атмосфере (AM-05, docs/air_model.md → «Поле на CPU»): с полем прикидки Онгудая
## (окно 100 м у Каянчи, фикстура tools/research/air3d/to_game_field.py) air_velocity_at и
## mean_wind_at на старте дают горизонталь и механическую вертикаль поля; выключенное поле и точки
## вне поля — побитно аналитика; отпечаток детерминизма — всегда без поля; конфиг с _doc.

const FIXTURE := "res://tests/atmosphere/fixtures/air_model/field/kayancha_w100_h13_U3_d180"


static func _sun(_x: float, _z: float) -> float:
	return 0.8


## Атмосфера без термиков, фонового опускания, волн и болтанки: остаются ветер, склон/поле и
## подветренная зона. Ветер — как у поля (3 м/с с юга).
static func _atmo(ground: Callable) -> Atmosphere:
	var w: Dictionary = Config.get_config("weather/medium").duplicate(true)
	w.wind_speed_kmh = Units.to_kmh(3.0)
	w.wind_from_deg = 180.0
	w.thermal_mode = "static"
	w.static_thermals = []
	w.background_sink_ms = 0.0
	w.convective_turbulence_ms = 0.0
	var a := Atmosphere.new()
	a.visuals_enabled = false
	a.configure(Config.get_config("atmosphere"), w)
	a.set_ground(ground, _sun)
	a.set_thermal_mode("static")
	a.turbulence_enabled = false
	a.wave.enabled = false
	a.step(0.01)
	return a


func test_kayancha_probes() -> void:
	var f := WindField.load_file(FIXTURE)
	check(f != null, "фикстура читается")
	if f == null:
		return
	var a := _atmo(f.ground_height)
	a.set_air_field(f, 0.0)
	check(a.is_air_field_on(), "поле включено (auto)")
	for p: Dictionary in f.meta.probes:
		var g: Array = p.game
		var pos := Vector3(g[0], g[1], g[2])
		var e: Dictionary = p.field
		var v := a.air_velocity_at(pos)
		var m := a.mean_wind_at(pos)
		var want := Vector3(e.u, e.w_mech, -float(e.v))
		print(
			(
				"    %s: air (%.3f, %.3f, %.3f), поле (%.3f, %.3f, %.3f), w_conv %.3f (не пилоту)"
				% [p.name, v.x, v.y, v.z, want.x, want.y, want.z, e.w_conv]
			)
		)
		check(
			(v - want).length() < 1.0e-4,
			"%s: air_velocity_at = поле (%s против %s)" % [p.name, v, want]
		)
		check((m - want).length() < 1.0e-4, "%s: mean_wind_at = поле" % p.name)
		approx(
			a.air_field.sample_theta(pos, pos.y - float(p.agl)).x, e.theta, 1.0e-4, "θ′ " + p.name
		)
		if p.has("trilinear"):
			var t: Dictionary = p.trilinear
			check(
				absf(v.x - t.u) < 0.01 and absf(v.y - t.w_mech) < 0.01, "%s: ≈ трилинейно" % p.name
			)
	a.free()


func test_off_and_outside_bitwise_analytic() -> void:
	var f := WindField.load_file(FIXTURE)
	var ref := _atmo(f.ground_height)
	var a := _atmo(f.ground_height)
	a.set_air_field(f, 0.0)
	var c := f.center_xz()
	var inside: Array[Vector3] = []
	var outside: Array[Vector3] = []
	for i in 7:
		for agl in [5.0, 60.0, 300.0]:
			var x := c.x - 600.0 + i * 200.0
			var z := c.y + 300.0 - i * 100.0
			inside.append(Vector3(x, f.ground_height(x, z) + agl, z))
			var xo := c.x + 3000.0 + i * 500.0
			outside.append(Vector3(xo, f.ground_height(xo, z) + agl, z))
	var diff_in := 0
	for p in inside:
		if a.air_velocity_at(p) != ref.air_velocity_at(p):
			diff_in += 1
	check(diff_in > 15, "с полем внутри — не аналитика (%d из %d)" % [diff_in, inside.size()])
	var diff_out := 0
	for p in outside:
		if (
			a.air_velocity_at(p) != ref.air_velocity_at(p)
			or a.mean_wind_at(p) != ref.mean_wind_at(p)
		):
			diff_out += 1
	check(diff_out == 0, "вне поля — побитно аналитика (%d отличий)" % diff_out)
	a.set_air_mode("off")
	check(not a.is_air_field_on(), "off — поле не используется")
	var diff_off := 0
	for p in inside:
		if (
			a.air_velocity_at(p) != ref.air_velocity_at(p)
			or a.mean_wind_at(p) != ref.mean_wind_at(p)
		):
			diff_off += 1
	check(diff_off == 0, "выключенное поле — побитно аналитика (%d отличий)" % diff_off)
	a.set_air_mode("auto")
	check(a.is_air_field_on(), "auto с полем — снова поле")
	# поле переживает configure (как функции рельефа)
	a.configure(a.cfg, a.weather)
	check(a.is_air_field_on(), "поле переживает configure")
	ref.free()
	a.free()


func test_edge_smooth_in_atmosphere() -> void:
	# Через край поля (полоса 5 клеток = 500 м) скорость меняется плавно, без скачка.
	var f := WindField.load_file(FIXTURE)
	var a := _atmo(f.ground_height)
	a.set_air_field(f, 0.0)
	var c := f.center_xz()
	var y := 2400.0  # выше рельефа окна, ниже верха
	var prev := a.air_velocity_at(Vector3(c.x, y, c.y))
	var jump := 0.0
	var x_edge := f.x0 + f.nx * f.dx
	var x := c.x
	while x < x_edge + 300.0:
		x += 5.0
		var v := a.air_velocity_at(Vector3(x, y, c.y))
		jump = maxf(jump, (v - prev).length())
		prev = v
	print("    край поля: макс. изменение %.4f м/с на 5 м" % jump)
	check(jump < 0.05, "край поля — без скачков (%.4f м/с на 5 м)" % jump)
	a.free()


func test_fingerprint_world_without_field() -> void:
	var w := AtmoFingerprint.make_world()
	check(String(w.cfg.air_model.enabled) == "off", "отпечаток: air_model.enabled = off")
	check(not w.is_air_field_on(), "отпечаток: поле не используется")
	w.free()
	check(
		String(Config.get_config("atmosphere").air_model.enabled) == "auto",
		"конфиг игры не тронут make_world"
	)


func test_config_documented() -> void:
	var am: Dictionary = Config.get_config("atmosphere").air_model
	check(am.has("_doc"), "air_model._doc")
	for k: String in am:
		if not k.ends_with("_doc"):
			check(am.has(k + "_doc"), "air_model.%s_doc" % k)
	check(String(am.enabled) in ["auto", "on", "off"], "enabled — auto|on|off")
