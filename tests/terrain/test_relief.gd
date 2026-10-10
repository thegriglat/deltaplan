extends TestCase
## Поля рельефа (TerrainRelief): влажность, AO, горизонт к солнцу, время расчёта.
## Запуск — godot --headless --path . res://tests/run_tests.tscn -- --filter=test_relief

const SPACING := 25.0
const N := 161  # −2000…+2000 м


## Гребни и долины вдоль Z: h = 500 + 100·cos(2πx/1000) + 0,05·z (долины по x = ±500, ±1500).
func _ridges() -> HeightLayer:
	var data := PackedFloat32Array()
	data.resize(N * N)
	var o := -(N - 1) * SPACING * 0.5
	for j in N:
		for i in N:
			var x := o + i * SPACING
			var z := o + j * SPACING
			data[j * N + i] = 500.0 + 100.0 * cos(TAU * x / 1000.0) + 0.05 * z
	return HeightLayer.from_heights("detail", N, N, SPACING, o, o, data)


func _cfg() -> Dictionary:
	return Config.get_config("world").get("surface", {}).get("relief", {})


func test_valley_wetter_than_ridge() -> void:
	var r := TerrainRelief.compute(_ridges(), _cfg(), 90.0)
	var valley := r.moisture_at(500.0, 0.0)
	var ridge := r.moisture_at(0.0, 0.0)
	check(valley > ridge + 0.25, "ложбина влажнее гребня: %.2f против %.2f" % [valley, ridge])
	# низ долины (больше водосбор) не суше верха
	check(
		r.moisture_at(500.0, 1500.0) >= r.moisture_at(500.0, -1500.0) - 0.02,
		"низ долины не суше верха"
	)


func test_ao_darker_in_valley() -> void:
	var r := TerrainRelief.compute(_ridges(), _cfg(), 90.0)
	var valley := r.ao_at(500.0, 0.0)
	var ridge := r.ao_at(0.0, 0.0)
	check(valley < ridge - 0.05, "AO в ложбине темнее: %.2f против %.2f" % [valley, ridge])
	check(ridge > 0.95, "гребень почти открыт небу: %.2f" % ridge)


func test_horizon_toward_sun() -> void:
	# солнце на востоке (+X): склон к солнцу (x ≈ 250) видит далёкий гребень (~7,6°),
	# склон от солнца (x ≈ 750) — за близким склоном гребня (~31°)
	var r := TerrainRelief.compute(_ridges(), _cfg(), 90.0)
	var lit := r.horizon_at(250.0, 0.0)
	var shade := r.horizon_at(750.0, 0.0)
	check(shade > lit + 10.0, "склон от солнца за гребнем: %.1f° против %.1f°" % [shade, lit])
	approx(shade, 31.5, 2.5, "угол горизонта до склона гребня (max tan ≈ 0,62)")
	r.recompute_horizon(270.0)  # солнце на западе — наоборот
	check(
		r.horizon_at(250.0, 0.0) > r.horizon_at(750.0, 0.0) + 10.0, "после смены азимута — наоборот"
	)


func test_terrain_set_sun_recomputes_shadow() -> void:
	var t := Terrain.new()
	t.location_id = ""
	var world: Dictionary = Config.get_config("world")
	t.layers = [_ridges()]
	var cd := PackedByteArray()
	cd.resize(N * N)
	cd.fill(SurfaceLayer.GRASS)
	var o := -(N - 1) * SPACING * 0.5
	t.set_surfaces(
		[SurfaceLayer.from_classes("g", N, N, SPACING, o, o, cd)],
		world.get("surface", {}),
		world.get("terrain_look", {})
	)
	t._compute_reliefs(_cfg())
	t.wait_relief()  # поля считаются в фоне
	check(t.reliefs.size() == 1, "поля посчитаны")
	check(t.moisture_at(500.0, 0.0) > t.moisture_at(0.0, 0.0), "Terrain.moisture_at")
	check(t.relief_ao_at(500.0, 0.0) < t.relief_ao_at(0.0, 0.0), "Terrain.relief_ao_at")
	t.set_sun(TerrainGeo.sun_direction(90.0, 10.0))
	t.wait_relief()
	approx(t.reliefs[0].horizon_azimuth_deg, 90.0, 0.01, "горизонт пересчитан под новый азимут")
	check(t.relief_horizon_at(750.0, 0.0) > 10.0, "тень за гребнем при солнце с востока")
	# сырая ложбина — источник термиков слабее (β по влажности, SurfaceHeat): сухой гребень сильнее
	t.set_sun(Vector3.UP)
	t.wait_relief()
	var wet := t.thermal_source_strength_at(500.0, 0.0)
	var dry := t.thermal_source_strength_at(0.0, 0.0)
	check(t.surface_at(500.0, 0.0) == t.surface_at(0.0, 0.0), "тот же класс у ложбины и гребня")
	var nw := t.normal_at(500.0, 0.0)
	var nd := t.normal_at(0.0, 0.0)
	check(nw.dot(nd) > 0.9999 and nw.y > 0.99, "нормали ложбины и гребня одинаковы, почти вертикальны")
	check(wet < dry, "сырая ложбина — источник слабее: %.3f против %.3f" % [wet, dry])
	t.free()


func test_compute_time_40km() -> void:
	var dir := Locations.data_dir("ongudai")
	var meta: Dictionary = JSON.parse_string(
		FileAccess.get_file_as_string(dir.path_join("meta.json"))
	)
	var total := 0.0
	var k := 0
	for info: Dictionary in meta.layers:
		var l := HeightLayer.load_from_file(dir.path_join(String(info.file)), info)
		var r := TerrainRelief.compute(l, _cfg(), 200.0, k)
		total += r.compute_s
		print("         поля %s (%d²): %.2f с %s" % [l.id, r.width, r.compute_s, r.timings])
		k += 1
	check(total < 3.0, "поля локации 40 км + фон ≤ 3 с, было %.2f с" % total)
