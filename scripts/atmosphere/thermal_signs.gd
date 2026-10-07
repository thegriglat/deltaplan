class_name ThermalSigns
extends Node3D
## Мелкие признаки молодого термика (VR-24, QL-9): стайка ласточек/стрижей — быстрые рывки низко
## над источником — и пух с мусором, поднимающиеся по оси. Только над термиками field.thermals:
## сила ≥ min_strength_ms, «молодой» (от рождения до конца роста + young_extra_s), у источника
## (20–150 м над землёй). Положение — чистая функция времени и термика (ось axis_at(y)), без
## состояния: тот же день — те же признаки. Размер на экране не меньше min_px (шейдер).

var atmo: Atmosphere
var cfg: Dictionary

var _mm_sw: MultiMesh
var _mm_fl: MultiMesh
## Активные источники: [{th: AtmoThermal, kind: "swallow"|"fluff", id: int, n: int}].
var _entries: Array[Dictionary] = []
var _acc: float = 1.0e9


func setup(atmosphere: Atmosphere) -> void:
	atmo = atmosphere
	cfg = atmo.cfg.thermal_signs
	var maxn := int(cfg.max_thermals)
	_mm_sw = _make_mm(_swallow_mesh(), maxn * int(cfg.swallows_per_flock[1]), 0, float(cfg.swallow_span_m))
	_mm_fl = _make_mm(_fluff_mesh(), maxn * int(cfg.fluff_count), 1, float(cfg.fluff_size_m))


func _make_mm(mesh: Mesh, count: int, mode: int, ref: float) -> MultiMesh:
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.use_custom_data = true
	mm.mesh = mesh
	mm.instance_count = count
	mm.visible_instance_count = 0
	var mat := ShaderMaterial.new()
	mat.shader = load("res://scripts/atmosphere/thermal_signs.gdshader")
	mat.set_shader_parameter("mode", mode)
	mat.set_shader_parameter("ref_size", ref)
	mat.set_shader_parameter("min_px", float(cfg.min_px))
	mat.set_shader_parameter("max_scale", float(cfg.max_scale))
	mat.set_shader_parameter("color_a", _col(cfg.color_swallow if mode == 0 else cfg.color_fluff))
	mat.set_shader_parameter("color_b", _col(cfg.color_debris))
	var mmi := MultiMeshInstance3D.new()
	mmi.multimesh = mm
	mmi.material_override = mat
	mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	mmi.extra_cull_margin = float(cfg.radius_m) + 500.0
	add_child(mmi)
	return mm


static func _col(a: Array) -> Color:
	return Color(float(a[0]), float(a[1]), float(a[2]))


func _swallow_mesh() -> Mesh:
	var h := float(cfg.swallow_span_m) * 0.5
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	for s in [1.0, -1.0]:
		st.add_vertex(Vector3(0, 0, -0.07 * h * 2.0))
		st.add_vertex(Vector3(s * h, 0.0, h * 0.35))
		st.add_vertex(Vector3(0, 0, h * 0.3))
	# Тело сбоку (вертикальный клин): иначе в профиль, при горизонтальных крыльях, птицы не видно.
	st.add_vertex(Vector3(0, 0, -0.14 * h))
	st.add_vertex(Vector3(0, 0.2 * h, 0.35 * h))
	st.add_vertex(Vector3(0, -0.2 * h, 0.35 * h))
	# Раздвоенный хвост.
	st.add_vertex(Vector3(0, 0, 0.1 * h))
	st.add_vertex(Vector3(-0.25 * h, 0, h * 0.9))
	st.add_vertex(Vector3(0.25 * h, 0, h * 0.9))
	return st.commit()


func _fluff_mesh() -> Mesh:
	var q := QuadMesh.new()
	q.size = Vector2.ONE * float(cfg.fluff_size_m)
	return q


func _process(_delta: float) -> void:
	if atmo == null:
		return
	_acc += _delta
	if _acc > 1.0:
		_acc = 0.0
		refresh(_eye())
	_draw(atmo.time_s)


func _eye() -> Vector3:
	var cam := get_viewport().get_camera_3d() if is_inside_tree() else null
	return cam.global_position if cam != null else atmo.get_focus()


## Термик молодой и достаточно сильный: от рождения до конца роста + young_extra_s.
## Статические (тесты) — всегда.
func is_young(th: AtmoThermal, t: float) -> bool:
	if th.strength < float(cfg.min_strength_ms):
		return false
	if th.is_static:
		return true
	var age := t - th.t_birth
	return age >= 0.05 * th.t_grow and age <= th.t_grow + float(cfg.young_extra_s)


## Какие признаки есть у термика (детерминированно от id): ["swallow"], ["fluff"], оба или пусто.
func kinds_of(th: AtmoThermal) -> Array[String]:
	var rng := RandomNumberGenerator.new()
	rng.seed = th.id * 104729 + 17
	var out: Array[String] = []
	if rng.randf() < float(cfg.swallow_chance):
		out.append("swallow")
	if rng.randf() < float(cfg.fluff_chance):
		out.append("fluff")
	return out


## Дальность видимости вида признака, м: не дальше, чем глаз различает объект его размера
## (size / eye_res_mrad) и не дальше radius_m.
func range_of(kind: String) -> float:
	var size := float(cfg.swallow_span_m) if kind == "swallow" else float(cfg.fluff_size_m)
	return minf(float(cfg.radius_m), size / (float(cfg.eye_res_mrad) * 1.0e-3))


## Пересобрать активные источники у точки eye: новые молодые термики с признаками добирают
## свободные слоты (ближние первыми), угасшие/далёкие убираются.
func refresh(eye: Vector3) -> void:
	var t := atmo.time_s
	var r := float(cfg.radius_m)
	var r2 := r * r
	var cands: Array = []
	for id in atmo.field.thermals:
		var th: AtmoThermal = atmo.field.thermals[id]
		if not is_young(th, t):
			continue
		var dx := th.src.x - eye.x
		var dz := th.src.z - eye.z
		var d2 := dx * dx + dz * dz
		if d2 > r2:
			continue
		for k in kinds_of(th):
			if d2 <= range_of(k) * range_of(k):
				cands.append([d2, int(th.id), k, th])
	cands.sort_custom(func(a: Array, b: Array) -> bool: return a[0] < b[0])
	var maxn := int(cfg.max_thermals)
	var keep: Array[Dictionary] = []
	var have := {}
	for e in _entries:
		# Уже показанные остаются, пока молоды и в радиусе (без дёрганья при смене ближних).
		var th: AtmoThermal = e.th
		if atmo.field.thermals.get(th.id) == th and is_young(th, t) and Vector2(
				th.src.x - eye.x, th.src.z - eye.z).length_squared() <= r2 * 1.21:
			keep.append(e)
			have["%d_%s" % [e.id, e.kind]] = true
	for c in cands:
		if keep.size() >= maxn:
			break
		var key := "%d_%s" % [c[1], c[2]]
		if have.has(key):
			continue
		keep.append(_make_entry(c[3], c[2]))
		have[key] = true
	_entries = keep


func _make_entry(th: AtmoThermal, kind: String) -> Dictionary:
	var rng := RandomNumberGenerator.new()
	rng.seed = th.id * 7907 + (3 if kind == "swallow" else 5)
	var n := 1
	if kind == "swallow":
		n = rng.randi_range(int(cfg.swallows_per_flock[0]), int(cfg.swallows_per_flock[1]))
	else:
		n = int(cfg.fluff_count)
	return {"th": th, "kind": kind, "id": int(th.id), "n": n}


## Положения всех признаков в момент t: [{id, kind, pos: Vector3, th}] (для рисования и замера).
func positions(t: float) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for e in _entries:
		var th: AtmoThermal = e.th
		for i in int(e.n):
			var d: Dictionary = _swallow(th, i, t) if e.kind == "swallow" else _fluff(th, i, t)
			if d.is_empty():
				continue
			d["id"] = e.id
			d["kind"] = e.kind
			d["th"] = th
			out.append(d)
	return out


func _lateral(th: AtmoThermal, key: String, frac: float) -> float:
	return minf(float(cfg[key]), th.radius * frac)


func _swallow(th: AtmoThermal, i: int, t: float) -> Dictionary:
	var rng := RandomNumberGenerator.new()
	rng.seed = th.id * 6151 + i * 31 + 1
	var lat := _lateral(th, "swallow_lateral_m", 0.6)
	var hb: Array = cfg.swallow_height_agl_m
	var hmid := (float(hb[0]) + float(hb[1])) * 0.5
	var hamp := (float(hb[1]) - float(hb[0])) * 0.5
	# Частота — из скорости рывков: v ≈ lat · ω; вторая гармоника даёт резкие развороты.
	var w := float(cfg.swallow_speed_ms) / maxf(lat, 1.0) * rng.randf_range(0.7, 1.2)
	var ph := [rng.randf() * TAU, rng.randf() * TAU, rng.randf() * TAU, rng.randf() * TAU]
	# Вертикаль — медленно: частота из вертикальной скорости 2–3 м/с (v_vert = hamp · w3).
	var w3 := rng.randf_range(2.0, 3.0) / maxf(hamp, 1.0)
	var f := func(tt: float) -> Vector3:
		var x := lat * (0.75 * sin(w * tt + ph[0]) + 0.25 * sin(2.7 * w * tt + ph[2]))
		var z := lat * (0.75 * sin(w * 0.83 * tt + ph[1]) + 0.25 * sin(2.3 * w * tt + ph[3]))
		var hy := hmid + hamp * sin(w3 * tt + ph[0] * 0.5)
		var y := th.src.y + hy
		var a := th.axis_at(y)
		return Vector3(a.x + x, y, a.y + z)
	var p: Vector3 = f.call(t)
	var p2: Vector3 = f.call(t + 0.1)
	return {"pos": p, "vel": (p2 - p) / 0.1, "phase": rng.randf()}


## Пух поднимается с воздухом: dy/dt = w_поля(точка частицы) − оседание (fluff_settle_ms);
## w — из ThermalField.sample (профиль (dh/150)^(1/3) у земли и т. д.), высота — численный
## интеграл по шагам от момента отрыва (повтор отрыва каждые P с, P своё у каждой частицы).
## Граница модели: огибающая и поле берутся на текущий момент (за прошлые ≤ P секунд не
## пересчитываются); турбулентности отрыва у земли в модели нет — частица стартует с 1 м.
## Где w ≤ оседания, пух не поднимается (пустой результат).
func _fluff(th: AtmoThermal, i: int, t: float) -> Dictionary:
	var rng := RandomNumberGenerator.new()
	rng.seed = th.id * 9931 + i * 17 + 2
	var period := rng.randf_range(float(cfg.fluff_period_s[0]), float(cfg.fluff_period_s[1]))
	var off := rng.randf()
	var age := t - (floorf(t / period - off) + off) * period
	var lat := _lateral(th, "fluff_lateral_m", 0.4)
	var ang := rng.randf() * TAU
	var rr0 := lat * sqrt(rng.randf())
	var sway_k := rng.randf_range(0.4, 1.0)
	var debris := 1.0 if rng.randf() < 0.3 else 0.0
	var settle := float(cfg.fluff_settle_ms)
	var steps := 6
	var dt := age / float(steps)
	var h := 1.0
	var hmax := float(cfg.fluff_height_agl_m[1])
	for _k in steps:
		var y := th.src.y + h
		var a := th.axis_at(y)
		var w: float = atmo.field.sample(Vector3(a.x + cos(ang) * rr0, y, a.y + sin(ang) * rr0)).x
		h += (w - settle) * dt
		if h <= 0.0 or h >= hmax:
			return {}
	if age < 0.5 or h < 1.5:
		return {}
	var u := h / hmax
	var rr := rr0 * (1.0 - 0.5 * u)
	var sway := 2.0 * sin(t * sway_k + ang)
	var y2 := th.src.y + h
	var a2 := th.axis_at(y2)
	var alpha := smoothstep(0.0, 3.0, age) * (1.0 - smoothstep(0.7 * period, period, age)) \
		* (1.0 - smoothstep(0.7, 1.0, u))
	return {
		"pos": Vector3(a2.x + cos(ang) * rr + sway, y2, a2.y + sin(ang) * rr),
		"alpha": alpha, "debris": debris, "age": age,
	}


func _draw(t: float) -> void:
	var ns := 0
	var nf := 0
	for d in positions(t):
		if d.kind == "swallow":
			if ns >= _mm_sw.instance_count:
				continue
			var v: Vector3 = d.vel
			var fwd := v.normalized() if v.length() > 0.1 else Vector3.FORWARD
			var basis := Basis.looking_at(fwd, Vector3.UP)
			_mm_sw.set_instance_transform(ns, Transform3D(basis, d.pos))
			_mm_sw.set_instance_custom_data(ns, Color(1.0, 0.0, d.phase, 0.0))
			ns += 1
		else:
			if nf >= _mm_fl.instance_count:
				continue
			_mm_fl.set_instance_transform(nf, Transform3D(Basis.IDENTITY, d.pos))
			_mm_fl.set_instance_custom_data(nf, Color(d.alpha, d.debris, 0.0, 0.0))
			nf += 1
	_mm_sw.visible_instance_count = ns
	_mm_fl.visible_instance_count = nf
