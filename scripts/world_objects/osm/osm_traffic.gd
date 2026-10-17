class_name OsmTraffic
extends Node3D
## Машинки на дорогах OSM (osm-traffic): легковушки, фургоны, грузовики едут по ломаным OsmData.roads
## (без тоннелей) вокруг камеры. Конфиг — world_objects.json → osm_traffic.
## Правила: на конце ломаной машина ищет по индексу ВСЕХ точек дорог (допуск join_tol_m) исходящие
## направления в этой точке и берёт с наименьшим углом поворота (в общей точке середины другой дороги —
## вперёд и назад по ней); нет продолжения или угол > turn_max_deg — остановка и разворот.
## Следующее ребро выбирается заранее (при въезде на дорогу) — видно машины за стыком и тормозить
## перед поворотом по углу. Следование без обгонов (списки машин по (дорога, направление), отсортированные
## по прогрессу), перекрёстки без правил. Вокруг камеры radius_m, не больше max_cars; ушедшая за радиус
## машина переставляется в кольцо у границы, где масштаб уже гасится в ноль. Локально, без сети.
## Модели: assets/models/osm/{car,van,truck}.glb (tools/blender/build_osm_traffic.py), по MultiMesh на тип.

const MODEL_PATH := "res://assets/models/osm/%s.glb"
const KMH := 1.0 / 3.6
const SEG_CELL := 500.0

var _c: Dictionary = {}
var _height_fn: Callable
var _rng := RandomNumberGenerator.new()

# --- сеть (строится в рабочем потоке)
var r_pts: Array = []                 # PackedVector2Array на дорогу
var r_cum: Array = []                 # PackedFloat32Array
var r_len := PackedFloat32Array()
var r_vd := PackedFloat32Array()      # лимит класса, м/с
var r_off := PackedFloat32Array()     # смещение вправо от оси, м
var r_dens := PackedFloat32Array()    # машин на км
var pt_road := PackedInt32Array()
var pt_idx := PackedInt32Array()
var pt_next := PackedInt32Array()
var pt_head := {}                     # ключ ячейки 1 м → первая точка цепочки
var smp_pos := PackedVector2Array()   # точки появления (шаг sample_step_m)
var smp_road := PackedInt32Array()
var smp_s := PackedFloat32Array()
var smp_w := PackedFloat32Array()     # машин на точку
var smp_cells := {}                   # Vector2i → PackedInt32Array
var _task := -1
var ready_net := false
var auto := true                      # false — без автопоявления/перестановки (тесты)

# --- машины
var cars: Array[Car] = []
var types: Array[Dictionary] = []     # {name, cfg, mm, mmi, count}
var _lanes := {}                      # ключ дорога*2+(dir>0?0:1) → Array[Car] по прогрессу
var _center := Vector3.ZERO
var _has_center := false
var _last_refresh_c := Vector2(1e9, 1e9)
var _refresh_t := 0.0
var _disk_ids := PackedInt32Array()
var _disk_cum := PackedFloat32Array()
var _ring_ids := PackedInt32Array()
var _ring_cum := PackedFloat32Array()
var _target := 0
var _fill_disk := true
var _frame_ms := 0.0                  # последний замер step, мс


class Car:
	extends RefCounted
	var type := 0
	var slot := 0
	var active := false
	var road := 0
	var dir := 1
	var s := 0.0
	var v := 0.0
	var vd := 0.0
	var length := 4.2
	var wb := 2.6
	var acc := 2.0
	var next_road := -1
	var next_dir := 1
	var next_idx := 0
	var v_end := 0.0
	var p := 0.0          # прогресс по ходу (на начало кадра)
	var lane_i := 0
	var pos := Vector3.ZERO
	var scale := 0.0
	var shown := false
	var color_i := 0
	var seg := -1         # кэш сегмента ломаной (-1 — найти заново)
	var acc_dt := 0.0
	var group := 0
	var lane_key := -1


## Узел трафика или null. Сеть строится в рабочем потоке (без блокировки), машины появляются, когда готова.
static func build(data: OsmData, cfg: Dictionary, height_fn: Callable, _obstacles: ObstacleIndex) -> Node3D:
	var tc: Dictionary = cfg.get("osm_traffic", {})
	if data == null or tc.is_empty() or not bool(tc.get("enabled", true)) or data.roads.is_empty():
		return null
	var node := OsmTraffic.new()
	node.setup(tc, cfg, height_fn, true)
	node.start_net(data.roads, cfg)
	return node


func _init() -> void:
	name = "Traffic"


func setup(tc: Dictionary, _cfg: Dictionary, height_fn: Callable, with_models: bool) -> void:
	_c = tc
	_height_fn = height_fn
	_rng.seed = 12345
	var tnames: Array = []
	for k in (tc.types as Dictionary):
		if not String(k).begins_with("_"):
			tnames.append(String(k))
	var total := 0
	for i in tnames.size():
		var tcfg: Dictionary = tc.types[tnames[i]]
		var n := int(round(float(tc.max_cars) * float(tcfg.share)))
		var e := {"name": tnames[i], "cfg": tcfg, "count": n, "mm": null, "mmi": null}
		types.append(e)
		for k in n:
			var c := Car.new()
			c.type = i
			c.slot = k
			c.length = float(tcfg.length_m)
			c.wb = float(tcfg.wheelbase_m)
			c.acc = float(tcfg.accel_ms2)
			cars.append(c)
		total += n
	if with_models:
		for e: Dictionary in types:
			_make_mm(e)


func _make_mm(e: Dictionary) -> void:
	var ps := load(MODEL_PATH % e.name) as PackedScene
	if ps == null:
		push_warning("OsmTraffic: нет модели " + String(e.name))
		return
	var inst := ps.instantiate()
	var mi := _first_mesh(inst)
	if mi == null:
		inst.free()
		return
	var mesh := mi.mesh.duplicate() as Mesh
	inst.free()
	for si in mesh.get_surface_count():
		var src := mesh.surface_get_material(si)
		var mname := src.resource_name if src != null else ""
		var m := StandardMaterial3D.new()
		m.cull_mode = BaseMaterial3D.CULL_DISABLED
		match mname:
			"paint":
				m.albedo_color = Color.WHITE
				m.vertex_color_use_as_albedo = true  # цвет экземпляра MultiMesh
				m.roughness = 0.35
				m.metallic = 0.1
			"cargo":
				m.albedo_color = Color(0.58, 0.6, 0.62)
				m.roughness = 0.6
			"glass":
				m.albedo_color = Color(0.03, 0.04, 0.06)
				m.roughness = 0.1
				m.metallic = 0.3
			_:
				m.albedo_color = Color(0.03, 0.03, 0.035)
				m.roughness = 0.8
		mesh.surface_set_material(si, m)
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.use_colors = true
	mm.mesh = mesh
	mm.instance_count = maxi(int(e.count), 1)
	mm.custom_aabb = AABB(Vector3(-60000, -2000, -60000), Vector3(120000, 12000, 120000))
	for i in mm.instance_count:
		mm.set_instance_transform(i, Transform3D(Basis.from_scale(Vector3.ZERO), Vector3.ZERO))
	var mmi := MultiMeshInstance3D.new()
	mmi.multimesh = mm
	mmi.name = String(e.name).capitalize()
	mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(mmi)
	e.mm = mm
	e.mmi = mmi


static func _first_mesh(n: Node) -> MeshInstance3D:
	if n is MeshInstance3D:
		return n
	for ch in n.get_children():
		var r := _first_mesh(ch)
		if r != null:
			return r
	return null


# --- сеть ---------------------------------------------------------------------------------------

func start_net(roads: Array, cfg: Dictionary) -> void:
	_task = WorkerThreadPool.add_task(_build_net.bind(roads, cfg), false, "osm_traffic_net")


## Дождаться сети (тесты).
func wait_net() -> void:
	if _task >= 0:
		WorkerThreadPool.wait_for_task_completion(_task)
		_task = -1


func _exit_tree() -> void:
	wait_net()


## Узел освобождают вне дерева (тесты, слой не в сцене) — сеть ещё строится в потоке: дождаться.
func _notification(what: int) -> void:
	if what == NOTIFICATION_PREDELETE:
		wait_net()


static func cell_key(x: float, z: float) -> int:
	return (floori(x) + 1048576) * 2097152 + (floori(z) + 1048576)


func _build_net(roads: Array, cfg: Dictionary) -> void:
	var tc := _c
	var cls: Dictionary = tc.classes
	var rcls: Dictionary = cfg.get("roads", {}).get("classes", {})
	var min_len := float(tc.min_road_m)
	var step := float(tc.sample_step_m)
	var lane_frac := float(tc.lane_offset_frac)
	for r: Dictionary in roads:
		if bool(r.get("tunnel", false)):
			continue
		var t := String(r.t)
		if t.begins_with("_") or not cls.has(t):
			continue
		var p: PackedVector2Array = r.p
		if p.size() < 2:
			continue
		var cum := PackedFloat32Array()
		cum.resize(p.size())
		var acc := 0.0
		for i in p.size():
			if i > 0:
				acc += p[i].distance_to(p[i - 1])
			cum[i] = acc
		if acc < min_len:
			continue
		var id := r_pts.size()
		r_pts.append(p)
		r_cum.append(cum)
		r_len.append(acc)
		r_vd.append(float(cls[t][0]) * KMH)
		r_dens.append(float(cls[t][1]))
		var w: float = float(rcls[t][0]) if rcls.has(t) else 5.0
		r_off.append(w * lane_frac)
		for i in p.size():
			var key := cell_key(p[i].x, p[i].y)
			var gid := pt_road.size()
			pt_road.append(id)
			pt_idx.append(i)
			pt_next.append(int(pt_head.get(key, -1)))
			pt_head[key] = gid
		# точки появления
		var dens := float(cls[t][1])
		if dens > 0.0:
			var n := maxi(1, int(acc / step))
			for k in n:
				var s := (k + 0.5) * acc / n
				var sp := _sample2(id, s)
				smp_pos.append(sp[0])
				smp_road.append(id)
				smp_s.append(s)
				smp_w.append(dens * acc / n / 1000.0)
				var ck := Vector2i(floori(sp[0].x / SEG_CELL), floori(sp[0].y / SEG_CELL))
				var ca: PackedInt32Array = smp_cells.get(ck, PackedInt32Array())
				ca.append(smp_pos.size() - 1)
				smp_cells[ck] = ca
	ready_net = true


static func _seg_search(cum: PackedFloat32Array, s: float) -> int:
	var lo := 0
	var hi := cum.size() - 1
	while hi - lo > 1:
		var mid := (lo + hi) >> 1
		if cum[mid] <= s:
			lo = mid
		else:
			hi = mid
	return lo


## Точка и единичная касательная (по росту s) на дороге r.
func _sample2(r: int, s: float) -> Array:
	var cum: PackedFloat32Array = r_cum[r]
	var p: PackedVector2Array = r_pts[r]
	s = clampf(s, 0.0, r_len[r])
	var lo := 0
	var hi := cum.size() - 1
	while hi - lo > 1:
		var mid := (lo + hi) >> 1
		if cum[mid] <= s:
			lo = mid
		else:
			hi = mid
	var seg := maxf(cum[lo + 1] - cum[lo], 1e-4)
	var f := (s - cum[lo]) / seg
	var d := (p[lo + 1] - p[lo])
	d = d / maxf(d.length(), 1e-6)
	return [p[lo].lerp(p[lo + 1], f), d]


## Исходящая единичная касательная в точке idx дороги r при движении dir (пропуская точки ближе 2 м).
func _out_tangent(r: int, idx: int, dir: int) -> Vector2:
	var p: PackedVector2Array = r_pts[r]
	var n := p.size()
	var j := idx + dir
	while j >= 0 and j < n:
		var d := p[j] - p[idx]
		if d.length() >= 2.0 or j == 0 or j == n - 1:
			return d.normalized() if d.length() > 1e-4 else Vector2.ZERO
		j += dir
	return Vector2.ZERO


## Следующее ребро для машины c в конце её дороги: заполняет next_*, v_end.
func choose_next(c: Car) -> void:
	var r := c.road
	var n := (r_pts[r] as PackedVector2Array).size()
	var end_idx := n - 1 if c.dir > 0 else 0
	var end_p: Vector2 = (r_pts[r] as PackedVector2Array)[end_idx]
	var din := -_out_tangent(r, end_idx, -c.dir)  # направление входа в конец
	var tol := float(_c.join_tol_m)
	var best := INF
	c.next_road = -1
	var max_ang := deg_to_rad(float(_c.turn_max_deg))
	var cx := floori(end_p.x)
	var cz := floori(end_p.y)
	for dx in range(-1, 2):
		for dz in range(-1, 2):
			var gid := int(pt_head.get(cell_key(cx + dx + 0.5, cz + dz + 0.5), -1))
			while gid >= 0:
				var r2 := pt_road[gid]
				var i2 := pt_idx[gid]
				gid = pt_next[gid]
				if r2 == r and absf((r_cum[r] as PackedFloat32Array)[i2] - (r_cum[r] as PackedFloat32Array)[end_idx]) < 5.0:
					continue
				var q: Vector2 = (r_pts[r2] as PackedVector2Array)[i2]
				if q.distance_to(end_p) > tol:
					continue
				var m2 := (r_pts[r2] as PackedVector2Array).size()
				for d2 in [1, -1]:
					if (d2 > 0 and i2 >= m2 - 1) or (d2 < 0 and i2 <= 0):
						continue
					var dout := _out_tangent(r2, i2, d2)
					if dout == Vector2.ZERO:
						continue
					var ang := acos(clampf(din.dot(dout), -1.0, 1.0))
					if ang > max_ang:
						continue
					var score := ang + _rng.randf() * 0.02
					if score < best:
						best = score
						c.next_road = r2
						c.next_dir = d2
						c.next_idx = i2
	if c.next_road < 0:
		c.v_end = 0.0
	else:
		c.v_end = _corner_speed(best, minf(c.vd, r_vd[c.next_road] * 1.15))


func _corner_speed(ang: float, vfree: float) -> float:
	var free := deg_to_rad(float(_c.turn_free_deg))
	if ang <= free:
		return vfree
	var v90 := float(_c.turn_speed_90_kmh) * KMH
	var half := PI * 0.5
	if ang < half:
		var f := (ang - free) / (half - free)
		return maxf(lerpf(vfree, v90, smoothstep(0.0, 1.0, f)), minf(v90, vfree))
	return maxf(v90 * (1.0 - (ang - half) / PI), 2.5)


# --- появление и перестановка -------------------------------------------------------------------

func _refresh(center: Vector3) -> void:
	var R := float(_c.radius_m)
	var r0 := R * float(_c.ring_min)
	var r1 := R * float(_c.ring_max)
	_disk_ids.resize(0)
	_disk_cum.resize(0)
	_ring_ids.resize(0)
	_ring_cum.resize(0)
	var c2 := Vector2(center.x, center.z)
	var cd := 0.0
	var cr := 0.0
	var total := 0.0
	var x0 := floori((c2.x - R) / SEG_CELL)
	var x1 := floori((c2.x + R) / SEG_CELL)
	var z0 := floori((c2.y - R) / SEG_CELL)
	var z1 := floori((c2.y + R) / SEG_CELL)
	for cx in range(x0, x1 + 1):
		for cz in range(z0, z1 + 1):
			var arr: PackedInt32Array = smp_cells.get(Vector2i(cx, cz), PackedInt32Array())
			for id in arr:
				var d := smp_pos[id].distance_to(c2)
				if d > R:
					continue
				var w := smp_w[id]
				total += w
				cd += w
				_disk_ids.append(id)
				_disk_cum.append(cd)
				if d >= r0 and d <= r1:
					cr += w
					_ring_ids.append(id)
					_ring_cum.append(cr)
	_target = mini(cars.size(), int(round(total)))
	_last_refresh_c = c2
	# лишние гасим, недостающие добавим в кольцо (или по диску при первой заливке)
	var active := 0
	for c in cars:
		if c.active:
			active += 1
	if active > _target:
		var k := active - _target
		for i in range(cars.size() - 1, -1, -1):
			if k <= 0:
				break
			if cars[i].active:
				cars[i].active = false
				k -= 1
	elif active < _target:
		var k2 := _target - active
		for c in cars:
			if k2 <= 0:
				break
			if not c.active:
				if _place(c, _fill_disk):
					k2 -= 1
	_fill_disk = false


func _pick(ids: PackedInt32Array, cum: PackedFloat32Array) -> int:
	if ids.is_empty():
		return -1
	var x := _rng.randf() * cum[cum.size() - 1]
	var lo := 0
	var hi := cum.size() - 1
	while lo < hi:
		var mid := (lo + hi) >> 1
		if cum[mid] < x:
			lo = mid + 1
		else:
			hi = mid
	return ids[lo]


## Поставить машину на случайную точку появления (кольцо или весь диск). false — не нашлось места.
func _place(c: Car, whole_disk: bool) -> bool:
	for attempt in 8:
		var id := _pick(_disk_ids, _disk_cum) if whole_disk else _pick(_ring_ids, _ring_cum)
		if id < 0:
			return false
		var r := smp_road[id]
		var s := clampf(smp_s[id] + _rng.randf_range(-15.0, 15.0), 0.0, r_len[r])
		var dir := 1 if _rng.randf() < 0.5 else -1
		var free := true
		for o in cars:
			if o != c and o.active and o.road == r and o.dir == dir and absf(o.s - s) < 20.0:
				free = false
				break
		if not free:
			continue
		var tcfg: Dictionary = types[c.type].cfg
		var sr: Array = _c.speed_random
		var vd := r_vd[r] * _rng.randf_range(float(sr[0]), float(sr[1])) * float(tcfg.speed_factor)
		c.vd = minf(vd, float(tcfg.max_kmh) * KMH)
		c.road = r
		c.seg = -1
		c.dir = dir
		c.s = s
		c.v = minf(c.vd, 0.8 * r_vd[r])
		c.active = true
		c.color_i = _rng.randi() % (tcfg.colors as Array).size()
		c.shown = false
		choose_next(c)
		_paint(c)
		c.acc_dt = 0.0
		_place_visual(c)
		return true
	return false


func _paint(c: Car) -> void:
	var mm: MultiMesh = types[c.type].mm
	if mm == null:
		return
	var col: Array = types[c.type].cfg.colors[c.color_i]
	mm.set_instance_color(c.slot, Color(col[0], col[1], col[2]).srgb_to_linear())


# --- шаг ----------------------------------------------------------------------------------------

func _process(dt: float) -> void:
	var vp := get_viewport()
	var cam := vp.get_camera_3d() if vp != null else null
	if cam == null:
		return
	advance(dt, cam.global_position)


func _lane_key(c: Car) -> int:
	return c.road * 2 + (0 if c.dir > 0 else 1)


## Один шаг логики и запись трансформов. center — позиция камеры/пилота (мир). Каждую машину
## обновляем раз в update_groups кадров (с накопленным dt), списки полос пересобираем в кадр группы 0.
func advance(dt: float, center: Vector3) -> void:
	if _task >= 0 and ready_net:
		wait_net()
	if not ready_net:
		return
	var t0 := Time.get_ticks_usec()
	dt = minf(dt, 0.1)
	var R := float(_c.radius_m)
	var c2 := Vector2(center.x, center.z)
	if auto and (not _has_center or c2.distance_to(Vector2(_center.x, _center.z)) > R * 1.5):
		_fill_disk = true
		_last_refresh_c = Vector2(1e9, 1e9)
		if _has_center:
			for c in cars:
				c.active = false
	_has_center = true
	_center = center
	_refresh_t += dt
	if auto and (c2.distance_to(_last_refresh_c) > 100.0 or _refresh_t > 3.0):
		_refresh_t = 0.0
		_refresh(center)
	var K := maxi(int(_c.get("update_groups", 3)), 1)
	_fc += 1
	var gnow := _fc % K
	if gnow == 0:
		_build_lanes()
	var brake := float(_c.brake_ms2)
	var comfort := float(_c.comfort_brake_ms2)
	var gap0 := float(_c.follow_gap_m)
	var gap_t := float(_c.follow_time_s)
	for ci in cars.size():
		var c: Car = cars[ci]
		if not c.active:
			continue
		c.acc_dt += dt
		if ci % K != gnow:
			continue
		var dtc := c.acc_dt
		c.acc_dt = 0.0
		var L := r_len[c.road]
		c.p = c.s if c.dir > 0 else L - c.s
		var d_end := L - c.p
		var uturn := c.next_road < 0
		var vt := c.vd
		vt = minf(vt, sqrt(c.v_end * c.v_end + 2.0 * comfort * maxf(d_end - (0.5 if uturn else 0.0), 0.0)))
		var g := _gap_ahead(c)
		if g > -1e8:
			var a := gap_ahead_car
			vt = minf(vt, (g - gap0) / gap_t)
			vt = minf(vt, sqrt(a.v * a.v + 2.0 * comfort * maxf(g - 3.0, 0.0)))
		vt = maxf(vt, 0.0)
		c.v += clampf(vt - c.v, -brake * dtc, c.acc * dtc)
		var p_new := c.p + c.v * dtc
		if uturn and (d_end < 0.7 and c.v < 0.8):
			# тупик: остановились — разворот на месте
			c.dir = -c.dir
			c.s = L if c.dir < 0 else 0.0
			c.v = 0.0
			choose_next(c)
		elif p_new >= L:
			if uturn:
				c.s = L if c.dir > 0 else 0.0
				c.v = 0.0
			else:
				var over := p_new - L
				c.road = c.next_road
				c.seg = -1
				c.dir = c.next_dir
				var L2 := r_len[c.road]
				var s0: float = (r_cum[c.road] as PackedFloat32Array)[c.next_idx]
				c.s = clampf(s0 + c.dir * over, 0.0, L2)
				choose_next(c)
		else:
			c.s = p_new if c.dir > 0 else L - p_new
		_place_visual(c)
		if auto and Vector2(c.pos.x, c.pos.z).distance_to(c2) > R * float(_c.ring_max) * 1.05:
			if not _place(c, false):
				c.active = false
	# погашенные — обнулить один раз
	for c in cars:
		if not c.active and c.shown:
			var mm: MultiMesh = types[c.type].mm
			if mm != null:
				mm.set_instance_transform(c.slot, Transform3D(Basis.from_scale(Vector3.ZERO), Vector3.ZERO))
			c.shown = false
	_frame_ms = (Time.get_ticks_usec() - t0) / 1000.0
	_sum_ms += _frame_ms


## Списки машин по полосам (дорога, направление), по возрастанию прогресса.
func _build_lanes() -> void:
	_lanes.clear()
	for c in cars:
		if not c.active:
			continue
		var L := r_len[c.road]
		c.p = c.s if c.dir > 0 else L - c.s
		var key := _lane_key(c)
		c.lane_key = key
		var lst: Array = _lanes.get(key, [])
		var i := lst.size()
		lst.append(c)
		while i > 0 and (lst[i - 1] as Car).p > c.p:
			lst[i] = lst[i - 1]
			i -= 1
		lst[i] = c
		_lanes[key] = lst
	for lst: Array in _lanes.values():
		for i in lst.size():
			(lst[i] as Car).lane_i = i


var gap_ahead_car: Car
var _fc := 0
var _sum_ms := 0.0


## Впереди идущая: зазор от бампера до бампера, м; -1e9 — нет. Машина — в gap_ahead_car.
func _gap_ahead(c: Car) -> float:
	var key := _lane_key(c)
	var L := r_len[c.road]
	if c.lane_key == key:
		var lst: Array = _lanes.get(key, [])
		for j in range(c.lane_i + 1, lst.size()):
			var a: Car = lst[j]
			if a.active and a.lane_key == key and a != c and _lane_key(a) == key:
				gap_ahead_car = a
				return a.p - c.p - 0.5 * (a.length + c.length)
	if c.next_road >= 0:
		var key2 := c.next_road * 2 + (0 if c.next_dir > 0 else 1)
		var l2: Array = _lanes.get(key2, [])
		var L2 := r_len[c.next_road]
		var s0: float = (r_cum[c.next_road] as PackedFloat32Array)[c.next_idx]
		var pe := s0 if c.next_dir > 0 else L2 - s0
		for a: Car in l2:
			if a != c and a.active and a.lane_key == key2 and _lane_key(a) == key2 and a.p >= pe - 1.0:
				gap_ahead_car = a
				return (L - c.p) + (a.p - pe) - 0.5 * (a.length + c.length)
	return -1e9


## Мировое положение и поворот машины, запись в MultiMesh.
func _place_visual(c: Car) -> void:
	var cum: PackedFloat32Array = r_cum[c.road]
	var pts: PackedVector2Array = r_pts[c.road]
	var sg := c.seg
	var nseg := cum.size() - 2
	if sg < 0 or sg > nseg:
		sg = _seg_search(cum, c.s)
	else:
		while sg > 0 and cum[sg] > c.s:
			sg -= 1
		while sg < nseg and cum[sg + 1] <= c.s:
			sg += 1
	c.seg = sg
	var dv := pts[sg + 1] - pts[sg]
	var dl := maxf(dv.length(), 1e-4)
	var f := clampf((c.s - cum[sg]) / dl, 0.0, 1.0)
	var d := dv / dl * float(c.dir)
	var right := Vector2(-d.y, d.x)
	var p2: Vector2 = pts[sg] + dv * f + right * r_off[c.road]
	var half := c.wb * 0.5
	var pf := p2 + d * half
	var pr := p2 - d * half
	var yf := float(_height_fn.call(pf.x, pf.y))
	var yr := float(_height_fn.call(pr.x, pr.y))
	var y := 0.5 * (yf + yr) + float(_c.lift_m)
	c.pos = Vector3(p2.x, y, p2.y)
	var mm: MultiMesh = types[c.type].mm
	if mm == null:
		return
	var R := float(_c.radius_m)
	var dist := Vector2(c.pos.x - _center.x, c.pos.z - _center.z).length()
	var sc := 1.0 - smoothstep(R * float(_c.fade_from), R, dist)
	var yaw := atan2(d.x, d.y)
	var pitch := -atan2(yf - yr, c.wb)
	var b := Basis(Vector3.UP, yaw) * Basis(Vector3.RIGHT, pitch)
	if sc < 0.03:
		b = Basis.from_scale(Vector3.ZERO)
	elif sc < 0.999:
		b = b.scaled(Vector3.ONE * sc)
	mm.set_instance_transform(c.slot, Transform3D(b, c.pos))
	c.shown = true


# --- для тестов ---------------------------------------------------------------------------------

## Узел с синтетическими дорогами без моделей: roads = [{t, p: PackedVector2Array}], сеть строится синхронно.
static func make_for_test(roads: Array, cfg: Dictionary, height_fn: Callable) -> OsmTraffic:
	var node := OsmTraffic.new()
	node.setup(cfg.osm_traffic, cfg, height_fn, false)
	node._build_net(roads, cfg)
	return node


func active_count() -> int:
	var n := 0
	for c in cars:
		if c.active:
			n += 1
	return n


func frame_ms() -> float:
	return _frame_ms


func avg_ms() -> float:
	return _sum_ms / maxi(_fc, 1)


## Поставить машину вручную (тесты): type — индекс типа.
func spawn_at(type: int, road: int, dir: int, s: float, v: float, vd: float) -> Car:
	for c in cars:
		if c.type == type and not c.active:
			c.road = road
			c.seg = -1
			c.dir = dir
			c.s = s
			c.v = v
			c.vd = vd
			c.active = true
			c.color_i = 0
			choose_next(c)
			return c
	return null
