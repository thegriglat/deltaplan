
# ---- LT-11: зонд разложения σ в точке test_lee_zone_all_starts (дописывается к началу теста) ----

const UP_DISTS: Array[float] = [60.0, 150.0, 300.0, 600.0, 1000.0, 1600.0]


static func _smooth(a: float, b: float, x: float) -> float:
	if absf(a - b) <= 1.0e-5 * maxf(absf(a), 1.0):
		return 0.0 if x <= a else 1.0
	var t := clampf((x - a) / (b - a), 0.0, 1.0)
	return t * t * (3.0 - 2.0 * t)


func _only() -> Array:
	var s := OS.get_environment("LT11_ONLY")
	return [] if s == "" else s.split(",")


## Превышение гребня против ветра (как analytic/ground.rs: max по dists выше точки минус земля у точки).
func _relief(terrain: Terrain, p: Vector3, from_deg: float) -> float:
	var up := Vector2(sin(deg_to_rad(from_deg)), -cos(deg_to_rad(from_deg)))
	var h := terrain.height_at(p.x, p.z)
	var crest := h
	for d in UP_DISTS:
		crest = maxf(crest, terrain.height_at(p.x + up.x * d, p.z + up.y * d))
	return crest - h


func _ready_levels(a: Atmosphere) -> Array:
	var fs: Variant = a.air_field
	var t0 := Time.get_ticks_msec()
	while (fs.levels as Array).is_empty() and Time.get_ticks_msec() - t0 < 120000:
		a.pump(8000)
		await (Engine.get_main_loop() as SceneTree).process_frame
	return fs.levels


func _chan_at(a: Atmosphere, terrain: Terrain, p: Vector3, from_deg: float) -> Dictionary:
	var fs: Variant = a.air_field
	var lv: WindField = (fs.levels as Array)[0]
	var ground := terrain.height_at(p.x, p.z)
	var s4: Vector4 = fs.sample(p, ground)
	var share := maxf(s4.w, 1.0e-9)
	var uf := Vector2(s4.x, s4.z).length() / share
	var tb: PackedFloat32Array = fs.sample_turb(p, ground)
	var agl := p.y - ground
	var z0 := lv.z0  # как в Rust: sep::lee и sigma() берут z0 уровня (лог-среднее карты), не столбца
	var z0_col := lv.z0_at(p)
	var u_out := tb[3]
	var a_out := tb[4]
	var lee := 0.0
	if u_out >= 0.5 and agl < a_out:
		var r := log(maxf(agl, 2.0 * z0) / z0) / log(maxf(a_out, 2.0 * z0) / z0)
		var ex := 1.0 - uf / u_out / maxf(r, 1.0e-3)
		var sep := _smooth(0.3, 0.7, ex)
		lee = sep * _smooth(0.0, 0.05, tb[5]) if sep > 0.0 else 0.0
	var relief := _relief(terrain, p, from_deg)
	var u_h := uf
	if lee > 0.0 and relief > agl:
		var s5: Vector4 = fs.sample(Vector3(p.x, ground + relief, p.z), ground)
		if s5.w > 0.0:
			u_h = Vector2(s5.x, s5.z).length() / s5.w
	var dx := (fs.levels as Array).map(func(l: WindField) -> float: return l.dx)
	return {
		"agl": agl, "ground": ground, "share": s4.w, "uf": uf, "vf": [s4.x / share, s4.y / share, s4.z / share],
		"tb": Array(tb), "z0": z0, "z0_col": z0_col, "lee_f": lee, "relief": relief, "u_h": u_h, "dx": dx,
	}


func _dump_pt(tag: String, a: Atmosphere, terrain: Terrain, p: Vector3, from_deg: float) -> void:
	await _ready_levels(a)
	var d := a.decompose(p)
	var names: PackedStringArray = d.names
	var ts := {}
	var tv := {}
	for i in names.size():
		ts[names[i]] = d.sigma[i]
		tv[names[i]] = [d.vel[i].x, d.vel[i].y, d.vel[i].z]
	var mw := a.mean_wind_at(p)
	var ch := _chan_at(a, terrain, p, from_deg)
	# вертикальный разрез в той же вертикали (agl 5…200)
	var prof := []
	var g := terrain.height_at(p.x, p.z)
	for z in [5.0, 10.0, 20.0, 35.0, 50.0, 75.0, 100.0, 150.0, 200.0, 300.0]:
		var q := Vector3(p.x, g + z, p.z)
		var c2 := _chan_at(a, terrain, q, from_deg)
		prof.append({"agl": z, "sigma": a.turbulence_intensity_at(q), "mean": [a.mean_wind_at(q).x, a.mean_wind_at(q).y, a.mean_wind_at(q).z], "uf": c2.uf, "lee_f": c2.lee_f, "tb": c2.tb, "u_h": c2.u_h, "relief": c2.relief})
	print("LT11 " + JSON.stringify({"tag": tag, "p": [p.x, p.y, p.z], "sigma": a.turbulence_intensity_at(p), "w": a.air_velocity_at(p).y,
		"mean": [mw.x, mw.y, mw.z], "term_sigma": ts, "term_vel": tv, "chan": ch, "prof": prof, "from_deg": from_deg}))


## Вся сетка поиска (расстояние × agl) обоих направлений: σ и w — для карты, где подветренная выше.
func _dump_grid(tag: String, a: Atmosphere, terrain: Terrain, site: Dictionary) -> void:
	var heading: float = float(site.heading_deg)
	var away_dir := Vector2(sin(deg_to_rad(heading)), -cos(deg_to_rad(heading)))
	var pos0: Vector3 = site.position
	var pts := PackedVector3Array()
	var meta := []
	var d := -LEE_D_RANGE_M
	while d <= LEE_D_RANGE_M:
		var p2: Vector2 = Vector2(pos0.x, pos0.z) + away_dir * d
		var gh := terrain.height_at(p2.x, p2.y)
		for agl: float in LEE_AGL:
			pts.append(Vector3(p2.x, gh + agl, p2.y))
			meta.append([d, agl, gh])
		d += LEE_D_STEP_M
	var v := a.sample_many(pts, Atmosphere.SAMPLE_MEAN)
	var rows := []
	for i in pts.size():
		rows.append([meta[i][0], meta[i][1], meta[i][2], v[4 * i], v[4 * i + 1], v[4 * i + 2], v[4 * i + 3]])
	print("LT11G " + JSON.stringify({"tag": tag, "rows": rows}))


func test_lt11_probe() -> void:
	await (Engine.get_main_loop() as SceneTree).process_frame
	var only := _only()
	await _each_site(
		func(loc_id: String, terrain: Terrain, site: Dictionary) -> void:
			var key := "%s/%s" % [loc_id, site.id]
			if not only.is_empty() and not (key in only):
				return
			var heading: float = float(site.heading_deg)
			var lee: Dictionary = await _scan_lee_point(terrain, site, 20.0)
			var p: Vector3 = lee.pos
			_site_pos = p
			print("LT11S " + JSON.stringify({"key": key, "heading": heading, "p": [p.x, p.y, p.z], "depth": lee.depth, "ground": terrain.height_at(p.x, p.z), "site": [site.position.x, site.position.y, site.position.z]}))
			var from_lee := fposmod(heading + 180.0, 360.0)
			var a_lee: Atmosphere = await _make_atmo(terrain, 20.0, from_lee)
			await _dump_pt(key + ".lee", a_lee, terrain, p, from_lee)
			_dump_grid(key + ".lee", a_lee, terrain, site)
			a_lee.free()
			var a_wind: Atmosphere = await _make_atmo(terrain, 20.0, heading)
			await _dump_pt(key + ".wind", a_wind, terrain, p, heading)
			_dump_grid(key + ".wind", a_wind, terrain, site)
			a_wind.free()
			check(true, key)
	)
