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
	check(names.size() >= 10, "вариантов камней: %d" % names.size())
	var m := RockScatter.load_meshes(String(cfg.model_path), names)
	check(m.size() == names.size() * RockScatter.LODS, "все LOD всех вариантов")
	for v in names.size():
		var a := (m[v * 3] as ArrayMesh).get_faces().size() / 3
		var b := (m[v * 3 + 2] as ArrayMesh).get_faces().size() / 3
		check(a <= 1500 and b < a and (v < cfg.boulders.size() or a <= 400), "%s: треугольников LOD0 %d, LOD2 %d" % [names[v], a, b])


func _all(t: Terrain, r: RockScatter, rad: float, small: bool) -> Dictionary:
	var out := {"size": PackedFloat32Array(), "var": PackedInt32Array(), "xf": PackedFloat32Array()}
	for k in _tiles(t, rad):
		var d := r.build_small_tile(k.x, k.y) if small else r.build_tile(k.x, k.y)
		out.size.append_array(d.size)
		out["var"].append_array(d["var"])
		out.xf.append_array(d.xf)
	return out


## Размеры — степенной закон: щебень доминирует, глыбы ≥ 1 м редки, 4 м — единицы.
func test_size_distribution() -> void:
	var t := _ongudai()
	var r := _scatter(t)
	var big := _all(t, r, 100.0, false)  # одна и та же площадь — доли сопоставимы
	var sm := _all(t, r, 100.0, true)
	var split := float(Config.get_config("world").rocks.split_m)
	var n_big := (big.size as PackedFloat32Array).size()
	var n_sm := (sm.size as PackedFloat32Array).size()
	var over1 := 0
	var over3 := 0
	var small_in_big := 0
	for s in big.size as PackedFloat32Array:
		over1 += 1 if s >= 1.0 else 0
		over3 += 1 if s >= 3.0 else 0
		small_in_big += 1 if s < split - 0.001 else 0
	var big_in_small := 0
	var sum_s := 0.0
	for s in sm.size as PackedFloat32Array:
		big_in_small += 1 if s > split + 0.001 else 0
		sum_s += s
	print("ROCKS крупных %d (≥1 м %d, ≥3 м %d), мелочи %d (ср. %.2f м)" % [n_big, over1, over3, n_sm, sum_s / maxf(n_sm, 1)])
	check(small_in_big == 0 and big_in_small == 0, "крупные ≥ split_m, мелочь < split_m")
	check(n_big > 100 and n_sm > 1000, "камней: крупных %d, мелких %d" % [n_big, n_sm])
	var all_n := n_big + n_sm
	check(float(over1) / all_n < 0.06, "глыб ≥ 1 м не больше 6%%: %d из %d" % [over1, all_n])
	check(float(n_sm) / all_n > 0.7, "щебень (<%.1f м) — основная масса" % split)
	# валуны (не куски гряды: те 3–8 м вдоль горизонтали) не крупнее 4 м
	var wide := _all(t, r, 450.0, false)
	var cfg: Dictionary = Config.get_config("world").rocks
	var names: Array = cfg.boulders + cfg.stones
	var combs: Array = []
	for nm in cfg.roles.comb.big:
		combs.append(names.find(nm))
	for i in (wide.size as PackedFloat32Array).size():
		if not (wide["var"][i] in combs):
			check(wide.size[i] <= 4.001, "размер ≤ 4 м: %.2f" % wide.size[i])
	r.free()


## Гребешки лежат длинной осью вдоль горизонтали (поперёк падения склона).
func test_ridges_along_contour() -> void:
	var t := _ongudai()
	var r := _scatter(t)
	var cfg: Dictionary = Config.get_config("world").rocks
	var names: Array = cfg.boulders + cfg.stones
	var combs: Array[int] = []
	for nm in cfg.roles.comb.big:
		combs.append(names.find(nm))
	var found := 0
	var bad := 0
	for k in _tiles(t, 700.0):
		var d := r.build_tile(k.x, k.y)
		var xf: PackedFloat32Array = d.xf
		for i in (d["var"] as PackedInt32Array).size():
			if not (d["var"][i] in combs):
				continue
			found += 1
			var ax := Vector2(xf[i * 12], xf[i * 12 + 8]).normalized()
			var g := RockScatter.down_dir(t.normal_at(xf[i * 12 + 3], xf[i * 12 + 11]))
			if g != Vector2.ZERO and absf(ax.dot(g)) > 0.5:
				bad += 1
	print("ROCKS гребешков %d, не вдоль горизонтали %d" % [found, bad])
	check(found > 0, "гребешки есть: %d" % found)
	check(bad * 5 <= found, "гребешки вдоль горизонтали: не так %d из %d" % [bad, found])
	r.free()


## Камни — только MultiMesh: ни коллизий, ни физических тел.
func test_no_physics() -> void:
	var t := _ongudai()
	var r := _scatter(t)
	var bad := 0
	for c in r.get_children():
		if not c is MultiMeshInstance3D:
			bad += 1
	check(bad == 0 and r.find_children("*", "CollisionObject3D", true, false).is_empty(), "камни без коллизий")
	r.free()


## Время построения тайла: крупные и мелочь, мс (в рабочем потоке, не в кадре).
func test_tile_time() -> void:
	var t := _ongudai()
	var r := _scatter(t)
	var tb := 0.0
	var ts := 0.0
	var n := 0
	for k in _tiles(t, 100.0):
		var t0 := Time.get_ticks_usec()
		r.build_tile(k.x, k.y)
		var t1 := Time.get_ticks_usec()
		r.build_small_tile(k.x, k.y)
		var t2 := Time.get_ticks_usec()
		tb += (t1 - t0) / 1000.0
		ts += (t2 - t1) / 1000.0
		n += 1
	print("ROCKS время тайла: крупные %.1f мс, мелочь %.1f мс (средн. по %d)" % [tb / n, ts / n, n])
	check(tb / n < 150.0 and ts / n < 400.0, "тайл строится быстро")
	r.free()


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
	check(kinds.size() >= 6, "разные варианты: %d" % kinds.size())
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
