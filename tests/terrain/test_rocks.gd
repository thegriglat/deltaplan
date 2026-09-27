extends TestCase
## Тесты разброса 3D-камней (RockScatter): модели, детерминированность, запреты (вода, лес,
## просеки, старт).

static var _terrain: Terrain


func _ongudai() -> Terrain:
	if _terrain == null:
		_terrain = Terrain.new()
		_terrain.location_id = ""
		_terrain.load_location("ongudai")
	return _terrain


func _scatter(t: Terrain) -> RockScatter:
	var r := RockScatter.new()
	r.terrain = t
	check(r.setup(Config.get_config("world").rocks), "модели камней загружены")
	r._check_key()
	return r


## Тайлы в радиусе rad вокруг первого старта.
func _tiles(t: Terrain, rad: float) -> Array[Vector2i]:
	var sp: Vector3 = t.get_start_sites()[0].position
	var tile := float(Config.get_config("world").rocks.tile_m)
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
	var cfg: Dictionary = Config.get_config("world").rocks
	var names: Array = cfg.boulders + cfg.stones
	check(names.size() >= 8, "вариантов камней: %d" % names.size())
	var m := RockScatter.load_meshes(String(cfg.model_path), names)
	check(m.size() == names.size() * RockScatter.LODS, "все LOD всех вариантов")
	for v in names.size():
		var a := (m[v * 3] as ArrayMesh).get_faces().size() / 3
		var b := (m[v * 3 + 2] as ArrayMesh).get_faces().size() / 3
		check(a <= 1500 and b < a, "%s: треугольников LOD0 %d, LOD2 %d" % [names[v], a, b])


func test_deterministic_and_allowed() -> void:
	var t := _ongudai()
	var r := _scatter(t)
	var total := 0
	var kinds := {}
	for k in _tiles(t, 250.0):
		var a := r.build_tile(k.x, k.y)
		var b := r.build_tile(k.x, k.y)
		check(a.xf == b.xf and a.col == b.col, "тайл %s детерминирован" % k)
		for p in _positions(a):
			var c := t.surface_at(p.x, p.y)
			check(
				c != SurfaceLayer.WATER and c != SurfaceLayer.FOREST and c != SurfaceLayer.BUILT,
				"камень в %s на классе %d" % [p, c]
			)
			total += 1
		for v in a["var"] as PackedInt32Array:
			kinds[v] = true
	check(total > 200, "камней вокруг старта: %d" % total)
	check(kinds.size() >= 5, "разные варианты: %d" % kinds.size())
	# у старта и в коридоре разбега — пусто
	var site: Dictionary = t.get_start_sites()[0]
	var sp := Vector2(site.position.x, site.position.z)
	var hd := TerrainGeo.heading_vector(float(site.heading_deg))
	for k in _tiles(t, 100.0):
		for p in _positions(r.build_tile(k.x, k.y)):
			check(p.distance_to(sp) > 12.0, "камень у старта: %s" % p)
			var d := p - sp
			var along := d.dot(Vector2(hd.x, hd.z))
			check(
				not (along > 0.0 and along < 45.0 and absf(d.cross(Vector2(hd.x, hd.z))) < 10.0),
				"камень в коридоре разбега: %s" % p
			)
	r.free()


func test_clearings() -> void:
	var t := _ongudai()
	var r := _scatter(t)
	# найти тайл с камнями и накрыть его просекой
	var hit := Vector2i(1 << 30, 0)
	for k in _tiles(t, 250.0):
		if (r.build_tile(k.x, k.y)["var"] as PackedInt32Array).size() > 5:
			hit = k
			break
	check(hit.x != 1 << 30, "есть тайл с камнями")
	var tile := float(Config.get_config("world").rocks.tile_m)
	var img := Image.create(64, 64, false, Image.FORMAT_L8)
	img.fill(Color(1, 1, 1))
	var org := Vector2(hit) * tile - Vector2(40, 40)
	t.set_clearings(img, org, 2.0)
	r._check_key()
	check(_positions(r.build_tile(hit.x, hit.y)).is_empty(), "на просеке камней нет")
	# настоящие просеки локации (дороги, ЛЭП, посадки)
	var c := WorldClearings.build_for("ongudai")
	if c != null:
		t.set_clearings(c.image, c.origin, c.cell_m)
		r._check_key()
		for k in _tiles(t, 250.0):
			for p in _positions(r.build_tile(k.x, k.y)):
				var i := floori((p.x - c.origin.x) / c.cell_m)
				var j := floori((p.y - c.origin.y) / c.cell_m)
				if i >= 0 and j >= 0 and i < c.image.get_width() and j < c.image.get_height():
					check(c.image.get_pixel(i, j).r <= 0.3, "камень на просеке %s" % p)
	t._clearings = []
	r.free()


func test_zz_cleanup() -> void:
	if _terrain != null:
		_terrain.free()
		_terrain = null
