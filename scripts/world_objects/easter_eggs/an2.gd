class_name EggAn2
extends EasterEgg
## Ан-2 («кукурузник»): биплан пролетает по прямой над полями и лугами долины на постоянной
## высоте н.у.м., со звуком мотора АШ-62ИР, затухающим с расстоянием. Только картинка и звук.
## Трасса — в мировых координатах (из rng в begin), не от пилота. Положение — функция ctx.t − t0.
## Модель — из примитивов, слитых по материалам (4 вызова отрисовки). Звук — зацикленный синтез
## (гармоники 150 Гц = 9 цилиндров звездой × 2000 об/мин / 2 / 60, биения винта, неровность).

const RATE := 22050
const FIRE_HZ := 150  # основной тон вспышек: 9/2 × (2000/60) = 150 Гц
const PERIOD := RATE / FIRE_HZ  # 147 отсчётов — целое, петля без стыка

static var _sound_cache: AudioStreamWAV

var track_ok := false  ## трасса найдена (для тестов)
var alt_msl := 0.0  ## высота полёта, м н.у.м. (для тестов)
var _p0 := Vector3.ZERO  # начало трассы, мир (высота — н.у.м.)
var _dir := Vector3.FORWARD  # единичный горизонтальный курс
var _speed := 50.0
var _len := 10000.0
var _roll_amp := 0.0
var _roll_phase := 0.0
var _player: AudioStreamPlayer3D


static func can_appear(ctx: EggContext, cfg: Dictionary) -> bool:
	if ctx.place == null or ctx.sun_elev_deg <= float(cfg.get("sun_min_deg", 5.0)):
		return false
	var m: Array = cfg.get("months", [5, 9])
	if ctx.month < int(m[0]) or ctx.month > int(m[1]):
		return false
	if ctx.wind_ms >= float(cfg.get("wind_max_ms", 8.0)) or ctx.sky == "overcast":
		return false
	return not ctx.place.nearest_place(0.0, 0.0).is_empty()


func begin(ctx: EggContext, cfg: Dictionary, rng: RandomNumberGenerator, _t0: float) -> void:
	_speed = float(cfg.get("speed_ms", 50.0))
	_roll_amp = deg_to_rad(float(cfg.get("roll_deg", 3.0)))
	_roll_phase = rng.randf() * TAU
	track_ok = false
	if ctx.place != null:
		track_ok = _find_track(ctx, cfg, rng)
	if not track_ok:
		return
	lifetime_s = _len / _speed
	_build_model(cfg, rng)
	_build_sound(cfg)
	update(ctx)


func update(ctx: EggContext) -> bool:
	var age := ctx.t - t0
	if not track_ok:
		# нет трассы (форс без места): невидима, живёт lifetime_s из конфига (К3, К7 «жизнь»)
		return age >= 0.0 and age < lifetime_s
	if age < 0.0 or age * _speed > _len:
		return false
	var s := age * _speed
	var pos := _p0 + _dir * s
	var roll := _roll_amp * sin(age * 0.35 + _roll_phase)
	var b := Basis.looking_at(_dir, Vector3.UP)
	b = b * Basis(Vector3.FORWARD, roll)
	transform = Transform3D(b, pos)
	return true


# ---------------------------------------------------------------- трасса


func _profile_ok(
	place: EggPlace, p0: Vector3, dir: Vector3, len_m: float, step: float, lo: float, hi: float
) -> Dictionary:
	var n := int(ceil(len_m / step))
	var hmin := INF
	var hmax := -INF
	for i in n + 1:
		var q := p0 + dir * minf(i * step, len_m)
		var h := place.height_at(q.x, q.z)
		hmin = minf(hmin, h)
		hmax = maxf(hmax, h)
	var lo_alt := hmax + lo
	var hi_alt := hmin + hi
	return {"ok": lo_alt <= hi_alt, "lo": lo_alt, "hi": hi_alt}


func _find_track(ctx: EggContext, cfg: Dictionary, rng: RandomNumberGenerator) -> bool:
	var place := ctx.place
	var lo := float(cfg.get("agl_min_m", 150.0))
	var hi := float(cfg.get("agl_max_m", 500.0))
	var step := float(cfg.get("probe_step_m", 200.0))
	var town_max := float(cfg.get("town_max_m", 10000.0))
	var h_max := float(cfg.get("terrain_max_msl_m", 1500.0))
	var slope_max := float(cfg.get("slope_max_deg", 6.0))
	var radius := float(cfg.get("search_radius_m", 6000.0))
	var accept := func(x: float, z: float) -> bool:
		var s := place.surface_at(x, z)
		if s != SurfaceLayer.CROP and s != SurfaceLayer.GRASS and s != SurfaceLayer.NONE:
			return false
		if place.is_mountain(x, z) or place.height_at(x, z) > h_max:
			return false
		if place.slope_deg_at(x, z) > slope_max:
			return false
		var np := place.nearest_place(x, z)
		return not np.is_empty() and float(np.dist_m) <= town_max
	for attempt in int(cfg.get("attempts", 16)):
		var mid: Variant = place.find_point(rng, Vector2.ZERO, radius, accept)
		var course := rng.randf() * TAU
		var len_m := rng.randf_range(float(cfg.length_m[0]), float(cfg.length_m[1]))
		var frac := rng.randf()
		if mid == null:
			continue
		var dir := Vector3(cos(course), 0.0, sin(course))
		var p0: Vector3 = (mid as Vector3) - dir * len_m * 0.5
		var pr := _profile_ok(place, p0, dir, len_m, step, lo, hi)
		if not pr.ok:
			continue
		if not _route_ok(ctx, cfg, p0, dir, len_m):
			continue
		_set_track(p0, dir, len_m, float(pr.lo) + frac * (float(pr.hi) - float(pr.lo)))
		return true
	return false


## Расстояние от точки (x, z) до отрезка a–b на плоскости, м.
static func _dist_seg(p: Vector2, a: Vector2, b: Vector2) -> float:
	var ab := b - a
	var l2 := ab.length_squared()
	var t := 0.0 if l2 < 1.0e-9 else clampf((p - a).dot(ab) / l2, 0.0, 1.0)
	return p.distance_to(a + ab * t)


## Пролёт над плоской равниной вдали от зоны полётов: на каждой пробе не горы, склон не круче
## slope_max_deg, рельеф не выше terrain_max_msl_m; вся трасса дальше min_dist_flying_zone_m
## от каждого старта и от пилота.
func _route_ok(ctx: EggContext, cfg: Dictionary, p0: Vector3, dir: Vector3, len_m: float) -> bool:
	var place := ctx.place
	var step := float(cfg.get("probe_step_m", 200.0))
	var h_max := float(cfg.get("terrain_max_msl_m", 1500.0))
	var slope_max := float(cfg.get("slope_max_deg", 6.0))
	var zone := float(cfg.get("min_dist_flying_zone_m", 6000.0))
	var a := Vector2(p0.x, p0.z)
	var b := a + Vector2(dir.x, dir.z) * len_m
	var centers: Array[Vector2] = [Vector2(ctx.pilot_pos.x, ctx.pilot_pos.z)]
	for site in place.start_sites():
		var sp: Vector3 = site.position
		centers.append(Vector2(sp.x, sp.z))
	for c in centers:
		if _dist_seg(c, a, b) < zone:
			return false
	for i in int(ceil(len_m / step)) + 1:
		var q := p0 + dir * minf(i * step, len_m)
		if place.height_at(q.x, q.z) > h_max or place.is_mountain(q.x, q.z):
			return false
		if place.slope_deg_at(q.x, q.z) > slope_max:
			return false
	return true


func _set_track(p0: Vector3, dir: Vector3, len_m: float, alt: float) -> void:
	alt_msl = alt
	_p0 = Vector3(p0.x, alt, p0.z)
	_dir = dir
	_len = len_m


## Точка трассы в момент t мира (для тестов).
func pos_at(t: float) -> Vector3:
	return _p0 + _dir * ((t - t0) * _speed)


func length_m() -> float:
	return _len


# ---------------------------------------------------------------- модель


static func _box(st: SurfaceTool, size: Vector3, at: Vector3, rot := Vector3.ZERO) -> void:
	var m := BoxMesh.new()
	m.size = size
	st.append_from(m, 0, Transform3D(Basis.from_euler(rot), at))


static func _cyl(
	st: SurfaceTool, r0: float, r1: float, h: float, at: Vector3, rot: Vector3, seg := 10
) -> void:
	var m := CylinderMesh.new()
	m.top_radius = r1
	m.bottom_radius = r0
	m.height = h
	m.radial_segments = seg
	m.rings = 1
	st.append_from(m, 0, Transform3D(Basis.from_euler(rot), at))


static func _mat(c: Color, rough := 0.6, metal := 0.0) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = c
	m.roughness = rough
	m.metallic = metal
	return m


func _add_surface(st: SurfaceTool, mat: Material) -> void:
	var mesh := st.commit()
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	mi.material_override = mat
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(mi)


func _new_st() -> SurfaceTool:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	return st


## Вперёд — −Z, вправо — +X. Нос в z = −6,3, хвост в z = +6,4.
func _build_model(_cfg: Dictionary, rng: RandomNumberGenerator) -> void:
	var scheme := rng.randi_range(0, 2)  # 0 серебро+красный, 1 серебро+синий, 2 зелёный
	var body_c := Color(0.72, 0.74, 0.77)
	var accent_c := Color(0.75, 0.10, 0.10)
	if scheme == 1:
		accent_c = Color(0.10, 0.25, 0.72)
	elif scheme == 2:
		body_c = Color(0.22, 0.38, 0.20)
		accent_c = Color(0.86, 0.86, 0.80)
	var hull := _new_st()  # основной цвет
	var acc := _new_st()  # полосы, законцовки
	var dark := _new_st()  # шасси, мотор, стойки
	# фюзеляж: капот, кабина, хвостовой конус
	_cyl(dark, 0.72, 0.72, 1.6, Vector3(0, 0, -5.4), Vector3(PI / 2, 0, 0), 14)
	_box(hull, Vector3(1.55, 2.0, 4.6), Vector3(0, 0.1, -2.5))
	_cyl(hull, 0.85, 0.28, 6.0, Vector3(0, 0.25, 3.4), Vector3(-PI / 2, 0, 0), 8)
	_box(acc, Vector3(1.58, 0.28, 10.0), Vector3(0, 0.05, -0.2))  # полоса вдоль борта
	# крылья: верхнее 18,2 м, нижнее 14,2 м
	_box(hull, Vector3(18.2, 0.28, 2.4), Vector3(0, 1.85, -1.6))
	_box(hull, Vector3(14.2, 0.24, 1.9), Vector3(0, -0.75, -1.5))
	for sx in [-1.0, 1.0]:
		_box(acc, Vector3(0.9, 0.3, 2.42), Vector3(sx * 8.85, 1.85, -1.6))
		_box(acc, Vector3(0.7, 0.26, 1.92), Vector3(sx * 6.75, -0.75, -1.5))
		# межкрыльевые стойки (по две пары) и подкосы
		for zz in [-2.1, -0.9]:
			_box(dark, Vector3(0.09, 2.7, 0.09), Vector3(sx * 3.9, 0.55, zz))
		_box(dark, Vector3(0.08, 3.4, 0.08), Vector3(sx * 2.6, 0.3, -1.5), Vector3(0, 0, sx * 0.55))
		# стабилизатор
		_box(hull, Vector3(2.7, 0.14, 1.4), Vector3(sx * 1.55, 0.95, 6.0))
		# шасси: ноги и колёса
		_box(
			dark, Vector3(0.1, 1.5, 0.12), Vector3(sx * 0.95, -1.35, -2.5), Vector3(0, 0, sx * 0.25)
		)
		_cyl(dark, 0.5, 0.5, 0.32, Vector3(sx * 1.25, -1.95, -2.5), Vector3(0, 0, PI / 2), 12)
	_box(hull, Vector3(0.14, 2.3, 1.9), Vector3(0, 1.5, 6.1))  # киль
	_box(acc, Vector3(0.16, 0.7, 1.4), Vector3(0, 2.4, 6.3))
	_cyl(dark, 0.2, 0.2, 0.14, Vector3(0, -0.2, 6.0), Vector3(0, 0, PI / 2), 8)  # хвостовое колесо
	_add_surface(hull, _mat(body_c, 0.45, 0.35))
	_add_surface(acc, _mat(accent_c, 0.6, 0.0))
	_add_surface(dark, _mat(Color(0.10, 0.10, 0.11), 0.8, 0.0))
	# диск винта — полупрозрачный
	var disc := CylinderMesh.new()
	disc.top_radius = 1.75
	disc.bottom_radius = 1.75
	disc.height = 0.02
	disc.radial_segments = 20
	disc.rings = 1
	var dm := StandardMaterial3D.new()
	dm.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	dm.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	dm.albedo_color = Color(0.25, 0.25, 0.25, 0.28)
	dm.cull_mode = BaseMaterial3D.CULL_DISABLED
	disc.material = dm
	var prop := MeshInstance3D.new()
	prop.mesh = disc
	prop.rotation = Vector3(PI / 2, 0, 0)
	prop.position = Vector3(0, 0, -6.35)
	prop.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(prop)


# ---------------------------------------------------------------- звук


## Одна секунда мотора (петля): гармоники 150 Гц с падающим спектром, биения винта
## (4 лопасти ≈ 88 Гц), неровность вспышек 3 Гц и медленная 1 Гц. Детерминирован, без rng.
static func engine_sound() -> AudioStreamWAV:
	if _sound_cache != null:
		return _sound_cache
	var amps := [1.0, 0.75, 0.55, 0.5, 0.32, 0.28, 0.2, 0.16, 0.12, 0.09, 0.07, 0.05]
	var period := PackedFloat32Array()
	period.resize(PERIOD)
	for i in PERIOD:
		var v := 0.0
		for k in amps.size():
			v += float(amps[k]) * sin(TAU * (k + 1) * i / PERIOD + 0.7 * k)
		period[i] = v
	var n := RATE
	var data := PackedByteArray()
	data.resize(n * 2)
	var lp := 0.0
	var seed_v := 12345
	for i in n:
		var t := float(i) / RATE
		seed_v = (seed_v * 1103515245 + 12345) & 0x7fffffff
		var noise := float(seed_v) / 1073741824.0 - 1.0
		lp += 0.08 * (noise - lp)
		var am := 1.0 + 0.25 * sin(TAU * 3.0 * t) + 0.12 * sin(TAU * 88.0 * t + 1.0)
		am *= 1.0 + 0.1 * sin(TAU * 1.0 * t + 2.0)
		var s := period[i % PERIOD] * 0.16 * am + sin(TAU * 88.0 * t) * 0.22 + lp * 0.6
		data.encode_s16(i * 2, int(clampf(s * 0.55, -1.0, 1.0) * 32000.0))
	var w := AudioStreamWAV.new()
	w.format = AudioStreamWAV.FORMAT_16_BITS
	w.mix_rate = RATE
	w.stereo = false
	w.data = data
	w.loop_mode = AudioStreamWAV.LOOP_FORWARD
	w.loop_begin = 0
	w.loop_end = n
	_sound_cache = w
	return w


func _build_sound(cfg: Dictionary) -> void:
	_player = AudioStreamPlayer3D.new()
	_player.stream = engine_sound()
	_player.bus = "Ambient" if AudioServer.get_bus_index("Ambient") >= 0 else "Master"
	_player.attenuation_model = AudioStreamPlayer3D.ATTENUATION_INVERSE_DISTANCE
	_player.unit_size = float(cfg.get("sound_unit_m", 100.0))
	_player.max_distance = float(cfg.get("sound_max_m", 3000.0))
	_player.volume_db = float(cfg.get("sound_volume_db", 0.0))
	_player.attenuation_filter_cutoff_hz = float(cfg.get("sound_filter_hz", 5000.0))
	_player.doppler_tracking = AudioStreamPlayer3D.DOPPLER_TRACKING_IDLE_STEP
	add_child(_player)
	_player.autoplay = true
