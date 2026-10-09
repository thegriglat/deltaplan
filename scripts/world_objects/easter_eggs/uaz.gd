class_name EggUaz
extends EasterEgg
## УАЗик с пылевым шлейфом (чисто картинка): 1–2 машины едут туда-обратно по бездорожью — по
## ровному открытому грунту низко над дном долины, вдоль долины, в сухую погоду за ними висит пыль. Машина — один ArrayMesh из коробок и
## цилиндров; пыль — MultiMesh квадов с шейдером smoke_puff (клубы — функция времени: клуб k
## «выпущен» k тактов назад там, где тогда была машина). Всё — функция ctx.t − t0 (К3/К4).
## Порядок бросков rng в begin: число машин; на каждую — поиск места (find_point), затем
## скорость, фаза пути, длина отрезка, сторона отрезка относительно точки.

const PUFF_SHADER := preload("res://scripts/world_objects/easter_eggs/uaz_dust.gdshader")
const KHAKI := Color(0.30, 0.34, 0.19)
const KHAKI_LIGHT := Color(0.38, 0.41, 0.26)
const DARK := Color(0.08, 0.08, 0.08)
const GLASS := Color(0.16, 0.2, 0.22)
const WHEEL_R := 0.38
const WHEELBASE := 2.4

## Итоги поиска для тестов: [{start: Vector3, route_m: float, speed_ms: float}]
var info: Array[Dictionary] = []

var _cfg: Dictionary = {}
var _cars: Array[Dictionary] = []
var _mesh: ArrayMesh
var _mat_car: StandardMaterial3D
var _mat_dust: ShaderMaterial
var _dusty := true


## День, есть годный отрезок ровного открытого грунта вдоль долины вблизи старта, не снег.
static func can_appear(ctx: EggContext, cfg: Dictionary) -> bool:
	if ctx.sun_elev_deg <= 0.0:
		return false
	if ctx.place == null:
		return false
	var rng := RandomNumberGenerator.new()
	rng.seed = ("%s|uaz_site" % ctx.world_key).hash()
	return _find_site(ctx.place, _start_of(ctx), rng, cfg, []) != null


## Пыль только в сухую погоду: не сплошная облачность и тепло.
static func is_dusty(ctx: EggContext, cfg: Dictionary) -> bool:
	return ctx.sky != "overcast" and ctx.temp_c > float(cfg.get("dust_min_temp_c", 5.0))


static func _start_of(ctx: EggContext) -> Vector2:
	var s := Vector2(ctx.pilot_pos.x, ctx.pilot_pos.z)
	var sites := ctx.place.start_sites()
	if not sites.is_empty():
		s = Vector2(sites[0].position.x, sites[0].position.z)
	return s


## Направление вдоль долины в точке (единичный Vector2): по кругу радиуса r берётся ось, у которой
## средняя высота двух противоположных точек ниже всего (поперёк долины склоны выше).
static func valley_dir(place: EggPlace, x: float, z: float, r: float) -> Vector2:
	var best := Vector2.RIGHT
	var best_h := INF
	for k in 8:
		var a := PI * float(k) / 8.0
		var d := Vector2(cos(a), sin(a))
		var h := place.height_at(x + d.x * r, z + d.y * r) + place.height_at(x - d.x * r, z - d.y * r)
		if h < best_h:
			best_h = h
			best = d
	return best


## Точка годна для езды: открытый грунт (луг, поле, кустарник; NONE — нет покрова, решают уклон и
## высота), не круче max_slope_deg, не выше cap над дном долины.
static func ground_ok(place: EggPlace, x: float, z: float, cfg: Dictionary, cap: float) -> bool:
	var s := place.surface_at(x, z)
	if (
		s != SurfaceLayer.GRASS
		and s != SurfaceLayer.CROP
		and s != SurfaceLayer.SHRUB
		and s != SurfaceLayer.NONE
	):
		return false
	if place.above_valley_m(x, z) > cap:
		return false
	return place.slope_deg_at(x, z) <= float(cfg.get("max_slope_deg", 8.0))


## Точка оси маршрута на расстоянии s от якоря: ось вдоль долины плюс плавное боковое покачивание
## (в якоре смещение 0).
static func axis_point(anchor: Vector2, dir: Vector2, s: float, wob_m: float, phase: float) -> Vector2:
	var perp := Vector2(-dir.y, dir.x)
	var off := wob_m * (sin(s / 120.0 + phase) - sin(phase))
	return anchor + dir * s + perp * off


## Сколько годного грунта по обе стороны якоря: {lo: ≤ 0, hi: ≥ 0} — крайние расстояния s вдоль
## оси (шаг 30 м, не дальше max_each_m в каждую сторону).
static func route_run(
	place: EggPlace, anchor: Vector2, dir: Vector2, phase: float, cfg: Dictionary, cap: float
) -> Dictionary:
	var wob := float(cfg.get("wobble_m", 15.0))
	var max_each := float((cfg.get("route_m", [500.0, 900.0]) as Array)[1])
	var out := {"lo": 0.0, "hi": 0.0}
	for sign_i in [-1.0, 1.0]:
		var s := 0.0
		while s < max_each:
			var q := axis_point(anchor, dir, (s + 30.0) * sign_i, wob, phase)
			if not ground_ok(place, q.x, q.y, cfg, cap):
				break
			s += 30.0
		if sign_i < 0.0:
			out.lo = -s
		else:
			out.hi = s
	return out


## Точки маршрута на отрезке [s0, s1] оси.
static func route_points(
	anchor: Vector2, dir: Vector2, s0: float, s1: float, wob: float, phase: float
) -> PackedVector2Array:
	var pts := PackedVector2Array()
	var n := maxi(int(ceil((s1 - s0) / 30.0)), 1)
	for i in n + 1:
		pts.append(axis_point(anchor, dir, lerpf(s0, s1, float(i) / float(n)), wob, phase))
	return pts


static func _line_length(pts: PackedVector2Array) -> float:
	var l := 0.0
	for i in range(pts.size() - 1):
		l += pts[i].distance_to(pts[i + 1])
	return l


## Подотрезок линии [s0, s1] как собственные точки и накопленные длины.
static func _slice(pts: PackedVector2Array, s0: float, s1: float) -> Dictionary:
	var out := PackedVector2Array()
	var cum := PackedFloat32Array()
	var acc := 0.0
	var total := 0.0
	for i in range(pts.size() - 1):
		var a := pts[i]
		var b := pts[i + 1]
		var l := a.distance_to(b)
		if l < 1.0e-6:
			continue
		var lo := maxf(s0, acc)
		var hi := minf(s1, acc + l)
		if hi > lo:
			var pa := a.lerp(b, (lo - acc) / l)
			var pb := a.lerp(b, (hi - acc) / l)
			if out.is_empty():
				out.append(pa)
				cum.append(0.0)
			total += pa.distance_to(pb)
			out.append(pb)
			cum.append(total)
		acc += l
	return {"pts": out, "cum": cum, "len": total}


static func _sample(pts: PackedVector2Array, cum: PackedFloat32Array, s: float) -> Vector2:
	var n := pts.size()
	if n == 1 or s <= 0.0:
		return pts[0]
	if s >= cum[n - 1]:
		return pts[n - 1]
	var i := 0
	while i < n - 2 and cum[i + 1] < s:
		i += 1
	var l := cum[i + 1] - cum[i]
	return pts[i].lerp(pts[i + 1], (s - cum[i]) / maxf(l, 1.0e-6))


## Подходящее место: {p: Vector3, cap: float, dir: Vector2} — якорь на ровном открытом грунте,
## вокруг которого вдоль долины есть годный отрезок не короче min_route_m. Допуск высоты над дном
## растёт от попытки к попытке (above_valley_m: [строго, мягко]). null — места нет.
static func _find_site(
	place: EggPlace,
	start: Vector2,
	rng: RandomNumberGenerator,
	cfg: Dictionary,
	found: Array[Vector3]
) -> Variant:
	var rad := float(cfg.get("search_radius_m", 4000.0))
	var gap := float(cfg.get("min_gap_m", 300.0))
	var min_route := float(cfg.get("min_route_m", 250.0))
	var cap_r: Array = cfg.get("above_valley_m", [150.0, 400.0])
	var dir_r := float(cfg.get("valley_dir_radius_m", 500.0))
	var tries := int(cfg.get("anchor_tries", 4))
	for k in tries:
		var r_k := rad * float(k + 1) / float(tries)
		var cap := lerpf(float(cap_r[0]), float(cap_r[1]), float(k) / maxf(float(tries - 1), 1.0))
		var res := {}
		var spot := func(x: float, z: float) -> bool:
			if not ground_ok(place, x, z, cfg, cap) or place.is_mountain(x, z):
				return false
			for f in found:
				if Vector2(f.x - x, f.z - z).length() < gap:
					return false
			var dir := valley_dir(place, x, z, dir_r)
			var run := route_run(place, Vector2(x, z), dir, 0.0, cfg, cap)
			if float(run.hi) - float(run.lo) < min_route:
				return false
			res["cap"] = cap
			res["dir"] = dir
			return true
		var p: Variant = place.find_point(rng, start, r_k, spot, 64)
		if p != null:
			res["p"] = p
			return res
	return null


func begin(ctx: EggContext, cfg: Dictionary, rng: RandomNumberGenerator, _t0: float) -> void:
	_cfg = cfg
	var cr: Array = cfg.get("cars_count", [1, 2])
	var n_cars := rng.randi_range(int(cr[0]), int(cr[1]))
	var found: Array[Vector3] = []
	for c in n_cars:
		var car := _plan_car(ctx, cfg, rng, found)
		if car.is_empty():
			continue
		found.append(car.start)
		_add_car(car)
	if not _cars.is_empty():
		position = _cars[0].start


func _plan_car(
	ctx: EggContext, cfg: Dictionary, rng: RandomNumberGenerator, found: Array[Vector3]
) -> Dictionary:
	var sp: Array = cfg.get("speed_kmh", [30.0, 50.0])
	var rr: Array = cfg.get("route_m", [500.0, 900.0])
	var slice: Dictionary
	var start: Vector3
	var place := ctx.place
	if place == null:
		# мира нет (тесты каркаса): прямая дорога 600 м в 200 м от игрока, без проверок
		start = Vector3(ctx.pilot_pos.x + 200.0, 0.0, ctx.pilot_pos.z)
		start.y = ctx.height_at.call(start.x, start.z)
		var pts := PackedVector2Array([Vector2(start.x, start.z), Vector2(start.x + 600.0, start.z)])
		slice = _slice(pts, 0.0, 600.0)
	else:
		var s0 := _start_of(ctx)
		var site: Variant = _find_site(place, s0, rng, cfg, found)
		if site == null:
			return {}
		start = site.p
		var anchor := Vector2(start.x, start.z)
		var dir: Vector2 = site.dir
		var cap: float = site.cap
		var length := lerpf(float(rr[0]), float(rr[1]), rng.randf())
		var side := rng.randf()  # где якорь внутри отрезка (доля)
		var wob := float(cfg.get("wobble_m", 15.0))
		var phase := rng.randf() * TAU
		var run := route_run(place, anchor, dir, phase, cfg, cap)
		if float(run.hi) - float(run.lo) < float(cfg.get("min_route_m", 250.0)):
			phase = 0.0  # при фазе 0 отрезок проверен поиском места
			run = route_run(place, anchor, dir, phase, cfg, cap)
		var lo := maxf(-length * side, float(run.lo))
		var hi := minf(length * (1.0 - side), float(run.hi))
		if hi - lo < float(cfg.get("min_route_m", 250.0)):
			lo = float(run.lo)
			hi = minf(float(run.hi), lo + length)
		slice = _slice(route_points(anchor, dir, lo, hi, wob, phase), 0.0, 1.0e6)
	var speed := lerpf(float(sp[0]), float(sp[1]), rng.randf()) / 3.6
	var phase := rng.randf()
	var car := {
		"pts": slice.pts,
		"cum": slice.cum,
		"len": float(slice.len),
		"speed": speed,
		"phase": phase,
		"start": start,
	}
	info.append({"start": start, "route_m": float(slice.len), "speed_ms": speed})
	return car


## Положение вдоль маршрута в момент t: {p: Vector2, fwd: Vector2 (единичный, куда едет)}.
func state_at(car: Dictionary, t: float) -> Dictionary:
	var l := float(car.len)
	var u := wrapf((t - t0) * float(car.speed) + float(car.phase) * 2.0 * l, 0.0, 2.0 * l)
	var forward := u < l
	var d := u if forward else 2.0 * l - u
	var pts: PackedVector2Array = car.pts
	var cum: PackedFloat32Array = car.cum
	var p := _sample(pts, cum, d)
	var ahead := _sample(pts, cum, clampf(d + 2.0, 0.0, l))
	var behind := _sample(pts, cum, clampf(d - 2.0, 0.0, l))
	var dirv := (ahead - behind)
	dirv = dirv.normalized() if dirv.length() > 1.0e-6 else Vector2.RIGHT
	if not forward:
		dirv = -dirv
	return {"p": p, "fwd": dirv}


func car_count() -> int:
	return _cars.size()


func car_position(i: int, t: float) -> Vector2:
	return state_at(_cars[i], t).p


func dust_visible(i: int) -> bool:
	return _cars[i].dust.visible


func _add_car(car: Dictionary) -> void:
	var mi := MeshInstance3D.new()
	mi.mesh = _car_mesh()
	mi.material_override = _car_material()
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(mi)
	car["body"] = mi
	var n := int(_cfg.get("dust_puffs", 24))
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.use_custom_data = true
	var quad := QuadMesh.new()
	mm.mesh = quad
	mm.instance_count = n
	var reach := 120.0
	mm.custom_aabb = AABB(Vector3(-reach, -20.0, -reach), Vector3(reach * 2.0, 80.0, reach * 2.0))
	var mmi := MultiMeshInstance3D.new()
	mmi.multimesh = mm
	mmi.material_override = _dust_material()
	mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(mmi)
	car["dust"] = mmi
	car["mm"] = mm
	_cars.append(car)


func _car_material() -> StandardMaterial3D:
	if _mat_car == null:
		_mat_car = StandardMaterial3D.new()
		_mat_car.vertex_color_use_as_albedo = true
		_mat_car.roughness = 0.9
	return _mat_car


func _dust_material() -> ShaderMaterial:
	if _mat_dust == null:
		_mat_dust = ShaderMaterial.new()
		_mat_dust.shader = PUFF_SHADER
		var tint: Array = _cfg.get("dust_tint", [0.62, 0.55, 0.43])
		_mat_dust.set_shader_parameter(
			&"tint", Color(float(tint[0]), float(tint[1]), float(tint[2]))
		)
		_mat_dust.set_shader_parameter(&"density", float(_cfg.get("dust_density", 0.5)))
	return _mat_dust


# ---------------------------------------------------------------- ход


func update(ctx: EggContext) -> bool:
	if _cars.is_empty():
		return false
	_dusty = is_dusty(ctx, _cfg)
	var cam := ctx.pilot_pos
	if ctx.camera != null and ctx.camera.is_inside_tree():
		cam = ctx.camera.global_position
	var vis_m := float(_cfg.get("visible_m", 3000.0))
	var t := ctx.t
	var first := true
	for car in _cars:
		var st := state_at(car, t)
		var p: Vector2 = st.p
		var fwd: Vector2 = st.fwd
		var hy: float = ctx.height_at.call(p.x, p.y)
		var wf := p + fwd * (WHEELBASE * 0.5)
		var wb := p - fwd * (WHEELBASE * 0.5)
		var yf: float = ctx.height_at.call(wf.x, wf.y)
		var yb: float = ctx.height_at.call(wb.x, wb.y)
		var f3 := Vector3(fwd.x * WHEELBASE, yf - yb, fwd.y * WHEELBASE).normalized()
		var z3 := -f3
		var x3 := Vector3.UP.cross(z3).normalized()
		var y3 := z3.cross(x3)
		var pos3 := Vector3(p.x, hy, p.y)
		if first:
			position = pos3
			first = false
		var body: MeshInstance3D = car.body
		body.transform = Transform3D(Basis(x3, y3, z3), pos3 - position)
		var d := cam.distance_to(pos3)
		body.visible = d < vis_m
		var dust: MultiMeshInstance3D = car.dust
		dust.visible = _dusty and d < vis_m
		dust.position = pos3 - position
		if dust.visible:
			_update_dust(car, ctx, pos3)
	return true


func _update_dust(car: Dictionary, ctx: EggContext, pos3: Vector3) -> void:
	var mm: MultiMesh = car.mm
	var n := mm.instance_count
	var dt := float(_cfg.get("puff_dt_s", 0.4))
	var t := ctx.t
	var f := wrapf(t - t0, 0.0, dt) / dt
	var idx0 := int(floor((t - t0) / dt))
	var life := dt * float(n)
	var a := deg_to_rad(ctx.wind_from_deg)
	var wind := Vector3(-sin(a), 0.0, cos(a)) * ctx.wind_ms * float(_cfg.get("dust_wind_k", 0.6))
	var rise := float(_cfg.get("dust_rise_ms", 0.6))
	var s0 := float(_cfg.get("dust_size_m", [1.5, 6.0])[0])
	var s1 := float(_cfg.get("dust_size_m", [1.5, 6.0])[1])
	for k in n:
		var age_s := (float(k) + f) * dt
		var te := t - age_s
		var seed_i := idx0 - k
		var rnd := wrapf(sin(float(seed_i) * 12.9898) * 43758.5453, 0.0, 1.0)
		var rnd2 := wrapf(sin(float(seed_i) * 78.233) * 12345.678, 0.0, 1.0)
		if te < t0:
			mm.set_instance_transform(k, Transform3D(Basis().scaled(Vector3.ZERO), Vector3.ZERO))
			mm.set_instance_custom_data(k, Color(0, 1, 0, 0))
			continue
		var q: Vector2 = state_at(car, te).p
		var g: float = ctx.height_at.call(q.x, q.y)
		var life_f := age_s / life
		var size := lerpf(s0, s1, life_f)
		var off := (Vector3(q.x, g, q.y) - pos3) + wind * age_s
		off += Vector3((rnd - 0.5) * 2.0, 0.6 + rise * age_s + rnd2 * 0.5, (rnd2 - 0.5) * 2.0)
		mm.set_instance_transform(k, Transform3D(Basis().scaled(Vector3(size, size, size)), off))
		mm.set_instance_custom_data(k, Color(rnd * TAU, life_f, rnd2, 0.0))


# ---------------------------------------------------------------- модель


func _car_mesh() -> ArrayMesh:
	if _mesh != null:
		return _mesh
	var v := PackedVector3Array()
	var n := PackedVector3Array()
	var c := PackedColorArray()
	var idx := PackedInt32Array()
	# «буханка» УАЗ-452 из коробок; нос смотрит в −Z, колёса ±0,9 по X
	_box(v, n, c, idx, Vector3(0, 0.85, 0.0), Vector3(1.8, 0.8, 4.0), KHAKI)
	_box(v, n, c, idx, Vector3(0, 1.6, 0.35), Vector3(1.75, 0.8, 3.1), KHAKI_LIGHT)
	_box(v, n, c, idx, Vector3(0, 1.62, -1.2), Vector3(1.78, 0.5, 0.05), GLASS)
	_box(v, n, c, idx, Vector3(0, 1.95, 0.35), Vector3(1.7, 0.08, 3.0), KHAKI)
	for sx in [-1.0, 1.0]:
		for z in [-1.3, 1.3]:
			_cylinder(v, n, c, idx, Vector3(sx * 0.9, WHEEL_R, z), WHEEL_R, 0.26, DARK)
	var arr := []
	arr.resize(Mesh.ARRAY_MAX)
	arr[Mesh.ARRAY_VERTEX] = v
	arr[Mesh.ARRAY_NORMAL] = n
	arr[Mesh.ARRAY_COLOR] = c
	arr[Mesh.ARRAY_INDEX] = idx
	_mesh = ArrayMesh.new()
	_mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arr)
	return _mesh


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
		idx.append_array([base, base + 2, base + 1, base, base + 3, base + 2])


## Цилиндр с осью по X (колесо): боковина и две торцевые крышки.
static func _cylinder(
	v: PackedVector3Array,
	nn: PackedVector3Array,
	col: PackedColorArray,
	idx: PackedInt32Array,
	center: Vector3,
	radius: float,
	width: float,
	color: Color
) -> void:
	var seg := 10
	var hw := width * 0.5
	for i in seg:
		var a0 := TAU * float(i) / seg
		var a1 := TAU * float(i + 1) / seg
		var p0 := Vector3(0, sin(a0), cos(a0))
		var p1 := Vector3(0, sin(a1), cos(a1))
		var base := v.size()
		for corner in [[p0, -hw], [p1, -hw], [p1, hw], [p0, hw]]:
			var pr: Vector3 = corner[0]
			v.append(center + pr * radius + Vector3(corner[1], 0, 0))
			nn.append(pr)
			col.append(color)
		idx.append_array([base, base + 1, base + 2, base, base + 2, base + 3])
		for sx in [-1.0, 1.0]:
			var b2 := v.size()
			v.append(center + Vector3(sx * hw, 0, 0))
			v.append(center + p0 * radius + Vector3(sx * hw, 0, 0))
			v.append(center + p1 * radius + Vector3(sx * hw, 0, 0))
			for k in 3:
				nn.append(Vector3(sx, 0, 0))
				col.append(color)
			if sx > 0.0:
				idx.append_array([b2, b2 + 2, b2 + 1])
			else:
				idx.append_array([b2, b2 + 1, b2 + 2])
