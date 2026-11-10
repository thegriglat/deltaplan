extends TestCase
## PT-14: зонд синтетического гребня (как test_atmosphere/test_lee_rotor): разложение по слагаемым.
## Копируется в tests/atmosphere/ временной копии. Вывод: строки "PROBE {json}".
const Rig := preload("res://tests/atmosphere/air_rig.gd")
const Sim := preload("res://tests/flight/flight_sim.gd")
const RIDGE_H := 300.0
const RIDGE_W := 400.0
const XS: Array = [-900.0, -600.0, -300.0, -150.0, 0.0, 100.0, 150.0, 200.0, 250.0, 300.0, 350.0, 500.0, 800.0]
const AGLS: Array = [20.0, 40.0, 80.0, 150.0]


static func _ridge(x: float, _z: float) -> float:
	return RIDGE_H * exp(-(x / RIDGE_W) * (x / RIDGE_W))


func _atmo(kmh: float) -> Atmosphere:
	var over := {
		"wind_speed_kmh": kmh,
		"wind_from_deg": 270.0,
		"background_sink_ms": 0.0,
		"convective_turbulence_ms": 0.0,
		"temperature_c": 20.0,
	}
	return Rig.make({"over": over, "mode": 1, "ground": _ridge, "half": 3000.0, "advance": 0.01})


func _pr(tag: String, d: Dictionary) -> void:
	d["tag"] = tag
	print("PROBE " + JSON.stringify(d))


func _dump(tag: String, a: Atmosphere) -> void:
	var names := a.decompose(Vector3(0, 800, 0)).names as PackedStringArray
	_pr(tag + ".names", {"names": Array(names)})
	for x: float in XS:
		for agl: float in AGLS:
			var p := Vector3(x, _ridge(x, 0.0) + agl, 0.0)
			var d := a.decompose(p)
			var mw := a.mean_wind_at(p)
			var vel: PackedVector3Array = d.vel
			var sg: PackedFloat32Array = d.sigma
			var row := {"x": x, "agl": agl, "mean": [mw.x, mw.y, mw.z], "total_sigma": (d.total as Vector4).w}
			var tv := {}
			var ts := {}
			for i in names.size():
				tv[names[i]] = [vel[i].x, vel[i].y, vel[i].z]
				ts[names[i]] = sg[i]
			row["vel"] = tv
			row["sigma"] = ts
			_pr(tag + ".pt", row)


func _variance_w(a: Atmosphere, x: float, agl: float) -> float:
	var s := 0.0
	var s2 := 0.0
	var n := 400
	for i in n:
		var p := Vector3(x + (i % 20) * 3.0, _ridge(x, 0) + agl, (i / 20) * 7.0)
		var w := a.air_velocity_at(p).y
		s += w
		s2 += w * w
	var m := s / n
	return s2 / n - m * m


func _dump_input(a: Atmosphere, wind_kmh: float) -> void:
	var pairs: PackedStringArray = a.call("_dp_configs")
	var cond: Dictionary = a.get("_f_cond")
	var f := FileAccess.open(OS.get_environment("PT14_OUT") + "/gdinput-%d.json" % int(wind_kmh * 10), FileAccess.WRITE)
	f.store_string(JSON.stringify({"configs": Array(pairs), "cond": cond}))
	f.close()


func test_probe() -> void:
	var a := _atmo(25.0)
	_dump_input(a, 25.0)
	_dump("w25", a)
	_pr("var", {"lee": _variance_w(a, 350.0, 40.0), "wind": _variance_w(a, -600.0, 40.0)})
	a.free()
	var b := _atmo(21.6)  # 6 м/с
	_dump("w6", b)
	b.free()
	var c := _atmo(0.0)
	_dump("w0", c)
	c.free()


func _atmo_ms(wind_ms: float) -> Atmosphere:
	return _atmo(Units.to_kmh(wind_ms) if wind_ms > 0.0 else 0.0)


## Как test_lee_rotor._fly_over_crest, но высота y0 берётся при пересечении x_meas (0 — гребень, как в тесте).
func _fly(wind_ms: float, x_meas: float) -> float:
	var a := _atmo_ms(wind_ms)
	var m := Sim.make("sport")
	var start := Vector3(-250.0, RIDGE_H + 50.0, 0.0)
	m.reset_in_air(start, 90.0, 0.0, a.mean_wind_at(start))
	var inp := Sim.input()
	var air := func(p: Vector3) -> Vector3: return a.air_velocity_at(p)
	var gnd := func(x: float, z: float) -> float: return _ridge(x, z)
	var dt := Sim.DT
	var guard := 0
	while m.position.x < x_meas and guard < int(60.0 / dt):
		Rig.step(a, dt)
		m.step(dt, inp, air, gnd)
		guard += 1
	var y0 := m.position.y
	for i in int(30.0 / dt):
		if m.mode != FlightModel.Mode.AIR:
			break
		Rig.step(a, dt)
		m.step(dt, inp, air, gnd)
	var lost := y0 - m.position.y
	if m.mode != FlightModel.Mode.AIR:
		lost = maxf(lost, y0 - _ridge(m.position.x, 0.0)) + 100.0
	a.free()
	return lost


func test_flight_and_variance() -> void:
	for xm: float in [0.0, 150.0, 250.0]:
		_pr("fly", {"x_meas": xm, "calm": _fly(0.0, xm), "wind6": _fly(6.0, xm)})
	var a := _atmo(25.0)
	for xl: float in [350.0, 500.0, 600.0, 800.0]:
		for xw: float in [-900.0, -600.0]:
			_pr("var2", {"x_lee": xl, "x_wind": xw, "lee": _variance_w(a, xl, 40.0), "wind": _variance_w(a, xw, 40.0)})
	a.free()
