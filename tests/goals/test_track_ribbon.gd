extends TestCase
## Полоса трека (GL-К6): цвет по вертикальной скорости, прореживание, позиции (x, alt_m, z).

const LATLON := 0.001  # градусов на 100 м в синтетическом треке


func _fn() -> Callable:
	return func(la: float, lo: float) -> Vector2: return Vector2(lo * 1000.0, -la * 1000.0)


func _cfg() -> Dictionary:
	return Config.get_config("goals/track")


## Прямой трек с постоянной вертикальной скоростью w, 1 Гц, n точек.
func _straight(w: float, n: int) -> FlightTrack:
	var t := FlightTrack.new()
	for i in n:
		t.append(-i * 0.01, i * 0.01, 1500.0 + w * i, float(i))
	return t


## Спираль в термике (набор) + планирование (снижение), 1 Гц.
static func _spiral_glide(n_turn: int, n_glide: int) -> FlightTrack:
	var t := FlightTrack.new()
	var r := 60.0
	var alt := 1000.0
	for i in n_turn:
		var a := i * TAU / 25.0
		alt += 2.5
		t.append(-r * sin(a) / 1000.0, r * cos(a) / 1000.0, alt, float(i))
	var x := r
	for i in n_glide:
		x += 11.0
		alt -= 1.2
		t.append(0.0, x / 1000.0, alt, float(n_turn + i))
	return t


func _ribbon(track: FlightTrack) -> TrackRibbon:
	var rb := TrackRibbon.new()
	rb.set_track(track, _fn())
	return rb


func test_colors_climb_sink_zero() -> void:
	var cfg := _cfg()
	var climb := TrackRibbon.vs_color(4.0, cfg)
	var sink := TrackRibbon.vs_color(-4.0, cfg)
	var zero := TrackRibbon.vs_color(0.0, cfg)
	var cc: Array = cfg.color_climb
	var cs: Array = cfg.color_sink
	approx(climb.r, cc[0], 1e-5, "набор +4 — насыщенный красный (r)")
	approx(climb.a, cc[3], 1e-5, "набор +4 — непрозрачность color_climb")
	check(climb.r > climb.b + 0.5, "набор красный: %s" % climb)
	approx(sink.b, cs[2], 1e-5, "снижение −4 — насыщенный синий (b)")
	check(sink.b > sink.r + 0.5, "снижение синее: %s" % sink)
	approx(zero.a, float(cfg.alpha_zero), 1e-5, "ноль — alpha_zero")
	approx(TrackRibbon.vs_color(float(cfg.dead_band_ms) * 0.9, cfg).a, float(cfg.alpha_zero), 1e-5, "внутри мёртвой зоны")
	var mid_w := 0.5 * (float(cfg.dead_band_ms) + float(cfg.climb_full_ms))
	approx(TrackRibbon.vs_color(mid_w, cfg).a, 0.5 * (float(cfg.alpha_zero) + float(cc[3])), 1e-4, "между — линейно")


func test_ribbon_vertex_colors_on_track() -> void:
	var up := _ribbon(_straight(4.0, 30))
	var down := _ribbon(_straight(-4.0, 30))
	var flat := _ribbon(_straight(0.0, 30))
	var cfg := _cfg()
	check(up.point_colors.size() >= 2 and up.mesh != null, "меш построен")
	for c in up.point_colors:
		approx(c.a, float(cfg.color_climb[3]), 1e-4, "набор — вся полоса насыщенная")
	for c in down.point_colors:
		check(c.b > c.r + 0.5, "снижение — синяя: %s" % c)
	for c in flat.point_colors:
		approx(c.a, float(cfg.alpha_zero), 1e-5, "горизонталь — почти бесцветно")
	check(up.mesh.get_surface_count() == 1, "одна поверхность — один draw call")
	up.free()
	down.free()
	flat.free()


func test_positions_through_latlon_fn() -> void:
	var t := _straight(1.0, 3)
	t.lat[1] = 0.5  # излом — точка не выбрасывается
	var rb := _ribbon(t)
	check(rb.kept.size() == 3, "3 точки остались: %s" % rb.kept)
	for k in rb.kept.size():
		var i := rb.kept[k]
		var xz: Vector2 = _fn().call(t.lat[i], t.lon[i])
		check(rb.points[k].is_equal_approx(Vector3(xz.x, t.alt_m[i], xz.y)),
				"точка %d = (x, alt_m, z): %s" % [i, rb.points[k]])
	rb.free()


func test_simplify_long_track() -> void:
	var t := _spiral_glide(3600, 3600)  # 2 ч × 1 Гц
	var cfg := _cfg()
	var maxp := int(cfg.max_points)
	var fn := _fn()
	var all := PackedVector3Array()
	for i in t.size():
		var xz: Vector2 = fn.call(t.lat[i], t.lon[i])
		all.append(Vector3(xz.x, t.alt_m[i], xz.y))
	var rb := TrackRibbon.new()
	rb.set_track(t, fn)
	check(rb.kept.size() <= maxp, "точек %d ≤ max_points %d" % [rb.kept.size(), maxp])
	check(rb.kept.size() > 100, "форма не потеряна: %d точек" % rb.kept.size())
	check(rb.kept[0] == 0 and rb.kept[rb.kept.size() - 1] == t.size() - 1, "концы на месте")
	# Отклонение исходных точек от оставшейся ломаной.
	var worst := 0.0
	for k in rb.kept.size() - 1:
		var a := all[rb.kept[k]]
		var b := all[rb.kept[k + 1]]
		var ab := b - a
		for j in range(rb.kept[k] + 1, rb.kept[k + 1]):
			var ap := all[j] - a
			var u := clampf(ap.dot(ab) / maxf(ab.length_squared(), 1e-9), 0.0, 1.0)
			worst = maxf(worst, (ap - ab * u).length())
	check(worst <= 5.0, "форма: макс. отклонение %.2f м ≤ 5 м (спираль r = 60 м)" % worst)
	var verts: int = rb.kept.size() * 2
	check(verts <= 2 * maxp, "вершин %d ≤ 2·max_points" % verts)
	rb.free()


func test_simplify_respects_limit_and_min_tol() -> void:
	var pts := PackedVector3Array()
	for i in 500:
		pts.append(Vector3(i, 0.0, 0.3 * sin(i * 0.7)))  # шум меньше simplify_min_m
	check(TrackRibbon.simplify(pts, 2000, 1.0).size() == 2, "прямая с мелким шумом — 2 точки")
	var zig := PackedVector3Array()
	for i in 500:
		zig.append(Vector3(i * 10.0, 0.0, 50.0 if i % 2 else 0.0))
	var s := TrackRibbon.simplify(zig, 100, 1.0)
	check(s.size() <= 100 and s.size() >= 50, "зигзаг урезан до лимита: %d" % s.size())


func test_empty_and_short() -> void:
	var rb := TrackRibbon.new()
	rb.set_track(FlightTrack.new(), _fn())
	check(rb.mesh == null, "пустой трек — нет меша")
	rb.set_track(_straight(0.0, 1), _fn())
	check(rb.mesh == null, "одна точка — нет меша")
	rb.free()
