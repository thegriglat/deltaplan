class_name ThermalSigns
extends Node3D
## Мелкие признаки молодого термика (VR-24, QL-9): стайка ласточек/стрижей — быстрые рывки низко
## над источником — и пух с мусором, поднимающиеся по оси. Только над ядрами подъёма фасада (cores, W6):
## сила ≥ min_strength_ms, «молодой» (от рождения до конца роста + young_extra_s), у источника
## (20–150 м над землёй). Положение — чистая функция времени и ядра (ось на высоте y), без
## состояния: тот же день — те же признаки. Размер на экране не меньше min_px (шейдер).

var atmo: Atmosphere
var cfg: Dictionary
## Положение наблюдателя — по умолчанию активная камера; тестам и превью можно задать.
var eye_fn: Callable = Callable()

var _mm_sw: MultiMesh
var _mm_fl: MultiMesh
## Активные источники: [{th: ядро (запись BirdFlock.parse_cores), kind: "swallow"|"fluff", id: int,
## n: int, wtab: таблица подъёма пуха}].
var _entries: Array[Dictionary] = []
## Записи ядер по id: обновляются на месте каждый кадр (ядро в записи источника «живое»).
var _cores: Dictionary = {}
## id ядер из последней выдачи фасада.
var _live: Dictionary = {}
## Доля роста в жизни термика (средние grow_s / (grow_s + mature_s + decay_s) конфига): длительности
## роста в описании ядра (W6) нет — известны возраст, жизнь и стадия.
var _grow_share: float = 0.2
const WTAB_H := 16
const WTAB_R := 3
var _acc: float = 1.0e9


func setup(atmosphere: Atmosphere) -> void:
	atmo = atmosphere
	cfg = atmo.cfg.thermal_signs
	var tc: Dictionary = atmo.cfg.thermal
	var g := _mid(tc.grow_s)
	_grow_share = g / maxf(g + _mid(tc.mature_s) + _mid(tc.decay_s), 1.0e-6)
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


static func _mid(a: Array) -> float:
	return (float(a[0]) + float(a[1])) * 0.5


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
	elif not _entries.is_empty():
		_sync_cores(_eye())
	_draw()


func _eye() -> Vector3:
	if eye_fn.is_valid():
		return eye_fn.call()
	var cam := get_viewport().get_camera_3d() if is_inside_tree() else null
	return cam.global_position if cam != null else Vector3.ZERO


## Обновить записи ядер вокруг eye (на месте) и набор живых id.
func _sync_cores(eye: Vector3) -> void:
	_live.clear()
	for c in BirdFlock.parse_cores(atmo.cores(eye, float(cfg.radius_m) * 1.2)):
		_live[c.id] = true
		var rec: Dictionary = _cores.get(c.id, {})
		if rec.is_empty():
			_cores[c.id] = c
		else:
			rec.merge(c, true)


## Ядро молодое и достаточно сильное: от рождения до конца роста + young_extra_s. Статические
## (тесты) — всегда. Конец роста: стадия < 1 — рост идёт (точно); дальше — доля роста в жизни по
## конфигу (длительности роста в описании ядра нет; граница модели).
func is_young(th: Dictionary) -> bool:
	if float(th.strength) < float(cfg.min_strength_ms):
		return false
	if bool(th.static):
		return true
	var st := float(th.stage)
	if st < 1.0:
		return st >= 0.05
	var t_grow := float(th.life) * _grow_share
	return float(th.age) <= t_grow + float(cfg.young_extra_s)


## Какие признаки есть у термика (детерминированно от id): ["swallow"], ["fluff"], оба или пусто.
func kinds_of(th: Dictionary) -> Array[String]:
	var rng := RandomNumberGenerator.new()
	rng.seed = int(th.id) * 104729 + 17
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
	_sync_cores(eye)
	var r := float(cfg.radius_m)
	var r2 := r * r
	var cands: Array = []
	for id in _live:
		var th: Dictionary = _cores[id]
		if not is_young(th):
			continue
		var dx := float(th.x) - eye.x
		var dz := float(th.z) - eye.z
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
		var th: Dictionary = e.th
		if _live.has(th.id) and is_young(th) and Vector2(
				float(th.x) - eye.x, float(th.z) - eye.z).length_squared() <= r2 * 1.21:
			if e.kind == "fluff":
				e["wtab"] = _fluff_table(th)
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


func _make_entry(th: Dictionary, kind: String) -> Dictionary:
	var rng := RandomNumberGenerator.new()
	rng.seed = int(th.id) * 7907 + (3 if kind == "swallow" else 5)
	var n := 1
	if kind == "swallow":
		n = rng.randi_range(int(cfg.swallows_per_flock[0]), int(cfg.swallows_per_flock[1]))
	else:
		n = int(cfg.fluff_count)
	var wtab := _fluff_table(th) if kind == "fluff" else PackedFloat32Array()
	return {"th": th, "kind": kind, "id": int(th.id), "n": n, "wtab": wtab}


## Вертикальная скорость воздуха (W2 sample, SAMPLE_MEAN) над источником ядра: WTAB_H высот от земли
## до fluff_height_agl_m[1] × WTAB_R расстояний от оси до fluff_lateral_m. Строится раз в refresh:
## пух не опрашивает воздух в каждом кадре (граница модели: поле берётся на момент обновления).
func _fluff_table(th: Dictionary) -> PackedFloat32Array:
	var hmax := float(cfg.fluff_height_agl_m[1])
	var lat := _lateral(th, "fluff_lateral_m", 0.4)
	var pts := PackedVector3Array()
	for j in WTAB_H:
		var y := float(th.y_src) + 1.0 + (hmax - 1.0) * float(j) / float(WTAB_H - 1)
		var a := BirdFlock.core_axis_at(th, y)
		for i in WTAB_R:
			pts.append(Vector3(a.x + lat * float(i) / float(WTAB_R - 1), y, a.y))
	var r := atmo.sample_many(pts, Atmosphere.SAMPLE_MEAN)
	var tab := PackedFloat32Array()
	tab.resize(pts.size())
	for k in pts.size():
		tab[k] = r[4 * k + 1]
	return tab


## Высота отрыва пуха: у самой земли вертикальной скорости воздуха нет (граничное условие), а
## отрывает частицу турбулентность, которой в модели нет, — поэтому старт с самой низкой высоты
## таблицы, где подъём не меньше удвоенного оседания; нигде нет — пух не поднимается (−1).
func _fluff_start(
	tab: PackedFloat32Array, rr: float, lat: float, settle: float, hmax: float
) -> float:
	for j in WTAB_H:
		var h := 1.0 + (hmax - 1.0) * float(j) / float(WTAB_H - 1)
		if _wlookup(tab, h, rr, lat) >= 2.0 * settle:
			return h
	return -1.0


## Подъём w из таблицы на высоте h над землёй источника и расстоянии rr от оси (билинейно).
func _wlookup(tab: PackedFloat32Array, h: float, rr: float, lat: float) -> float:
	if tab.size() != WTAB_H * WTAB_R:
		return 0.0
	var hmax := float(cfg.fluff_height_agl_m[1])
	var fj := clampf((h - 1.0) / maxf(hmax - 1.0, 1.0e-6), 0.0, 1.0) * float(WTAB_H - 1)
	var fi := clampf(rr / maxf(lat, 1.0e-6), 0.0, 1.0) * float(WTAB_R - 1)
	var j0 := mini(int(fj), WTAB_H - 2)
	var i0 := mini(int(fi), WTAB_R - 2)
	var u := fj - float(j0)
	var v := fi - float(i0)
	var a := lerpf(tab[j0 * WTAB_R + i0], tab[j0 * WTAB_R + i0 + 1], v)
	var b := lerpf(tab[(j0 + 1) * WTAB_R + i0], tab[(j0 + 1) * WTAB_R + i0 + 1], v)
	return lerpf(a, b, u)


## Положения всех признаков в момент t: [{id, kind, pos: Vector3, th}] (для рисования и замера).
func positions(t: float) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for e in _entries:
		var th: Dictionary = e.th
		for i in int(e.n):
			var d: Dictionary = (
				_swallow(th, i, t)
				if e.kind == "swallow"
				else _fluff(th, i, t, e.get("wtab", PackedFloat32Array()))
			)
			if d.is_empty():
				continue
			d["id"] = e.id
			d["kind"] = e.kind
			d["th"] = th
			out.append(d)
	return out


func _lateral(th: Dictionary, key: String, frac: float) -> float:
	return minf(float(cfg[key]), float(th.radius) * frac)


func _swallow(th: Dictionary, i: int, t: float) -> Dictionary:
	var rng := RandomNumberGenerator.new()
	rng.seed = int(th.id) * 6151 + i * 31 + 1
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
		var y := float(th.y_src) + hy
		var a := BirdFlock.core_axis_at(th, y)
		return Vector3(a.x + x, y, a.y + z)
	var p: Vector3 = f.call(t)
	var p2: Vector3 = f.call(t + 0.1)
	return {"pos": p, "vel": (p2 - p) / 0.1, "phase": rng.randf()}


## Пух поднимается с воздухом: dy/dt = w_поля(точка частицы) − оседание (fluff_settle_ms);
## w — вертикальная скорость воздуха из таблицы _fluff_table (W2 sample), высота — численный
## интеграл по шагам от момента отрыва (повтор отрыва каждые P с, P своё у каждой частицы).
## Граница модели: огибающая и поле берутся на текущий момент (за прошлые ≤ P секунд не
## пересчитываются); турбулентности отрыва у земли в модели нет — частица стартует с 1 м.
## Где w ≤ оседания, пух не поднимается (пустой результат).
func _fluff(th: Dictionary, i: int, t: float, wtab: PackedFloat32Array) -> Dictionary:
	var rng := RandomNumberGenerator.new()
	rng.seed = int(th.id) * 9931 + i * 17 + 2
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
	var hmax := float(cfg.fluff_height_agl_m[1])
	var h := _fluff_start(wtab, rr0, lat, settle, hmax)
	if h < 0.0:
		return {}
	for _k in steps:
		var w := _wlookup(wtab, h, rr0, lat)
		h += (w - settle) * dt
		if h <= 0.0 or h >= hmax:
			return {}
	if age < 0.5 or h < 1.5:
		return {}
	var u := h / hmax
	var rr := rr0 * (1.0 - 0.5 * u)
	var sway := 2.0 * sin(t * sway_k + ang)
	var y2 := float(th.y_src) + h
	var a2 := BirdFlock.core_axis_at(th, y2)
	var alpha := smoothstep(0.0, 3.0, age) * (1.0 - smoothstep(0.7 * period, period, age)) \
		* (1.0 - smoothstep(0.7, 1.0, u))
	return {
		"pos": Vector3(a2.x + cos(ang) * rr + sway, y2, a2.y + sin(ang) * rr),
		"alpha": alpha, "debris": debris, "age": age,
	}


func _draw() -> void:
	var ns := 0
	var nf := 0
	for d in positions(float(atmo.status().time_s)):
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
