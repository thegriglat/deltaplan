extends TestCase
## Тесты рельефа: запуск — godot --headless --path . res://tests/run_tests.tscn -- --filter=terrain

const LOCATION := "altai"

static var _terrain: Terrain
static var _load_s: float = 0.0


## Одна загрузка на все тесты (рельеф не меняется).
func _altai() -> Terrain:
	if _terrain == null:
		_terrain = Terrain.new()
		_terrain.location_id = ""
		var t0 := Time.get_ticks_usec()
		_terrain.load_location(LOCATION)
		_load_s = (Time.get_ticks_usec() - t0) / 1e6
	return _terrain


func _raw_layer(info: Dictionary) -> PackedFloat32Array:
	var dir: String = Config.get_config("locations/" + LOCATION).data_dir
	var bytes := FileAccess.get_file_as_bytes(dir.path_join(info.file))
	return (
		bytes
		. decompress(int(info.width) * int(info.height) * 4, FileAccess.COMPRESSION_BROTLI)
		. to_float32_array()
	)


func _meta() -> Dictionary:
	var dir: String = Config.get_config("locations/" + LOCATION).data_dir
	return JSON.parse_string(FileAccess.get_file_as_string(dir.path_join("meta.json")))


func _plane_terrain(ax: float, az: float) -> Terrain:
	# Наклонная плоскость h = 500 + ax·x + az·z на сетке 21×21 шагом 10 м.
	var n := 21
	var data := PackedFloat32Array()
	data.resize(n * n)
	for j in n:
		for i in n:
			var x := -100.0 + i * 10.0
			var z := -100.0 + j * 10.0
			data[j * n + i] = 500.0 + ax * x + az * z
	var t := Terrain.new()
	t.location_id = ""
	t.layers = [HeightLayer.from_heights("plane", n, n, 10.0, -100.0, -100.0, data)]
	return t


func test_load_time() -> void:
	var t := _altai()
	check(t.layers.size() >= 1, "слои загружены")
	check(_load_s < 10.0, "загрузка ≤ 10 с (NFR-2), было %.2f с" % _load_s)
	print("         загрузка локации: %.2f с, чанков %d" % [_load_s, t.renderer.chunk_count()])


func test_height_matches_source_nodes() -> void:
	var t := _altai()
	var meta := _meta()
	var rng := RandomNumberGenerator.new()
	rng.seed = 42
	for info in meta.layers:
		var raw := _raw_layer(info)
		var w := int(info.width)
		var step := float(info.spacing_m)
		for k in 200:
			var i := rng.randi_range(0, w - 1)
			var j := rng.randi_range(0, int(info.height) - 1)
			var x := float(info.origin_x_m) + i * step
			var z := float(info.origin_z_m) + j * step
			# Для грубого слоя проверяем только точки вне детального.
			if info.id != meta.layers[0].id and t.layers[0].contains(x, z):
				continue
			approx(t.height_at(x, z), raw[j * w + i], 0.01, "%s узел (%d,%d)" % [info.id, i, j])


func test_bilinear_between_nodes() -> void:
	var t := _altai()
	var l := t.layers[0]
	var i := 700
	var j := 900
	var x := l.origin_x + (i + 0.5) * l.spacing
	var z := l.origin_z + (j + 0.5) * l.spacing
	var avg := (l.node(i, j) + l.node(i + 1, j) + l.node(i, j + 1) + l.node(i + 1, j + 1)) / 4.0
	approx(t.height_at(x, z), avg, 0.001, "центр клетки = среднее 4 узлов")
	var x2 := l.origin_x + (i + 0.25) * l.spacing
	approx(
		t.height_at(x2, l.origin_z + j * l.spacing),
		lerpf(l.node(i, j), l.node(i + 1, j), 0.25),
		0.001,
		"интерполяция по ребру"
	)


func test_layers_match_at_boundary() -> void:
	# На границе детального слоя грубый слой должен давать ту же высоту (узлы выровнены).
	var t := _altai()
	if t.layers.size() < 2:
		return
	var d := t.layers[0]
	var f := t.layers[1]
	for k in 20:
		var x := d.origin_x + k * 2000.0
		var z := d.origin_z
		approx(f.sample(x, z), d.sample(x, z), 0.05, "стык слоёв x=%.0f" % x)


func test_normal_on_plane() -> void:
	var t := _plane_terrain(0.3, -0.1)
	var n := t.normal_at(12.0, -33.0)
	var expected := Vector3(-0.3, 1.0, 0.1).normalized()
	check(n.distance_to(expected) < 1e-4, "нормаль плоскости %s ≈ %s" % [n, expected])
	approx(t.height_at(12.0, -33.0), 500.0 + 0.3 * 12.0 - 0.1 * -33.0, 1e-3, "высота плоскости")
	t.free()


func test_normal_real_terrain_unit_and_up() -> void:
	var t := _altai()
	var rng := RandomNumberGenerator.new()
	rng.seed = 7
	for k in 100:
		var x := rng.randf_range(-19000, 19000)
		var z := rng.randf_range(-19000, 19000)
		var n := t.normal_at(x, z)
		approx(n.length(), 1.0, 1e-4, "нормаль единичная")
		check(n.y > 0.3, "нормаль смотрит вверх (уклон < 72°)")


func test_sun_exposure() -> void:
	var t := _plane_terrain(0.0, 0.0)
	var sun := t.sun_direction()
	t.refresh_sun()
	sun = t.sun_direction()
	approx(t.sun_exposure_at(0, 0), sun.y, 1e-3, "ровная площадка: exposure = sin(высоты солнца)")
	# Склон, развёрнутый к солнцу, освещён сильнее, чем от солнца.
	var toward := _plane_terrain(-sun.x / sun.y * 0.5, -sun.z / sun.y * 0.5)
	var away := _plane_terrain(sun.x / sun.y * 0.5, sun.z / sun.y * 0.5)
	toward.refresh_sun()
	away.refresh_sun()
	check(toward.sun_exposure_at(0, 0) > t.sun_exposure_at(0, 0), "склон к солнцу светлее")
	check(away.sun_exposure_at(0, 0) < t.sun_exposure_at(0, 0), "склон от солнца темнее")
	var e := toward.sun_exposure_at(0, 0)
	check(e >= 0.0 and e <= 1.0, "в диапазоне 0..1")
	t.free()
	toward.free()
	away.free()


func test_start_sites() -> void:
	var t := _altai()
	var sites := t.get_start_sites()
	check(sites.size() >= 2, "минимум 2 стартовые площадки")
	var agl := float(Config.get_config("locations/" + LOCATION).get("start_position_agl_m", 0.0))
	var bounds := t.detail_bounds()
	var headings: Array[float] = []
	for s in sites:
		var p: Vector3 = s.position
		var ground := t.height_at(p.x, p.z)
		check(p.y >= ground - 0.01, "%s: не под землёй" % s.id)
		approx(p.y, ground + agl, 0.01, "%s: на земле" % s.id)
		check(bounds.has_point(Vector2(p.x, p.z)), "%s: в детальной зоне" % s.id)
		# Склон: по курсу разбега земля уходит вниз, уклон 8–35°.
		var dir := TerrainGeo.heading_vector(float(s.heading_deg))
		var ahead := t.height_at(p.x + dir.x * 50.0, p.z + dir.z * 50.0)
		check(
			ahead < ground - 5.0,
			"%s: вниз по курсу (через 50 м %.1f м против %.1f)" % [s.id, ahead, ground]
		)
		var slope := rad_to_deg(acos(t.normal_at(p.x, p.z).y))
		check(slope > 8.0 and slope < 35.0, "%s: уклон %.1f° в пределах 8–35°" % [s.id, slope])
		headings.append(float(s.heading_deg))
	var max_diff := 0.0
	for a in headings:
		for b in headings:
			max_diff = maxf(max_diff, absf(angle_difference(deg_to_rad(a), deg_to_rad(b))))
	check(rad_to_deg(max_diff) >= 90.0, "есть площадки разной экспозиции")


func test_geo_roundtrip() -> void:
	var t := _altai()
	var p := t.latlon_to_local(51.9, 85.95)
	var ll := t.local_to_latlon(p.x, p.y)
	approx(ll.x, 51.9, 1e-5, "lat (Vector2 — float32, ~1 м)")
	approx(ll.y, 85.95, 1e-5, "lon")
	check(p.x > 0 and p.y < 0, "северо-восток от центра → x>0, z<0")
	var one_km := TerrainGeo.latlon_to_local(51.87 + 1.0 / 111.195, 85.87, 51.87, 85.87)
	approx(one_km.y, -1000.0, 1.0, "1/111.195° широты ≈ 1 км на север")


func test_height_at_speed() -> void:
	var t := _altai()
	var t0 := Time.get_ticks_usec()
	var s := 0.0
	for k in 10000:
		s += t.height_at(-15000.0 + k * 3.1, 2000.0 - k * 1.7)
	var ms := (Time.get_ticks_usec() - t0) / 1000.0
	print("         10000 × height_at: %.1f мс" % ms)
	check(ms < 100.0, "height_at быстрый: 10000 вызовов за %.1f мс" % ms)
	check(s > 0.0, "высоты положительные")


func test_lod_selection() -> void:
	var t := _altai()
	var cam := Camera3D.new()
	var site: Dictionary = t.get_start_sites()[0]
	cam.position = site.position + Vector3.UP * 2.0
	t.renderer.lod_camera = cam
	t.renderer.update_lods(true)
	var hist := t.renderer.lod_histogram()
	check(hist.has(0), "у камеры есть чанки LOD 0: %s" % hist)
	check(int(hist.get(0, 0)) <= 9, "LOD 0 только рядом: %s" % hist)
	t.renderer.lod_camera = null
	cam.free()


## Последний тест: освободить общий рельеф (иначе утечки при выходе).
func test_zz_cleanup() -> void:
	if _terrain != null:
		_terrain.free()
		_terrain = null


## Рантайм-рельеф (FR-17): на высоких широтах уровень тайлов понижается — сетка не разрастается
## как 1/cos(широта) (Гренландия грузилась в разы дольше); на средних — как в конфиге.
func test_runtime_zoom_by_latitude() -> void:
	var rt: Dictionary = Config.get_config("world").runtime_terrain
	var detail: Dictionary = rt.layers[0]
	check(TerrariumLoader.layer_zoom(detail, 51.0) == int(detail.zoom), "Алтай — zoom из конфига")
	for lat in [64.2, 72.0, 80.0]:
		var z := TerrariumLoader.layer_zoom(detail, lat)
		var step := (
			TAU * TerrariumLoader.MERCATOR_R_M * cos(deg_to_rad(lat)) / float(TerrariumLoader.TILE_PX << z)
		)
		check(z < int(detail.zoom), "%.1f° — уровень понижен (%d)" % [lat, z])
		check(step >= float(detail.min_spacing_m), "%.1f° — шаг %.1f м не мельче минимума" % [lat, step])


## Море: над океаном тайлы дают 0 м, карты покрова нет → море; суша выше нуля; впадина — море.
func test_runtime_sea_check() -> void:
	var flat := func(h: float) -> HeightLayer:
		var d := PackedFloat32Array()
		d.resize(9)
		d.fill(h)
		return HeightLayer.from_heights("detail", 3, 3, 10.0, -10.0, -10.0, d)
	var land := PackedByteArray()
	land.resize(9)
	land.fill(SurfaceLayer.GRASS)
	var grass := SurfaceLayer.from_classes("detail", 3, 3, 10.0, -10.0, -10.0, land)
	check(Terrain.is_sea(flat.call(0.0), null, -450.0), "0 м без карты покрова — море")
	check(not Terrain.is_sea(flat.call(0.0), grass, -450.0), "0 м, карта — луг: суша (низина)")
	check(not Terrain.is_sea(flat.call(300.0), null, -450.0), "300 м — суша")
	check(Terrain.is_sea(flat.call(-2000.0), grass, -450.0), "−2000 м — море")


## Ход загрузки: доля по весам этапов, внутри этапа — по sub, неизвестный этап долю не двигает.
func test_load_progress_fractions() -> void:
	var p := LoadProgress.new({"dem": 2.0, "mesh": 1.0, "glider": 1.0})
	p.begin()
	check(p.fraction == 0.0, "начало — 0")
	p.stage("dem", "a")
	p.sub(1, 2)
	approx(p.fraction, 0.25, 1e-6, "половина первого этапа")
	p.stage("other", "b")
	approx(p.fraction, 0.25, 1e-6, "неизвестный этап — доля та же")
	p.stage("glider", "c")
	approx(p.fraction, 0.75, 1e-6, "начало последнего этапа")
	p.finish()
	check(p.fraction == 1.0 and p.text == "", "готово — 1")
	check(p.timings.size() == 3, "длительности этапов записаны (%d)" % p.timings.size())
