extends TestCase
## scene-look SL-2: свет дальнего леса числами (CPU-зеркало формул scene_look.gdshaderinc:
## sl_canopy_lit / sl_canopy_direct / sl_canopy_tone; правятся вместе). Яркость пикселя в
## единицах Godot: альбедо × (солнце · cos к склону · множитель полога + рассеянный свет неба).
## Печатает таблицу: лес по солнцу / против, отношение лес/луг — до модуля и с ним.

const LW := Vector3(0.2126, 0.7152, 0.0722)


static func _sl() -> Dictionary:
	return Config.get_config("world").get("scene_look", {})


static func _lin(c: Array) -> Vector3:
	var col := Color(float(c[0]), float(c[1]), float(c[2])).srgb_to_linear()
	return Vector3(col.r, col.g, col.b)


## = sl_canopy_lit
static func canopy_lit(n: Vector3, v: Vector3, l: Vector3, sl: Dictionary) -> float:
	var mu := clampf(n.dot(l), 0.02, 1.0)
	var s := 1.0 - exp(-float(sl.canopy_shadow_k) * sqrt(1.0 - mu * mu) / mu)
	s += (1.0 - s) * (1.0 - clampf(n.dot(v), 0.0, 1.0)) * 0.5
	var cx := clampf(v.dot(l), -1.0, 1.0)
	var hs := exp(-acos(cx) / maxf(float(sl.canopy_hotspot[1]), 1e-3))
	var hide := 1.0 - (1.0 - pow(0.5 + 0.5 * cx, float(sl.canopy_hide_p))) * (1.0 - hs)
	return 1.0 - s * (1.0 - hide) + float(sl.canopy_hotspot[0]) * hs


## = sl_canopy_direct при w = 1
static func canopy_direct(n: Vector3, v: Vector3, l: Vector3, sl: Dictionary) -> float:
	var s45 := 1.0 - exp(-float(sl.canopy_shadow_k))
	var h45 := 1.0 - (
		(1.0 - pow(0.5 + 0.5 * 0.70711, float(sl.canopy_hide_p)))
		* (1.0 - exp(-0.7854 / maxf(float(sl.canopy_hotspot[1]), 1e-3)))
	)
	return canopy_lit(n, v, l, sl) / (1.0 - s45 * (1.0 - h45))


static func _dir(az_deg: float, el_deg: float) -> Vector3:
	# азимут от севера по часовой; север — −Z, восток — +X (TerrainGeo)
	var az := deg_to_rad(az_deg)
	var el := deg_to_rad(el_deg)
	return Vector3(sin(az) * cos(el), sin(el), -cos(az) * cos(el))


## Таблица случаев: солнце (az 200°, el 52° — world.json sun), склон 20° к солнцу / от солнца,
## взгляд с 1000 м на 5 км (≈ 11° сверху) по солнцу (солнце за спиной) и против.
func _cases() -> Array[Dictionary]:
	var sun: Dictionary = Config.get_config("world").sun
	var az := float(sun.azimuth_deg)
	var l := _dir(az, float(sun.elevation_deg))
	var out: Array[Dictionary] = []
	for slope in [["к солнцу", az], ["от солнца", az + 180.0], ["ровно", az]]:
		var tilt := 0.0 if slope[0] == "ровно" else 20.0
		var n := _dir(float(slope[1]), 90.0 - tilt)
		for view in [["по солнцу", az], ["против", az + 180.0], ["сбоку", az + 90.0]]:
			# v — от точки к камере: камера со стороны view[1] (солнце за спиной → камера по азимуту солнца)
			var v := _dir(float(view[1]), 11.0)
			out.append({"slope": slope[0], "view": view[0], "n": n, "v": v, "l": l})
	return out


func test_far_forest_numbers() -> void:
	var sl := _sl()
	var tl: Dictionary = Config.get_config("world").terrain_look
	var sky := TerrainRenderer.scene_look_sky(_dir(200.0, 52.0))
	var amb := (sky.sky_up as Vector3).dot(LW)
	var e_sun := float(Config.get_config("world").sun.energy)
	var fmean := _lin(tl.forest_color)
	var base_alb := fmean.dot(LW) * float(tl.canopy_far_shade)
	var new_alb := float(sl.canopy_albedo[0])
	var meadow := 0.5 * (_lin(tl.grass_color).dot(LW) + _lin(tl.dry_grass_color).dot(LW))
	print("         рассеянный свет неба (Y) %.3f, солнце %.2f; альбедо хвойного полога: было %.4f, стало %.3f; луг ≈ %.3f" % [amb, e_sun, base_alb, new_alb, meadow])
	print("         склон       взгляд      k_dir  лес было  лес стало  лес/луг было  лес/луг стало")
	var res := {}
	for c in _cases():
		var ndl := maxf((c.n as Vector3).dot(c.l), 0.0)
		var k := canopy_direct(c.n, c.v, c.l, sl)
		var m := meadow * (e_sun * ndl + amb)
		var f0 := base_alb * (e_sun * ndl + amb)
		var f1 := new_alb * (e_sun * ndl * k + amb)
		res["%s/%s" % [c.slope, c.view]] = f1
		print("         %-10s  %-10s  %.2f   %.4f    %.4f     %.2f          %.2f" % [c.slope, c.view, k, f0, f1, f0 / m, f1 / m])
	# по солнцу ярче, чем против, в 1,5–4 раза (анизотропия отражения полога в видимом)
	var r: float = res["ровно/по солнцу"] / res["ровно/против"]
	check(r > 1.5 and r < 4.0, "по солнцу / против = %.2f" % r)
	check(res["к солнцу/по солнцу"] > res["от солнца/по солнцу"], "солнечный склон ярче")
	# средняя яркость в надир при солнце 45° = альбедо (нормировка)
	var n_up := Vector3.UP
	approx(canopy_direct(n_up, n_up, _dir(0.0, 45.0), sl), 1.0, 2e-3, "нормировка k_dir")


func test_canopy_floor() -> void:
	# пятна/опушка/сырость не темнее ×floor: max(fc, floor·fc0)
	var floor_k := float(_sl().canopy_floor)
	check(floor_k >= 0.5 - 1e-6, "пол пятен ≥ ×0,5")
