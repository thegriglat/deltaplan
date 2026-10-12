class_name EggPeople
extends EasterEgg
## Люди на старте (чисто картинка): 3–8 простых фигурок у палаток лагеря пилотов. Переминаются
## и прохаживаются около своих мест; когда игрок низко проходит над лагерем, поворачиваются к
## нему и машут руками (локальная анимация, К3). По MultiMesh на часть модели camp_person.glb
## (ноги, торс, голова, правая, левая рука; запасной путь — капсулы), экземпляр i — человек i. Положение и руки — функция ctx.t.
## Порядок бросков rng в begin: число людей; на каждого — палатка, угол, расстояние от края
## палатки, курс, фазы, рост, цвета (рубашка, штаны, кожа).

const PARTS := 5  ## ноги, торс, голова, левая рука, правая рука
const SHOULDER_Y := 1.42
const MODEL := "res://assets/models/world/camp_person.glb"
const PART_NODES := ["Legs", "Torso", "Head", "ArmR", "ArmL"]

## Итоги для тестов: [{home: Vector3, tent: int, edge_m: float}]
var info: Array[Dictionary] = []

var _cfg: Dictionary = {}
var _people: Array[Dictionary] = []
var _mms: Array[MultiMesh] = []  ## по MultiMesh на часть; экземпляр i — человек i
var _mmis: Array[MultiMeshInstance3D] = []
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
		var origin := Vector3(pos.x - _center.x, g - _center.y, pos.y - _center.z)
		var b := Basis(Vector3.UP, yaw)
		var s: float = float(p.h) / 1.75
		var sb := b.scaled(Vector3(s, s, s))
		# ноги, торс, голова
		_set_part(0, i, sb, origin, Vector3(0, 0.43, 0), Vector3(0.3, 0.43, 0.26), Basis.IDENTITY)
		_set_part(1, i, sb, origin, Vector3(0, 1.12, 0), Vector3(0.4, 0.33, 0.25), Basis.IDENTITY)
		_set_part(2, i, sb, origin, Vector3(0, 1.62, 0), Vector3(0.22, 0.13, 0.22), Basis.IDENTITY)
		# руки: r — поднять и махать; в покое чуть покачиваются
		var wave := 0.35 * sin(t * 7.0 + ph.w * TAU)
		var a_r := lerpf(0.12 + 0.05 * sin(0.5 * t + ph.x), up + wave, r)
		var a_l := lerpf(0.12 + 0.05 * sin(0.5 * t + ph.y), up - wave * 0.6, r * step_on(ph.w))
		p.arm = maxf(a_l, a_r)
		for side in 2:
			var sx := 1.0 if side == 0 else -1.0
			var a := a_r if side == 0 else a_l
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
