class_name EggBalloon
extends EasterEgg
## Воздушный шар / фестиваль шаров (чисто картинка). Утром в слабый ветер шар дрейфует по ветру
## прогноза (степенной рост скорости с высотой), поднимается на 200–1200 м и колышется. Все шары
## одной пасхалки — два MultiMesh (оболочки и корзины). Положение — функция ctx.t − t0 и параметров
## из rng, в мировых координатах. Воздух не трогаем: ветер только из прогноза.

const SHADER := preload("res://scripts/world_objects/easter_eggs/balloon.gdshader")
const RINGS := 14
const SEGMENTS := 20
const STRING_M := 3.0  ## оболочка над корзиной (стропы), м
const START_FRAC := 0.15  ## доля рабочей высоты в момент появления

var _origin := Vector3.ZERO  ## опорная точка узла в t0: центр набора на средней высоте
var _dir := Vector3.RIGHT  ## куда дует (горизонтально, единичный)
var _speed := 3.0  ## скорость сноса, м/с
var _base: Array[Vector3] = []  ## точка старта каждого шара (Y — рельеф)
var _alt: PackedFloat32Array = PackedFloat32Array()  ## рабочая высота над точкой, м
var _ramp: PackedFloat32Array = PackedFloat32Array()  ## время подъёма, с
var _yaw: PackedFloat32Array = PackedFloat32Array()
var _basket_m := 1.5
var _ramp_max := 1.0
var _settled := false
var _env: MultiMeshInstance3D
var _bask: MultiMeshInstance3D
var _mats: Array[ShaderMaterial] = []


## Утро (солнце в окне и час ≤ max_hour), сезон, слабый ветер, не overcast, есть точка старта.
static func can_appear(ctx: EggContext, cfg: Dictionary) -> bool:
	var sun: Array = cfg.get("sun_elev_deg", [0, 25])
	if ctx.sun_elev_deg < float(sun[0]) or ctx.sun_elev_deg > float(sun[1]):
		return false
	if ctx.hour > float(cfg.get("max_hour", 10.0)):
		return false
	var months: Array = cfg.get("months", [4, 10])
	if ctx.month < int(months[0]) or ctx.month > int(months[1]):
		return false
	if ctx.wind_ms > float(cfg.get("wind_max_ms", 3.5)) or ctx.sky == "overcast":
		return false
	var rng := RandomNumberGenerator.new()
	rng.seed = ("%s|balloon_site" % ctx.world_key).hash()
	return find_site(ctx, rng, cfg) != null


## Куда дует (единичный, горизонтально): «откуда» — из погоды, иначе из прогноза контекста.
static func wind_dir(ctx: EggContext) -> Vector3:
	var from_deg := ctx.wind_from_deg
	if ctx.weather.has("wind_from_deg"):
		from_deg = float(ctx.weather.wind_from_deg)
	var a := deg_to_rad(from_deg)
	return Vector3(-sin(a), 0.0, cos(a))


## Скорость сноса на высоте alt_m над землёй: ветер у земли, степенной рост с высотой.
static func drift_speed(ctx: EggContext, cfg: Dictionary, alt_m: float) -> float:
	var w10 := maxf(ctx.wind_ms, float(cfg.get("min_wind_ms", 0.8)))
	return w10 * pow(maxf(alt_m, 10.0) / 10.0, float(cfg.get("wind_exponent", 0.25)))


## Расстояние от точки q до отрезка a–b на плоскости, м.
static func dist_to_segment(q: Vector2, a: Vector2, b: Vector2) -> float:
	var ab := b - a
	var l2 := ab.length_squared()
	var t := 0.0 if l2 < 1.0e-9 else clampf((q - a).dot(ab) / l2, 0.0, 1.0)
	return q.distance_to(a + ab * t)


## Точка старта (центр набора): на своей долине или равнине не ближе min_dist_flying_zone_m (плюс
## разброс фестиваля) ни к одному старту локации на всём пути сноса за время жизни, ни к пилоту
## в момент появления; ≤ village_max_m от посёлка OSM; не горы, рельеф ≤ max_ground_m, под точкой
## не снег/скалы/лес/вода. Vector3 на рельефе или null (шара нет).
static func find_site(ctx: EggContext, rng: RandomNumberGenerator, cfg: Dictionary) -> Variant:
	var place := ctx.place
	if place == null:
		return null
	var cnt: Array = cfg.get("count", [1, 1])
	var margin := float(cfg.get("min_dist_flying_zone_m", 5000.0))
	if int(cnt[1]) > 1:
		margin += float(cfg.get("spread_m", 1500.0))
	var alt_max := float((cfg.get("altitude_m", [200, 1200]) as Array)[1])
	var path := drift_speed(ctx, cfg, alt_max) * float(cfg.get("lifetime_s", 4500.0))
	var dir := wind_dir(ctx)
	var d2 := Vector2(dir.x, dir.z)
	var starts: Array[Vector2] = []
	for st in place.start_sites():
		starts.append(Vector2(st.position.x, st.position.z))
	var pilot := Vector2(ctx.pilot_pos.x, ctx.pilot_pos.z)
	var max_h := float(cfg.get("max_ground_m", 1500.0))
	var village_max := float(cfg.get("village_max_m", 10000.0))
	var accept := func(x: float, z: float) -> bool:
		var q := Vector2(x, z)
		if q.distance_to(pilot) < margin:
			return false
		for st in starts:
			if dist_to_segment(st, q, q + d2 * path) < margin:
				return false
		if place.is_mountain(x, z) or place.height_at(x, z) > max_h:
			return false
		var sf := place.surface_at(x, z)
		if (
			sf == SurfaceLayer.SNOW
			or sf == SurfaceLayer.BARE
			or sf == SurfaceLayer.FOREST
			or sf == SurfaceLayer.WATER
		):
			return false
		var v := place.nearest_place(x, z)
		return not v.is_empty() and float(v.dist_m) <= village_max
	return place.find_point(
		rng, Vector2.ZERO, float(cfg.get("search_radius_m", 16000.0)), accept, 200
	)


func begin(ctx: EggContext, cfg: Dictionary, rng: RandomNumberGenerator, _t0: float) -> void:
	# порядок бросков: точка старта, число шаров, дальше по шарам (разброс, высота, подъём,
	# поворот, цвета). Места нет (в том числе при форсе) — шара нет: узел пустой до конца жизни.
	var site: Variant = find_site(ctx, rng, cfg)
	if site == null:
		return
	var center: Vector3 = site
	var cnt: Array = cfg.get("count", [1, 1])
	var n := rng.randi_range(int(cnt[0]), int(cnt[1]))
	var spread := float(cfg.get("spread_m", 1500.0)) if n > 1 else 0.0
	var alt_r: Array = cfg.get("altitude_m", [200, 1200])
	var ramp_r: Array = cfg.get("ramp_s", [180, 420])
	var wedge_opts := [8, 10, 12, 16]
	_basket_m = float(cfg.get("basket_m", 1.5))
	var colors: Array[Color] = []
	var customs: Array[Color] = []
	var alt_sum := 0.0
	for i in n:
		var p := center
		if n > 1:
			var a := rng.randf() * TAU
			var r := spread * sqrt(rng.randf())
			p = center + Vector3(cos(a), 0.0, sin(a)) * r
			p.y = float(ctx.height_at.call(p.x, p.z))
		_base.append(p)
		_alt.append(lerpf(float(alt_r[0]), float(alt_r[1]), rng.randf()))
		_ramp.append(lerpf(float(ramp_r[0]), float(ramp_r[1]), rng.randf()))
		_yaw.append(rng.randf() * TAU)
		var hue := rng.randf()
		var ca := Color.from_hsv(hue, rng.randf_range(0.7, 0.95), rng.randf_range(0.85, 1.0))
		var cb := Color.from_hsv(
			fposmod(hue + rng.randf_range(0.15, 0.5), 1.0),
			rng.randf_range(0.6, 0.95),
			rng.randf_range(0.85, 1.0)
		)
		if rng.randf() < 0.3:
			cb = Color(0.95, 0.93, 0.85)
		var wedges: int = wedge_opts[rng.randi() % wedge_opts.size()]
		colors.append(ca.srgb_to_linear())
		customs.append(Color(cb.srgb_to_linear(), float(wedges) / 32.0))
		alt_sum += _alt[i]
		_ramp_max = maxf(_ramp_max, _ramp[i])
	# снос: направление — куда дует; скорость — ветер у земли на средней высоте
	_dir = wind_dir(ctx)
	var alt_mean := alt_sum / n
	_speed = drift_speed(ctx, cfg, alt_mean)
	# запас над рельефом по пути дрейфа: при нужде поднимаем всех
	var path_len := _speed * lifetime_s
	var top := 0.0
	for k in 13:
		var q := center + _dir * path_len * (float(k) / 12.0)
		top = maxf(top, float(ctx.height_at.call(q.x, q.z)))
	var extra := maxf(0.0, top + float(cfg.get("clearance_m", 150.0)) - (center.y + alt_mean))
	for i in n:
		_alt[i] += extra
	_origin = Vector3(center.x, center.y + alt_mean, center.z)
	_build(cfg, colors, customs)
	update(ctx)


func _profile(y: float, height: float, rmax: float) -> float:
	# «капля»: наибольшая ширина на ~60 % высоты, у горловины — не меньше 1,6 м, сверху закрыта
	var r := rmax * pow(maxf(sin(PI * pow(y, 1.3)), 0.0), 0.6)
	return maxf(r, 1.6 * (1.0 - y * height / 1.2))


func _envelope_mesh(cfg: Dictionary) -> ArrayMesh:
	var height := float(cfg.get("height_m", 22.0))
	var rmax := float(cfg.get("diameter_m", 17.0)) * 0.5
	var verts := PackedVector3Array()
	var norms := PackedVector3Array()
	var uvs := PackedVector2Array()
	var idx := PackedInt32Array()
	for j in RINGS + 1:
		var y := float(j) / RINGS
		var r := _profile(y, height, rmax)
		var e := 0.01
		var slope := (
			(_profile(minf(y + e, 1.0), height, rmax) - _profile(maxf(y - e, 0.0), height, rmax))
			/ (2.0 * e * height)
		)
		for i in SEGMENTS + 1:
			var th := TAU * float(i) / SEGMENTS
			var c := cos(th)
			var s := sin(th)
			verts.append(Vector3(c * r, y * height, s * r))
			norms.append(Vector3(c, -slope, s).normalized())
			uvs.append(Vector2(float(i) / SEGMENTS, y))
	var w := SEGMENTS + 1
	for j in RINGS:
		for i in SEGMENTS:
			var a := j * w + i
			idx.append_array([a, a + 1, a + w, a + 1, a + w + 1, a + w])
	var arr := []
	arr.resize(Mesh.ARRAY_MAX)
	arr[Mesh.ARRAY_VERTEX] = verts
	arr[Mesh.ARRAY_NORMAL] = norms
	arr[Mesh.ARRAY_TEX_UV] = uvs
	arr[Mesh.ARRAY_INDEX] = idx
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arr)
	return mesh


func _build(cfg: Dictionary, colors: Array[Color], customs: Array[Color]) -> void:
	var n := _base.size()
	# границы экземпляров в локальных осях узла (узел двигается только по X, Z)
	var lo := Vector3(INF, INF, INF)
	var hi := Vector3(-INF, -INF, -INF)
	var alt_top := 0.0
	for i in n:
		lo = lo.min(_base[i] - _origin)
		hi = hi.max(_base[i] - _origin)
		alt_top = maxf(alt_top, _base[i].y + _alt[i] - _origin.y)
	var box := AABB(
		Vector3(lo.x - 40.0, lo.y - 10.0, lo.z - 40.0),
		Vector3(hi.x - lo.x + 80.0, alt_top - lo.y + 80.0, hi.z - lo.z + 80.0)
	)
	var mm_e := MultiMesh.new()
	mm_e.transform_format = MultiMesh.TRANSFORM_3D
	mm_e.use_colors = true
	mm_e.use_custom_data = true
	mm_e.mesh = _envelope_mesh(cfg)
	mm_e.instance_count = n
	mm_e.custom_aabb = box
	var mm_b := MultiMesh.new()
	mm_b.transform_format = MultiMesh.TRANSFORM_3D
	var bm := BoxMesh.new()
	bm.size = Vector3.ONE * _basket_m
	mm_b.mesh = bm
	mm_b.instance_count = n
	mm_b.custom_aabb = box
	for i in n:
		mm_e.set_instance_color(i, colors[i])
		mm_e.set_instance_custom_data(i, customs[i])
	var bob_p := cfg.get("bob_period_s", [70, 140]) as Array
	for k in 2:
		var m := ShaderMaterial.new()
		m.shader = SHADER
		m.set_shader_parameter(&"basket", k == 1)
		m.set_shader_parameter(&"bob_period", 0.5 * (float(bob_p[0]) + float(bob_p[1])))
		m.set_shader_parameter(&"bob_amp", float(cfg.get("bob_m", 4.0)))
		_mats.append(m)
	_env = MultiMeshInstance3D.new()
	_env.multimesh = mm_e
	_env.material_override = _mats[0]
	_env.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(_env)
	_bask = MultiMeshInstance3D.new()
	_bask.multimesh = mm_b
	_bask.material_override = _mats[1]
	_bask.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(_bask)


## Высота подъёма шара i над точкой старта к моменту age, м.
func _rise(i: int, age: float) -> float:
	var s := smoothstep(0.0, 1.0, age / _ramp[i])
	return _alt[i] * (START_FRAC + (1.0 - START_FRAC) * s)


func _place_instances(age: float) -> void:
	var mm_e := _env.multimesh
	var mm_b := _bask.multimesh
	for i in _base.size():
		var b := _base[i] - _origin
		var y := b.y + _basket_m * 0.5 + _rise(i, age)
		mm_b.set_instance_transform(i, Transform3D(Basis.IDENTITY, Vector3(b.x, y, b.z)))
		var env_y := y + _basket_m * 0.5 + STRING_M
		var basis := Basis(Vector3.UP, _yaw[i])
		mm_e.set_instance_transform(i, Transform3D(basis, Vector3(b.x, env_y, b.z)))


func update(ctx: EggContext) -> bool:
	var age := ctx.t - t0
	if lifetime_s > 0.0 and age > lifetime_s:
		return false
	if _env == null:
		return true
	# снос: весь набор сдвигается по ветру; подъём — отдельно по шарам, пока не набрали высоту
	position = _origin + _dir * _speed * age
	if not _settled:
		_place_instances(age)
		_settled = age >= _ramp_max
	for m in _mats:
		m.set_shader_parameter(&"wt", age)
	return true


func count() -> int:
	return _base.size()


## Положение шара i на момент age (для тестов), мир.
func balloon_pos(i: int, age: float) -> Vector3:
	return _origin + _dir * _speed * age + _base[i] - _origin


func envelopes() -> MultiMeshInstance3D:
	return _env
