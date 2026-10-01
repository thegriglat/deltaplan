class_name EggEagle
extends EasterEgg
## «Орёл» (E11, docs/plan/world_easter_eggs.md): крупная хищная птица (размах ~2 м) появляется
## сзади-сбоку, медленно обгоняет дельтаплан по пологой диагонали мимо законцовки в 5–15 м со
## скоростью крыла +2–4 м/с, затем по плавной дуге уходит в ближайший термик и кружит в нём
## с набором, пока не уйдёт из вида или не кончится lifetime_s; термика нет — уходит вперёд
## и исчезает вдали. Голову к пилоту не поворачивает. Только картинка.
##
## Траектория задаётся в begin от положения, курса и скорости крыла в момент появления (без
## слежения и подстройки): обгон — прямая в системе крыла, движущейся с его скоростью при
## появлении; дуга — кривая Эрмита от конца обгона к точке входа в круг; круг — вокруг оси
## термика (наклон + снос AtmoThermal.drift_at — функция времени). Всё — функция ctx.t − t0.
## Термик ищется общим поиском птиц BirdFlock.near_thermals (только чтение поля термиков).
## Порядок бросков rng в begin: сторона, прибавка скорости, угол диагонали, промах, высота.
## Локальная по смыслу (К4): от игрока, у каждого пилота своя.

## Крыло в момент появления {pos, vel} — подмена для тестов (пусто — телеметрия игры).
var wing: Dictionary = {}
## Параметры прохода (для тестов): сторона ±1, прибавка скорости, м/с, промах, м.
var side := 1.0
var dv := 3.0
var miss_m := 10.0
## Термик, к которому летит (null — нет).
var thermal: AtmoThermal
## Длительности фаз, с: обгон, дуга.
var pass_s := 28.0
var arc_s := 0.0
## Скорость набора в термике, м/с.
var climb_ms := 0.0

var _cfg: Dictionary = {}
var _p0 := Vector3.ZERO  ## крыло в t0
var _v := Vector3.ZERO  ## скорость крыла при появлении
var _tip := Vector3.ZERO  ## законцовка относительно центра крыла
var _c := Vector3.ZERO  ## точка наибольшего сближения относительно центра крыла
var _vrel := Vector3.ZERO  ## скорость орла относительно крыла
var _t_in := 14.0
var _q1 := Vector3.ZERO  ## конец обгона
var _w1 := Vector3.ZERO  ## скорость в конце обгона
var _e := Vector3.ZERO  ## точка входа в круг
var _arc_m0 := Vector2.ZERO
var _arc_m1 := Vector2.ZERO
var _phi_e := 0.0
var _turn := 1.0
var _radius := 25.0
var _top := INF
var _leave_dv := Vector3.ZERO  ## прибавка скорости при уходе вдаль (без термика)
var _mm: MultiMesh
var _scale := 1.0


## Условия: день, не пасмурно, пилот в воздухе на разумной высоте, горы со скалами, термик рядом.
static func can_appear(ctx: EggContext, cfg: Dictionary) -> bool:
	if ctx.sun_elev_deg < float(cfg.get("sun_min_deg", 5.0)) or ctx.sky == "overcast":
		return false
	var g := _game_of(ctx.terrain)
	if g != null and g.glider != null and g.glider.get_telemetry().on_ground:
		return false
	var p := ctx.pilot_pos
	var agl := p.y - float(ctx.height_at.call(p.x, p.z))
	if agl < float(cfg.get("agl_min_m", 40.0)) or agl > float(cfg.get("agl_max_m", 1500.0)):
		return false
	if not rocky_mountains(ctx.place, p, cfg):
		return false
	return not find_thermal(ctx, p, cfg).is_empty()


## Горы со скалами вокруг точки: is_mountain под ней и хоть одна проба вокруг — голые скалы
## (BARE) или крутые луг/кустарник. Равнина и сплошной лес без скал — нет.
static func rocky_mountains(place: EggPlace, p: Vector3, cfg: Dictionary) -> bool:
	if place == null or not place.is_mountain(p.x, p.z):
		return false
	var r := float(cfg.get("rock_radius_m", 600.0))
	var steep := float(cfg.get("rock_slope_deg", 30.0))
	for ring: float in [0.0, 0.5, 1.0]:
		var n := 1 if ring == 0.0 else 8
		for k in n:
			var a := TAU * float(k) / float(n)
			var x := p.x + cos(a) * r * ring
			var z := p.z + sin(a) * r * ring
			var s := place.surface_at(x, z)
			if s == SurfaceLayer.BARE:
				return true
			if (s == SurfaceLayer.GRASS or s == SurfaceLayer.SHRUB) and place.slope_deg_at(x, z) > steep:
				return true
	return false


## Ближайший к точке подходящий термик (поиск птиц BirdFlock.near_thermals): [d², id, термик]
## или [] — нет воздуха или термиков в радиусе.
static func find_thermal(ctx: EggContext, p: Vector3, cfg: Dictionary) -> Array:
	if ctx.air == null:
		return []
	var field: Variant = ctx.air.get("field")
	if field == null:
		return []
	var ths: Variant = field.get("thermals")
	if not ths is Dictionary:
		return []
	var t_air := float(ctx.air.get("time_s")) if ctx.air.get("time_s") != null else ctx.t
	var c := BirdFlock.near_thermals(
		ths,
		t_air,
		p,
		float(cfg.get("thermal_radius_m", 1500.0)),
		float(cfg.get("thermal_min_ms", 1.0))
	)
	return c[0] if not c.is_empty() else []


static func _game_of(n: Node) -> Game:
	while n != null:
		if n is Game:
			return n
		n = n.get_parent()
	return null


func begin(ctx: EggContext, cfg: Dictionary, rng: RandomNumberGenerator, p_t0: float) -> void:
	_cfg = cfg
	var since := ctx.t - p_t0  # прыжок времени: крыло «сейчас» — это t0 + since
	_read_wing(ctx)
	_p0 = Vector3(wing.pos) - Vector3(wing.vel) * since
	_v = wing.vel
	var f := Vector3(_v.x, 0.0, _v.z)
	if f.length() < 1.0:
		f = _cam_forward(ctx)
	f = f.normalized()
	var right := f.cross(Vector3.UP).normalized()
	# броски — строго в этом порядке
	side = 1.0 if rng.randf() < 0.5 else -1.0
	var dvr: Array = cfg.get("overtake_ms", [2.0, 4.0])
	dv = rng.randf_range(float(dvr[0]), float(dvr[1]))
	var angr: Array = cfg.get("diagonal_deg", [5.0, 12.0])
	var ang := deg_to_rad(rng.randf_range(float(angr[0]), float(angr[1])))
	var mr: Array = cfg.get("miss_m", [6.0, 13.0])
	miss_m = rng.randf_range(float(mr[0]), float(mr[1]))
	var hr: Array = cfg.get("height_m", [-2.0, 3.0])
	var h := clampf(rng.randf_range(float(hr[0]), float(hr[1])), -miss_m * 0.5, miss_m * 0.5)
	# обгон: прямая в системе крыла; ближе всего к законцовке — через _t_in с
	_tip = right * side * float(cfg.get("wingtip_m", 5.0))
	_vrel = (f * cos(ang) + right * side * sin(ang)) * dv
	var n := right * side * cos(ang) - f * sin(ang)  # наружу, ⟂ _vrel
	_c = _tip + n * sqrt(miss_m * miss_m - h * h) + Vector3.UP * h
	_t_in = float(cfg.get("pass_in_s", 14.0))
	pass_s = _t_in + float(cfg.get("pass_out_s", 14.0))
	_q1 = _pass_pos(pass_s)
	_w1 = _v + _vrel
	# дуга в ближайший термик или уход вдаль
	var hit := find_thermal(ctx, _q1, cfg)
	if not hit.is_empty():
		thermal = hit[2]
		_plan_arc()
	else:
		var wh := Vector3(_w1.x, 0.0, _w1.z)
		var turn := deg_to_rad(float(_cfg.get("leave_turn_deg", 25.0))) * side
		var out := wh.normalized().rotated(Vector3.UP, -turn)  # наружу, от крыла
		_leave_dv = out * (wh.length() + float(_cfg.get("leave_extra_ms", 6.0))) - wh
	_build_mesh(cfg)
	update(ctx)


func _read_wing(ctx: EggContext) -> void:
	if not wing.is_empty():
		return
	var g := _game_of(ctx.terrain)
	if g != null and g.glider != null:
		var tel: Telemetry = g.glider.get_telemetry()
		wing = {"pos": tel.position, "vel": tel.velocity}
		return
	wing = {"pos": ctx.pilot_pos, "vel": _cam_forward(ctx) * 12.0}


static func _cam_forward(ctx: EggContext) -> Vector3:
	if ctx.camera != null and ctx.camera.is_inside_tree():
		var fw := -ctx.camera.global_transform.basis.z
		fw.y = 0.0
		if fw.length() > 0.1:
			return fw.normalized()
	return Vector3(0.0, 0.0, -1.0)


## Ось термика на высоте y в момент t (наклон + снос — функция времени, AtmoThermal).
func _axis(y: float, t: float) -> Vector2:
	var th := thermal
	var dh := maxf(y - th.src.y, 0.0)
	var d := th.drift_at(t)
	return Vector2(th.src.x + th.lean.x * dh + d.x, th.src.z + th.lean.y * dh + d.y)


func _plan_arc() -> void:
	var speed := maxf(Vector2(_w1.x, _w1.z).length(), 6.0)
	_radius = float(_cfg.get("circle_radius_m", 25.0))
	_top = thermal.top - float(_cfg.get("top_margin_m", 60.0))
	var sink := float(_cfg.get("glide_sink_ratio", 0.08))
	var q := Vector2(_q1.x, _q1.z)
	var w := Vector2(_w1.x, _w1.z).normalized()
	arc_s = 20.0
	_e.y = _q1.y
	# три прохода: точка входа зависит от времени входа (снос) и высоты (наклон оси)
	for _i in 3:
		var cc := _axis(_e.y, t0 + pass_s + arc_s)
		var to_c := cc - q
		var u := to_c.normalized() if to_c.length() > 1.0 else w
		_turn = 1.0 if w.x * u.y - w.y * u.x >= 0.0 else -1.0
		# точка круга, где касательная (по направлению кружения) совпадает с u
		_phi_e = atan2(-u.x, u.y) if _turn > 0.0 else atan2(u.x, -u.y)
		var e2 := cc + Vector2(cos(_phi_e), sin(_phi_e)) * _radius
		var chord := maxf((e2 - q).length(), 1.0)
		_arc_m0 = w * chord
		_arc_m1 = u * chord
		_e.x = e2.x
		_e.z = e2.y
		var length := _hermite_len(q, e2)
		arc_s = maxf(length / speed, 2.0)
		_e.y = clampf(_q1.y - length * sink, thermal.src.y + 50.0, maxf(_top, thermal.src.y + 50.0))
	climb_ms = clampf(
		thermal.strength * float(_cfg.get("climb_frac", 0.7)) - float(_cfg.get("sink_ms", 0.8)),
		float(_cfg.get("climb_min_ms", 0.4)),
		float(_cfg.get("climb_max_ms", 4.0))
	)


func _hermite(q: Vector2, e: Vector2, s: float) -> Vector2:
	var s2 := s * s
	var s3 := s2 * s
	return (
		q * (2.0 * s3 - 3.0 * s2 + 1.0)
		+ _arc_m0 * (s3 - 2.0 * s2 + s)
		+ e * (-2.0 * s3 + 3.0 * s2)
		+ _arc_m1 * (s3 - s2)
	)


func _hermite_len(q: Vector2, e: Vector2) -> float:
	var length := 0.0
	var prev := q
	for k in range(1, 17):
		var p := _hermite(q, e, k / 16.0)
		length += (p - prev).length()
		prev = p
	return length


## Положение на обгоне (возраст age, с): крыло (прямо, со скоростью при появлении) + прямая
## в его системе.
func _pass_pos(age: float) -> Vector3:
	return _p0 + _v * age + _c + _vrel * (age - _t_in)


## Положение орла в возрасте age, с (функция только age и параметров begin).
func pos_at(age: float) -> Vector3:
	if age <= pass_s:
		return _pass_pos(age)
	var a := age - pass_s
	if thermal == null:
		# уход вдаль: за leave_turn_s плавно доворачивает наружу и прибавляет скорость
		var ta := float(_cfg.get("leave_turn_s", 6.0))
		return _q1 + _w1 * a + _leave_dv * (a * a / (2.0 * ta) if a < ta else a - ta * 0.5)
	if a <= arc_s:
		var s := a / arc_s
		var h := _hermite(Vector2(_q1.x, _q1.z), Vector2(_e.x, _e.z), s)
		return Vector3(h.x, lerpf(_q1.y, _e.y, s), h.y)
	var tc := a - arc_s
	var y := minf(_e.y + climb_ms * tc, maxf(_top, _e.y))
	var phi := _phi_e + _turn * float(_cfg.get("circle_speed_ms", 12.0)) / _radius * tc
	var ax := _axis(y, t0 + age)
	return Vector3(ax.x + cos(phi) * _radius, y, ax.y + sin(phi) * _radius)


## Законцовка крыла в возрасте age при прямолинейном полёте (для тестов).
func wingtip_at(age: float) -> Vector3:
	return _p0 + _v * age + _tip


## Скорость орла относительно крыла на обгоне, м/с.
func overtake_speed() -> float:
	return _vrel.length()


func _build_mesh(cfg: Dictionary) -> void:
	var mesh := _load_mesh(String(cfg.get("model_path", "res://assets/models/bird.glb")))
	var span := float(cfg.get("span_m", 2.0))
	var w := mesh.get_aabb().size.x if mesh != null else 0.0
	_scale = span / w if w > 0.01 else 1.0
	_mm = MultiMesh.new()
	_mm.transform_format = MultiMesh.TRANSFORM_3D
	_mm.use_custom_data = true
	_mm.mesh = mesh
	_mm.instance_count = 1
	var mat := ShaderMaterial.new()
	mat.shader = load("res://scripts/atmosphere/bird.gdshader")
	var c: Array = cfg.get("color", [0.2, 0.13, 0.07])
	mat.set_shader_parameter("color", Color(float(c[0]), float(c[1]), float(c[2])))
	mat.set_shader_parameter("flap_hz", float(cfg.get("flap_hz", 1.6)))
	var mmi := MultiMeshInstance3D.new()
	mmi.multimesh = _mm
	mmi.material_override = mat
	mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(mmi)


## Меш птицы игры (первый MeshInstance3D модели) или простая «галочка».
static func _load_mesh(path: String) -> Mesh:
	if path != "" and ResourceLoader.exists(path):
		var scene: PackedScene = load(path)
		if scene != null:
			var root := scene.instantiate()
			var mesh: Mesh = null
			var stack: Array[Node] = [root]
			while not stack.is_empty() and mesh == null:
				var nd: Node = stack.pop_back()
				if nd is MeshInstance3D:
					mesh = (nd as MeshInstance3D).mesh
				stack.append_array(nd.get_children())
			root.free()
			if mesh != null:
				return mesh
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	for s in [1.0, -1.0]:
		st.add_vertex(Vector3(0, 0, -0.3))
		st.add_vertex(Vector3(s, 0.1, 0.1))
		st.add_vertex(Vector3(0, 0, 0.4))
	return st.commit()


func update(ctx: EggContext) -> bool:
	var age := ctx.t - t0
	if lifetime_s > 0.0 and age > lifetime_s:
		return false
	var p := pos_at(age)
	var eye := ctx.pilot_pos
	if ctx.camera != null and ctx.camera.is_inside_tree():
		eye = ctx.camera.global_position
	if age > pass_s and p.distance_to(eye) > float(_cfg.get("vanish_m", 800.0)):
		return false
	position = p
	if _mm == null:
		return true
	# курс и крен — по самой траектории (голова к пилоту не поворачивается)
	var dt := 0.25
	var v1 := p - pos_at(age - dt)
	var v2 := pos_at(age + dt) - p
	var fwd := (v1 + v2) * 0.5
	var basis := Basis()
	if fwd.length_squared() > 1.0e-6:
		var h1 := Vector2(v1.x, v1.z)
		var h2 := Vector2(v2.x, v2.z)
		var om := atan2(h1.x * h2.y - h1.y * h2.x, h1.dot(h2)) / dt  # > 0 — поворот вправо
		var spd := fwd.length() / dt
		var bank := clampf(atan(spd * om / Units.G), -0.8, 0.8)
		basis = Basis.looking_at(fwd, Vector3.UP).rotated(fwd.normalized(), bank)
	_mm.set_instance_transform(0, Transform3D(basis.scaled(Vector3.ONE * _scale), Vector3.ZERO))
	# взмахи — редкими сериями, остальное время парит
	var period := float(_cfg.get("flap_period_s", 9.0))
	var flap := (
		float(_cfg.get("flap_amplitude", 0.35))
		if fmod(age, period) < float(_cfg.get("flap_burst_s", 1.5))
		else 0.0
	)
	_mm.set_instance_custom_data(0, Color(0.0, flap, 0.0, 0.0))
	return true
