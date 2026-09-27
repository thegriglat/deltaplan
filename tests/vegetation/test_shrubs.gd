extends TestCase
## Тесты кустов и одиночных деревьев (ShrubScatter): модели, детерминированность, запреты
## (лес, вода, просеки, старт и коридор разбега), кусты гуще на классе «кустарник».

static var _terrain: Terrain


func _ongudai() -> Terrain:
	if _terrain == null:
		_terrain = Terrain.new()
		_terrain.location_id = ""
		_terrain.load_location("ongudai")
	return _terrain


func _cfg() -> Dictionary:
	return Config.get_config("vegetation").shrubs


func _scatter(t: Terrain) -> ShrubScatter:
	var r := ShrubScatter.new()
	r.terrain = t
	check(r.setup(_cfg()), "модели кустов загружены")
	r._check_key()
	return r


## Тайлы размера tile в радиусе rad вокруг первого старта.
func _tiles(t: Terrain, rad: float, tile: float) -> Array[Vector2i]:
	var sp: Vector3 = t.get_start_sites()[0].position
	var out: Array[Vector2i] = []
	var n := int(ceil(rad / tile))
	var c := Vector2i(floori(sp.x / tile), floori(sp.z / tile))
	for j in range(-n, n + 1):
		for i in range(-n, n + 1):
			out.append(c + Vector2i(i, j))
	return out


func _positions(d: Dictionary) -> PackedVector2Array:
	var out := PackedVector2Array()
	var xf: PackedFloat32Array = d.xf
	for i in (d["var"] as PackedInt32Array).size():
		out.append(Vector2(xf[i * 12 + 3], xf[i * 12 + 11]))
	return out


func test_models() -> void:
	var cfg := _cfg()
	var names: Array = cfg.variants
	check(names.size() >= 2, "вариантов кустов: %d" % names.size())
	var m := RockScatter.load_meshes(String(cfg.model_path), names)
	check(m.size() == names.size() * ShrubScatter.LODS, "все LOD всех вариантов")
	for v in names.size():
		var a := (m[v * 3] as ArrayMesh).get_faces().size() / 3
		var b := (m[v * 3 + 2] as ArrayMesh).get_faces().size() / 3
		var h := m[v * 3].get_aabb().size.y
		check(a <= 2600 and b < a, "%s: треугольников LOD0 %d, LOD2 %d" % [names[v], a, b])
		approx(h, 1.0, 0.05, "%s: высота модели" % names[v])


func test_deterministic_and_allowed() -> void:
	var t := _ongudai()
	var r := _scatter(t)
	var tile := float(_cfg().tile_m)
	var total := 0
	var on_shrub := 0
	var kinds := {}
	var site: Dictionary = t.get_start_sites()[0]
	var sp := Vector2(site.position.x, site.position.z)
	var hd := TerrainGeo.heading_vector(float(site.heading_deg))
	var dir := Vector2(hd.x, hd.z).normalized()
	for k in _tiles(t, 400.0, tile):
		var a := r.build_tile(k.x, k.y)
		var b := r.build_tile(k.x, k.y)
		check(a.xf == b.xf and a.col == b.col, "тайл %s детерминирован" % k)
		for p in _positions(a):
			var c := t.surface_at(p.x, p.y)
			check(
				c == SurfaceLayer.GRASS or c == SurfaceLayer.SHRUB, "куст %s на классе %d" % [p, c]
			)
			on_shrub += 1 if c == SurfaceLayer.SHRUB else 0
			total += 1
			var d := p - sp
			check(d.length() > 15.0, "куст у старта: %s" % p)
			var along := d.dot(dir)
			check(
				not (along > 0.0 and along < 55.0 and absf(d.cross(dir)) < 12.0),
				"куст в коридоре разбега: %s" % p
			)
		for v in a["var"] as PackedInt32Array:
			kinds[v] = true
	print("    кустов в 400 м от старта: %d (на кустарнике %d)" % [total, on_shrub])
	check(total > 100, "кустов вокруг старта: %d" % total)
	check(kinds.size() >= 2, "разные варианты: %d" % kinds.size())
	r.free()


func test_trees() -> void:
	var t := _ongudai()
	var r := _scatter(t)
	var tcfg: Dictionary = _cfg().trees
	var total := 0
	var groups := 0
	for k in _tiles(t, 1500.0, float(tcfg.tile_m)):
		var a := r.build_tree_tile(k.x, k.y)
		var b := r.build_tree_tile(k.x, k.y)
		check(a.xf == b.xf, "тайл деревьев %s детерминирован" % k)
		var ps := _positions(a)
		for p in ps:
			var c := t.surface_at(p.x, p.y)
			check(c != SurfaceLayer.WATER and c != SurfaceLayer.FOREST, "дерево на классе %d" % c)
			check(t.forest_at(p.x, p.y) <= float(tcfg.keep_off_forest), "дерево в лесу %s" % p)
		total += ps.size()
		groups += 1 if ps.size() > 1 else 0
	print("    одиночных деревьев в 1,5 км от старта: %d" % total)
	check(total > 10, "деревьев на лугах: %d" % total)
	r.free()


func test_clearings() -> void:
	var t := _ongudai()
	var c := WorldClearings.build_for("ongudai")
	check(c != null, "просеки локации построены")
	if c == null:
		return
	t.set_clearings(c.image, c.origin, c.cell_m)
	var r := _scatter(t)
	var all := PackedVector2Array()
	for k in _tiles(t, 400.0, float(_cfg().tile_m)):
		all.append_array(_positions(r.build_tile(k.x, k.y)))
	for k in _tiles(t, 1000.0, float(_cfg().trees.tile_m)):
		all.append_array(_positions(r.build_tree_tile(k.x, k.y)))
	for p in all:
		var i := floori((p.x - c.origin.x) / c.cell_m)
		var j := floori((p.y - c.origin.y) / c.cell_m)
		if i >= 0 and j >= 0 and i < c.image.get_width() and j < c.image.get_height():
			check(c.image.get_pixel(i, j).r <= 0.3, "куст/дерево на просеке %s" % p)
	t._clearings = []
	r.free()


func test_zz_cleanup() -> void:
	if _terrain != null:
		_terrain.free()
		_terrain = null
