extends TestCase
## Шуршание ног о траву (PH-4, PH-К6): логика громкости, процедурный луп, сведение в FlightSoundMix
## и GrassField.height_at на искусственной местности.

const N := 41  # 41 × 10 м = 400 м, начало (−200, −200)


func _cfg() -> Dictionary:
	return Config.get_config("audio").flight.rustle


## Поле с плоской землёй; в полосе x ≥ 100 — класс cls_east, остальное луг; склон > 38° на z ≥ 150.
func _field(cls_east: int = SurfaceLayer.GRASS, with_slope: bool = false) -> GrassField:
	var hs := PackedFloat32Array()
	hs.resize(N * N)
	var cs := PackedByteArray()
	cs.resize(N * N)
	for j in N:
		for i in N:
			var x := -200.0 + i * 10.0
			var z := -200.0 + j * 10.0
			hs[j * N + i] = (z - 150.0) * 1.5 if with_slope and z >= 150.0 else 0.0
			cs[j * N + i] = cls_east if x >= 100.0 else SurfaceLayer.GRASS
	var g := GrassField.new()
	g._layer = HeightLayer.from_heights("t", N, N, 10.0, -200.0, -200.0, hs)
	g._surface = SurfaceLayer.from_classes("t", N, N, 10.0, -200.0, -200.0, cs)
	g._cfg = Config.get_config("vegetation").grass.duplicate(true)
	g._cfg["enabled"] = true
	g._cfg["density_pct"] = 100
	g._rock_slope_deg = 38.0
	return g


func _foot(clear: float, spd: float, h: float) -> Dictionary:
	return {"clearance_m": clear, "speed_ms": spd, "grass_h_m": h}


func test_level_rules() -> void:
	var c := _cfg()
	check(GrassRustle.level([_foot(0.0, 3.0, 0.4)], c) > 0.9, "ноги в траве и бегут — громко")
	check(GrassRustle.level([_foot(0.0, 0.0, 0.4)], c) == 0.0, "стоим — тишина")
	check(GrassRustle.level([_foot(0.0, 3.0, 0.0)], c) == 0.0, "травы нет — тишина")
	check(GrassRustle.level([_foot(0.6, 8.0, 0.4)], c) == 0.0, "подошвы выше травы — тишина")
	check(GrassRustle.level([_foot(0.9, 8.0, 0.4)], c) == 0.0, "высоко — тишина")
	check(GrassRustle.level([], c) == 0.0, "нет ног — тишина")
	var prev := -1.0
	for d in [0.35, 0.25, 0.15, 0.05, 0.0]:
		var l := GrassRustle.level([_foot(d, 3.0, 0.4)], c)
		check(l >= prev, "глубже — не тише (%.2f: %.3f)" % [d, l])
		prev = l
	prev = -1.0
	for v in [0.1, 0.5, 1.0, 2.0, 4.0]:
		var l := GrassRustle.level([_foot(0.0, v, 0.4)], c)
		check(l >= prev, "быстрее — не тише (%.1f: %.3f)" % [v, l])
		prev = l
	check(GrassRustle.level_to_db(0.0, c) <= -80.0, "уровень 0 → тишина в дБ")
	check(GrassRustle.level_to_db(1.0, c) == float(c.db), "полный уровень = db")
	check(GrassRustle.pitch_for(3.0, c) > GrassRustle.pitch_for(0.0, c), "быстрее — выше тон")
	var off := c.duplicate()
	off["enabled"] = false
	check(GrassRustle.level([_foot(0.0, 3.0, 0.4)], off) == 0.0, "enabled=false — тишина")


func test_mix_rustle_layer() -> void:
	var m := FlightSoundMix.new()
	m.setup(Config.get_config("audio").flight, 1)
	var rc := _cfg()
	var quiet: Vector2 = m.compute()[FlightSoundMix.RUSTLE_LOOP]
	check(quiet.x <= -80.0, "без ног шуршания нет")
	m.feet = [_foot(0.05, 3.0, 0.4), _foot(0.2, 3.0, 0.4)]
	var loud: Vector2 = m.compute()[FlightSoundMix.RUSTLE_LOOP]
	check(loud.x > -30.0 and loud.x <= float(rc.db) + 3.1, "шуршит (%.1f дБ)" % loud.x)
	m.feet = [_foot(0.05, 0.0, 0.4)]
	check(m.compute()[FlightSoundMix.RUSTLE_LOOP].x <= -80.0, "стоим — тишина")


func test_loop_procedural() -> void:
	var w := GrassRustle.make_loop(_cfg(), 7)
	var n := w.data.size() / 2
	check(w.loop_mode == AudioStreamWAV.LOOP_FORWARD and w.loop_end == n, "зациклен")
	check(absf(w.get_length() - float(_cfg().loop_s)) < 0.01, "длина %.2f с" % w.get_length())
	var peak := 0
	var energy := 0.0
	for i in n:
		var s := w.data.decode_s16(i * 2)
		peak = maxi(peak, absi(s))
		energy += float(s) * float(s)
	check(peak > 20000 and peak <= 32767, "пик %d" % peak)
	check(energy > 0.0, "не пусто")
	var w2 := GrassRustle.make_loop(_cfg(), 7)
	check(w2.data == w.data, "детерминирован по зерну")


func test_height_at_classes() -> void:
	var g := _field()
	var h := g.height_at(0.0, 0.0)
	var lo := float(g._cfg.blade_height_m[0])
	var hi := float(g._cfg.blade_height_m[1])
	check(h >= lo and h <= hi, "луг: %.2f в [%.2f, %.2f]" % [h, lo, hi])
	g.free()
	for c in [
		SurfaceLayer.BARE, SurfaceLayer.WATER, SurfaceLayer.SNOW, SurfaceLayer.BUILT
	]:
		var f := _field(c)
		check(f.height_at(150.0, 0.0) == 0.0, "класс %d: травы нет" % c)
		check(f.height_at(0.0, 0.0) > 0.0, "рядом луг")
		f.free()
	var crop := _field(SurfaceLayer.CROP)
	check(crop.height_at(150.0, 0.0) > crop.height_at(0.0, 0.0), "пашня выше луга")
	crop.free()
	var forest := _field(SurfaceLayer.FOREST)
	check(forest.height_at(150.0, 0.0) < forest.height_at(0.0, 0.0), "под лесом ниже луга")
	forest.free()


func test_height_at_slope_landing_disabled() -> void:
	var g := _field(SurfaceLayer.GRASS, true)
	check(g.height_at(0.0, 100.0) > 0.0, "ровное — трава")
	check(g.height_at(0.0, 190.0) == 0.0, "крутой склон — скалы, травы нет")
	var open := g.height_at(0.0, 0.0)
	var sites: Array[Dictionary] = [
		{"position": Vector3(0, 0, 0), "axis_deg": 0.0, "length_m": 60.0, "width_m": 30.0}
	]
	g.set_landing_sites(sites)
	var mown := g.height_at(0.0, 0.0)
	check(mown > 0.0 and mown < open, "на площадке ниже (%.2f < %.2f)" % [mown, open])
	check(absf(g.height_at(0.0, -100.0) - open) < 1e-5, "вне площадки как было")
	g._cfg["density_pct"] = 0
	check(g.height_at(0.0, -100.0) == 0.0, "трава выключена — 0")
	g.free()


func test_feet_positions_without_skeleton() -> void:
	var v := GliderVisual.new()
	check(v.feet_positions().is_empty(), "нет скелета — пустой массив")
	v.free()

