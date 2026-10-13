extends Node
## Проба «как выглядят скалы» (fix/cliffs-shymbulak). Не игровой код: грузит место (как игра —
## Terrain.load_point / load_builtin), проходит детальный слой сеткой в круге вокруг точки и
## повторяет на CPU формулы раскраски крутых склонов из terrain.gdshader (уклон по ±1 узлу —
## нормаль фрагмента вблизи, классы карты поверхности, вес скал, выходов породы, осыпи, снега в
## кулуарах, промоин). Шум шейдера (rnoise, пятна) — средним значением. Печатает таблицу по
## корзинам уклона: доля площади, классы, средние веса и «фактурная доля» — где на склоне есть
## рисунок породы (текстура скал или выходов), а где ровный цвет грунта/травы.
##
##   XDG_DATA_HOME=$(mktemp -d) godot --headless --path . res://tools/bench/cliff_look_probe.tscn -- \
##     --latlon=43.128,77.081 [--radius=3000] [--step=20] [--tag=shymbulak]
##   --location=ongudai   встроенное место (центр — его старт по умолчанию — центр локации)
##   --shape=1   ещё и форма: сырые высоты Copernicus (без сглаживания сборки) на той же сетке против
##               слоя игры и сетки LOD (узлы через 2/4/8) — уклоны, гребни и ложбины
## Печатает строки «CLIFF …» и «cliff_look_probe: OK».

const BINS := [0.0, 15.0, 25.0, 30.0, 38.0, 45.0, 55.0, 90.0]

var _lat := NAN
var _lon := NAN
var _location := ""
var _radius := 3000.0
var _step := 20.0
var _tag := ""
var _shape := false


func _ready() -> void:
	for a in OS.get_cmdline_user_args():
		var kv := a.split("=", true, 1)
		match kv[0]:
			"--latlon":
				var p := kv[1].split(",")
				_lat = float(p[0])
				_lon = float(p[1])
			"--location":
				_location = kv[1]
			"--radius":
				_radius = float(kv[1])
			"--step":
				_step = float(kv[1])
			"--tag":
				_tag = kv[1]
			"--shape":
				_shape = kv[1] == "1"
	if _tag == "":
		_tag = _location if _location != "" else "%.3f,%.3f" % [_lat, _lon]
	var t := Terrain.new()
	t.location_id = ""
	add_child(t)
	var res := {"ok": false, "done": false, "err": ""}
	t.loaded.connect(func() -> void: res.ok = true; res.done = true)
	t.load_failed.connect(func(m: String) -> void: res.err = m; res.done = true)
	if _location != "":
		t.load_builtin(_location)
	else:
		t.load_point(_lat, _lon)
	var t0 := Time.get_ticks_msec()
	while not res.done and Time.get_ticks_msec() - t0 < 600000:
		await get_tree().process_frame
	if not res.ok:
		print("cliff_look_probe: FAIL %s %s" % [_tag, res.err])
		get_tree().quit(1)
		return
	var c := Vector2.ZERO
	if not is_nan(_lat):
		c = t.latlon_to_local(_lat, _lon)
	_measure(t, c)
	if _shape:
		await _measure_shape(t, c)
	print("cliff_look_probe: OK %s" % _tag)
	t.queue_free()
	await get_tree().process_frame
	get_tree().quit(0)


static func _ss(e0: float, e1: float, x: float) -> float:
	var u := clampf((x - e0) / (e1 - e0), 0.0, 1.0)
	return u * u * (3.0 - 2.0 * u)


func _measure(t: Terrain, c: Vector2) -> void:
	var L: HeightLayer = t.layers[0]
	var S: SurfaceLayer = t.surfaces[0]
	var look: Dictionary = t._look
	var rock_deg := float(look.get("rock_slope_deg", 38.0))
	var rock_bl := float(look.get("rock_blend_deg", 8.0))
	var oc_sl: Array = look.get("outcrop_slope_deg", [25.0, 36.0])
	var snow_line := float(look.get("gully_snow_line_m", 2500.0))
	var e_sl: Array = look.get("erosion_slope_deg", [5.0, 18.0])
	var sn_sl: Array = look.get("snow_slope_deg", [38.0, 52.0])
	var sn_hollow := float(look.get("snow_hollow_deg", 6.0))
	var sn_blow := float(look.get("snow_ridge_blow", 0.6))
	var cvx_k := float(look.get("outcrop_convex_k", 0.035))
	var cvx_m := float(look.get("outcrop_scale_m", 35.0))
	var sp := L.spacing
	print("CLIFF %s layer spacing=%.1f m, rock_slope_deg=%.0f±%.0f, outcrop=%s, snow_line=%.0f"
			% [_tag, sp, rock_deg, rock_bl * 0.5, str(oc_sl), snow_line])
	var nb := BINS.size() - 1
	var cnt := PackedFloat64Array()
	cnt.resize(nb)
	var acc := {}
	for k in ["forest", "grass", "shrub", "bare", "snow", "other", "rock", "outcrop", "gsnow",
			"eros", "plain", "tex", "h", "snow2"]:
		var a := PackedFloat64Array()
		a.resize(nb)
		acc[k] = a
	var n := int(_radius / _step)
	var total := 0
	for j in range(-n, n + 1):
		for i in range(-n, n + 1):
			var p := c + Vector2(i, j) * _step
			if p.length_squared() > 0.0 and (p - c).length() > _radius:
				continue
			if not L.contains(p.x, p.y):
				continue
			var h := L.sample(p.x, p.y)
			var gx := (L.sample(p.x + sp, p.y) - L.sample(p.x - sp, p.y)) / (2.0 * sp)
			var gz := (L.sample(p.x, p.y + sp) - L.sample(p.x, p.y - sp)) / (2.0 * sp)
			var slope := rad_to_deg(atan(sqrt(gx * gx + gz * gz)))
			var b := 0
			while b < nb - 1 and slope >= BINS[b + 1]:
				b += 1
			var cl := S.class_at(p.x, p.y)
			var forest := float(cl == SurfaceLayer.FOREST)
			var grass := float(cl == SurfaceLayer.GRASS or cl == 0 or cl > 8 or cl == SurfaceLayer.CROP)
			var shrub := float(cl == SurfaceLayer.SHRUB)
			var bare := float(cl == SurfaceLayer.BARE)
			var snow := float(cl == SurfaceLayer.SNOW)
			# снег класса 8 после MLK-4 (CPU-зеркало шейдера; шум кромки — средним: ступенька по 0,5)
			var cg := maxf(cvx_m, sp)
			var cv := -(L.sample(p.x + cg, p.y) + L.sample(p.x - cg, p.y) + L.sample(p.x, p.y + cg)
					+ L.sample(p.x, p.y - cg) - 4.0 * h) / (4.0 * cg) / cvx_k
			var s_eff := slope - sn_hollow * _ss(0.0, 1.0, -cv)
			var keep := (1.0 - _ss(float(sn_sl[0]), float(sn_sl[1]), s_eff)) * (1.0 - sn_blow * _ss(0.7, 1.6, cv))
			var snow2 := snow * _ss(0.44, 0.56, snow * keep)
			var other := 1.0 - forest - grass - shrub - bare - snow
			var open_w := grass + shrub + bare
			# скалы (шум rnoise — средним)
			var rock := _ss(rock_deg - rock_bl * 0.5, rock_deg + rock_bl * 0.5, slope) * open_w
			# выходы породы: крутизна (выпуклость не считаем — нижняя оценка), доля пятен ~ 0,5
			var steep := _ss(float(oc_sl[0]), float(oc_sl[1]), slope)
			var outcrop := 0.5 * _ss(0.0, 0.3, steep) * open_w * (1.0 - rock)
			# снег в кулуарах: ложбина (лапласиан 60 м) выше линии
			var gd := maxf(60.0, 2.0 * sp)
			var lap := (L.sample(p.x + gd, p.y) + L.sample(p.x - gd, p.y) + L.sample(p.x, p.y + gd)
					+ L.sample(p.x, p.y - gd) - 4.0 * h) / (4.0 * gd)
			var gsnow := _ss(0.0, 0.08, lap) * _ss(snow_line - 100.0, snow_line + 150.0, h) \
					* (1.0 - _ss(48.0, 58.0, slope)) * (1.0 - forest)
			var eros := (1.0 - forest) * (1.0 - snow) * (1.0 - gsnow) * _ss(float(e_sl[0]), float(e_sl[1]), slope)
			# фактурная доля: порода с текстурой (скалы + коренные выходы); ровно: голый грунт и
			# луг без скал на склоне круче 25°
			var tex := clampf(rock + outcrop, 0.0, 1.0) * (1.0 - gsnow)
			var plain := (1.0 - tex) * (1.0 - gsnow) * (bare + float(slope > 25.0) * (grass + shrub))
			cnt[b] += 1.0
			total += 1
			var vals := {"forest": forest, "grass": grass, "shrub": shrub, "bare": bare, "snow": snow,
					"other": other, "rock": rock, "outcrop": outcrop, "gsnow": gsnow, "eros": eros,
					"plain": plain, "tex": tex, "h": h, "snow2": snow2}
			for k: String in vals:
				var a: PackedFloat64Array = acc[k]
				a[b] += vals[k]
				acc[k] = a
	print("CLIFF %s точек=%d (шаг %.0f м, радиус %.0f м)" % [_tag, total, _step, _radius])
	print("CLIFF %s снег класса 8 по уклону: доля клеток снега до -> после (MLK-4)" % _tag)
	for b in nb:
		if cnt[b] > 0.0:
			print("CLIFF %s SNOWBAND %2.0f-%2.0f° n=%d before=%.3f after=%.3f"
					% [_tag, BINS[b], BINS[b + 1], int(cnt[b]), acc["snow"][b] / cnt[b], acc["snow2"][b] / cnt[b]])
	print("CLIFF %s уклон    площ%%  высота  лес  луг  куст грунт снег | скалы выход снегКул промоин | фактура ровно" % _tag)
	for b in nb:
		if cnt[b] <= 0.0:
			continue
		var m := func(k: String) -> float: return acc[k][b] / cnt[b]
		print("CLIFF %s %2.0f-%2.0f°  %5.1f  %5.0f  %4.2f %4.2f %4.2f %4.2f  %4.2f | %4.2f  %4.2f  %4.2f   %4.2f   | %4.2f   %4.2f"
				% [_tag, BINS[b], BINS[b + 1], 100.0 * cnt[b] / total, m.call("h"), m.call("forest"),
				m.call("grass"), m.call("shrub"), m.call("bare"), m.call("snow"), m.call("rock"),
				m.call("outcrop"), m.call("gsnow"), m.call("eros"), m.call("tex"), m.call("plain")])


## Сырые высоты (Copernicus, тот же источник и сетка, без smooth_sigma_cells) в квадрате 16 км у центра.
func _raw_layer(t: Terrain) -> HeightLayer:
	var L: HeightLayer = t.layers[0]
	var st: Object = (load("res://scripts/terrain/build/dem_stage.gd") as GDScript).new()
	var ctx := LocationBuildContext.new()
	ctx.key = "cliff_probe_raw"
	ctx.center_lat = t.center_lat
	ctx.center_lon = t.center_lon
	ctx.host = self
	ctx.dir = OS.get_user_data_dir().path_join("cliff_probe_raw")
	ctx.spec = {"dem": {"layers": [{"id": "detail", "size_km": 16, "spacing_m": L.spacing,
			"source": "copernicus", "zoom": 12, "quantize_per_m": 32, "smooth_sigma_cells": 0}]}}
	var err: int = await st.run(ctx)
	if err != OK:
		print("CLIFF %s raw: ошибка %d %s" % [_tag, err, str(ctx.log_lines)])
		return null
	var n := int(round(16000.0 / L.spacing)) + 1
	var half := (n - 1) * L.spacing / 2.0
	return HeightLayer.from_heights("raw", n, n, L.spacing, -half, -half, ctx.heights["detail"])


## Высота «как рисует сетка LOD с шагом s узлов»: билинейно между узлами через s.
static func _mesh_h(L: HeightLayer, x: float, z: float, s: int) -> float:
	var fx := (x - L.origin_x) / L.spacing / s
	var fz := (z - L.origin_z) / L.spacing / s
	var i := int(floor(fx))
	var j := int(floor(fz))
	var tx := fx - i
	var tz := fz - j
	var a := L.node(i * s, j * s)
	var b := L.node((i + 1) * s, j * s)
	var c := L.node(i * s, (j + 1) * s)
	var d := L.node((i + 1) * s, (j + 1) * s)
	return lerpf(lerpf(a, b, tx), lerpf(c, d, tx), tz)


func _measure_shape(t: Terrain, c: Vector2) -> void:
	var L: HeightLayer = t.layers[0]
	var R := await _raw_layer(t)
	if R == null:
		return
	var sp := L.spacing
	var lods := [1, 2, 4, 8]
	# поля: сырые, слой игры, сетка LOD1..3 (по узлам слоя игры)
	var names := ["сырые", "игра", "LOD1(50м)", "LOD2(100м)", "LOD3(200м)"]
	var slopes: Array = []
	for k in names.size():
		slopes.append([])
	var crest := PackedFloat64Array()
	crest.resize(names.size())
	var vall := PackedFloat64Array()
	vall.resize(names.size())
	var n_crest := 0
	var n_vall := 0
	var curv_raw := 0.0
	var curv_game := 0.0
	var n := int(_radius / sp)
	var ci := int(round((c.x - L.origin_x) / sp))
	var cj := int(round((c.y - L.origin_z) / sp))
	for j in range(cj - n, cj + n + 1):
		for i in range(ci - n, ci + n + 1):
			var x := L.origin_x + i * sp
			var z := L.origin_z + j * sp
			if Vector2(x, z).distance_to(c) > _radius or not R.contains(x - 3 * sp, z - 3 * sp) \
					or not R.contains(x + 3 * sp, z + 3 * sp):
				continue
			var hs := []
			for k in names.size():
				var f: Callable
				if k == 0:
					f = func(xx: float, zz: float) -> float: return R.sample(xx, zz)
				elif k == 1:
					f = func(xx: float, zz: float) -> float: return L.sample(xx, zz)
				else:
					var s: int = lods[k - 1]
					f = func(xx: float, zz: float) -> float: return _mesh_h(L, xx, zz, s)
				var gx: float = (f.call(x + sp, z) - f.call(x - sp, z)) / (2.0 * sp)
				var gz: float = (f.call(x, z + sp) - f.call(x, z - sp)) / (2.0 * sp)
				(slopes[k] as Array).append(rad_to_deg(atan(sqrt(gx * gx + gz * gz))))
				hs.append(f.call(x, z))
			# гребень/ложбина в сырых: лапласиан на шаге сетки (м/м)
			var h0 := R.sample(x, z)
			var lap := (R.sample(x + sp, z) + R.sample(x - sp, z) + R.sample(x, z + sp) + R.sample(x, z - sp)
					- 4.0 * h0) / (4.0 * sp)
			var lapg := (L.sample(x + sp, z) + L.sample(x - sp, z) + L.sample(x, z + sp) + L.sample(x, z - sp)
					- 4.0 * L.sample(x, z)) / (4.0 * sp)
			if lap < -0.15:
				n_crest += 1
				curv_raw += -lap
				curv_game += -lapg
				for k in names.size():
					crest[k] += h0 - float(hs[k])
			elif lap > 0.15:
				n_vall += 1
				for k in names.size():
					vall[k] += float(hs[k]) - h0
	print("CLIFF %s ФОРМА: точек=%d, гребней (лапласиан сырых < −0,15 м/м на шаге %.0f м)=%d, ложбин=%d"
			% [_tag, (slopes[0] as Array).size(), sp, n_crest, n_vall])
	if n_crest > 0:
		print("CLIFF %s кривизна гребней: сырые %.3f м/м, игра %.3f м/м (×%.2f)"
				% [_tag, curv_raw / n_crest, curv_game / n_crest, curv_game / maxf(curv_raw, 1e-6)])
	print("CLIFF %s поле          уклон p50  p90  p99  max | гребень ниже сырых, м | ложбина выше, м" % _tag)
	for k in names.size():
		var a: Array = slopes[k]
		a.sort()
		var q := func(p: float) -> float: return a[mini(int(p * a.size()), a.size() - 1)]
		print("CLIFF %s %-12s %5.1f %5.1f %5.1f %5.1f | %6.2f | %6.2f" % [_tag, names[k], q.call(0.5), q.call(0.9),
				q.call(0.99), a[a.size() - 1], crest[k] / maxf(n_crest, 1), vall[k] / maxf(n_vall, 1)])
