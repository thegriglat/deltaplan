class_name StartGear
extends RefCounted
## Снаряжение лётного выезда у старта (docs/plan/start-camp.md SC-2, контракты SC-K1/K2/K3/K5):
## 2–4 собранных крыла на базовой штанге носом в землю и в ветер, полусобранный аппарат
## (kit_bundle + kit_frame), чехлы кучками, рюкзаки/подвески, шлемы, бутылки. Постоянный набор
## (не от погоды, часа и игрока) — детерминированно от места и курса старта.
## Параметры — configs/world_objects.json → start_gear. Без нод: plan() — чистая функция (тесты),
## build_node() — визуал: мелочь — MultiMesh на вариант × LOD, крылья — glider_<id>.glb целиком
## (дальше wing_detail_m — без трапеции, дальше wing_visibility_m — не рисуются).
## WorldObjects строит набор у каждого старта локации и добавляет препятствия «gear».
##   var items := StartGear.plan(start, heading_deg, cfg.start_gear, env)
## Элемент: {kind, variant, position, basis, yaw, color, radius_m, box, center}; center — центр
## коробки препятствия на земле (у вещей = position, у крыла position — HangPoint, высоко над землёй).

const MAIN_KINDS := ["wing", "kit_bundle", "kit_frame", "bag", "harness", "helmet", "bottle"]
## Эти виды — препятствия «gear» (box ≠ ZERO).
const OBSTACLE_KINDS := ["wing", "kit_bundle", "kit_frame", "bag"]
const FABRIC_PRESETS := {"Fabric": "bag", "FabricDark": "fabric_dark", "Sail": "sail"}
const TINTED_STD := ["Shell"]

## Позы моделей крыльев: id → {nose, bar_l, bar_r, span, aabb, tris_near, tris_far, glb}.
static var _poses: Dictionary = {}
## Меши мелочи: "вариант|lod" → Mesh (с материалами игры).
static var _meshes: Dictionary = {}
static var _glb_meshes: Dictionary = {}
static var _glb_loaded: Dictionary = {}
static var _fabric_cache: Dictionary = {}
static var _std_cache: Dictionary = {}


# ---------------------------------------------------------------------------------------------
# План
# ---------------------------------------------------------------------------------------------


## План набора у старта. start — точка старта на земле, heading_deg — курс разбега (ветер в лицо),
## cfg — start_gear, env — как у TentCamp.plan (height_fn обязателен; blocked_fn, lines, points,
## points_fn — по возможности). Места нет — меньше вещей, без ошибки.
static func plan(
	start: Vector3, heading_deg: float, cfg: Dictionary, env: Dictionary
) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	if cfg.is_empty() or not bool(cfg.get("enabled", true)):
		return out
	var ctx := _Ctx.new(start, heading_deg, cfg, env)
	var rng := RandomNumberGenerator.new()
	rng.seed = hash(
		[int(cfg.get("seed", 1)), roundi(start.x * 2.0), roundi(start.z * 2.0), roundi(heading_deg)]
	)
	var counts: Dictionary = cfg.get("counts", {})
	var n_wing := _count(counts, "wing", rng)
	var n_kit := _count(counts, "kit", rng)
	var n_bag := _count(counts, "bag", rng)
	var n_harness := _count(counts, "harness", rng)
	var n_helmet := _count(counts, "helmet", rng)
	var n_bottle := _count(counts, "bottle", rng)
	var palette: Array = cfg.get("colors", [[1, 1, 1]])
	var variants: Dictionary = cfg.get("variants", {})
	var spread := deg_to_rad(float(cfg.get("wing_yaw_spread_deg", 8.0)))
	var wing_ids: Array = []
	var pool: Array = cfg.get("wing_pool", [])
	for i in n_wing:
		if not pool.is_empty():
			wing_ids.append(String(pool[rng.randi_range(0, pool.size() - 1)]))
	# 1. Крылья: рядом друг с другом, зазор gap_m
	var wing_circles: Array = []
	for id: String in wing_ids:
		var pose := wing_pose(id)
		var r := float(pose.span) * 0.5
		var psi := ctx.base_yaw + rng.randf_range(-spread, spread)
		var geo := _wing_geom(pose)
		var q: Variant = ctx.find_spot(rng, r, wing_circles, ctx.gap)
		if q == null:
			continue
		var qv: Vector2 = q
		var off := Basis(Vector3.UP, psi) * Vector3(0.0, 0.0, float(geo.cz))
		var bm := qv - Vector2(off.x, off.z)
		var wp := _wing_place(pose, bm, psi, ctx.height_fn)
		var gy := float(ctx.height_fn.call(qv.x, qv.y))
		var item := {
			"kind": "wing",
			"variant": id,
			"position": wp.position,
			"basis": wp.basis,
			"yaw": psi,
			"color": -1,
			"radius_m": r,
			"box": Vector3(r, float(geo.hz), float(geo.h)),
			"center": Vector3(qv.x, gy, qv.y),
		}
		ctx.add(qv, r)
		wing_circles.append([qv, r])
		out.append(item)
	# 2. Полусобранный аппарат: kit_bundle + kit_frame рядом (≤ 4 м)
	for k in n_kit:
		var bsz: Array = _size(variants, "kit_bundle")
		var fsz: Array = _size(variants, "kit_frame")
		var ur := float(bsz[1]) * 0.5 + 0.5
		var q: Variant = ctx.find_spot(rng, ur, wing_circles, 0.6)
		if q == null:
			continue
		var qv: Vector2 = q
		var yaw := ctx.base_yaw + rng.randf_range(-0.5 * PI, 0.5 * PI)
		var side := 1.0 if rng.randf() < 0.5 else -1.0
		var rot := Basis(Vector3.UP, yaw)
		var fo := rot * Vector3(side * (float(bsz[0]) * 0.5 + float(fsz[0]) * 0.5 + 0.9), 0.0, rng.randf_range(-0.8, 0.8))
		var fp := qv + Vector2(fo.x, fo.z)
		var unit_r := maxf(ur, fp.distance_to(qv) + float(fsz[1]) * 0.5 + 0.3)
		ctx.add(qv, unit_r)
		out.append(_ground(ctx, "kit_bundle", "kit_bundle", qv, yaw, _pick_color(rng, palette, true), cfg))
		out.append(
			_ground(
				ctx,
				"kit_frame",
				"kit_frame",
				fp,
				yaw + rng.randf_range(-0.6, 0.6),
				-1,
				cfg
			)
		)
		wing_circles.append([qv, unit_r])
	# 3. Чехлы кучками (часть — у крыльев)
	var left := n_bag
	var anchors: Array = wing_circles.duplicate()
	while left > 0:
		var n := mini(left, rng.randi_range(1, 3))
		left -= n
		var vname := "wing_bag_long" if rng.randf() < 0.6 else "wing_bag_short"
		var sz: Array = _size(variants, vname)
		var pr := _hyp(float(sz[1]) * 0.5 + 0.4, float(n) * 0.28 + 0.2)
		var anchor: Array = []
		if not anchors.is_empty() and rng.randf() < 0.6:
			anchor = anchors
		var q: Variant = ctx.find_spot(rng, pr, anchor, 0.5)
		if q == null:
			continue
		var qv: Vector2 = q
		var yaw := ctx.base_yaw + rng.randf_range(-PI, PI)
		var rot := Basis(Vector3.UP, yaw)
		ctx.add(qv, pr)
		for j in n:
			var lo := rot * Vector3(
				(j - (n - 1) * 0.5) * (float(sz[0]) + 0.16), 0.0, rng.randf_range(-0.5, 0.5)
			)
			var p := qv + Vector2(lo.x, lo.z)
			out.append(
				_ground(
					ctx,
					"bag",
					vname,
					p,
					yaw + rng.randf_range(-0.12, 0.12),
					_pick_color(rng, palette, true),
					cfg
				)
			)
		anchors.append([qv, pr])
	# 4. Рюкзаки и подвески
	var harness_at: Array = []
	for i in n_harness:
		var vname := "harness_pack" if rng.randf() < 0.6 else "harness_open"
		var sz: Array = _size(variants, vname)
		var hr := _hyp(float(sz[0]) * 0.5, float(sz[1]) * 0.5) + 0.1
		var anchor: Array = anchors if (not anchors.is_empty() and rng.randf() < 0.5) else []
		var q: Variant = ctx.find_spot(rng, hr, anchor, 0.3)
		if q == null:
			continue
		var qv: Vector2 = q
		ctx.add(qv, hr)
		harness_at.append([qv, hr])
		out.append(
			_ground(
				ctx,
				"harness",
				vname,
				qv,
				ctx.base_yaw + rng.randf_range(-PI, PI),
				_pick_color(rng, palette, true),
				cfg
			)
		)
	# 5. Шлемы (у рюкзаков) и бутылки (где придётся, чаще у вещей)
	var near: Array = harness_at if not harness_at.is_empty() else anchors
	for i in n_helmet:
		var q: Variant = ctx.find_spot(rng, 0.2, near, 0.2)
		if q == null:
			continue
		var qv: Vector2 = q
		ctx.add(qv, 0.2)
		out.append(
			_ground(
				ctx,
				"helmet",
				"helmet",
				qv,
				ctx.base_yaw + rng.randf_range(-PI, PI),
				_pick_color(rng, palette, true),
				cfg
			)
		)
	var all_near: Array = anchors + harness_at
	for i in n_bottle:
		var q: Variant = ctx.find_spot(rng, 0.15, all_near, 0.2)
		if q == null:
			continue
		var qv: Vector2 = q
		ctx.add(qv, 0.15)
		out.append(
			_ground(ctx, "bottle", "bottle", qv, ctx.base_yaw + rng.randf_range(-PI, PI), -1, cfg)
		)
	_trim_to_budget(out, cfg)
	return out


static func _hyp(a: float, b: float) -> float:
	return Vector2(a, b).length()


static func _count(counts: Dictionary, key: String, rng: RandomNumberGenerator) -> int:
	var a: Array = counts.get(key, [0, 0])
	return rng.randi_range(int(a[0]), int(a[1]))


static func _size(variants: Dictionary, name: String) -> Array:
	return (variants.get(name, {}) as Dictionary).get("size_m", [0.3, 0.3, 0.3])


static func _pick_color(rng: RandomNumberGenerator, palette: Array, tinted: bool) -> int:
	return rng.randi_range(0, palette.size() - 1) if tinted else -1


## Вещь на земле: высота, наклон по рельефу, поворот (yaw — вокруг +Y, −Z модели → направление).
static func _ground(
	ctx: _Ctx, kind: String, variant: String, p: Vector2, yaw: float, color: int, cfg: Dictionary
) -> Dictionary:
	var sz: Array = _size(cfg.get("variants", {}), variant)
	var hx := float(sz[0]) * 0.5
	var hz := float(sz[1]) * 0.5
	var r := clampf(hz, 0.3, 2.5)
	var hf: Callable = ctx.height_fn
	var n := Vector3(
		float(hf.call(p.x - r, p.y)) - float(hf.call(p.x + r, p.y)),
		2.0 * r,
		float(hf.call(p.x, p.y - r)) - float(hf.call(p.x, p.y + r))
	).normalized()
	var tilt := Basis(Quaternion(Vector3.UP, n))
	var y := float(hf.call(p.x, p.y)) - float(cfg.get("sink_m", 0.02))
	var pos := Vector3(p.x, y, p.y)
	return {
		"kind": kind,
		"variant": variant,
		"position": pos,
		"basis": tilt * Basis(Vector3.UP, yaw),
		"yaw": yaw,
		"color": color,
		"radius_m": _hyp(hx, hz),
		"box": Vector3(hx, hz, float(sz[2])) if kind in OBSTACLE_KINDS else Vector3.ZERO,
		"center": pos,
	}


## Оценка треугольников вблизи; сверх бюджета — убираем с конца (бутылки, шлемы, рюкзаки, чехлы, крылья > 2).
static func _trim_to_budget(items: Array[Dictionary], cfg: Dictionary) -> void:
	var budget := int(cfg.get("budget_near_tris", 70000))
	var variants: Dictionary = cfg.get("variants", {})
	for order: String in ["bottle", "helmet", "harness", "bag", "wing"]:
		while _near_tris(items, variants) > budget:
			var idx := -1
			var n_wings := 0
			for i in items.size():
				if items[i].kind == "wing":
					n_wings += 1
			for i in range(items.size() - 1, -1, -1):
				if items[i].kind == order:
					idx = i
					break
			if idx < 0 or (order == "wing" and n_wings <= 2):
				break
			items.remove_at(idx)


static func _near_tris(items: Array[Dictionary], variants: Dictionary) -> int:
	var t := 0
	for it in items:
		if it.kind == "wing":
			t += int(wing_pose(String(it.variant)).tris_near)
		else:
			t += int((variants.get(String(it.variant), {}) as Dictionary).get("tris", [0, 0])[0])
	return t


# ---------------------------------------------------------------------------------------------
# Поза крыла
# ---------------------------------------------------------------------------------------------


## Геометрия модели крыла glider_<id>.glb для постановки на штангу (считается один раз на модель):
## nose — передний конец киля, bar_l/bar_r — нижние точки концов базовой штанги (колёса), span,
## aabb — габарит модели, tris_near/tris_far — треугольники целиком / без трапеции. Модель — в осях
## HangPoint, нос в −Z. Нет файла — запасные числа.
static func wing_pose(id: String) -> Dictionary:
	if _poses.has(id):
		return _poses[id]
	var pose := {
		"nose": Vector3(0.0, 0.0, -1.25),
		"bar_l": Vector3(-0.7, -1.5, -0.75),
		"bar_r": Vector3(0.7, -1.5, -0.75),
		"span": 10.0,
		"aabb": AABB(Vector3(-5.0, -1.55, -1.3), Vector3(10.0, 1.6, 3.0)),
		"tris_near": 14000,
		"tris_far": 9000,
		"glb": "",
	}
	var path := String(Config.get_config("wings/" + id).get("visual", {}).get("visual_model", ""))
	if path != "" and ResourceLoader.exists(path):
		var scene := load(path) as PackedScene
		var inst: Node = scene.instantiate() if scene != null else null
		if inst != null:
			pose.glb = path
			var sail := inst.find_child("Sail", true, false) as MeshInstance3D
			var frame := inst.find_child("Frame", true, false) as MeshInstance3D
			var cf := inst.find_child("ControlFrame", true, false) as MeshInstance3D
			var box := AABB()
			var first := true
			var tn := 0
			var tf := 0
			for mi: MeshInstance3D in [sail, frame, cf]:
				if mi == null:
					continue
				var bb := mi.get_aabb()
				box = bb if first else box.merge(bb)
				first = false
				var t := _mesh_tris(mi.mesh)
				tn += t
				if mi != cf:
					tf += t
			pose.aabb = box
			pose.tris_near = tn
			pose.tris_far = tf
			if sail != null:
				pose.span = sail.get_aabb().size.x
			if frame != null:
				var vs := _verts(frame.mesh)
				var zmin := INF
				for v in vs:
					zmin = minf(zmin, v.z)
				var acc := Vector3.ZERO
				var cnt := 0
				for v in vs:
					if v.z < zmin + 0.05:
						acc += v
						cnt += 1
				if cnt > 0:
					pose.nose = acc / cnt
			if cf != null:
				var vs := _verts(cf.mesh)
				var ymin := INF
				for v in vs:
					ymin = minf(ymin, v.y)
				var accl := Vector3.ZERO
				var accr := Vector3.ZERO
				var nl := 0
				var nr := 0
				for v in vs:
					if v.y < ymin + 0.04:
						if v.x < 0.0:
							accl += v
							nl += 1
						else:
							accr += v
							nr += 1
				if nl > 0 and nr > 0:
					pose.bar_l = accl / nl
					pose.bar_r = accr / nr
			inst.free()
	_poses[id] = pose
	return pose


static func _verts(mesh: Mesh) -> PackedVector3Array:
	var out := PackedVector3Array()
	for s in mesh.get_surface_count():
		out.append_array(mesh.surface_get_arrays(s)[Mesh.ARRAY_VERTEX])
	return out


static func _mesh_tris(mesh: Mesh) -> int:
	if mesh == null:
		return 0
	var t := 0
	for s in mesh.get_surface_count():
		var arr := mesh.surface_get_arrays(s)
		var idx: Variant = arr[Mesh.ARRAY_INDEX]
		if idx is PackedInt32Array and (idx as PackedInt32Array).size() > 0:
			t += (idx as PackedInt32Array).size() / 3
		else:
			t += (arr[Mesh.ARRAY_VERTEX] as PackedVector3Array).size() / 3
	return t


## Тангаж «нос и штанга на одной высоте» на ровной земле (рад, поворот вокруг X модели).
static func _pitch_flat(pose: Dictionary) -> float:
	var nose: Vector3 = pose.nose
	var bm: Vector3 = ((pose.bar_l as Vector3) + (pose.bar_r as Vector3)) * 0.5
	var dz := nose.z - bm.z
	if absf(dz) < 1.0e-4:
		return -0.5 * PI
	return atan((nose.y - bm.y) / dz)


## Габарит крыла в позе на ровной земле: cz — сдвиг центра коробки от середины штанги вдоль курса
## (знак — вдоль +Z модели до поворота), hz — полудлина, h — высота над землёй.
static func _wing_geom(pose: Dictionary) -> Dictionary:
	var bb: AABB = pose.aabb
	var b := Basis(Vector3.RIGHT, _pitch_flat(pose))
	var bm: Vector3 = ((pose.bar_l as Vector3) + (pose.bar_r as Vector3)) * 0.5
	var bmr := b * bm
	var z0 := INF
	var z1 := -INF
	var y1 := -INF
	for i in 8:
		var c := b * bb.get_endpoint(i)
		z0 = minf(z0, c.z)
		z1 = maxf(z1, c.z)
		y1 = maxf(y1, c.y)
	return {"cz": (z0 + z1) * 0.5 - bmr.z, "hz": (z1 - z0) * 0.5, "h": y1 - bmr.y}


## Поза крыла: середина штанги в мире (bm_xz), курс psi (рад вокруг +Y) → {position (HangPoint), basis}.
## Нос и концы штанги — на земле: тангаж подгоняется под уклон вдоль курса, крен — поперёк.
static func _wing_place(pose: Dictionary, bm_xz: Vector2, psi: float, hf: Callable) -> Dictionary:
	var nose: Vector3 = pose.nose
	var bl: Vector3 = pose.bar_l
	var br: Vector3 = pose.bar_r
	var bm := (bl + br) * 0.5
	var dy := nose.y - bm.y
	var dz := nose.z - bm.z
	var phi := _pitch_flat(pose)
	var rr := _hyp(dy, dz)
	var alpha := atan2(dz, dy)
	var yaw_b := Basis(Vector3.UP, psi)
	var h0 := float(hf.call(bm_xz.x, bm_xz.y))
	for _i in 3:
		var b := yaw_b * Basis(Vector3.RIGHT, phi)
		var o := b * (nose - bm)
		var dh := float(hf.call(bm_xz.x + o.x, bm_xz.y + o.z)) - h0
		var c := clampf(dh / maxf(rr, 0.01), -0.95, 0.95)
		var c1 := acos(c) - alpha
		var c2 := -acos(c) - alpha
		phi = c1 if absf(wrapf(c1 - phi, -PI, PI)) < absf(wrapf(c2 - phi, -PI, PI)) else c2
	var base := yaw_b * Basis(Vector3.RIGHT, phi)
	# крен: концы штанги на разной высоте (поперечный уклон)
	var ol := base * (bl - bm)
	var orr := base * (br - bm)
	var hl := float(hf.call(bm_xz.x + ol.x, bm_xz.y + ol.z))
	var hr := float(hf.call(bm_xz.x + orr.x, bm_xz.y + orr.z))
	var width := maxf(absf(orr.x - ol.x) + absf(orr.z - ol.z), 0.2)
	var fwd := yaw_b * Vector3(0.0, 0.0, -1.0)
	var basis := Basis(fwd, -atan2(hr - hl, width)) * base
	var pos_xz := bm_xz - Vector2((basis * bm).x, (basis * bm).z)
	var ys := 0.0
	for lp: Vector3 in [nose, bl, br]:
		var off := basis * lp
		ys += float(hf.call(pos_xz.x + off.x, pos_xz.y + off.z)) - off.y
	return {"position": Vector3(pos_xz.x, ys / 3.0, pos_xz.y), "basis": basis}


# ---------------------------------------------------------------------------------------------
# Контекст места
# ---------------------------------------------------------------------------------------------


class _Ctx:
	var s: Vector2
	var fwd: Vector2
	var right: Vector2
	var base_yaw: float
	var cfg: Dictionary
	var height_fn: Callable
	var blocked_fn: Callable
	var lines: Array
	var points: Array
	var placed: Array = []  ## [[Vector2 центр, радиус]]
	var d_lo: float
	var d_hi: float
	var prefer: float
	var along_max: float
	var corr_behind: float
	var corr_half: float
	var max_slope: float
	var cliff_probe: float
	var cliff_slope: float
	var margin: float
	var attempts: int
	var gap: float
	var _hmemo: Dictionary = {}

	func _init(start: Vector3, heading_deg: float, c: Dictionary, env: Dictionary) -> void:
		s = Vector2(start.x, start.z)
		var h := TerrainGeo.heading_vector(heading_deg)
		fwd = Vector2(h.x, h.z).normalized()
		right = Vector2(-fwd.y, fwd.x)
		base_yaw = atan2(-fwd.x, -fwd.y)
		cfg = c
		height_fn = env.height_fn
		blocked_fn = env.get("blocked_fn", Callable())
		lines = env.get("lines", [])
		points = (env.get("points", []) as Array).duplicate()
		d_lo = float(c.get("distance_m", [6.0, 28.0])[0])
		d_hi = float(c.get("distance_m", [6.0, 28.0])[1])
		prefer = float(c.get("prefer_distance_m", 17.0))
		along_max = float(c.get("along_max_m", -3.0))
		corr_behind = float(c.get("corridor_behind_m", 8.0))
		corr_half = float(c.get("corridor_half_width_m", 9.0))
		if FileAccess.file_exists("res://configs/bots.json"):
			var lc: Dictionary = Config.get_config("bots").get("launch", {})
			corr_half = float(lc.get("corridor_half_width_m", corr_half))
		corr_half += float(c.get("corridor_margin_m", 2.0))
		max_slope = float(c.get("max_slope_deg", 8.0))
		cliff_probe = float(c.get("cliff_probe_m", 4.0))
		cliff_slope = float(c.get("cliff_slope_deg", 14.0))
		margin = float(c.get("scatter_margin_m", 0.3))
		attempts = int(c.get("attempts", 60))
		gap = float(c.get("gap_m", 0.5))
		var points_fn: Callable = env.get("points_fn", Callable())
		if points_fn.is_valid():
			points.append_array(points_fn.call(s, d_hi + 8.0))

	func add(p: Vector2, r: float) -> void:
		placed.append([p, r])

	func h(p: Vector2) -> float:
		var k := Vector2i(roundi(p.x * 2.0), roundi(p.y * 2.0))
		if not _hmemo.has(k):
			_hmemo[k] = float(height_fn.call(p.x, p.y))
		return _hmemo[k]

	func slope_deg(p: Vector2, r: float) -> float:
		var h0 := h(p)
		var worst := 0.0
		for k in 8:
			worst = maxf(worst, absf(h(p + Vector2.from_angle(k * TAU / 8.0) * r) - h0))
		return rad_to_deg(atan2(worst, r))

	## Круг радиуса r в центре p: допустим ли по SC-K1 (кольцо, коридор, запреты, зазоры, уклон).
	func fits(p: Vector2, r: float, gap: float) -> bool:
		var v := p - s
		var d := v.length()
		if d < d_lo or d > d_hi:
			return false
		var along := v.dot(fwd)
		var lat := v.dot(right)
		if along > along_max:
			return false
		if along > -corr_behind - r and absf(lat) < corr_half + r:
			return false
		for q: Array in placed:
			if p.distance_to(q[0]) < float(q[1]) + r + gap:
				return false
		for l: Array in lines:
			if TentCamp.dist_to_polyline(p, l[0]) < float(l[1]) + r:
				return false
		for o: Vector3 in points:
			if p.distance_to(Vector2(o.x, o.y)) < o.z + r + margin:
				return false
		if blocked_fn.is_valid():
			for k in 5:
				var q := p if k == 0 else p + Vector2.from_angle(k * TAU / 4.0) * r
				if blocked_fn.call(q.x, q.y):
					return false
		var sr := minf(r, 3.0)
		if slope_deg(p, sr) > max_slope:
			return false
		return slope_deg(p, sr + cliff_probe) <= cliff_slope

	## Место для круга r: рядом с кругами anchors ([[центр, радиус]]) или в кольце от старта.
	## null — места нет.
	func find_spot(rng: RandomNumberGenerator, r: float, anchors: Array, gap_: float) -> Variant:
		var g := gap_
		for attempt in attempts:
			var p: Vector2
			if not anchors.is_empty() and attempt < attempts * 2 / 3:
				var a: Array = anchors[rng.randi_range(0, anchors.size() - 1)]
				var ang := rng.randf() * TAU
				p = (a[0] as Vector2) + Vector2.from_angle(ang) * (float(a[1]) + r + g + rng.randf() * 1.5)
			else:
				var dist := clampf(
					prefer + rng.randfn(0.0, 6.0) if attempt % 2 == 0 else rng.randf_range(d_lo, d_hi),
					d_lo,
					d_hi
				)
				# позади старта (полуплоскость along < 0), чаще — сбоку от коридора
				var ang := rng.randf_range(-0.5 * PI, 0.5 * PI)
				var dir := -fwd * cos(ang) + right * sin(ang)
				p = s + dir.normalized() * dist
			if fits(p, r, g):
				return p
		return null


# ---------------------------------------------------------------------------------------------
# Визуал
# ---------------------------------------------------------------------------------------------


## Узел набора: крылья — glider_<id>.glb (трапеция дальше wing_detail_m не рисуется, всё крыло —
## дальше wing_visibility_m), мелочь — MultiMesh на вариант × LOD.
static func build_node(items: Array, cfg: Dictionary) -> Node3D:
	var root := Node3D.new()
	root.name = "StartGear"
	var lod_m := float(cfg.get("lod_m", 25.0))
	var detail_m := float(cfg.get("wing_detail_m", 120.0))
	var vis_m := float(cfg.get("wing_visibility_m", 900.0))
	var shadow := (
		GeometryInstance3D.SHADOW_CASTING_SETTING_ON
		if bool(cfg.get("cast_shadows", true))
		else GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	)
	var palette: Array = cfg.get("colors", [[1, 1, 1]])
	var groups: Dictionary = {}
	var wi := 0
	for it: Dictionary in items:
		if it.kind == "wing":
			var node := _wing_node(String(it.variant))
			if node == null:
				continue
			node.name = "Wing_%d_%s" % [wi, it.variant]
			wi += 1
			node.transform = Transform3D(it.basis, it.position)
			root.add_child(node)
			for m in node.find_children("*", "MeshInstance3D", true, false):
				var mi := m as MeshInstance3D
				mi.cast_shadow = shadow
				mi.visibility_range_begin = 0.0
				mi.visibility_range_end = detail_m if mi.name == &"ControlFrame" else vis_m
		else:
			var v := String(it.variant)
			if not groups.has(v):
				groups[v] = []
			(groups[v] as Array).append(it)
	for v: String in groups:
		var arr: Array = groups[v]
		var c := Vector3.ZERO
		for it: Dictionary in arr:
			c += it.position as Vector3
		c /= arr.size()
		var tint := bool((cfg.get("variants", {}).get(v, {}) as Dictionary).get("tint", true))
		for lod in 2:
			var mesh := variant_mesh(v, lod, cfg)
			if mesh == null:
				continue
			var mm := MultiMesh.new()
			mm.transform_format = MultiMesh.TRANSFORM_3D
			mm.use_colors = true
			mm.mesh = mesh
			mm.instance_count = arr.size()
			for i in arr.size():
				var it: Dictionary = arr[i]
				mm.set_instance_transform(
					i, Transform3D(it.basis, (it.position as Vector3) - c)
				)
				var col := Color.WHITE
				var ci := int(it.color)
				if tint and ci >= 0:
					var rgb: Array = palette[ci % palette.size()]
					col = Color(float(rgb[0]), float(rgb[1]), float(rgb[2]))
				mm.set_instance_color(i, col)
			var mmi := MultiMeshInstance3D.new()
			mmi.name = "%s_LOD%d" % [v, lod]
			mmi.multimesh = mm
			mmi.position = c
			mmi.cast_shadow = shadow
			mmi.visibility_range_begin = 0.0 if lod == 0 else lod_m
			mmi.visibility_range_end = lod_m if lod == 0 else detail_m
			root.add_child(mmi)
	return root


static func _wing_node(id: String) -> Node3D:
	var pose := wing_pose(id)
	var path := String(pose.glb)
	if path == "":
		push_warning("StartGear: нет модели крыла %s" % id)
		return null
	return (load(path) as PackedScene).instantiate() as Node3D


## Меш варианта и LOD: нода <вариант>_LOD<n> из glb SC-K3 или временный простой меш тех же размеров.
## Материалы заменены по именам SC-K3 (ткань — CampFabric, шлем — тон вершин).
static func variant_mesh(variant: String, lod: int, cfg: Dictionary) -> Mesh:
	var key := "%s|%d" % [variant, lod]
	if _meshes.has(key):
		return _meshes[key]
	var mesh: Mesh = null
	var vc: Dictionary = (cfg.get("variants", {}) as Dictionary).get(variant, {})
	var path := String(
		cfg.get("model_kit", "") if String(vc.get("kind", "")).begins_with("kit_") else cfg.get("model_gear", "")
	)
	var src := _glb_mesh(path, "%s_LOD%d" % [variant, lod])
	if src != null:
		mesh = src.duplicate() as Mesh
	else:
		mesh = _temp_mesh(variant, lod, vc)
	_map_materials(mesh, cfg)
	_meshes[key] = mesh
	return mesh


static func _glb_mesh(path: String, node_name: String) -> Mesh:
	if path == "" or not ResourceLoader.exists(path):
		return null
	if not _glb_loaded.has(path):
		_glb_loaded[path] = true
		var inst := (load(path) as PackedScene).instantiate()
		for mi in inst.find_children("*", "MeshInstance3D", true, false):
			_glb_meshes["%s|%s" % [path, mi.name]] = (mi as MeshInstance3D).mesh
		inst.free()
	return _glb_meshes.get("%s|%s" % [path, node_name])


static func _map_materials(mesh: Mesh, cfg: Dictionary) -> void:
	for s in mesh.get_surface_count():
		var m := mesh.surface_get_material(s)
		if m == null:
			continue
		var n := String(m.resource_name)
		if FABRIC_PRESETS.has(n):
			mesh.surface_set_material(s, _fabric(String(FABRIC_PRESETS[n]), cfg))
		elif n in TINTED_STD and m is BaseMaterial3D:
			var key := "tint|" + n
			if not _std_cache.has(key):
				var d := m.duplicate() as BaseMaterial3D
				d.vertex_color_use_as_albedo = true
				_std_cache[key] = d
			mesh.surface_set_material(s, _std_cache[key])


## Ткань лагеря (SC-K5): CampFabric.material(preset) через load() — класс может быть ещё не слит;
## нет — StandardMaterial3D, тон — цвет экземпляра MultiMesh.
static func _fabric(preset: String, cfg: Dictionary) -> Material:
	if _fabric_cache.has(preset):
		return _fabric_cache[preset]
	var mat: Material = null
	var path := String(cfg.get("fabric_script", ""))
	if path != "" and ResourceLoader.exists(path):
		var sc := load(path) as GDScript
		if sc != null:
			mat = sc.call(&"material", preset) as Material
	if mat == null:
		var s := StandardMaterial3D.new()
		s.resource_name = preset
		s.roughness = 0.85
		s.cull_mode = BaseMaterial3D.CULL_DISABLED
		if preset == "fabric_dark":
			s.albedo_color = Color(0.12, 0.12, 0.13)
		else:
			s.vertex_color_use_as_albedo = true
		mat = s
	_fabric_cache[preset] = mat
	return mat


# --- временные меши (нет glb SC-K3) ---


static func _temp_mat(name: String) -> StandardMaterial3D:
	var key := "temp|" + name
	if _std_cache.has(key):
		return _std_cache[key]
	var m := StandardMaterial3D.new()
	m.resource_name = name
	m.roughness = 0.8
	match name:
		"Tube", "Steel":
			m.albedo_color = Color(0.62, 0.64, 0.68)
			m.metallic = 0.6
			m.roughness = 0.4
		"Webbing":
			m.albedo_color = Color(0.1, 0.1, 0.1)
		"Bottle":
			m.albedo_color = Color(0.55, 0.75, 0.9)
		"Cap":
			m.albedo_color = Color(0.9, 0.9, 0.9)
		"Tire":
			m.albedo_color = Color(0.05, 0.05, 0.05)
		"Shell":
			m.vertex_color_use_as_albedo = true
		_:
			m.vertex_color_use_as_albedo = true
			m.cull_mode = BaseMaterial3D.CULL_DISABLED
	_std_cache[key] = m
	return m


## Простой меш варианта: [ширина x, длина z, высота y], низ y = 0, длинная ось вдоль Z.
static func _temp_mesh(variant: String, lod: int, vc: Dictionary) -> ArrayMesh:
	var sz: Array = vc.get("size_m", [0.3, 0.3, 0.3])
	var w := float(sz[0])
	var l := float(sz[1])
	var h := float(sz[2])
	var parts: Array = []  # [PrimitiveMesh, Transform3D, имя материала]
	var seg := 8 if lod == 0 else 4
	var lay := Basis(Vector3.RIGHT, PI * 0.5)  # ось Y примитива → вдоль Z
	match variant:
		"wing_bag_long", "wing_bag_short":
			var cap := CapsuleMesh.new()
			cap.radius = 0.5
			cap.height = 1.0
			cap.radial_segments = seg
			cap.rings = 2
			var xf := Transform3D(lay * Basis.from_scale(Vector3(w, l, h)), Vector3(0, h * 0.5, 0))
			parts.append([cap, xf, "Fabric"])
		"harness_pack", "harness_open":
			var box := BoxMesh.new()
			box.size = Vector3(w, h, l)
			parts.append([box, Transform3D(Basis.IDENTITY, Vector3(0, h * 0.5, 0)), "Fabric"])
		"helmet":
			var sph := SphereMesh.new()
			sph.radius = 0.5
			sph.height = 1.0
			sph.is_hemisphere = true
			sph.radial_segments = seg
			sph.rings = 3
			parts.append([sph, Transform3D(Basis.from_scale(Vector3(w, h * 2.0, l)), Vector3.ZERO), "Shell"])
		"bottle":
			var cyl := CylinderMesh.new()
			cyl.top_radius = w * 0.5
			cyl.bottom_radius = w * 0.5
			cyl.height = l
			cyl.radial_segments = seg
			cyl.rings = 1
			parts.append([cyl, Transform3D(lay, Vector3(0, w * 0.5, 0)), "Bottle"])
		"kit_bundle":
			var bag := BoxMesh.new()
			bag.size = Vector3(w, 0.05, l)
			parts.append([bag, Transform3D(Basis.IDENTITY, Vector3(0, 0.025, 0)), "Fabric"])
			var roll := CapsuleMesh.new()
			roll.radius = 0.2
			roll.height = l - 0.2
			roll.radial_segments = seg
			roll.rings = 2
			parts.append([roll, Transform3D(lay, Vector3(0, 0.25, 0)), "Sail"])
			var tube := CylinderMesh.new()
			tube.top_radius = 0.025
			tube.bottom_radius = 0.025
			tube.height = l - 0.1
			tube.radial_segments = 6
			tube.rings = 1
			parts.append([tube, Transform3D(lay, Vector3(0.12, 0.1, 0)), "Tube"])
		"kit_frame":
			# трапеция плашмя: две стойки от вершины (к −Z) и базовая штанга поперёк
			var apex := Vector3(0.0, 0.04, -l * 0.5)
			for sgn in [-1.0, 1.0]:
				var foot := Vector3(sgn * 0.7, 0.04, l * 0.5)
				parts.append([_rod(apex, foot, 0.02, seg), Transform3D.IDENTITY, "Tube"])
			parts.append(
				[
					_rod(Vector3(-0.7, 0.04, l * 0.5), Vector3(0.7, 0.04, l * 0.5), 0.02, seg),
					Transform3D.IDENTITY,
					"Tube"
				]
			)
			for sgn in [-1.0, 1.0]:
				var wheel := CylinderMesh.new()
				wheel.top_radius = 0.1
				wheel.bottom_radius = 0.1
				wheel.height = 0.05
				wheel.radial_segments = seg
				wheel.rings = 1
				parts.append(
					[
						wheel,
						Transform3D(Basis(Vector3.BACK, PI * 0.5), Vector3(sgn * 0.72, 0.1, l * 0.5)),
						"Tire"
					]
				)
		_:
			var b := BoxMesh.new()
			b.size = Vector3(w, h, l)
			parts.append([b, Transform3D(Basis.IDENTITY, Vector3(0, h * 0.5, 0)), "Fabric"])
	if lod > 0:
		# дальний силуэт: один параллелепипед габарита
		var b := BoxMesh.new()
		b.size = Vector3(w, h, l)
		parts = [[b, Transform3D(Basis.IDENTITY, Vector3(0, h * 0.5, 0)), "Fabric"]]
	var mesh := ArrayMesh.new()
	var by_mat: Dictionary = {}
	for p: Array in parts:
		var mname := String(p[2])
		if not by_mat.has(mname):
			by_mat[mname] = SurfaceTool.new()
			(by_mat[mname] as SurfaceTool).begin(Mesh.PRIMITIVE_TRIANGLES)
		(by_mat[mname] as SurfaceTool).append_from(p[0] as Mesh, 0, p[1] as Transform3D)
	for mname: String in by_mat:
		var st: SurfaceTool = by_mat[mname]
		st.commit(mesh)
		mesh.surface_set_material(mesh.get_surface_count() - 1, _temp_mat(mname))
	return mesh


## Тонкий цилиндр между двумя точками (мировые координаты меша).
static func _rod(a: Vector3, b: Vector3, radius: float, seg: int) -> ArrayMesh:
	var cyl := CylinderMesh.new()
	cyl.top_radius = radius
	cyl.bottom_radius = radius
	cyl.height = a.distance_to(b)
	cyl.radial_segments = maxi(seg - 2, 4)
	cyl.rings = 1
	var y := (b - a).normalized()
	var x := y.cross(Vector3.UP if absf(y.y) < 0.99 else Vector3.RIGHT).normalized()
	var z := x.cross(y)
	var xf := Transform3D(Basis(x, y, z), (a + b) * 0.5)
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	st.append_from(cyl, 0, xf)
	return st.commit()


# ---------------------------------------------------------------------------------------------
# Замеры (отчёт SC-2)
# ---------------------------------------------------------------------------------------------


## Треугольники и вызовы отрисовки набора на расстоянии dist от камеры (по visibility_range узлов):
## {tris, tris_small, draw_calls_small}. Вблизи — dist < wing_detail_m, вдали — больше.
static func stats(root: Node3D, dist: float) -> Dictionary:
	var tris := 0
	var tris_small := 0
	var calls := 0
	for n in root.find_children("*", "GeometryInstance3D", true, false):
		var g := n as GeometryInstance3D
		if dist < g.visibility_range_begin or (g.visibility_range_end > 0.0 and dist >= g.visibility_range_end):
			continue
		if g is MultiMeshInstance3D:
			var mm := (g as MultiMeshInstance3D).multimesh
			var t := _mesh_tris(mm.mesh) * mm.instance_count
			tris += t
			tris_small += t
			calls += mm.mesh.get_surface_count()
		elif g is MeshInstance3D:
			tris += _mesh_tris((g as MeshInstance3D).mesh)
	return {"tris": tris, "tris_small": tris_small, "draw_calls_small": calls}
