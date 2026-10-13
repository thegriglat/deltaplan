extends TestCase
## scene-look SL-5: склоны по солнцу в полдень, прибрежная полоса, граница леса — числами
## (CPU-зеркало формул scene_look.gdshaderinc: sl_noon_sun / sl_aspect / sl_riparian_* /
## sl_treeline_height / sl_forest; правятся вместе). Север — −Z.

const DOY_JULY := 196.0
const DOY_EQUINOX := 80.0


static func _sl() -> Dictionary:
	return Config.get_config("world").get("scene_look", {})


static func decl(doy: float) -> float:
	return 23.44 * sin(TAU * (doy - 81.0) / 365.0)


## = sl_noon_sun
static func noon_sun(lat: float, doy: float) -> Vector3:
	var dl := lat - decl(doy)
	var alt := deg_to_rad(90.0 - absf(dl))
	return Vector3(0.0, sin(alt), (1.0 if dl >= 0.0 else -1.0) * cos(alt))


## = sl_aspect
static func aspect(n: Vector3, lat: float, doy: float, sl: Dictionary) -> float:
	var s := noon_sun(lat, doy)
	var m := float(sl.slope_max)
	return clampf(n.dot(s) / maxf(s.y, 0.15) - 1.0, -m, m)


## Нормаль склона уклона tilt_deg к экватору (to_eq = true) или от него (северное полушарие:
## к югу = +Z; южное — к северу = −Z).
static func slope_n(tilt_deg: float, lat: float, to_eq: bool) -> Vector3:
	var south := lat >= 0.0
	var dir_z := (1.0 if south else -1.0) * (1.0 if to_eq else -1.0)
	var t := deg_to_rad(tilt_deg)
	return Vector3(0.0, cos(t), dir_z * sin(t))


## = sl_treeline_height
static func treeline(lat: float, sl: Dictionary) -> float:
	var la: Array = sl.treeline_lat
	var hm: Array = sl.treeline_m
	var a := clampf(absf(lat), float(la[0]), float(la[3]))
	var r := float(hm[0])
	for i in 3:
		var t := clampf((a - float(la[i])) / maxf(float(la[i + 1]) - float(la[i]), 1e-3), 0.0, 1.0)
		if a >= float(la[i]):
			r = lerpf(float(hm[i]), float(hm[i + 1]), t)
	return r


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


func test_slope_dryness() -> void:
	var sl := _sl()
	check(bool(sl.slope_enabled), "slope_enabled в конфиге")
	var k := float(sl.slope_dry_k)
	print("         склон 30° к экватору / от экватора: E/E_ровного − 1 и сдвиг сухости")
	var diffs := {}
	for c in [["50°N июль", 50.0, DOY_JULY], ["35°S июль", -35.0, DOY_JULY], ["2°N июль", 2.0, DOY_JULY],
			["2°N равноденствие", 2.0, DOY_EQUINOX], ["50°N декабрь", 50.0, 355.0]]:
		var to_eq := aspect(slope_n(30.0, c[1], true), c[1], c[2], sl)
		var away := aspect(slope_n(30.0, c[1], false), c[1], c[2], sl)
		diffs[c[0]] = to_eq - away
		print("         %-18s к экватору %+.3f (сухость %+.3f)  от %+.3f (%+.3f)  разница %.3f" % [c[0], to_eq, k * to_eq, away, k * away, to_eq - away])
	# 50°N, июль: сторона к экватору светлее ровного места, обратная — заметно темнее
	var n50 := aspect(slope_n(30.0, 50.0, true), 50.0, DOY_JULY, sl)
	var f50 := aspect(slope_n(30.0, 50.0, false), 50.0, DOY_JULY, sl)
	check(n50 > 0.05 and f50 < -0.3, "50°N: к экватору %.3f, от %.3f" % [n50, f50])
	# 35°S: к экватору — к северу (−Z): то же самое зеркально
	var s35 := aspect(slope_n(30.0, -35.0, true), -35.0, DOY_JULY, sl)
	var s35a := aspect(slope_n(30.0, -35.0, false), -35.0, DOY_JULY, sl)
	check(s35 > s35a and s35a < -0.2, "35°S: к экватору %.3f > от %.3f" % [s35, s35a])
	check(slope_n(30.0, -35.0, true).z < 0.0, "35°S: склон к экватору смотрит на север (−Z)")
	# экватор в равноденствие: стороны почти не различаются, много меньше, чем на 50°
	check(diffs["2°N равноденствие"] < 0.05, "2°N в равноденствие разница сторон %.3f" % diffs["2°N равноденствие"])
	check(diffs["2°N равноденствие"] < 0.15 * diffs["50°N июль"], "экватор ≪ 50°N")
	# ровное место — ноль
	approx(aspect(Vector3.UP, 50.0, DOY_JULY, sl), 0.0, 1e-6, "ровное")
	# сухость итого = k·asp: прежний −Z вклад вычитается: dsk·north + adk·north_s + k·asp
	var tl: Dictionary = Config.get_config("world").terrain_look
	var dsk := float(tl.dry_south_k)
	var old_dry := -dsk * 1.0 - float(tl.aspect_dry_k) * 1.0   # северный склон: было влажнее
	var new_total := old_dry + (dsk * 1.0 + float(tl.aspect_dry_k) * 1.0 + k * f50)
	approx(new_total, k * f50, 1e-6, "прежний вклад погашен")


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
