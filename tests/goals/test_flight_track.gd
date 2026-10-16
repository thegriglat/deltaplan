extends TestCase
## FlightTrack и TrackRecorder (GL-К5).


func _ramp() -> FlightTrack:
	var t := FlightTrack.new()
	for i in 11:
		t.append(50.0 + i * 0.001, 30.0, 1000.0 + i * 2.0, float(i))
	return t


func test_vertical_speed_middle_and_edges() -> void:
	var t := _ramp()
	approx(t.vertical_speed_ms(5, 4.0), 2.0, 1e-4, "середина")
	approx(t.vertical_speed_ms(0, 4.0), 2.0, 1e-4, "начало (короткое окно)")
	approx(t.vertical_speed_ms(10, 4.0), 2.0, 1e-4, "конец")
	approx(t.vertical_speed_ms(5, 0.5), 0.0, 1e-6, "окно уже шага — одна точка")
	approx(t.vertical_speed_ms(99, 4.0), 0.0, 1e-6, "вне диапазона")


func test_inside_fraction() -> void:
	var t := _ramp()
	var fn := func(la: float, lo: float) -> Vector2: return Vector2((la - 50.0) * 1000.0, lo)
	approx(t.inside_fraction(Rect2(0, 0, 4.5, 100), fn), 5.0 / 11.0, 1e-6, "5 из 11")
	approx(t.inside_fraction(Rect2(-5, 100, 5000, 5000), fn), 0.0, 1e-6, "lon=30 вне по Z")
	approx(FlightTrack.new().inside_fraction(Rect2(), fn), 0.0, 1e-6, "пустой")


func _tel(time: float, y: float, ground: bool) -> Telemetry:
	var t := Telemetry.new()
	t.time_s = time
	t.position = Vector3(100.0, y, -200.0)
	t.on_ground = ground
	return t


func test_recorder_one_hz_air_only() -> void:
	var r := TrackRecorder.new()
	r.start(func(x: float, z: float) -> Vector2: return Vector2(50.0 - z * 1e-5, 30.0 + x * 1e-5))
	r.update(_tel(0.0, 1000.0, true))
	r.update(_tel(5.0, 1000.0, true))
	check(r.track().size() == 0, "на земле не пишет")
	for k in 31:
		var tt := 10.0 + k * 0.1
		r.update(_tel(tt, 1100.0 + tt, false))
	var tr := r.track()
	check(tr.size() == 4, "1 Гц: 4 точки за 3 с, получено %d" % tr.size())
	approx(tr.t_s[0], 0.0, 1e-6, "t от первой точки")
	approx(tr.t_s[3], 3.0, 0.11, "t последней")
	approx(tr.lat[0], 50.002, 1e-5, "lat из -Z")
	approx(tr.lon[0], 30.001, 1e-5, "lon из X")
	approx(tr.alt_m[0], 1110.0, 1e-3, "высота = position.y")
	r.start(Callable())
	check(r.track().size() == 0, "start даёт пустой трек")
