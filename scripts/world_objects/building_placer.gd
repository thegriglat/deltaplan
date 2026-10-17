class_name BuildingPlacer
extends RefCounted
## Дома (VR-6, VR-9, NO-2, OL-1): коробка стен реального размера + (у села) двускатная крыша-призма, по тайлам
## для MultiMesh. Стены уходят в землю ниже самой низкой точки пятна (на склоне не висят). Вид — стиль L2
## (BuildingStyle: город / село / промзона): цвета стен и крыш из палитры стиля с гарантированным контрастом,
## данные экземпляра для шейдера building.gdshader (альфа цвета), трубы и точки дыма у села (L3).
## Без нод: place() → {Vector2i тайл: {walls, wall_colors, roofs, roof_colors, chimneys,
## chimney_colors, smoke}}, попутно заносит коробки в ObstacleIndex (если передан).
## Запись дома — L1: [x, z, w, l, угол_град, высота_стен_м, крыша, (тип, по_правилу)]; крыша 0 — двускатная
## (только у села), 1 — плоская; у города и промзоны крыша всегда плоская. 7 полей — процедурный дом посёлка.
## Формы по профилю региона (RV-К4, buildings.village_roof / city_roof / hip_pitch_deg / parapet_*): вальмовая крыша
## (H2, tile.hips: {ступень вытянутости: {xf, col}}), плоская с парапетом (H1, tile.parapets + parapet_colors, цвет стен).
## max_levels > 0 ограничивает высоту стен домов по правилу (по_правилу = 1) до max_levels · level_m.
## Данные экземпляра стен — в альфе цвета (INSTANCE_COLOR.a·32 = стиль + 4 × стекло + 8 × индекс цвета плоской
## крыши; кратно 1/32 — точно в половинной точности); зерно разброса окон шейдер берёт из положения экземпляра.

const WALL_SHADER := preload("res://scripts/world_objects/osm/building.gdshader")
## Вальмовая крыша (H2): меш в единичном кубе зависит от вытянутости плана; формы — ступенями 1/HIP_BINS.
const HIP_BINS := 10
## Дальности LOD моделей домов (RV-К6), м: LOD0 до LOD0_M, LOD1 до LOD1_M, LOD2 дальше (до visibility_m).
const LOD0_M := 250.0
const LOD1_M := 1500.0
## Подставные модели для тестов: {имя: [Mesh LOD0, LOD1, LOD2]}; используются вместо файла из реестра.
static var test_models: Dictionary = {}
## Кеш загруженных моделей: {путь: [Mesh ×3] или []}.
static var _model_cache: Dictionary = {}


## style / glass — стиль и флаг фасада на запись (BuildingStyle.classify / adjust); пусто — стиль считается здесь
## (все записи 7-польные — всё село), стекла нет.
static func place(
	buildings: Array,
	cfg: Dictionary,
	height_fn: Callable,
	obstacles: ObstacleIndex = null,
	style: PackedByteArray = PackedByteArray(),
	glass: PackedByteArray = PackedByteArray()
) -> Dictionary:
	var tile := float(cfg.tile_m)
	var sink := float(cfg.sink_m)
	var pitch := tan(deg_to_rad(float(cfg.roof_pitch_deg)))
	var scfg: Dictionary = cfg.style
	if style.size() != buildings.size():
		style = BuildingStyle.classify(buildings, scfg)
	var has_glass := glass.size() == buildings.size()
	var pals := _palettes(scfg)
	var min_c := float(scfg.get("min_roof_contrast", 0.08))
	var ccfg: Dictionary = cfg.get("chimney", {})
	var chim_frac := float(ccfg.get("fraction", 0.0))
	var csize: Array = ccfg.get("size_m", [0.5, 1.3, 0.5])
	var chim_col := WorldTiles.linear_color(ccfg.get("color", [0.36, 0.3, 0.28]))
	var smoke_frac := float(cfg.get("smoke", {}).get("fraction", 0.0))
	var village_roof := str(cfg.get("village_roof", "gable"))
	var city_roof := str(cfg.get("city_roof", "flat"))
	var hip_pitch := tan(deg_to_rad(float(cfg.get("hip_pitch_deg", 20.0))))
	var parapet_h := float(cfg.get("parapet_h_m", 0.8))
	var parapet_t := float(cfg.get("parapet_t_m", 0.25))
	var max_h := float(cfg.get("max_levels", 0)) * float(cfg.get("level_m", 3.0))
	var picks := _model_picks(cfg)
	var model_share := float(cfg.get("village_model_share", 0.0))
	var model_max_area := float(cfg.get("village_model_max_area_m2", 150.0))
	var out := {}
	var n := buildings.size()
	for i in n:
		var b: Array = buildings[i]
		var x: float = b[0]
		var z: float = b[1]
		var w: float = b[2]
		var l: float = b[3]
		var ang := deg_to_rad(b[4] as float)
		var ca := cos(ang)
		var sa := sin(ang)
		# Basis(UP, -ang): (px, pz) → (px·cos a − pz·sin a, px·sin a + pz·cos a); пять точек: центр и углы
		var hx := w * 0.5
		var hz := l * 0.5
		var ex := hx * ca - hz * sa
		var ez := hx * sa + hz * ca
		var fx := hx * ca + hz * sa
		var fz := hx * sa - hz * ca
		var g0 := height_fn.call(x, z) as float
		var g1 := height_fn.call(x - ex, z - ez) as float
		var g2 := height_fn.call(x + fx, z + fz) as float
		var g3 := height_fn.call(x + ex, z + ez) as float
		var g4 := height_fn.call(x - fx, z - fz) as float
		var gmin := minf(minf(g0, g1), minf(minf(g2, g3), g4))
		var gmax := maxf(maxf(g0, g1), maxf(maxf(g2, g3), g4))
		var rot := Basis(Vector3.UP, -ang)
		var base := gmin - sink
		var bh: float = b[5]
		if max_h > 0.0 and b.size() > 8 and int(b[8]) == 1:
			bh = minf(bh, max_h)
		var wall_h := bh + (gmax - gmin) + sink
		var tk := WorldTiles.key(x, z, tile)
		if not out.has(tk):
			out[tk] = {
				"walls": [] as Array[Transform3D],
				"wall_colors": PackedColorArray(),
				"roofs": [] as Array[Transform3D],
				"roof_colors": PackedColorArray(),
				"chimneys": [] as Array[Transform3D],
				"chimney_colors": PackedColorArray(),
				"smoke": PackedVector3Array(),
				"hips": {},
				"parapets": [] as Array[Transform3D],
				"parapet_colors": PackedColorArray(),
				"models": {},
			}
		var t: Dictionary = out[tk]
		var st: int = style[i]
		if (
			not picks.is_empty()
			and st == BuildingStyle.VILLAGE
			and (b.size() < 9 or int(b[8]) == 1)
			and w * l <= model_max_area
		):
			var mh := _house_hash(x, z)
			if float(mh % 1000) * 0.001 < model_share:
				var mname := _pick_model(picks, float((mh >> 10) % 1000) * 0.001)
				var sz: Array = picks.sizes[mname]
				var sx := float(sz[0])
				var szz := float(sz[1])
				var brot := rot
				var kx := w / sx
				var kz := l / szz
				if (w < l) != (sx < szz):  # длинная сторона модели — вдоль длинной стороны дома
					brot = rot * Basis(Vector3.UP, PI * 0.5)
					kx = l / sx
					kz = w / szz
				var ky := (kx + kz) * 0.5
				var pal_m: Dictionary = pals[st]
				var mc: Color = pal_m.walls[((((i * 2654435761) + 12345) & 0xffffffff) >> 8) % pal_m.walls.size()]
				mc.a = 1.0
				if not t.models.has(mname):
					t.models[mname] = {"xf": [] as Array[Transform3D], "col": PackedColorArray()}
				t.models[mname].xf.append(
					Transform3D(brot * Basis.from_scale(Vector3(kx, ky, kz)), Vector3(x, gmin, z))
				)
				t.models[mname].col.append(mc)
				if obstacles != null:
					obstacles.add_box(x, z, w * 0.5, l * 0.5, ang, base, gmin + bh + 0.5 * minf(w, l) * pitch, "building")
				continue
		t.walls.append(
			Transform3D(
				rot * Basis.from_scale(Vector3(w, wall_h, l)), Vector3(x, base + wall_h * 0.5, z)
			)
		)
		var pal: Dictionary = pals[st]
		var hh := ((i * 2654435761) + 12345) & 0xffffffff
		var h1 := hh >> 8
		var wl: PackedFloat32Array = pal.wall_l
		var wi: int = h1 % wl.size()
		var rl: PackedFloat32Array = pal.roof_l
		var nr := rl.size()
		var ri: int = (h1 >> 8) % nr
		for _k in nr:  # крыша другой яркости, чем стены этого дома (палитры не пересекаются, но проверяем)
			if absf(rl[ri] - wl[wi]) >= min_c:
				break
			ri = (ri + 1) % nr
		var gl := 1 if has_glass and glass[i] == 1 else 0
		var wc: Color = pal.walls[wi]
		wc.a = float(st + 4 * gl + 8 * ri) * 0.03125
		t.wall_colors.append(wc)
		var top := base + wall_h
		var parapet := (
			(st == BuildingStyle.VILLAGE and int(b[6]) == 0 and village_roof == "flat_parapet")
			or (st == BuildingStyle.CITY and city_roof == "flat_parapet")
		)
		if parapet and parapet_h > 0.0:
			var pt := minf(parapet_t, minf(w, l) * 0.25)
			var pc := wc
			pc.a = 1.0
			# 4 коробки кольцом: длинные по w (z = ±(l/2 − pt/2)), короткие между ними по l
			for sd in [-1.0, 1.0]:
				t.parapets.append(
					Transform3D(
						rot * Basis.from_scale(Vector3(w, parapet_h, pt)),
						Vector3(x, top + parapet_h * 0.5, z) + rot * Vector3(0.0, 0.0, sd * (hz - pt * 0.5))
					)
				)
				t.parapets.append(
					Transform3D(
						rot * Basis.from_scale(Vector3(pt, parapet_h, maxf(l - 2.0 * pt, 0.01))),
						Vector3(x, top + parapet_h * 0.5, z) + rot * Vector3(sd * (hx - pt * 0.5), 0.0, 0.0)
					)
				)
				t.parapet_colors.append(pc)
				t.parapet_colors.append(pc)
			top += parapet_h
		elif st == BuildingStyle.VILLAGE and int(b[6]) == 0:
			var span := minf(w, l)
			var ridge := maxf(w, l)
			var is_hip := village_roof == "hip"
			var rh := span * 0.5 * (hip_pitch if is_hip else pitch)
			var rb := rot
			if w >= l:
				rb = rot * Basis(Vector3.UP, PI * 0.5)
			var rxf := Transform3D(
				rb * Basis.from_scale(Vector3(span, rh, ridge)), Vector3(x, top + rh * 0.5, z)
			)
			var ridge_half := ridge * 0.5
			if is_hip:
				var bin := clampi(roundi(span / ridge * HIP_BINS), 1, HIP_BINS)
				if not t.hips.has(bin):
					t.hips[bin] = {"xf": [] as Array[Transform3D], "col": PackedColorArray()}
				t.hips[bin].xf.append(rxf)
				t.hips[bin].col.append(pal.roofs[ri])
				ridge_half = ridge * (1.0 - float(bin) / HIP_BINS) * 0.5  # длина конька (L − S)/2
			else:
				t.roofs.append(rxf)
				t.roof_colors.append(pal.roofs[ri])
			# труба (L3): на скате у конька; дым — у доли домов с трубой; выбор по округлённым координатам
			var hc := ((roundi(x) * 73856093) ^ (roundi(z) * 19349663)) & 0x7fffffff
			if float(hc % 1000) * 0.001 < chim_frac:
				var side := 1.0 if (hc >> 10) & 1 == 0 else -1.0
				var lat := span * 0.18 * side
				var along := ridge * (float((hc >> 11) % 1000) * 0.001 - 0.5) * 0.5
				if is_hip:
					along = clampf(along, -ridge_half * 0.8, ridge_half * 0.8)
				var lp: Vector3 = rb * Vector3(lat, 0.0, along)
				var surf := top + rh * (1.0 - 2.0 * absf(lat) / span)
				var ch := top + rh + float(csize[1]) - (surf - 0.3)
				var base_c := Vector3(x + lp.x, surf - 0.3 + ch * 0.5, z + lp.z)
				t.chimneys.append(
					Transform3D(rb * Basis.from_scale(Vector3(float(csize[0]), ch, float(csize[2]))), base_c)
				)
				t.chimney_colors.append(chim_col)
				if float((hc >> 4) % 1000) * 0.001 < smoke_frac:
					t.smoke.append(Vector3(base_c.x, surf - 0.3 + ch, base_c.z))
			top += rh
		if obstacles != null:
			obstacles.add_box(x, z, w * 0.5, l * 0.5, ang, base, top, "building")
	return out


## MultiMesh-узлы по тайлам (стены с шейдером стиля, крыши села, трубы) + узел дыма OsmSmoke (группа osm_wind).
## Общее для OsmBuildings и VillageLayer; корень без имени.
static func make_nodes(tiles: Dictionary, cfg: Dictionary) -> Node3D:
	return OsmLayer.run_all(node_steps(tiles, cfg))


## То же порциями (FL-6, главный поток): {root, steps}, шаг — узлы одного тайла; последний — дым.
static func node_steps(tiles: Dictionary, cfg: Dictionary) -> Dictionary:
	var scfg: Dictionary = cfg.style
	var wall := BoxMesh.new()
	wall.material = wall_material(scfg)
	var vmat := StandardMaterial3D.new()
	vmat.vertex_color_use_as_albedo = true
	vmat.roughness = 0.9
	var roof := PrismMesh.new()
	roof.material = vmat
	var chim := BoxMesh.new()
	chim.material = vmat
	var par := BoxMesh.new()
	par.material = vmat
	var hip_meshes := {}
	var tile := float(cfg.tile_m)
	var r := WorldTiles.tile_range(float(cfg.visibility_m), tile)
	var shadows := bool(cfg.cast_shadows)
	var root := Node3D.new()
	var smoke_pts := PackedVector3Array()
	var steps: Array[Callable] = []
	for k in tiles:
		var t: Dictionary = tiles[k]
		var o := WorldTiles.center(k, tile)
		steps.append(func() -> void:
			if not t.walls.is_empty():
				root.add_child(WorldTiles.multimesh_node(wall, t.walls, t.wall_colors, o, r, shadows))
			for mname: String in t.get("models", {}):
				var lods := _model_lods(mname, cfg)
				var mp: Dictionary = t.models[mname]
				var vis := float(cfg.visibility_m)
				for j in lods.size():
					var mi := WorldTiles.multimesh_node(lods[j], mp.xf, mp.col, o, r, shadows)
					mi.visibility_range_begin = 0.0 if j == 0 else (LOD0_M if j == 1 else LOD1_M)
					mi.visibility_range_end = LOD0_M if j == 0 else (LOD1_M if j == 1 else vis)
					root.add_child(mi)
			if not t.roofs.is_empty():
				root.add_child(WorldTiles.multimesh_node(roof, t.roofs, t.roof_colors, o, r, shadows))
			for bin: int in t.hips:
				if not hip_meshes.has(bin):
					hip_meshes[bin] = hip_mesh(bin)
					(hip_meshes[bin] as Mesh).surface_set_material(0, vmat)
				var hp: Dictionary = t.hips[bin]
				root.add_child(WorldTiles.multimesh_node(hip_meshes[bin], hp.xf, hp.col, o, r, shadows))
			if not t.parapets.is_empty():
				root.add_child(
					WorldTiles.multimesh_node(par, t.parapets, t.parapet_colors, o, r, shadows)
				)
			if not t.chimneys.is_empty():
				root.add_child(
					WorldTiles.multimesh_node(chim, t.chimneys, t.chimney_colors, o, r, false)
				))
		smoke_pts.append_array(t.smoke)
	if not smoke_pts.is_empty():
		steps.append(func() -> void:
			var sm := OsmSmoke.new()
			sm.name = "Smoke"
			sm.setup(smoke_pts, cfg.get("smoke", {}))
			root.add_child(sm))
	return {"root": root, "steps": steps}


## Хеш положения дома (детерминированно, без камеры): выбор «модель или коробка» и какая модель.
static func _house_hash(x: float, z: float) -> int:
	var h := ((roundi(x) * 2246822519) ^ (roundi(z) * 3266489917)) & 0xffffffff
	h = ((h ^ (h >> 15)) * 2654435761) & 0xffffffff
	return (h ^ (h >> 13)) & 0x7fffffff


## Доступные модели профиля: {names, weights, sizes} либо {} (share 0, нет реестра или файлов — дома коробками).
static func _model_picks(cfg: Dictionary) -> Dictionary:
	if float(cfg.get("village_model_share", 0.0)) <= 0.0:
		return {}
	var reg: Dictionary = cfg.get("models", {})
	var names: Array = []
	var weights: Array = []
	var sizes := {}
	var total := 0.0
	for e: Dictionary in cfg.get("village_models", []):
		var nm := str(e.get("name", ""))
		var wt := float(e.get("weight", 1.0))
		if wt <= 0.0 or not reg.has(nm) or not _model_available(nm, reg[nm]):
			continue
		var sz: Array = reg[nm].get("size_m", [0.0, 0.0])
		if float(sz[0]) <= 0.0 or float(sz[1]) <= 0.0:
			continue
		names.append(nm)
		total += wt
		weights.append(total)
		sizes[nm] = sz
	if names.is_empty():
		return {}
	return {"names": names, "cum": weights, "total": total, "sizes": sizes}


static func _pick_model(picks: Dictionary, u: float) -> String:
	var v: float = u * float(picks.total)
	var names: Array = picks.names
	var cum: Array = picks.cum
	for k in names.size():
		if v < float(cum[k]):
			return names[k]
	return names[names.size() - 1]


static func _model_available(nm: String, def: Dictionary) -> bool:
	return test_models.has(nm) or ResourceLoader.exists(str(def.get("path", "")))


## Меши LOD0…2 модели (главный поток); материалы — копии с цветом экземпляра как альбедо. Нет файла/нод — [].
static func _model_lods(nm: String, cfg: Dictionary) -> Array[Mesh]:
	var out: Array[Mesh] = []
	var src: Array = []
	if test_models.has(nm):
		src = test_models[nm]
	else:
		var path := str(cfg.models[nm].path)
		if not _model_cache.has(path):
			var cached := []
			var ps := load(path) as PackedScene
			if ps != null:
				var inst := ps.instantiate()
				for lod in 3:
					var mi := inst.find_child("LOD%d" % lod, true, false) as MeshInstance3D
					if mi == null or mi.mesh == null:
						cached = []
						break
					cached.append(mi.mesh)
				inst.free()
			_model_cache[path] = cached
		src = _model_cache[path]
	for m: Mesh in src:
		var c := m.duplicate() as Mesh
		for sidx in c.get_surface_count():
			var mat := c.surface_get_material(sidx)
			var cm: StandardMaterial3D = (
				(mat.duplicate() as StandardMaterial3D) if mat is StandardMaterial3D else StandardMaterial3D.new()
			)
			cm.vertex_color_use_as_albedo = true
			c.surface_set_material(sidx, cm)
		out.append(c)
	return out


## Вальмовая крыша в единичном кубе (x — поперёк конька, z — вдоль, y от −0,5 свес до +0,5 конёк): ступень bin —
## отношение пролёта к длине S/L = bin / HIP_BINS, конёк длиной (1 − S/L) от длины; 1 — шатёр. После масштаба
## (S, S/2·tan(уклон), L) длинные скаты имеют ровно заданный уклон. Без текстур, нормали плоские (граней).
static func hip_mesh(bin: int) -> ArrayMesh:
	var f := 1.0 - float(bin) / HIP_BINS
	var rz := f * 0.5  # конёк: (0, 0.5, ±rz)
	var a := Vector3(-0.5, -0.5, -0.5)
	var b := Vector3(0.5, -0.5, -0.5)
	var c := Vector3(0.5, -0.5, 0.5)
	var d := Vector3(-0.5, -0.5, 0.5)
	var r0 := Vector3(0.0, 0.5, -rz)
	var r1 := Vector3(0.0, 0.5, rz)
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	st.set_smooth_group(-1)
	# порядок вершин — по часовой стрелке снаружи (лицевая сторона Godot)
	var tris: Array = [[a, r0, r1], [a, r1, d], [b, c, r1], [b, r1, r0], [a, b, r0], [c, d, r1]]
	if f < 0.001:
		tris = [[a, r0, d], [b, c, r0], [a, b, r0], [c, d, r0]]
	for tri: Array in tris:
		for v: Vector3 in tri:
			st.add_vertex(v)
	st.generate_normals()
	return st.commit()


## Материал стен: шейдер building.gdshader с параметрами стиля.
static func wall_material(scfg: Dictionary) -> ShaderMaterial:
	var m := ShaderMaterial.new()
	m.shader = WALL_SHADER
	var pals := _palettes(scfg)
	var roofs := PackedColorArray()
	for s in 3:
		var rc: PackedColorArray = pals[s].roofs
		for k in 4:
			roofs.append(rc[k % rc.size()])
	m.set_shader_parameter(&"roof_pal", roofs)
	m.set_shader_parameter(&"floor_m", float(scfg.get("floor_m", 3.0)))
	m.set_shader_parameter(&"ground_dark", float(scfg.get("ground_dark", 0.45)))
	m.set_shader_parameter(&"ground_h_m", float(scfg.get("ground_dark_h_m", 1.0)))
	m.set_shader_parameter(&"window_fade_m", float(scfg.get("window_fade_m", 1100.0)))
	for k: String in ["window_dark", "window_light", "glass"]:
		if scfg.has(k):
			var c: Color = WorldTiles.linear_color(scfg[k])
			m.set_shader_parameter(StringName(k), Vector3(c.r, c.g, c.b))
	return m


## Палитры по стилю: [{walls, roofs (PackedColorArray, линейные), wall_l, roof_l (яркость)}] для CITY, VILLAGE, INDUSTRIAL.
static func _palettes(scfg: Dictionary) -> Array:
	var out := []
	for s in 3:
		var p := BuildingStyle.palette(scfg, s)
		var d := {
			"walls": PackedColorArray(),
			"roofs": PackedColorArray(),
			"wall_l": PackedFloat32Array(),
			"roof_l": PackedFloat32Array(),
		}
		for c: Array in p.get("wall_colors", [[0.7, 0.7, 0.7]]):
			d.walls.append(WorldTiles.linear_color(c))
			d.wall_l.append(BuildingStyle.luminance(c))
		for c: Array in p.get("roof_colors", [[0.3, 0.3, 0.3]]):
			d.roofs.append(WorldTiles.linear_color(c))
			d.roof_l.append(BuildingStyle.luminance(c))
		out.append(d)
	return out
