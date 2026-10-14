extends TestCase
## SL-26: тень горизонта на детальном слое от далёких гор. Горизонт детального слоя (канал A
## relief_tex, SL-К7) видит гребни дальше своей дальности луча (horizon_range_m) и за краем своей
## сетки — по высотам фона (TerrainRelief.outer). Прежде луч детального слоя кончался на 8 км или
## у края слоя: вокруг пилота земля светилась, а на фоне тень гор была.
## Синтетика: равнина 500 м, гребень вдоль Z к востоку; детальный слой 20 км (50 м), фон 80 км
## (200 м) — те же высоты; солнце с востока 6°. Через Terrain (как в игре: поля в фоне, set_sun).

const SUN_EL := 6.0


static func _h(x: float, z: float, rx: float, rh: float) -> float:
	var d := (x - rx) / 2000.0
	return 500.0 + rh * exp(-d * d) + 10.0 * sin(z / 700.0) * cos(x / 900.0)


static func _layer(id: String, n: int, step: float, rx: float, rh: float) -> HeightLayer:
	var o := -(n - 1) * step * 0.5
	var data := PackedFloat32Array()
	data.resize(n * n)
	for j in n:
		for i in n:
			data[j * n + i] = _h(o + i * step, o + j * step, rx, rh)
	return HeightLayer.from_heights(id, n, n, step, o, o, data)


static func _surf(l: HeightLayer) -> SurfaceLayer:
	var cd := PackedByteArray()
	cd.resize(l.width * l.height)
	cd.fill(SurfaceLayer.GRASS)
	return SurfaceLayer.from_classes(l.id, l.width, l.height, l.spacing, l.origin_x, l.origin_z, cd)


## Terrain с детальным слоем и фоном, поля посчитаны, солнце az/SUN_EL.
static func _terrain(rx: float, rh: float, az: float) -> Terrain:
	var t := Terrain.new()
	t.location_id = ""
	var ls: Array[HeightLayer] = [_layer("detail", 401, 50.0, rx, rh), _layer("far", 401, 200.0, rx, rh)]
	t.layers = ls
	var world: Dictionary = Config.get_config("world")
	t.set_surfaces([_surf(ls[0]), _surf(ls[1])], world.get("surface", {}), world.get("terrain_look", {}))
	t._compute_reliefs(world.get("surface", {}).get("relief", {}))
	t.wait_relief()
	t.set_sun(TerrainGeo.sun_direction(az, SUN_EL))
	t.wait_relief()
	return t


## Угол горизонта из канала A текстуры полей (что читает шейдер), градусы.
static func _hz_tex(r: TerrainRelief, x: float, z: float) -> float:
	var i := clampi(roundi((x - r.origin_x) / r.cell_m), 0, r.width - 1)
	var j := clampi(roundi((z - r.origin_z) / r.cell_m), 0, r.height - 1)
	return r.texture_bytes()[(j * r.width + i) * 4 + 3] * TerrainRelief.HORIZON_MAX_DEG / 255.0


## Точный угол горизонта (луч по высотам с шагом 50 м до 40 км).
static func _hz_true(x: float, z: float, rx: float, rh: float) -> float:
	var best := 0.0
	var s := 50.0
	while s < 40000.0:
		best = maxf(best, rad_to_deg(atan((_h(x + s, z, rx, rh) - _h(x, z, rx, rh)) / s)))
		s += 50.0
	return best


func _case(name: String, rx: float, rh: float) -> void:
	var t := _terrain(rx, rh, 90.0)
	check(t.reliefs.size() == 2, "%s: поля обоих слоёв" % name)
	if t.reliefs.size() < 2:
		t.free()
		return
	var rd := t.reliefs[0]
	var rf := t.reliefs[1]
	var shaded := 0
	var n := 0
	var worst := 0.0
	for p: Vector2 in [Vector2(0, 0), Vector2(-3000, 2000), Vector2(2000, -4000), Vector2(-6000, -6000)]:
		var truth := _hz_true(p.x, p.y, rx, rh)
		var hd := _hz_tex(rd, p.x, p.y)
		n += 1
		if hd > SUN_EL:
			shaded += 1
		worst = maxf(worst, truth - hd)
		print("         %s (%.0f, %.0f): горизонт детального %.1f°, фона %.1f°, точный %.1f°" % [
			name, p.x, p.y, hd, rf.horizon_at(p.x, p.y), truth])
	check(shaded == n, "%s: детальный слой в тени гребня (солнце %.0f°): %d из %d точек" % [name, SUN_EL, shaded, n])
	check(worst < 1.5, "%s: горизонт детального не ниже точного больше чем на 1,5° (было %.1f°)" % [name, worst])
	# солнце с запада — гребень за спиной: тени нет (дальнее поле не выдумывает заслон)
	t.set_sun(TerrainGeo.sun_direction(270.0, SUN_EL))
	t.wait_relief()
	var lit := _hz_tex(t.reliefs[0], 0.0, 0.0)
	check(lit < 1.0, "%s: солнце с запада — горизонт в центре ровный (%.1f°)" % [name, lit])
	t.free()


## Гребень внутри детального слоя, но дальше его луча (horizon_range_m = 8 км).
func test_ridge_beyond_detail_range() -> void:
	_case("гребень 9,5 км (в слое)", 9500.0, 2000.0)


## Гребень за краем детального слоя (слой ±10 км) — только в фоне.
func test_ridge_outside_detail_layer() -> void:
	_case("гребень 16 км (за слоем)", 16000.0, 2800.0)
