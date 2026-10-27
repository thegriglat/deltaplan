class_name BirdFlock
extends Node3D
## Птицы — честный природный признак подъёма (FR-22, VR-8): кружат в термиках (в т.ч. слабых,
## где дельтаплану уже тяжело — birds.min_strength_ms), набирают высоту реальной скоростью
## подъёма на своей высоте (air_velocity_at), у верха термика/под кромкой облака расходятся и
## планируют к следующему. Реагируют на пилота (положение камеры): ближе flee_radius_m —
## отваливают и уходят; редко пара птиц терпит пилота и кружит рядом с ним в том же термике.
## Одна MultiMesh на всех птиц. Модель — configs/atmosphere.json → birds.model_path,
## если файла нет — простая процедурная «галочка».

var atmo: Atmosphere
var cfg: Dictionary

var _mm: MultiMesh
var _mmi: MultiMeshInstance3D
## Стаи: [ядро подъёма (запись parse_cores, обновляется на месте), птицы (Array[Dictionary]),
## id ядра на момент выбора, хищная ли].
## Птица: phase (угол на круге), radius, dir (±1), y, state ("circle"|"flee"|"glide"),
## thermal (текущее ядро), next_thermal (куда планирует), companion (не боится пилота),
## pos (мировая позиция кадра), flee_dir, flee_t, glide_from/target/t/total.
var _flocks: Array = []
var _acc: float = 1.0e9
## Размах модели в метрах (aabb.x меша): экземпляр хищной птицы масштабируется до своего span_m.
var _model_span: float = 1.6
var _last_eye: Vector3 = Vector3.INF
## Положение наблюдателя (пилот) — по умолчанию активная камера; тестам и превью можно задать.
var eye_fn: Callable = Callable()
## Записи ядер подъёма по id (W6 cores), обновляются на месте: стая держит ссылку на запись, а
## ядро, исчезнувшее из выдачи, остаётся с последним известным состоянием.
var _cores: Dictionary = {}
## Стаи: 4-й элемент записи — true для одиночной хищной птицы (вне max_flocks).


func setup(atmosphere: Atmosphere) -> void:
	atmo = atmosphere
	cfg = atmo.cfg.birds
	_mm = MultiMesh.new()
	_mm.transform_format = MultiMesh.TRANSFORM_3D
	_mm.use_custom_data = true
	_mm.mesh = _load_mesh(String(cfg.model_path))
	_model_span = maxf(_mm.mesh.get_aabb().size.x, 0.01)
	var mat := ShaderMaterial.new()
	mat.shader = load("res://scripts/atmosphere/bird.gdshader")
	var c: Array = cfg.color
	mat.set_shader_parameter("color", Color(float(c[0]), float(c[1]), float(c[2])))
	mat.set_shader_parameter("flap_hz", float(cfg.flap_hz))
	mat.set_shader_parameter("min_span_px", float(cfg.min_span_px))
	mat.set_shader_parameter("model_span_m", _model_span)
	_mmi = MultiMeshInstance3D.new()
	_mmi.multimesh = _mm
	_mmi.material_override = mat
	_mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	# Стаи разбросаны по radius_m вокруг пилота — не дать движку срезать дальних птиц по AABB меша.
	_mmi.extra_cull_margin = float(cfg.radius_m)
	add_child(_mmi)


## Меш птицы из модели (первый MeshInstance3D, масштаб — по размаху из конфига) или заглушка.
func _load_mesh(path: String) -> Mesh:
	if path != "" and ResourceLoader.exists(path):
		var scene: PackedScene = load(path)
		if scene != null:
			var root := scene.instantiate()
			var mi := _find_mesh(root)
			var mesh: Mesh = mi.mesh if mi != null else null
			root.free()
			if mesh != null:
				return mesh
	push_warning("BirdFlock: модель '%s' не найдена — процедурная заглушка" % path)
	var half := float(cfg.span_m) * 0.5
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	for s in [1.0, -1.0]:
		st.add_vertex(Vector3(0, 0, -0.15))
		st.add_vertex(Vector3(s * half, 0.08, 0.05))
		st.add_vertex(Vector3(0, 0, 0.2))
	return st.commit()


func _find_mesh(n: Node) -> MeshInstance3D:
	if n is MeshInstance3D:
		return n
	for c in n.get_children():
		var r := _find_mesh(c)
		if r != null:
			return r
	return null


func _process(delta: float) -> void:
	if atmo == null:
		return
	_acc += delta
	if _acc > 1.0:
		_acc = 0.0
		_choose_flocks()
	_place_birds(delta)


## Раздать птиц ближайшим достаточно сильным и зрелым термикам (в т.ч. слабым — VR-8), не
## трогая уже летающие стаи: новые термики только добирают свободные слоты до max_flocks,
## опустевшие стаи (птицы разлетелись/спуганы) убираются.
func _choose_flocks() -> void:
	var eye := _eye()
	var rad := float(cfg.radius_m)
	_refresh_cores(eye, rad * 1.5)
	var have: Dictionary = {}
	for entry in _flocks:
		have[int(entry[2])] = true
	var heading := _heading(eye)
	var n_flocks := 0
	var n_r := 0
	var have_r: Dictionary = {}
	for entry in _flocks:
		if bool(entry[3]):
			have_r[int(entry[2])] = true
			n_r += 1
		else:
			n_flocks += 1
	var cands := near_thermals(
		_cores.values(),
		eye,
		rad,
		float(cfg.min_strength_ms),
		have,
		heading,
		float(cfg.ahead_bias)
	)
	var slots := int(cfg.max_flocks) - n_flocks
	for i in mini(cands.size(), maxi(slots, 0)):
		_spawn_flock(cands[i][2], cands[i][1])
	# Хищные птицы: по одной, в глубоких термиках выше raptor_min_height_m над источником.
	var r_need := float(cfg.raptor_min_height_m) + float(cfg.top_margin_m)
	for c in cands:
		if n_r >= int(cfg.max_raptors):
			break
		var th: Dictionary = c[2]
		if have_r.has(int(c[1])) or float(th.top) - float(th.y_src) < r_need:
			continue
		_spawn_flock(th, c[1], true)
		n_r += 1
	for i in range(_flocks.size() - 1, -1, -1):
		if (_flocks[i][1] as Array).is_empty():
			_flocks.remove_at(i)
	_last_eye = eye


## Горизонтальный курс пилота (единичный) по сдвигу наблюдателя за секунду, иначе по взгляду
## камеры; нулевой, если ни того ни другого.
func _heading(eye: Vector3) -> Vector2:
	if _last_eye != Vector3.INF:
		var d := Vector2(eye.x - _last_eye.x, eye.z - _last_eye.z)
		if d.length() > 2.0:
			return d.normalized()
	var cam := get_viewport().get_camera_3d() if is_inside_tree() else null
	if cam != null:
		var f := -cam.global_transform.basis.z
		var h := Vector2(f.x, f.z)
		if h.length() > 0.1:
			return h.normalized()
	return Vector2.ZERO


## Положение наблюдателя: eye_fn, иначе активная камера, иначе начало координат.
func _eye() -> Vector3:
	if eye_fn.is_valid():
		return eye_fn.call()
	var cam := get_viewport().get_camera_3d() if is_inside_tree() else null
	return cam.global_position if cam != null else Vector3.ZERO


## Ядра подъёма фасада (W6) → записи: id, static, cloud, cb, x, z (ось на высоте земли источника,
## со сносом), y_src, top, w (пик с огибающей), env (огибающая 0..1 — из стадии), strength
## (w / env), radius, lean (Vector2), age, life, stage, seed, storm, src (Vector3).
static func parse_cores(d: PackedFloat32Array) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	var n := Atmosphere.CORE_STRIDE
	for k in range(0, d.size() - n + 1, n):
		var fl := int(d[k + Atmosphere.CORE_FLAGS])
		var st := d[k + Atmosphere.CORE_STAGE]
		var env := 1.0
		if st < 1.0:
			env = smoothstep(0.0, 1.0, st)
		elif st >= 2.0:
			env = 1.0 - smoothstep(0.0, 1.0, st - 2.0)
		var w := d[k + Atmosphere.CORE_W]
		out.append(
			{
				"id": int(d[k + Atmosphere.CORE_ID]),
				"static": (fl & 1) != 0,
				"cloud": (fl & 2) != 0,
				"cb": (fl & 4) != 0,
				"x": d[k + Atmosphere.CORE_X],
				"z": d[k + Atmosphere.CORE_Z],
				"y_src": d[k + Atmosphere.CORE_Y_SRC],
				"top": d[k + Atmosphere.CORE_TOP],
				"w": w,
				"env": env,
				"strength": w / env if env > 1.0e-6 else 0.0,
				"radius": d[k + Atmosphere.CORE_RADIUS],
				"lean": Vector2(d[k + Atmosphere.CORE_LEAN_X], d[k + Atmosphere.CORE_LEAN_Z]),
				"age": d[k + Atmosphere.CORE_AGE],
				"life": d[k + Atmosphere.CORE_LIFE],
				"stage": st,
				"seed": int(d[k + Atmosphere.CORE_VIS_SEED]),
				"storm": d[k + Atmosphere.CORE_STORM],
				"src": Vector3(d[k + Atmosphere.CORE_X], d[k + Atmosphere.CORE_Y_SRC], d[k + Atmosphere.CORE_Z]),
			}
		)
	return out


## Ось ядра на высоте y (x, z): с наклоном и сносом, (ось термика на высоте y).
static func core_axis_at(c: Dictionary, y: float) -> Vector2:
	var dh := maxf(y - float(c.y_src), 0.0)
	var lean: Vector2 = c.lean
	return Vector2(float(c.x) + lean.x * dh, float(c.z) + lean.y * dh)


## Обновить записи ядер вокруг eye. Запись существующего id правится на месте (стаи держат ссылки).
func _refresh_cores(eye: Vector3, radius_m: float) -> void:
	for c in parse_cores(atmo.cores(eye, radius_m)):
		var rec: Dictionary = _cores.get(c.id, {})
		if rec.is_empty():
			_cores[c.id] = c
		else:
			rec.merge(c, true)


## Достаточно сильные (≥ min_strength_ms) и зрелые (огибающая ≥ 0,5) ядра, чья ось на высоте
## eye ближе radius_m по горизонтали, кроме id из skip: [квадрат расстояния, id, ядро] от
## ближнего к дальнему (при ненулевых heading и ahead_bias — по «взвешенной» дальности: ядро позади
## дальше в (1 + ahead_bias) раз, впереди — по-честному). Только чтение (птицы и орёл-пасхалка E11).
## cores — записи parse_cores.
static func near_thermals(
	cores: Array,
	eye: Vector3,
	radius_m: float,
	min_strength_ms: float,
	skip: Dictionary = {},
	heading: Vector2 = Vector2.ZERO,
	ahead_bias: float = 0.0
) -> Array:
	var cands: Array = []
	var r2 := radius_m * radius_m
	for th: Dictionary in cores:
		var id: int = th.id
		if skip.has(id):
			continue
		if float(th.strength) < min_strength_ms or float(th.env) < 0.5:
			continue
		var a := core_axis_at(th, clampf(eye.y, float(th.y_src), float(th.top)))
		var d := Vector2(a.x - eye.x, a.y - eye.z).length_squared()
		if d < r2:
			var score := d
			if ahead_bias > 0.0 and heading != Vector2.ZERO and d > 1.0:
				var cosv := (Vector2(a.x - eye.x, a.y - eye.z) / sqrt(d)).dot(heading)
				score = d * (1.0 + ahead_bias * (1.0 - cosv) * 0.5)
			cands.append([d, id, th, score])
	cands.sort_custom(func(x, y): return x[3] < y[3])
	return cands


## Новая стая птиц над термиком th (детерминированно от его noise_seed).
func _spawn_flock(th: Dictionary, id: int, raptor: bool = false) -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = int(th.seed) + (7919 if raptor else 0)
	var n := 1 if raptor else rng.randi_range(int(cfg.birds_per_flock[0]), int(cfg.birds_per_flock[1]))
	var band: Array = cfg.altitude_band_m
	# Редко пара птиц не боится пилота и кружит рядом с ним в том же термике.
	var companion_pair := not raptor and n >= 2 and rng.randf() < float(cfg.companion_chance)
	var birds: Array = []
	for k in n:
		var y_top := float(th.top) - float(cfg.top_margin_m)
		var y0 := clampf(
			float(th.y_src) + lerpf(float(band[0]), float(band[1]), rng.randf()),
			float(th.y_src) + float(band[0]),
			y_top
		)
		var span := _model_span
		var rad := rng.randf_range(float(cfg.circle_radius_m[0]), float(cfg.circle_radius_m[1]))
		if raptor:
			y0 = lerpf(float(th.y_src) + float(cfg.raptor_min_height_m), y_top, rng.randf())
			span = rng.randf_range(float(cfg.raptor_span_m[0]), float(cfg.raptor_span_m[1]))
			rad = rng.randf_range(float(cfg.raptor_circle_radius_m[0]), float(cfg.raptor_circle_radius_m[1]))
		birds.append(
			{
				"phase": rng.randf() * TAU,
				"radius": rad,
				"raptor": raptor,
				"span_m": span,
				"dir": 1.0 if rng.randf() < 0.5 else -1.0,
				"y": y0,
				"state": "circle",
				"thermal": th,
				"next_thermal": null,
				"companion": companion_pair and k < 2,
				"pos": Vector3(float(th.x), y0, float(th.z)),
				"flee_dir": Vector3.ZERO,
				"flee_t": 0.0,
				"glide_from": Vector3.ZERO,
				"glide_target": Vector3.ZERO,
				"glide_t": 0.0,
				"glide_total": 1.0,
			}
		)
	_flocks.append([th, birds, id, raptor])


## Другой термик из числа уже занятых птицами (не current) — куда планировать/куда вернуться
## после того, как пилот отпугнул птицу. null, если стай сейчас нет.
func _pick_next_thermal(current: Variant) -> Variant:
	var opts: Array = []
	for entry in _flocks:
		var th: Dictionary = entry[0]
		if th != current:
			opts.append(th)
	if opts.is_empty():
		return null
	return opts[randi() % opts.size()]


## Термик кончился/ушёл слишком далеко для планирования — берём курс по ветру, теряя высоту.
func _glide_away(b: Dictionary, pos: Vector3) -> void:
	# Курс по фоновому ветру на высоте птицы (W2 background_wind).
	var bw := atmo.background_wind(PackedFloat32Array([pos.y]))
	var wd := Vector2(bw[0], bw[1])
	var dir := wd.normalized() if wd.length() > 0.01 else Vector2(1.0, 0.0)
	var dist := float(cfg.glide_distance_m)
	b.next_thermal = null
	b.glide_target = Vector3(
		pos.x + dir.x * dist, maxf(pos.y - dist * 0.15, float(b.thermal.y_src) + 20.0), pos.z + dir.y * dist
	)


## Птица набрала высоту до верха/кромки облака или подъём на её высоте иссяк — расходится и
## планирует к следующему термику (или по ветру, если рядом больше нет ни одного).
func _start_glide(b: Dictionary, pos: Vector3) -> void:
	b.state = "glide"
	b.glide_from = pos
	b.glide_t = 0.0
	var target_th: Variant = _pick_next_thermal(b.thermal) if not bool(b.raptor) else null
	if target_th != null:
		var axis := core_axis_at(target_th, float(target_th.y_src))
		var band: Array = cfg.altitude_band_m
		b.next_thermal = target_th
		b.glide_target = Vector3(axis.x, float(target_th.y_src) + float(band[0]) * 0.5, axis.y)
	else:
		_glide_away(b, pos)
	var glide_v := maxf(float(cfg.glide_speed_ms), 1.0)
	b.glide_total = maxf(1.0, (b.glide_target - pos).length() / glide_v)


## Птица закончила отваливать от пилота — снова кружит (в прежнем термике либо в любом другом
## занятом стаей), если поблизости вообще есть куда; иначе улетает насовсем (false).
func _resume_after_flee(b: Dictionary, pos: Vector3) -> bool:
	if bool(b.raptor):
		return false
	var th: Variant = b.thermal if b.thermal != null else _pick_next_thermal(null)
	if th == null:
		th = _pick_next_thermal(null)
	if th == null:
		return false
	b.thermal = th
	b.state = "circle"
	b.phase = randf() * TAU
	b.radius = randf_range(float(cfg.circle_radius_m[0]), float(cfg.circle_radius_m[1]))
	var band: Array = cfg.altitude_band_m
	b.y = clampf(pos.y, float(th.y_src) + float(band[0]) * 0.3, float(th.top) - float(cfg.top_margin_m))
	return true


## Пилот подошёл ближе flee_radius_m — птица (кроме «привычной» пары) шарахается и уходит.
func _maybe_flee(b: Dictionary, pos: Vector3, eye: Vector3, flee_r2: float) -> bool:
	if bool(b.companion):
		return false
	var away := pos - eye
	if away.length_squared() >= flee_r2:
		return false
	b.state = "flee"
	b.flee_dir = away.normalized() if away.length() > 0.01 else Vector3(1.0, 0.0, 0.0)
	b.flee_t = 0.0
	return true


func _place_birds(delta: float = -1.0) -> void:
	var dt := clampf(delta if delta >= 0.0 else get_process_delta_time(), 0.0, 0.2)
	var eye := _eye()
	var t_now := float(atmo.status().time_s)
	if not _flocks.is_empty():
		_refresh_cores(eye, float(cfg.radius_m) * 1.5)
	var v := float(cfg.speed_ms)
	var flee_r2 := float(cfg.flee_radius_m) * float(cfg.flee_radius_m)
	var total := 0
	for entry in _flocks:
		total += (entry[1] as Array).size()
	if _mm.instance_count != total:
		_mm.instance_count = total
	var i := 0
	for entry in _flocks:
		var birds: Array = entry[1]
		for bi in range(birds.size() - 1, -1, -1):
			var b: Dictionary = birds[bi]
			var pos: Vector3 = b.pos
			var fwd := Vector3.ZERO
			var bank := 0.0
			match String(b.state):
				"circle":
					var th: Dictionary = b.thermal
					var radius := float(b.radius)
					var bdir := float(b.dir)
					var phase := float(b.phase)
					var w: float = v / maxf(radius, 1.0) * bdir
					phase += w * dt
					b.phase = phase
					var by := float(b.y)
					var axis := core_axis_at(th, by)
					pos = Vector3(axis.x + cos(phase) * radius, by, axis.y + sin(phase) * radius)
					var climb: float = atmo.sample(pos).y
					by += climb * dt
					b.y = by
					fwd = Vector3(-sin(phase), 0.0, cos(phase)) * bdir
					bank = atan(v * v / (Units.G * maxf(radius, 1.0))) * bdir
					if by >= float(th.top) - float(cfg.top_margin_m) or climb < float(cfg.min_climb_ms):
						_start_glide(b, pos)
					else:
						_maybe_flee(b, pos, eye, flee_r2)
				"flee":
					var flee_t := float(b.flee_t) + dt
					b.flee_t = flee_t
					var flee_dir: Vector3 = b.flee_dir
					pos = pos + flee_dir * float(cfg.flee_speed_ms) * dt
					fwd = flee_dir
					if flee_t > float(cfg.flee_duration_s) and not _resume_after_flee(b, pos):
						birds.remove_at(bi)
						continue
				"glide":
					var glide_t := float(b.glide_t) + dt
					b.glide_t = glide_t
					var glide_total := float(b.glide_total)
					var glide_from: Vector3 = b.glide_from
					var glide_target: Vector3 = b.glide_target
					var frac: float = clampf(glide_t / maxf(glide_total, 0.001), 0.0, 1.0)
					pos = glide_from.lerp(glide_target, frac)
					var dvec: Vector3 = glide_target - glide_from
					fwd = dvec.normalized() if dvec.length() > 0.01 else Vector3(0.0, 0.0, 1.0)
					if not _maybe_flee(b, pos, eye, flee_r2) and frac >= 1.0:
						if b.next_thermal != null:
							b.thermal = b.next_thermal
							b.state = "circle"
							b.phase = randf() * TAU
							b.radius = randf_range(
								float(cfg.circle_radius_m[0]), float(cfg.circle_radius_m[1])
							)
							b.y = pos.y
						else:
							birds.remove_at(bi)
							continue
			b.pos = pos
			var basis := Basis()
			if fwd.length_squared() > 1.0e-6:
				basis = Basis.looking_at(fwd, Vector3.UP).rotated(fwd.normalized(), -bank)
			basis = basis.scaled(Vector3.ONE * (float(b.span_m) / _model_span))
			_mm.set_instance_transform(i, Transform3D(basis, pos))
			var flap := (
				float(cfg.flap_amplitude)
				if fmod(t_now * 0.1 + b.phase, 1.0) < float(cfg.flap_fraction)
				else 0.0
			)
			_mm.set_instance_custom_data(i, Color(fmod(float(b.phase) / TAU, 1.0), flap, 0.0, 0.0))
			i += 1
