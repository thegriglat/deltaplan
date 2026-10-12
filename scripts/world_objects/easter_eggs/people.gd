class_name EggPeople
extends EasterEgg
## Люди на старте (чисто картинка): 3–8 простых фигурок у палаток лагеря пилотов. Переминаются
## и прохаживаются около своих мест; когда игрок низко проходит над лагерем, поворачиваются к
## нему и машут руками (локальная анимация, К3). По MultiMesh на часть модели camp_person.glb
## (ноги, торс, голова, правая, левая рука; запасной путь — капсулы), экземпляр i — человек i. Положение и руки — функция ctx.t.
## Вблизи (ближе near_m от камеры, с гистерезисом; не больше max_skinned человек) человек рисуется
## моделью camp_pilot.glb со скелетной анимацией (idle / walk / wave / wave_both, SC-K4 v2), в
## MultiMesh он скрыт; AnimationPlayer работает только у ближних. Раскраска та же, что у дальнего LOD.
## Порядок бросков rng в begin: число людей; на каждого — палатка, угол, расстояние от края
## палатки, курс, фазы, рост, цвета (рубашка, штаны, кожа).

const PARTS := 5  ## ноги, торс, голова, левая рука, правая рука
const SHOULDER_Y := 1.42
const MODEL := "res://assets/models/world/camp_person.glb"
const PART_NODES := ["Legs", "Torso", "Head", "ArmR", "ArmL"]
const NEAR_MODEL := "res://assets/models/world/camp_pilot.glb"
const WALK_STRIDE_M := 1.2  ## длина шага цикла walk, м (SC-11)
const BLEND_S := 0.35  ## плавный переход между анимациями, с
const HAIR_PALETTE: Array[Color] = [
	Color(0.12, 0.08, 0.05), Color(0.22, 0.15, 0.1), Color(0.4, 0.28, 0.16),
	Color(0.62, 0.5, 0.3), Color(0.55, 0.55, 0.55)
]
static var _skin_mats: Dictionary = {}  ## квантованный тон кожи → общий материал
static var _hair_mats: Dictionary = {}  ## индекс палитры → общий материал

## Итоги для тестов: [{home: Vector3, tent: int, edge_m: float}]
var info: Array[Dictionary] = []

var _cfg: Dictionary = {}
var _people: Array[Dictionary] = []
var _mms: Array[MultiMesh] = []  ## по MultiMesh на часть; экземпляр i — человек i
var _mmis: Array[MultiMeshInstance3D] = []
var _slot_of: Array[int] = []  ## человек i → номер ближнего экземпляра в _pool (−1 — дальний LOD)
var _pool: Array[Dictionary] = []  ## {root, ap, a, b, person, anim}; создаются по мере надобности
var _near_ok := true  ## модель camp_pilot.glb загрузилась
var _near_meshes: Array[Mesh] = []  ## [куртка+кожа+волосы+обувь, штаны] — тонируются по отдельности
var _near_max := 0  ## максимум одновременно ближних за жизнь
var _near_tris := 0
var _walk_mps := 1.1
var _hidden: Array[bool] = []  ## человек i скрыт в MultiMesh (ближний LOD рисует его сам)
var _model := false  ## части из camp_person.glb (иначе запасные капсулы)
var _center := Vector3.ZERO
var _camp_r := 0.0
var _shadow := false
var _last_t := NAN
var _last_tick := -1.0e9


## Условия: солнце выше −6°, есть место и в нём лагерь.
static func can_appear(ctx: EggContext, cfg: Dictionary) -> bool:
	if ctx.sun_elev_deg <= float(cfg.get("min_sun_deg", -6.0)):
		return false
	if ctx.place == null:
		return false
	return not ctx.place.camp().is_empty()


func begin(ctx: EggContext, cfg: Dictionary, rng: RandomNumberGenerator, _t0: float) -> void:
	_cfg = cfg
	if ctx.place == null:
		return
	var camp := ctx.place.camp()
	if camp.is_empty():
		return
	var c2 := Vector2.ZERO
	for t in camp:
		c2 += Vector2(t.position.x, t.position.z)
	c2 /= float(camp.size())
	for t in camp:
		_camp_r = maxf(_camp_r, c2.distance_to(Vector2(t.position.x, t.position.z)) + float(t.radius))
	_center = Vector3(c2.x, ctx.height_at.call(c2.x, c2.y), c2.y)
	position = _center
	var cr: Array = cfg.get("count", [3, 8])
	var n := rng.randi_range(int(cr[0]), int(cr[1]))
	var er: Array = cfg.get("edge_m", [3.0, 5.0])
	var gap := float(cfg.get("tent_gap_m", 1.5))
	var homes: Array[Vector2] = []
	for i in n:
		var ti := rng.randi_range(0, camp.size() - 1)
		var home := Vector2.ZERO
		var edge := 0.0
		for k in 8:  # место не ближе gap к любой палатке (край) и не в толпе
			var ang := rng.randf() * TAU
			edge = lerpf(float(er[0]), float(er[1]), rng.randf())
			var tp: Vector3 = camp[ti].position
			home = Vector2(tp.x, tp.z) + Vector2(cos(ang), sin(ang)) * (float(camp[ti].radius) + edge)
			if _spot_ok(home, camp, gap, homes):
				break
		homes.append(home)
		var tp2: Vector3 = camp[ti].position
		var ecl := home.distance_to(Vector2(tp2.x, tp2.z)) - float(camp[ti].radius)
		var p := {
			"tent": ti,
			"home": home,
			"yaw0": rng.randf() * TAU,
			"ph": Vector4(rng.randf() * TAU, rng.randf() * TAU, rng.randf() * TAU, rng.randf()),
			"h": lerpf(1.68, 1.82, rng.randf()),
			"shirt": _rand_color(rng, 0.0, 1.0, 0.4, 0.85, 0.5, 0.95),
			"pants": _rand_color(rng, 0.55, 0.7, 0.2, 0.6, 0.2, 0.5),
			"skin": Color(
				lerpf(0.75, 0.95, rng.randf()),
				lerpf(0.55, 0.72, rng.randf()),
				lerpf(0.42, 0.6, rng.randf())
			),
			"walk_dir": rng.randf() * TAU,
			"react": 0.0,
			"yaw": 0.0,
			"pos": home,
			"arm": 0.0,
		}
		p.yaw = p.yaw0
		_people.append(p)
		_slot_of.append(-1)
		info.append({"home": Vector3(home.x, 0.0, home.y), "tent": ti, "edge_m": ecl})
	var reach := _camp_r + 20.0
	var aabb := AABB(Vector3(-reach, -60.0, -reach), Vector3(reach * 2.0, 120.0, reach * 2.0))
	var meshes := _part_meshes()
	_model = not meshes.is_empty()
	if not _model:  # модели нет — запасной путь: капсулы
		var cap := CapsuleMesh.new()  # единичная: радиус 0,5, высота 2 — масштаб задаёт размеры
		cap.radius = 0.5
		cap.height = 2.0
		cap.radial_segments = 8
		cap.rings = 3
		var cmat := StandardMaterial3D.new()
		cmat.vertex_color_use_as_albedo = true
		cmat.roughness = 1.0
		cap.material = cmat
		for k in PARTS:
			meshes.append(cap)
	for k in PARTS:
		var mm := MultiMesh.new()
		mm.transform_format = MultiMesh.TRANSFORM_3D
		mm.use_colors = true
		mm.mesh = meshes[k]
		mm.instance_count = n
		for i in n:
			var p: Dictionary = _people[i]
			# ноги — штаны; голова — кожа; торс и руки — рубашка
			mm.set_instance_color(i, p.pants if k == 0 else (p.skin if k == 2 else p.shirt))
		mm.custom_aabb = aabb
		var mmi := MultiMeshInstance3D.new()
		mmi.multimesh = mm
		mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		mmi.visible = false
		add_child(mmi)
		_mms.append(mm)
		_mmis.append(mmi)


## Меши частей из camp_person.glb (порядок как PARTS) с материалами по именам; пусто, если модели нет.
func _part_meshes() -> Array[Mesh]:
	var out: Array[Mesh] = []
	if not ResourceLoader.exists(MODEL):
		return out
	var ps := load(MODEL) as PackedScene
	if ps == null:
		return out
	var root := ps.instantiate()
	var skin := StandardMaterial3D.new()
	skin.vertex_color_use_as_albedo = true
	skin.roughness = 0.8
	for nm in PART_NODES:
		var mi := root.get_node_or_null(nm) as MeshInstance3D
		if mi == null or mi.mesh == null:
			root.free()
			out.clear()
			return out
		var m: Mesh = mi.mesh.duplicate()
		for sidx in m.get_surface_count():
			var old := m.surface_get_material(sidx)
			var mname := old.resource_name if old != null else ""
			if mname == "Cloth":
				m.surface_set_material(sidx, CampFabric.material("cloth"))
			elif mname == "SkinTint":
				m.surface_set_material(sidx, skin)
		out.append(m)
	root.free()
	return out


func _rand_color(
	rng: RandomNumberGenerator, h0: float, h1: float, s0: float, s1: float, v0: float, v1: float
) -> Color:
	return Color.from_hsv(
		lerpf(h0, h1, rng.randf()), lerpf(s0, s1, rng.randf()), lerpf(v0, v1, rng.randf())
	)


func _spot_ok(
	h: Vector2, camp: Array[Dictionary], gap: float, others: Array[Vector2]
) -> bool:
	for j in camp.size():
		var tp: Vector3 = camp[j].position
		if h.distance_to(Vector2(tp.x, tp.z)) < float(camp[j].radius) + gap:
			return false
	for o in others:
		if h.distance_to(o) < 0.8:
			return false
	return true


## Скрыть/показать человека i в MultiMesh (нулевой масштаб экземпляров); виден после ближайшего update.
func set_person_visible(i: int, vis: bool) -> void:
	while _hidden.size() < _people.size():
		_hidden.append(false)
	_hidden[i] = not vis
	_last_tick = -1.0e9


func person_count() -> int:
	return _people.size()


## Положение человека i (x/z) после последнего обновления.
func person_pos(i: int) -> Vector2:
	return _people[i].pos


## Угол поднятия руки, рад (0 — вниз вдоль тела, π — вверх), максимум из двух рук.
func arm_angle(i: int) -> float:
	return _people[i].arm


func update(ctx: EggContext) -> bool:
	if _people.is_empty():
		return true  # force без лагеря: пасхалка жива, но показывать нечего
	var t := ctx.t
	var tick := float(_cfg.get("tick_s", 0.05))
	if t >= _last_tick and t - _last_tick < tick:
		return true
	_last_tick = t
	var cam := ctx.pilot_pos
	if ctx.camera != null and ctx.camera.is_inside_tree():
		cam = ctx.camera.global_position
	var d := cam.distance_to(_center)
	if d > _camp_r + float(_cfg.get("sleep_m", 1500.0)):
		for m in _mmis:
			m.visible = false
		_hide_all_near()
		_last_t = NAN
		return true
	for m in _mmis:
		m.visible = true
	var want := d < float(_cfg.get("shadow_m", 150.0))
	if want != _shadow:
		_shadow = want
		for m in _mmis:
			m.cast_shadow = (
				GeometryInstance3D.SHADOW_CASTING_SETTING_ON
				if want
				else GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
			)
	var dt := 0.0  # прыжок времени и первый кадр — без сглаживания (сразу в цель)
	if not is_nan(_last_t):
		var raw := t - _last_t
		dt = raw if raw > 0.0 and raw <= 0.5 else 0.0
	_last_t = t
	var pil := Vector2(ctx.pilot_pos.x, ctx.pilot_pos.z)
	var react_r := float(_cfg.get("react_radius_m", 150.0))
	var react_h := float(_cfg.get("react_height_m", 60.0))
	var gpil: float = ctx.height_at.call(pil.x, pil.y)
	var reacting := (
		pil.distance_to(Vector2(_center.x, _center.z)) < react_r + _camp_r
		and ctx.pilot_pos.y - gpil < react_h
	)
	var pace := float(_cfg.get("pace_m", 0.8))
	var up := float(_cfg.get("wave_raise_rad", 2.7))
	for i in _people.size():
		var p: Dictionary = _people[i]
		var ph: Vector4 = p.ph
		var dirv := Vector2(cos(p.walk_dir), sin(p.walk_dir))
		var pos: Vector2 = p.home + dirv * (pace * sin(0.25 * t + ph.x)) + Vector2(
			0.2 * sin(0.4 * t + ph.y), 0.2 * cos(0.35 * t + ph.z)
		)
		var moving := absf(cos(0.25 * t + ph.x)) * pace * 0.25 > 0.05
		# скорость перемещения (производная положения), м/с — темп шага ближней анимации
		var vel := dirv * (pace * 0.25 * cos(0.25 * t + ph.x)) + Vector2(
			0.08 * cos(0.4 * t + ph.y), -0.07 * sin(0.35 * t + ph.z)
		)
		p.speed = vel.length()
		p.moving = moving
		var target := 1.0 if reacting else 0.0
		var r: float = p.react
		r = target if dt == 0.0 else move_toward(r, target, dt / float(_cfg.get("react_s", 1.0)))
		p.react = r
		var base_yaw: float = p.yaw0 + 0.5 * sin(0.07 * t + ph.z)
		if moving:
			base_yaw = atan2(-dirv.x * signf(cos(0.25 * t + ph.x)), -dirv.y * signf(cos(0.25 * t + ph.x)))
		var to := Vector2(pil.x - pos.x, pil.y - pos.y)
		var yaw := base_yaw
		if r > 0.0 and to.length() > 0.5:
			yaw = lerp_angle(base_yaw, atan2(-to.x, -to.y), clampf(r * 1.5, 0.0, 1.0))
		p.yaw = yaw
		p.pos = pos
		var g: float = ctx.height_at.call(pos.x, pos.y)
		p.origin = Vector3(pos.x - _center.x, g - _center.y, pos.y - _center.z)
		var s: float = float(p.h) / 1.75
		p.sb = Basis(Vector3.UP, yaw).scaled(Vector3(s, s, s))
		p.dist = cam.distance_to(Vector3(pos.x, g + 1.0, pos.y))
		# руки: r — поднять и махать; в покое чуть покачиваются
		var wave := 0.35 * sin(t * 7.0 + ph.w * TAU)
		p.a_r = lerpf(0.12 + 0.05 * sin(0.5 * t + ph.x), up + wave, r)
		p.a_l = lerpf(0.12 + 0.05 * sin(0.5 * t + ph.y), up - wave * 0.6, r * step_on(ph.w))
		p.arm = maxf(p.a_l, p.a_r)
	_assign_near()
	for i in _people.size():
		var p: Dictionary = _people[i]
		var origin: Vector3 = p.origin
		var sb: Basis = p.sb
		if _slot_of[i] >= 0:
			_pose_near(i)
		# ноги, торс, голова
		_set_part(0, i, sb, origin, Vector3(0, 0.43, 0), Vector3(0.3, 0.43, 0.26), Basis.IDENTITY)
		_set_part(1, i, sb, origin, Vector3(0, 1.12, 0), Vector3(0.4, 0.33, 0.25), Basis.IDENTITY)
		_set_part(2, i, sb, origin, Vector3(0, 1.62, 0), Vector3(0.22, 0.13, 0.22), Basis.IDENTITY)
		for side in 2:
			var sx := 1.0 if side == 0 else -1.0
			var a: float = p.a_r if side == 0 else p.a_l
			if _model:  # шарнир в плече; поворот вокруг Z (рука вдоль −Y → вверх при a = π)
				if _is_hidden(i):
					_mms[3 + side].set_instance_transform(i, Transform3D(Basis.from_scale(Vector3.ZERO), origin))
					continue
				var tr := Transform3D(sb * Basis(Vector3.BACK, sx * a), origin + sb * Vector3(sx * 0.22, SHOULDER_Y, 0.0))
				_mms[3 + side].set_instance_transform(i, tr)
				continue
			var dir := Vector3(sx * sin(a), -cos(a), 0.0)
			var c := Vector3(sx * 0.22, SHOULDER_Y, 0.0) + dir * 0.3
			_set_part(3 + side, i, sb, origin, c, Vector3(0.1, 0.3, 0.1), Basis(Vector3.BACK, sx * a))
	return true


# ---------- ближний LOD: camp_pilot.glb со скелетом ----------


## Кто сейчас ближний: выходят дальше near_m + гистерезис, входят ближе near_m (ближайшие первыми),
## не больше max_skinned. Скрытый в MultiMesh ⇔ показан скелетный.
func _assign_near() -> void:
	var near_m := float(_cfg.get("near_m", 70.0))
	var hyst := float(_cfg.get("near_hyst_m", 10.0))
	var cap := int(_cfg.get("max_skinned", 8))
	var used := 0
	for i in _people.size():
		if _slot_of[i] >= 0:
			if float(_people[i].dist) > near_m + hyst:
				_release(i)
			else:
				used += 1
	if used < cap and _near_ok:
		var cand: Array[int] = []
		for i in _people.size():
			if _slot_of[i] < 0 and float(_people[i].dist) < near_m:
				cand.append(i)
		cand.sort_custom(func(x: int, y: int) -> bool: return float(_people[x].dist) < float(_people[y].dist))
		for i in cand:
			if used >= cap:
				break
			if _acquire(i):
				used += 1
	_near_max = maxi(_near_max, used)


func _hide_all_near() -> void:
	for i in _people.size():
		if _slot_of[i] >= 0:
			_release(i)


func _release(i: int) -> void:
	var sl: Dictionary = _pool[_slot_of[i]]
	_slot_of[i] = -1
	sl.person = -1
	sl.anim = ""
	var ap: AnimationPlayer = sl.ap
	ap.stop()
	ap.active = false
	ap.process_mode = Node.PROCESS_MODE_DISABLED
	sl.root.visible = false
	while _hidden.size() < _people.size():
		_hidden.append(false)
	_hidden[i] = false
	_last_tick = -1.0e9


## Занять ближний экземпляр человеком i: раскраска, анимация с его фазой.
func _acquire(i: int) -> bool:
	var k := -1
	for j in _pool.size():
		if int(_pool[j].person) < 0:
			k = j
			break
	if k < 0:
		k = _make_slot()
		if k < 0:
			_near_ok = false
			return false
	var sl: Dictionary = _pool[k]
	var p: Dictionary = _people[i]
	sl.person = i
	_slot_of[i] = k
	var a: MeshInstance3D = sl.a
	var b: MeshInstance3D = sl.b
	var sh: Color = p.shirt
	var pn: Color = p.pants
	a.set_instance_shader_parameter("tint", Vector3(sh.r, sh.g, sh.b))
	b.set_instance_shader_parameter("tint", Vector3(pn.r, pn.g, pn.b))
	var sk := _skin_material(p.skin)
	var hr := _hair_material(int(float(p.ph.w) * HAIR_PALETTE.size()))
	for s in a.mesh.get_surface_count():
		var nm := a.mesh.surface_get_material(s).resource_name
		if nm == "Skin":
			a.set_surface_override_material(s, sk)
		elif nm == "Hair":
			a.set_surface_override_material(s, hr)
	var ap: AnimationPlayer = sl.ap
	ap.process_mode = Node.PROCESS_MODE_INHERIT
	ap.active = true
	sl.root.visible = true
	sl.anim = "idle"
	ap.play("idle")
	ap.seek(fmod(float(p.ph.x), TAU) / TAU * ap.get_animation("idle").length, true)
	while _hidden.size() < _people.size():
		_hidden.append(false)
	_hidden[i] = true
	_last_tick = -1.0e9
	return true


## Положение, тень и анимация ближнего человека i по его состоянию.
func _pose_near(i: int) -> void:
	var p: Dictionary = _people[i]
	var sl: Dictionary = _pool[_slot_of[i]]
	var root: Node3D = sl.root
	# рост модели 1,78 м, а не 1,75
	var sb: Basis = (p.sb as Basis).scaled(Vector3.ONE * (1.75 / 1.78))
	root.transform = Transform3D(sb, p.origin)
	var mode := (
		GeometryInstance3D.SHADOW_CASTING_SETTING_ON
		if float(p.dist) < float(_cfg.get("shadow_m", 150.0))
		else GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	)
	(sl.a as MeshInstance3D).cast_shadow = mode
	(sl.b as MeshInstance3D).cast_shadow = mode
	var r: float = p.react
	var want: String = sl.anim
	if r > 0.3 or (want.begins_with("wave") and r > 0.1):
		want = "wave_both" if step_on(p.ph.w) >= 1.0 else "wave"
	elif p.moving:
		want = "walk"
	else:
		want = "idle"
	var ap: AnimationPlayer = sl.ap
	if want != sl.anim:
		sl.anim = want
		ap.play(want, BLEND_S)
	# темп шага под скорость перемещения: иначе ноги скользят
	ap.speed_scale = clampf(float(p.speed) / _walk_mps, 0.08, 1.6) if want == "walk" else 1.0


func _make_slot() -> int:
	if not ResourceLoader.exists(NEAR_MODEL):
		return -1
	var ps := load(NEAR_MODEL) as PackedScene
	if ps == null:
		return -1
	var root := ps.instantiate() as Node3D
	var body := root.find_child("PersonBody", true, false) as MeshInstance3D
	var ap := root.find_child("AnimationPlayer", true, false) as AnimationPlayer
	if body == null or ap == null:
		root.free()
		return -1
	if _near_meshes.is_empty():
		_near_meshes = _split_body(body.mesh)
	var b := MeshInstance3D.new()
	b.name = "PersonTrousers"
	body.get_parent().add_child(b)
	b.skin = body.skin
	b.skeleton = body.skeleton
	body.mesh = _near_meshes[0]
	b.mesh = _near_meshes[1]
	root.visible = false
	add_child(root)
	_near_tris = _mesh_tris(_near_meshes[0]) + _mesh_tris(_near_meshes[1])
	_walk_mps = WALK_STRIDE_M / maxf(0.1, ap.get_animation("walk").length)
	ap.active = false
	ap.process_mode = Node.PROCESS_MODE_DISABLED
	_pool.append({"root": root, "ap": ap, "a": body, "b": b, "person": -1, "anim": ""})
	return _pool.size() - 1


## Тело на два меша: куртка+кожа+волосы+обувь и штаны — у MeshInstance3D один instance-тон на меш.
func _split_body(src: Mesh) -> Array[Mesh]:
	var ma := ArrayMesh.new()
	var mb := ArrayMesh.new()
	for s in src.get_surface_count():
		var mat := src.surface_get_material(s)
		var dst: ArrayMesh = mb if mat.resource_name == "Trousers" else ma
		dst.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, src.surface_get_arrays(s))
		var idx := dst.get_surface_count() - 1
		if mat.resource_name == "Jacket" or mat.resource_name == "Trousers":
			dst.surface_set_material(idx, CampFabric.material("cloth"))
			dst.surface_set_name(idx, mat.resource_name)
		else:
			dst.surface_set_material(idx, mat)
	var out: Array[Mesh] = [ma, mb]
	return out


func _mesh_tris(m: Mesh) -> int:
	var n := 0
	for s in m.get_surface_count():
		var arr := m.surface_get_arrays(s)
		var idx = arr[Mesh.ARRAY_INDEX]
		n += (idx.size() if idx != null else arr[Mesh.ARRAY_VERTEX].size()) / 3
	return n


## Общий материал кожи по палитре (тон квантуется до 0,05): материалов мало, не по одному на человека.
func _skin_material(c: Color) -> Material:
	var q := Color(roundf(c.r * 20.0) / 20.0, roundf(c.g * 20.0) / 20.0, roundf(c.b * 20.0) / 20.0)
	var key := q.to_html(false)
	if not _skin_mats.has(key):
		var m := StandardMaterial3D.new()
		m.resource_name = "Skin_" + key
		m.albedo_color = q
		m.roughness = 0.8
		_skin_mats[key] = m
	return _skin_mats[key]


func _hair_material(k: int) -> Material:
	k = clampi(k, 0, HAIR_PALETTE.size() - 1)
	if not _hair_mats.has(k):
		var m := StandardMaterial3D.new()
		m.resource_name = "Hair_%d" % k
		m.albedo_color = HAIR_PALETTE[k]
		m.roughness = 0.9
		_hair_mats[k] = m
	return _hair_mats[k]


## Для тестов и отчёта: ближний ли человек i, его анимация, играет ли AnimationPlayer.
func is_near(i: int) -> bool:
	return _slot_of[i] >= 0


func near_count() -> int:
	var n := 0
	for k in _slot_of:
		n += 1 if k >= 0 else 0
	return n


func near_count_max() -> int:
	return _near_max


func near_tris() -> int:
	return _near_tris


func near_anim(i: int) -> String:
	return "" if _slot_of[i] < 0 else String(_pool[_slot_of[i]].anim)


## AnimationPlayer всех экземпляров пула: [{person, active, playing, disabled, visible}].
func near_players() -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for sl in _pool:
		var ap: AnimationPlayer = sl.ap
		out.append({
			"person": int(sl.person),
			"active": ap.active,
			"playing": ap.is_playing(),
			"disabled": ap.process_mode == Node.PROCESS_MODE_DISABLED,
			"visible": (sl.root as Node3D).visible,
		})
	return out


## Часть людей машет двумя руками, часть — одной (вторая опускается неполно).
func step_on(x: float) -> float:
	return 1.0 if x > 0.4 else 0.35


## Часть idx человека i: у модели — начало в шарнире (c), у капсул — центр c и масштаб sc.
func _set_part(
	idx: int, i: int, sb: Basis, origin: Vector3, c: Vector3, sc: Vector3, rot: Basis
) -> void:
	if _is_hidden(i):
		_mms[idx].set_instance_transform(i, Transform3D(Basis.from_scale(Vector3.ZERO), origin))
		return
	if _model:
		var joints := [Vector3.ZERO, Vector3(0, 0.95, 0), Vector3(0, 1.50, 0)]
		_mms[idx].set_instance_transform(i, Transform3D(sb * rot, origin + sb * joints[idx]))
		return
	var bb := sb * rot.scaled(sc)
	_mms[idx].set_instance_transform(i, Transform3D(bb, origin + sb * c))


func _is_hidden(i: int) -> bool:
	return i < _hidden.size() and _hidden[i]
