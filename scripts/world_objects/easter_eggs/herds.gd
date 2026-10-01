class_name EggHerds
extends EasterEgg
## Отары и табуны (чисто картинка): 1–3 стайки овец/коров/лошадей на лугах у посёлков OSM.
## Одна стайка = один MultiMesh (модель из примитивов). Центр дрейфует по эллипсу, животные
## блуждают около своих мест — всё функция ctx.t. Низкий пролёт игрока пугает: животные бегут
## от него несколько секунд, потом бредут дальше от новых мест (локальная анимация, К3/К4).
## Порядок бросков rng в begin: число стайк; на каждую — поиск места (find_point), вид,
## число животных, дрейф, затем по каждому животному — смещение, фазы, окрас, размер.

const SHEEP := "sheep"

## Итоги поиска для тестов и печати: [{species, count, center: Vector3, village_m, start_m}]
var info: Array[Dictionary] = []

var _cfg: Dictionary = {}
var _herds: Array[Dictionary] = []
var _last_tick := -1.0e9
var _meshes := {}  ## вид → ArrayMesh
var _mat: StandardMaterial3D


## Условия: день, апрель–октябрь, не сильный ветер, есть место и посёлок OSM.
static func can_appear(ctx: EggContext, cfg: Dictionary) -> bool:
	if ctx.sun_elev_deg <= 0.0:
		return false
	if ctx.month < int(cfg.get("min_month", 4)) or ctx.month > int(cfg.get("max_month", 10)):
		return false
	if ctx.wind_ms > float(cfg.get("max_wind_ms", 10.0)):
		return false
	if ctx.place == null:
		return false
	return not ctx.place.nearest_place(ctx.pilot_pos.x, ctx.pilot_pos.z).is_empty()


## Годится ли точка под пастбище: луг (реже кустарник), не круто, не горы.
static func ground_ok(place: EggPlace, x: float, z: float, cfg: Dictionary) -> bool:
	var s := place.surface_at(x, z)
	if s == SurfaceLayer.SHRUB:
		var share := float(cfg.get("shrub_share", 0.25))
		var cell := int(floorf(x / 50.0)) * 7 + int(floorf(z / 50.0)) * 13
		if float(posmod(cell, 100)) / 100.0 >= share:
			return false
	elif s != SurfaceLayer.GRASS:
		return false
	if place.slope_deg_at(x, z) > float(cfg.get("max_slope_deg", 20.0)):
		return false
	return not place.is_mountain(x, z)


## Центр стайки: пастбище + кольцо вокруг тоже пастбище.
static func spot_ok(place: EggPlace, x: float, z: float, cfg: Dictionary) -> bool:
	if not ground_ok(place, x, z, cfg):
		return false
	var r := float(cfg.get("ring_m", 25.0))
	for a in 4:
		var ang := a * PI * 0.5 + 0.4
		if not ground_ok(place, x + cos(ang) * r, z + sin(ang) * r, cfg):
			return false
	return true


func begin(ctx: EggContext, cfg: Dictionary, rng: RandomNumberGenerator, _t0: float) -> void:
	_cfg = cfg
	var place := ctx.place
	if place == null:
		# мира нет (тесты каркаса): одна стайка в 200 м от игрока, без проверок места
		var q := Vector2(ctx.pilot_pos.x + 200.0, ctx.pilot_pos.z)
		_make_herd(ctx, Vector3(q.x, ctx.height_at.call(q.x, q.y), q.y), rng, cfg, q)
		position = _herds[0].anchor
		return
	var start := Vector2(ctx.pilot_pos.x, ctx.pilot_pos.z)
	var sites := place.start_sites()
	if not sites.is_empty():
		start = Vector2(sites[0].position.x, sites[0].position.z)
	var rc: Array = cfg.get("herds_count", [1, 3])
	var n_herds := rng.randi_range(int(rc[0]), int(rc[1]))
	var found: Array[Vector3] = []
	for h in n_herds:
		var p: Variant = _find_spot(place, rng, start, cfg, found)
		if p == null:
			continue
		found.append(p)
		_make_herd(ctx, p, rng, cfg, start)
	if not _herds.is_empty():
		position = _herds[0].anchor


func _find_spot(
	place: EggPlace,
	rng: RandomNumberGenerator,
	start: Vector2,
	cfg: Dictionary,
	found: Array[Vector3]
) -> Variant:
	var rad := float(cfg.get("search_radius_m", 10000.0))  # предел удаления от старта
	var vmax := float(cfg.get("village_max_m", 3000.0))
	var gap := float(cfg.get("min_gap_m", 300.0))
	var near_village := func(x: float, z: float) -> bool:
		var v := place.nearest_place(x, z)
		return not v.is_empty() and float(v.dist_m) <= vmax
	var spot := func(x: float, z: float) -> bool:
		if Vector2(x - start.x, z - start.y).length() > rad:
			return false
		var v := place.nearest_place(x, z)
		if v.is_empty() or float(v.dist_m) > vmax:
			return false
		for f in found:
			if Vector2(f.x - x, f.z - z).length() < gap:
				return false
		return spot_ok(place, x, z, cfg)
	var tries := int(cfg.get("anchor_tries", 4))
	for k in tries:
		# сперва ближе к старту (чтобы стайку можно было увидеть), потом шире
		var r_k := rad * float(k + 1) / float(tries)
		var a: Variant = place.find_point(rng, start, r_k, near_village)
		if a == null:
			continue
		var v := place.nearest_place(a.x, a.z)
		var p: Variant = place.find_point(rng, Vector2(v.x, v.z), vmax, spot)
		if p != null:
			return p
	return null


func _make_herd(
	ctx: EggContext, c: Vector3, rng: RandomNumberGenerator, cfg: Dictionary, start: Vector2
) -> void:
	var sps: Dictionary = cfg.species
	var total := 0.0
	for k in sps:
		if sps[k] is Dictionary:
			total += float(sps[k].get("weight", 1.0))
	var pick := rng.randf() * total
	var kind := SHEEP
	for k in sps:
		if sps[k] is Dictionary:
			pick -= float(sps[k].get("weight", 1.0))
			kind = String(k)
			if pick <= 0.0:
				break
	var sp: Dictionary = sps[kind]
	var cr: Array = sp.count
	var n := rng.randi_range(int(cr[0]), int(cr[1]))
	var spread := float(sp.spread_per_sqrt_m) * sqrt(float(n))
	var dr: Array = cfg.get("drift_radius_m", [25.0, 45.0])
	var rx := lerpf(float(dr[0]), float(dr[1]), rng.randf())
	var rz := lerpf(float(dr[0]), float(dr[1]), rng.randf())
	var drift := float(cfg.get("drift_ms", 0.15))
	var h := {
		"kind": kind,
		"sp": sp,
		"n": n,
		"c0": Vector2(c.x, c.z),
		"anchor": c,
		"rx": rx,
		"rz": rz,
		"phi": rng.randf() * TAU,
		"omega": drift / maxf(maxf(rx, rz), 1.0),
		"spread": spread,
		"off": PackedVector2Array(),
		"w_ph": PackedVector4Array(),
		"w_w": PackedVector2Array(),
		"yaw0": PackedFloat32Array(),
		"size": PackedFloat32Array(),
		"flee_v": PackedVector2Array(),
		"flee_dur": PackedFloat32Array(),
		"push": PackedVector2Array(),
		"flee": PackedFloat32Array(),
		"fdir": PackedVector2Array(),
		"fspd": PackedFloat32Array(),
		"yaw": PackedFloat32Array(),
		"prev": PackedVector2Array(),
		"pos": PackedVector2Array(),
		"awake": false,
		"last_t": NAN,
		"shadow": false,
	}
	var ww: Array = cfg.get("wander_w", [0.02, 0.06])
	var fs: Array = cfg.get("flee_s", [3.0, 6.0])
	var fv: Array = sp.flee_ms
	var cols: Array = sp.colors
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.use_colors = true
	mm.mesh = _mesh_for(kind, sp)
	mm.instance_count = n
	for i in n:
		var off := Vector2.ZERO
		for k in 6:  # животное только на лугу; не нашлось места — ближе к центру
			var ang := rng.randf() * TAU
			var rad := spread * sqrt(rng.randf())
			off = Vector2(cos(ang), sin(ang)) * rad
			if ctx.place == null:
				break
			var sa := ctx.place.surface_at(c.x + off.x, c.z + off.y)
			if sa == SurfaceLayer.GRASS or sa == SurfaceLayer.SHRUB:
				break
			off *= 0.3
		h.off.append(off)
		h.w_ph.append(Vector4(rng.randf() * TAU, rng.randf() * TAU, 0.0, 0.0))
		h.w_w.append(
			Vector2(
				lerpf(float(ww[0]), float(ww[1]), rng.randf()),
				lerpf(float(ww[0]), float(ww[1]), rng.randf())
			)
		)
		h.yaw0.append(rng.randf() * TAU)
		h.size.append(lerpf(0.9, 1.1, rng.randf()))
		h.flee_v.append(Vector2(lerpf(float(fv[0]), float(fv[1]), rng.randf()), 0.0))
		h.flee_dur.append(lerpf(float(fs[0]), float(fs[1]), rng.randf()))
		var col: Array = cols[rng.randi_range(0, cols.size() - 1)]
		var j := lerpf(0.94, 1.06, rng.randf())
		mm.set_instance_color(i, Color(float(col[0]) * j, float(col[1]) * j, float(col[2]) * j))
		h.push.append(Vector2.ZERO)
		h.flee.append(0.0)
		h.fdir.append(Vector2.ZERO)
		h.fspd.append(0.0)
		h.yaw.append(h.yaw0[i])
		h.prev.append(Vector2.ZERO)
		h.pos.append(Vector2.ZERO)
	var reach := spread + float(cfg.get("max_push_m", 200.0)) + 20.0
	mm.custom_aabb = AABB(Vector3(-reach, -120.0, -reach), Vector3(reach * 2.0, 240.0, reach * 2.0))
	var mmi := MultiMeshInstance3D.new()
	mmi.multimesh = mm
	mmi.material_override = _material()
	mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	mmi.visible = false
	add_child(mmi)
	h["mmi"] = mmi
	h["mm"] = mm
	_herds.append(h)
	var vil := ctx.place.nearest_place(c.x, c.z) if ctx.place != null else {}
	(
		info
		. append(
			{
				"species": kind,
				"count": n,
				"center": c,
				"village_m": float(vil.get("dist_m", INF)),
				"start_m": Vector2(c.x - start.x, c.z - start.y).length(),
			}
		)
	)


func _material() -> StandardMaterial3D:
	if _mat == null:
		_mat = StandardMaterial3D.new()
		_mat.vertex_color_use_as_albedo = true
		_mat.roughness = 1.0
		_mat.albedo_color = Color.WHITE
	return _mat


# ---------------------------------------------------------------- модель


func _mesh_for(kind: String, sp: Dictionary) -> ArrayMesh:
	if _meshes.has(kind):
		return _meshes[kind]
	var ln := float(sp.length_m)
	var ht := float(sp.height_m)
	var wd := float(sp.width_m)
	var hy := float(sp.head_y_frac) * ht
	var leg_h := ht * 0.45
	var legw := ln * 0.055
	var v := PackedVector3Array()
	var n := PackedVector3Array()
	var c := PackedColorArray()
	var idx := PackedInt32Array()
	var body := Color(1, 1, 1)
	var head_c := Color(0.3, 0.3, 0.3) if kind == SHEEP else Color(0.8, 0.8, 0.8)
	var leg_c := Color(0.4, 0.4, 0.4)
	# туловище, шея, голова, четыре ноги; голова смотрит в −Z
	_box(
		v,
		n,
		c,
		idx,
		Vector3(0, (leg_h + ht) * 0.5, ln * 0.12),
		Vector3(wd, ht - leg_h, ln * 0.68),
		body
	)
	var neck_lo := ht * 0.72
	var neck_hi := maxf(hy + ht * 0.1, ht * 0.95)
	_box(
		v,
		n,
		c,
		idx,
		Vector3(0, (neck_lo + neck_hi) * 0.5, -ln * 0.22),
		Vector3(wd * 0.45, neck_hi - neck_lo, ln * 0.14),
		body
	)
	_box(v, n, c, idx, Vector3(0, hy, -ln * 0.37), Vector3(wd * 0.55, ht * 0.2, ln * 0.26), head_c)
	for sx in [-1.0, 1.0]:
		for z in [-0.14, 0.4]:
			_box(
				v,
				n,
				c,
				idx,
				Vector3(sx * wd * 0.36, leg_h * 0.5, ln * z),
				Vector3(legw, leg_h, legw),
				leg_c
			)
	var arr := []
	arr.resize(Mesh.ARRAY_MAX)
	arr[Mesh.ARRAY_VERTEX] = v
	arr[Mesh.ARRAY_NORMAL] = n
	arr[Mesh.ARRAY_COLOR] = c
	arr[Mesh.ARRAY_INDEX] = idx
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arr)
	_meshes[kind] = mesh
	return mesh


static func _box(
	v: PackedVector3Array,
	nn: PackedVector3Array,
	col: PackedColorArray,
	idx: PackedInt32Array,
	center: Vector3,
	size: Vector3,
	color: Color
) -> void:
	var h := size * 0.5
	for nrm in [
		Vector3.RIGHT, Vector3.LEFT, Vector3.UP, Vector3.DOWN, Vector3.BACK, Vector3.FORWARD
	]:
		var n3: Vector3 = nrm
		var u := n3.cross(Vector3.UP) if absf(n3.y) < 0.9 else Vector3.RIGHT
		var w := n3.cross(u)
		var hn := absf(n3.dot(h))
		var hu := absf(u.dot(h))
		var hw := absf(w.dot(h))
		var base := v.size()
		for corner in [Vector2(-1, -1), Vector2(1, -1), Vector2(1, 1), Vector2(-1, 1)]:
			v.append(center + n3 * hn + u * hu * corner.x + w * hw * corner.y)
			nn.append(n3)
			col.append(color)
		# Godot: лицевая сторона — по часовой стрелке
		idx.append_array([base, base + 2, base + 1, base, base + 3, base + 2])


# ---------------------------------------------------------------- ход


## Центр стайки в момент t (мир, x/z): эллипс вокруг начальной точки; в t0 — ровно в ней.
func center_at(h: Dictionary, t: float) -> Vector2:
	var a := float(h.omega) * (t - t0) + float(h.phi)
	var a0 := float(h.phi)
	return h.c0 + Vector2(float(h.rx) * (cos(a) - cos(a0)), float(h.rz) * (sin(a) - sin(a0)))


## Положения животных стайки i после последнего обновления (для тестов), x/z.
func animal_positions(i: int) -> PackedVector2Array:
	return _herds[i].pos


func herd_count() -> int:
	return _herds.size()


func update(ctx: EggContext) -> bool:
	if _herds.is_empty():
		return false
	var t := ctx.t
	var tick := float(_cfg.get("tick_s", 0.1))
	if t >= _last_tick and t - _last_tick < tick:
		return true
	_last_tick = t
	var cam := ctx.pilot_pos
	if ctx.camera != null and ctx.camera.is_inside_tree():
		cam = ctx.camera.global_position
	for h in _herds:
		_update_herd(h, ctx, cam)
	return true


func _update_herd(h: Dictionary, ctx: EggContext, cam: Vector3) -> void:
	var t := ctx.t
	var mmi: MultiMeshInstance3D = h.mmi
	var cen := center_at(h, t)
	var cy: float = ctx.height_at.call(cen.x, cen.y)
	var d := cam.distance_to(Vector3(cen.x, cy, cen.y))
	var vis_m := float(_cfg.get("visible_m", 2000.0))
	var far := d > float(h.spread) + float(_cfg.get("sleep_m", 3500.0))
	if far:
		h.awake = false
		mmi.visible = false
		return
	var was_awake: bool = h.awake
	h.awake = true
	var dt := 0.0  # прыжок времени (вперёд > 0,5 с или назад) и первый кадр — без интегрирования
	if was_awake and not is_nan(h.last_t):
		var raw := t - float(h.last_t)
		dt = raw if raw > 0.0 and raw <= 0.5 else 0.0
	h.last_t = t
	mmi.visible = d < vis_m + float(h.spread)
	var want_shadow: bool = d < float(_cfg.get("shadow_m", 300.0))
	if want_shadow != h.shadow:
		h.shadow = want_shadow
		mmi.cast_shadow = (
			GeometryInstance3D.SHADOW_CASTING_SETTING_ON
			if want_shadow
			else GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		)
	mmi.position = Vector3(cen.x, cy, cen.y) - position
	var pil := Vector2(ctx.pilot_pos.x, ctx.pilot_pos.z)
	var scare_r := float(_cfg.get("scare_radius_m", 80.0))
	var scare_h := float(_cfg.get("scare_height_m", 50.0))
	var tau := float(_cfg.get("settle_tau_s", 120.0))
	var max_push := float(_cfg.get("max_push_m", 200.0))
	var wander := float(_cfg.get("wander_m", 2.5))
	var decay := exp(-dt / maxf(tau, 1.0))
	var mm: MultiMesh = h.mm
	var base_y := cy
	for i in int(h.n):
		var ph: Vector4 = h.w_ph[i]
		var ww: Vector2 = h.w_w[i]
		var push: Vector2 = h.push[i]
		var p: Vector2 = (
			cen + h.off[i] + Vector2(sin(ww.x * t + ph.x), cos(ww.y * t + ph.y)) * wander + push
		)
		var g: float = ctx.height_at.call(p.x, p.y)
		# испуг: игрок низко над этим животным и близко по горизонтали
		var flee: float = h.flee[i]
		if dt > 0.0:
			var away: Vector2 = p - pil
			if away.length() < scare_r and ctx.pilot_pos.y - g < scare_h:
				var dirv := (
					away.normalized() if away.length() > 0.5 else Vector2.RIGHT.rotated(h.yaw0[i])
				)
				h.fdir[i] = dirv
				h.fspd[i] = h.flee_v[i].x
				flee = h.flee_dur[i]
			if flee > 0.0:
				push += h.fdir[i] * float(h.fspd[i]) * dt
				flee = maxf(flee - dt, 0.0)
			else:
				push *= decay
			if push.length() > max_push:
				push = push.normalized() * max_push
		h.flee[i] = flee
		h.push[i] = push
		var np: Vector2 = (
			cen + h.off[i] + Vector2(sin(ww.x * t + ph.x), cos(ww.y * t + ph.y)) * wander + push
		)
		# курс: по движению, если идёт заметно, иначе пасётся
		var yaw: float = h.yaw[i]
		var mv: Vector2 = np - h.prev[i]
		if dt > 0.0 and mv.length() / dt > 0.3:
			yaw = lerp_angle(yaw, atan2(-mv.x, -mv.y), minf(dt * 5.0, 1.0))
		else:
			yaw = lerp_angle(
				yaw, float(h.yaw0[i]) + 0.6 * sin(0.03 * t + ph.x), minf(dt * 0.5, 1.0)
			)
		h.yaw[i] = yaw
		h.prev[i] = np
		h.pos[i] = np
		var gy: float = ctx.height_at.call(np.x, np.y)
		var bob := 0.0
		if flee > 0.0:
			bob = 0.12 * absf(sin(t * 9.0 + ph.y))
		var s: float = h.size[i]
		var b := Basis(Vector3.UP, yaw).scaled(Vector3(s, s, s))
		mm.set_instance_transform(
			i, Transform3D(b, Vector3(np.x - cen.x, gy - base_y + bob, np.y - cen.y))
		)
