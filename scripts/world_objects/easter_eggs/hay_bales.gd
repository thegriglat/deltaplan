class_name EggHayBales
extends EasterEgg
## Рулоны сена (чисто картинка, живой мир): на скошенных участках полей (FieldPlots.MOWN) и, реже, на
## лугах у посёлков лежат круглые рулоны — рядами по полю (вдоль rows_axis) или горкой у края участка.
## Что и где лежит — чистая функция (ключ мира, участок): plan_cell(); не «вокруг пилота», у всех в сети
## одинаково. Рисуется в пределах вокруг камеры (visible_m), два MultiMesh (ближний с тенями, дальний без),
## пересборка при сдвиге камеры порциями по cells_per_frame участков. Сезон — по layout (rows / pile).

const MODEL := "res://assets/easter_eggs/hay_bales/hay_bale.glb"
const D := 1.5  ## диаметр рулона, м (К11)
const W := 1.2  ## ширина рулона вдоль оси, м
const TIER_H := 1.3  ## высота центра второго яруса над нижним (рулоны касаются боками)

var _cfg: Dictionary = {}
var _fp: FieldPlots
var _place: EggPlace
var _key := ""
var _south := false
var _mesh: Mesh
var _mat: StandardMaterial3D
var _near: MultiMeshInstance3D
var _far: MultiMeshInstance3D
var _cache := {}  ## Vector2i → {layout, pack: PackedFloat32Array, n}
var _center := Vector2(1.0e12, 1.0e12)  ## центр последней завершённой сборки
var _job_center := Vector2.ZERO
var _job: Array[Vector2i] = []  ## ячейки, которые ещё считать
var _job_all: Array[Vector2i] = []
var _job_on := false
## Для тестов и печати.
var instances := 0
var near_instances := 0
var rebuilds := 0
var last_update_us := 0
var max_update_us := 0
var sum_update_us := 0
var frames := 0


## Месяц с поправкой на полушарие: южное — зеркально (+6 мес).
static func season_month(ctx: EggContext) -> int:
	var lat: Variant = ctx.get("lat_deg")
	if lat != null and float(lat) < 0.0:
		return (ctx.month + 5) % 12 + 1
	return ctx.month


static func month_in(m: int, range_cfg: Array) -> bool:
	return m >= int(range_cfg[0]) and m <= int(range_cfg[1])


## Условия: есть мир и сезон хотя бы у одной из раскладок.
static func can_appear(ctx: EggContext, cfg: Dictionary) -> bool:
	if ctx.place == null:
		return false
	var m := season_month(ctx)
	return month_in(m, cfg.get("rows_months", [6, 9])) or month_in(m, cfg.get("pile_months", [6, 11]))


# ---------------------------------------------------------------- раскладка участка (чистая)


## Подходит ли участок: {ok, type: "mown"/"meadow"}.
static func cell_type(cell: Vector2i, fp: FieldPlots, place: EggPlace, cfg: Dictionary) -> String:
	var r := fp.rect(cell)
	var c := r.get_center()
	var pts: Array[Vector2] = [
		c,
		r.position,
		r.position + Vector2(r.size.x, 0.0),
		r.position + Vector2(0.0, r.size.y),
		r.end,
	]
	var n_crop := 0
	var n_grass := 0
	for p in pts:
		var sf := place.surface_at(p.x, p.y)
		n_grass += 1 if sf == SurfaceLayer.GRASS else 0
	for gx in 5:
		for gz in 3:
			var q := r.position + Vector2(r.size.x * (0.1 + 0.2 * gx), r.size.y * (0.17 + 0.33 * gz))
			n_crop += 1 if place.surface_at(q.x, q.y) == SurfaceLayer.CROP else 0
	if place.is_mountain(c.x, c.y):
		return ""
	# поле: участок целиком вписан в покров редко (пятна WorldCover мельче участка), поэтому достаточно
	# crop_min_points из 15 проверочных точек (сетка 5×3), а каждый рулон потом проверяется на CROP отдельно
	if n_crop >= int(cfg.get("crop_min_points", 3)):
		if fp.tone(cell) < FieldPlots.MOWN_MIN + float(cfg.get("mown_margin", 0.03)):
			return ""
		return "mown"
	if n_grass == pts.size():
		var v := place.nearest_place(c.x, c.y)
		if not v.is_empty() and float(v.dist_m) <= float(cfg.get("meadow_village_max_m", 2500.0)):
			return "meadow"
	return ""


## Раскладка участка: {} — рулонов нет; иначе
## {layout: "rows"|"pile", type, axis: Vector2, xf: Array[Transform3D], row: PackedInt32Array, tier: PackedInt32Array}.
## row — номер ряда (rows) или «срез» вдоль оси (pile); tier — ярус горки (rows — 0).
static func plan_cell(
	cell: Vector2i, fp: FieldPlots, place: EggPlace, cfg: Dictionary, world_key: String
) -> Dictionary:
	var rng := RandomNumberGenerator.new()
	rng.seed = ("%s|hay_bales|%d|%d" % [world_key, cell.x, cell.y]).hash()
	var u_share := rng.randf()
	var u_layout := rng.randf()
	var type := cell_type(cell, fp, place, cfg)
	if type == "":
		return {}
	var share := float(cfg.get("mown_share" if type == "mown" else "meadow_share", 0.5))
	if u_share >= share:
		return {}
	var out := {
		"type": type,
		"want": SurfaceLayer.CROP if type == "mown" else SurfaceLayer.GRASS,
		"axis": fp.rows_axis(cell),
		"xf": [] as Array[Transform3D],
		"row": PackedInt32Array(),
		"tier": PackedInt32Array(),
	}  # row/tier — упакованные массивы (значения): добавлять через out.row.append, не через `as`
	if u_layout < float(cfg.get("pile_share", 0.35)):
		out.layout = "pile"
		_make_pile(out, fp.rect(cell), place, cfg, rng)
	else:
		out.layout = "rows"
		_make_rows(out, fp.rect(cell), place, cfg, rng)
	if (out.xf as Array).is_empty():
		return {}
	return out


## Под рулоном нужный покров (CROP на поле, GRASS на лугу) и не круто.
static func _spot_ok(place: EggPlace, p: Vector2, want: int, cfg: Dictionary) -> bool:
	return (
		place.surface_at(p.x, p.y) == want
		and place.slope_deg_at(p.x, p.y) <= float(cfg.get("max_slope_deg", 15.0))
	)


static func _ground_xf(place: EggPlace, p: Vector2, yaw: float, sink: float, max_tilt: float) -> Transform3D:
	var h := place.height_at(p.x, p.y)
	var e := 1.5
	var nx := place.height_at(p.x - e, p.y) - place.height_at(p.x + e, p.y)
	var nz := place.height_at(p.x, p.y - e) - place.height_at(p.x, p.y + e)
	var n := Vector3(nx, 2.0 * e, nz).normalized()
	var ang := Vector3.UP.angle_to(n)
	if ang > deg_to_rad(max_tilt):
		n = Vector3.UP.slerp(n, deg_to_rad(max_tilt) / ang).normalized()
	var tilt := Basis(Quaternion(Vector3.UP, n)) if n.y < 0.99999 else Basis.IDENTITY
	var b := tilt * Basis(Vector3.UP, yaw)
	return Transform3D(b, Vector3(p.x, h - sink, p.y))


## yaw, при котором локальная ось X рулона смотрит вдоль горизонтального направления d (x — восток, z — юг).
static func _yaw_for(d: Vector2) -> float:
	return atan2(-d.y, d.x)


static func _make_rows(out: Dictionary, r: Rect2, place: EggPlace, cfg: Dictionary, rng: RandomNumberGenerator) -> void:
	var ax: Vector2 = out.axis
	var pp := Vector2(-ax.y, ax.x)  # поперёк рядов
	var c := r.get_center()
	var half_a := (r.size.x if ax.x != 0.0 else r.size.y) * 0.5
	var half_p := (r.size.y if ax.x != 0.0 else r.size.x) * 0.5
	var inset := float(cfg.get("edge_inset_m", 10.0))
	var sp: Array = cfg.get("row_gap_m", [15.0, 25.0])
	var ss: Array = cfg.get("step_m", [20.0, 40.0])
	var gap := rng.randf_range(float(sp[0]), float(sp[1]))
	var step := rng.randf_range(float(ss[0]), float(ss[1]))
	var keep := rng.randf_range(float(cfg.get("keep", [0.5, 0.9])[0]), float(cfg.get("keep", [0.5, 0.9])[1]))
	var row_keep := float(cfg.get("row_keep", 0.8))
	var jit_a := float(cfg.get("jitter_along_m", 1.5))
	var jit_p := float(cfg.get("jitter_across_m", 0.6))
	var jit_yaw := deg_to_rad(float(cfg.get("jitter_yaw_deg", 8.0)))
	var tilt := float(cfg.get("max_tilt_deg", 15.0))
	var cap := int(cfg.get("max_per_cell", 60))
	var q0 := -half_p + inset + rng.randf() * gap
	var a_phase := rng.randf() * step
	var k := 0
	var q := q0
	while q <= half_p - inset:
		var row_on := rng.randf() < row_keep
		var a := -half_a + inset + a_phase * rng.randf()
		while a <= half_a - inset:
			var has := rng.randf() < keep
			var ja := rng.randf_range(-jit_a, jit_a)
			var jp := rng.randf_range(-jit_p, jit_p)
			var jy := rng.randf_range(-jit_yaw, jit_yaw)
			var pos := c + ax * (a + ja) + pp * (q + jp)
			if row_on and has and (out.xf as Array).size() < cap and _spot_ok(place, pos, out.want, cfg):
				var across := pp  # ось рулона поперёк хода — поперёк ряда
				var yaw := _yaw_for(across) + jy
				(out.xf as Array).append(_ground_xf(place, pos, yaw, 0.04, tilt))
				out.row.append(k)
				out.tier.append(0)
			a += step
		q += gap
		k += 1


static func _make_pile(out: Dictionary, r: Rect2, place: EggPlace, cfg: Dictionary, rng: RandomNumberGenerator) -> void:
	var ax: Vector2 = out.axis  # оси рулонов горки — вдоль борозд
	var pp := Vector2(-ax.y, ax.x)
	var tiers_all: Array = cfg.get("pile_shapes", [[3, 2, 1], [4, 3]])
	var shape: Array = tiers_all[rng.randi_range(0, tiers_all.size() - 1)]
	var dr: Array = cfg.get("pile_depth", [1, 3])
	var depth := rng.randi_range(int(dr[0]), int(dr[1]))
	var inset := float(cfg.get("pile_edge_m", 9.0))
	# у края участка: выбираем сторону и положение вдоль неё
	var p := Vector2.ZERO
	var found := false
	for attempt in int(cfg.get("pile_tries", 8)):
		var side := rng.randi_range(0, 3)
		var t := rng.randf_range(0.2, 0.8)
		match side:
			0:
				p = Vector2(r.position.x + r.size.x * t, r.position.y + inset)
			1:
				p = Vector2(r.position.x + r.size.x * t, r.end.y - inset)
			2:
				p = Vector2(r.position.x + inset, r.position.y + r.size.y * t)
			_:
				p = Vector2(r.end.x - inset, r.position.y + r.size.y * t)
		found = true
		for off in [Vector2.ZERO, ax * 4.0, -ax * 4.0, pp * 4.0, -pp * 4.0]:
			if not _spot_ok(place, p + off, out.want, cfg):
				found = false
				break
		if found:
			break
	if not found:
		return
	var gap := float(cfg.get("pile_gap_m", 0.05))
	var yaw := _yaw_for(ax)
	var base := _ground_xf(place, p, yaw, 0.04, float(cfg.get("max_tilt_deg", 15.0)))
	var pitch := D + gap
	for ti in shape.size():
		var cnt: int = int(shape[ti])
		for i in cnt:
			var lz := (float(i) - float(cnt - 1) * 0.5) * pitch  # поперёк оси рулонов
			for d_i in depth:
				var lx := (float(d_i) - float(depth - 1) * 0.5) * (W + gap)  # вдоль оси
				var local := Vector3(lx, float(ti) * (TIER_H + gap * 0.5) , lz)
				var xf := Transform3D(base.basis, base * local)
				(out.xf as Array).append(xf)
				out.row.append(d_i)
				out.tier.append(ti)


# ---------------------------------------------------------------- узел


func begin(ctx: EggContext, cfg: Dictionary, _rng: RandomNumberGenerator, _t0: float) -> void:
	_cfg = cfg
	_place = ctx.place
	_key = ctx.world_key
	_fp = FieldPlots.from_world_config()
	_south = season_month(ctx) != ctx.month
	var sc: Variant = load(MODEL)
	if sc is PackedScene:
		var root: Node = (sc as PackedScene).instantiate()
		var mi := _find_mesh(root)
		if mi != null:
			_mesh = mi.mesh
		root.free()
	if _mesh != null:
		_mat = StandardMaterial3D.new()
		_mat.vertex_color_use_as_albedo = true
		var m0: Material = _mesh.surface_get_material(0)
		if m0 is StandardMaterial3D:
			_mat = (m0 as StandardMaterial3D).duplicate()
			_mat.vertex_color_use_as_albedo = true
		_mat.roughness = 1.0
	_near = _new_mmi(true)
	_far = _new_mmi(false)


func _find_mesh(n: Node) -> MeshInstance3D:
	if n is MeshInstance3D:
		return n
	for c in n.get_children():
		var r := _find_mesh(c)
		if r != null:
			return r
	return null


func _new_mmi(shadow: bool) -> MultiMeshInstance3D:
	var mmi := MultiMeshInstance3D.new()
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.mesh = _mesh
	mm.instance_count = 0
	var R := float(_cfg.get("visible_m", 1500.0)) + 400.0
	mm.custom_aabb = AABB(Vector3(-R, -2000.0, -R), Vector3(2.0 * R, 6000.0, 2.0 * R))
	mmi.multimesh = mm
	mmi.material_override = _mat
	mmi.cast_shadow = (
		GeometryInstance3D.SHADOW_CASTING_SETTING_ON if shadow else GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	)
	add_child(mmi)
	return mmi


func update(ctx: EggContext) -> bool:
	if _mesh == null or _place == null or _fp == null:
		return true
	var t_us := Time.get_ticks_usec()
	var cam := ctx.pilot_pos
	if ctx.camera != null:
		cam = ctx.camera.global_position
	var c2 := Vector2(cam.x, cam.z)
	if not _job_on and c2.distance_to(_center) > float(_cfg.get("rebuild_m", 150.0)):
		_start_job(c2)
	if _job_on:
		_step_job(ctx)
	last_update_us = Time.get_ticks_usec() - t_us
	max_update_us = maxi(max_update_us, last_update_us)
	sum_update_us += last_update_us
	frames += 1
	return true


func _start_job(c2: Vector2) -> void:
	_job_center = c2
	_job_all.clear()
	var R := float(_cfg.get("visible_m", 1500.0))
	var half_diag := _fp.size_m.length() * 0.5
	var cy0 := int(floorf((c2.y - R) / _fp.size_m.y)) - 1
	var cy1 := int(floorf((c2.y + R) / _fp.size_m.y)) + 1
	var cand: Array = []
	for cy in range(cy0, cy1 + 1):
		var band := floorf(float(cy) / FieldPlots.BAND_ROWS)
		var sh := band * FieldPlots.ROW_SHIFT
		var cx0 := int(floorf((c2.x - R) / _fp.size_m.x + sh)) - 1
		var cx1 := int(floorf((c2.x + R) / _fp.size_m.x + sh)) + 1
		for cx in range(cx0, cx1 + 1):
			var cell := Vector2i(cx, cy)
			var d := _fp.center(cell).distance_to(c2)
			if d <= R + half_diag * 0.0 + 0.0:
				cand.append([d, cell])
	cand.sort_custom(func(a, b): return a[0] < b[0])
	for e in cand:
		_job_all.append(e[1])
	_job = []
	for cell in _job_all:
		if not _cache.has(cell):
			_job.append(cell)
	if _cache.size() > int(_cfg.get("cache_max", 2500)):
		var keep := {}
		for cell in _job_all:
			if _cache.has(cell):
				keep[cell] = _cache[cell]
		_cache = keep
	_job_on = true


func _step_job(ctx: EggContext) -> void:
	var n := int(_cfg.get("cells_per_frame", 8))
	while n > 0 and not _job.is_empty():
		var cell: Vector2i = _job.pop_front()
		_cache[cell] = _eval(cell)
		n -= 1
	if _job.is_empty():
		_assemble(ctx)
		_center = _job_center
		_job_on = false
		rebuilds += 1


func _eval(cell: Vector2i) -> Dictionary:
	var pl := plan_cell(cell, _fp, _place, _cfg, _key)
	if pl.is_empty():
		return {}
	var xf: Array = pl.xf
	var pack := PackedFloat32Array()
	pack.resize(xf.size() * 12)
	var i := 0
	for t in xf:
		var b: Basis = t.basis
		var o: Vector3 = t.origin
		pack[i] = b.x.x
		pack[i + 1] = b.y.x
		pack[i + 2] = b.z.x
		pack[i + 3] = o.x
		pack[i + 4] = b.x.y
		pack[i + 5] = b.y.y
		pack[i + 6] = b.z.y
		pack[i + 7] = o.y
		pack[i + 8] = b.x.z
		pack[i + 9] = b.y.z
		pack[i + 10] = b.z.z
		pack[i + 11] = o.z
		i += 12
	return {"layout": pl.layout, "pack": pack, "n": xf.size()}


func _assemble(ctx: EggContext) -> void:
	var m := season_month(ctx)
	var rows_on := month_in(m, _cfg.get("rows_months", [6, 9]))
	var pile_on := month_in(m, _cfg.get("pile_months", [6, 11]))
	var near := PackedFloat32Array()
	var far := PackedFloat32Array()
	var sh_r := float(_cfg.get("shadow_m", 250.0)) + _fp.size_m.length() * 0.5
	for cell in _job_all:
		var d: Dictionary = _cache.get(cell, {})
		if d.is_empty():
			continue
		if (d.layout == "rows" and not rows_on) or (d.layout == "pile" and not pile_on):
			continue
		if _fp.center(cell).distance_to(_job_center) < sh_r:
			near.append_array(d.pack)
		else:
			far.append_array(d.pack)
	_fill(_near, near)
	_fill(_far, far)
	near_instances = near.size() / 12
	instances = near_instances + far.size() / 12


func _fill(mmi: MultiMeshInstance3D, pack: PackedFloat32Array) -> void:
	var mm := mmi.multimesh
	var n := pack.size() / 12
	mm.instance_count = n
	if n > 0:
		mm.buffer = pack
