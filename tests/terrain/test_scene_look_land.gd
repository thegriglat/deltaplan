extends TestCase
## scene-look SL-5: прибрежная полоса, граница леса — числами
## (CPU-зеркало формул scene_look.gdshaderinc: sl_riparian_* /
## Terrain.treeline_height / sl_forest; правятся вместе). Север — −Z.

static func _sl() -> Dictionary:
	return Config.get_config("world").get("scene_look", {})


## = Terrain.treeline_height (результат уходит в uniform sl_treeline_h)
static func treeline(lat: float, sl: Dictionary) -> float:
	return Terrain.treeline_height(lat, sl)


## Прямой берег: вода при x < 0, маска 10 м билинейно (скат шириной 10 м от x = −5 до x = 5)
static func mask_g(x: float) -> float:
	return clampf(0.5 - x / 10.0, 0.0, 1.0)


## = sl_riparian_w (sl_riparian_ring по прямому берегу) на расстоянии d от кромки воды
static func riparian_w(d: float, sl: Dictionary) -> float:
	var r := float(sl.riparian_radius_m)
	var s := 0.0
	for i in 6:
		var a := deg_to_rad(60.0 * i)
		var b := deg_to_rad(60.0 * i + 30.0)
		s += mask_g(d + cos(a) * r) + mask_g(d + cos(b) * 0.5 * r)
	return smoothstep(0.0, float(sl.riparian_sat), s / 12.0) * (1.0 - mask_g(d))


## Доля лесных пикселей, перекрашенных в просвет луга на высоте h (шум просветов — равномерный 0…1):
## = gap из sl_forest
static func gap_share(h: float, lat: float, sl: Dictionary) -> float:
	var tl := treeline(lat, sl)
	var p := smoothstep(tl - float(sl.treeline_thin_m), tl, h)
	var acc := 0.0
	for k in 200:
		var n2 := (k + 0.5) / 200.0
		acc += smoothstep(0.0, 0.2, p * 1.2 - n2)
	return acc / 200.0


func test_riparian_width() -> void:
	var sl := _sl()
	check(bool(sl.riparian_enabled), "riparian_enabled в конфиге")
	var full := 0.0
	var half := 0.0
	var edge := 0.0
	var d := 6.0
	print("         прибрежная полоса (прямой берег): расстояние от воды → вес")
	while d < 90.0:
		var w := riparian_w(d, sl)
		if int(d) % 12 == 0:
			print("           %3.0f м  %.2f" % [d, w])
		if w >= 0.99:
			full = d
		if w >= 0.5:
			half = d
		if w > 0.02:
			edge = d
		d += 1.0
	print("         полная сила до %.0f м, половина до %.0f м, край %.0f м" % [full, half, edge])
	check(full >= 20.0 and full <= 45.0, "полная сила до %.0f м" % full)
	check(edge >= 40.0 and edge <= 65.0, "край полосы %.0f м" % edge)
	check(riparian_w(150.0, sl) == 0.0, "далеко от воды 0")


func test_treeline() -> void:
	var sl := _sl()
	check(bool(sl.treeline_enabled), "treeline_enabled в конфиге")
	var t0 := treeline(0.0, sl)
	var t47 := treeline(47.0, sl)
	var t60 := treeline(60.0, sl)
	var ts := treeline(-47.0, sl)
	print("         граница леса: 0° %.0f м, 47° %.0f м, 60° %.0f м, 47°S %.0f м" % [t0, t47, t60, ts])
	check(t0 >= 3500.0 and t0 <= 4000.0, "тропики 3500–4000")
	check(absf(t47 - 2000.0) <= 200.0, "Альпы ≈ 2000 (%.0f)" % t47)
	check(absf(t60 - 1000.0) <= 150.0, "60° ≈ 1000 (%.0f)" % t60)
	check(is_equal_approx(ts, t47), "симметрия полушарий")
	# доля леса, перекрашенного в просвет/луг, по высоте у границы на 47°
	var tl := t47
	print("         доля леса в просветах (47°): tl−300 %.2f, tl−150 %.2f, tl %.2f, tl+100 %.2f" % [
		gap_share(tl - 300.0, 47.0, sl), gap_share(tl - 150.0, 47.0, sl), gap_share(tl, 47.0, sl), gap_share(tl + 100.0, 47.0, sl)])
	check(gap_share(tl - 400.0, 47.0, sl) < 0.01, "ниже зоны — сплошной лес")
	check(gap_share(tl - 150.0, 47.0, sl) > 0.1 and gap_share(tl - 150.0, 47.0, sl) < 0.7, "у границы редеет")
	check(gap_share(tl + 50.0, 47.0, sl) > 0.95, "выше границы — луг (доля леса %.2f)" % (1.0 - gap_share(tl + 50.0, 47.0, sl)))
