class_name GliderVisual
extends Node3D
## Визуал дельтаплана: крыло + пилот (docs/flight.md → «Визуал и контракт моделей»).
##
## Крыло: wings/<id>.json → visual.visual_model. Начало координат модели — HangPoint;
## ноды Sail, ControlFrame, маркеры HangPoint, BaseBar, InstrumentMount, WingTipL, WingTipR.
## Пилот: pilot.json → visual.visual_model. Начало — карабин (вешается в HangPoint), лёжа,
## голова в −Z, пустышка Head — глаза. Пилот висит под нодой Pilot, которая сдвигается
## по крену и тангажу. Маркер PilotHead этой обёртки следует за Head (кабинная камера).
## Нет файла — заглушка из примитивов с теми же именами.
## Нода стоит в начале координат Glider (ноги пилота), 1 ед. = 1 м, вперёд −Z, вверх +Y.

const WING_MARKERS: Array[String] = [
	"HangPoint", "BaseBar", "InstrumentMount", "WingTipL", "WingTipR"
]
## Стоя (stand/walk/run из pilot.glb) ступни на ~0,3 м позади таза, ноги наклонены ~19°, глаза
## на ~0,7 м впереди ступней: взгляд вниз не достаёт до ног. Модель на земле чуть отклоняется
## назад вокруг хвата рук на стойках (руки остаются на стойках, ступни выходят под корпус).
const GROUND_LEAN_BACK_DEG := 15.0
## Хват рук на стойках в позе stand относительно карабина, м (+Y вверх, −Z вперёд).
const GROUND_GRIP := Vector3(0.0, -0.59, -0.43)
## Середина ступней (кости Foot) в позе stand относительно карабина без наклона, м.
const GROUND_FEET := Vector3(0.0, -1.905, 0.17)

var wing: Node3D  ## модель крыла
var pilot: Node3D  ## нода Pilot (качается маятником вокруг HangPoint), внутри — модель пилота
var head_marker: Marker3D  ## PilotHead: следует за Head модели пилота
## Смещение центра масс пилота от нейтрали (крен/тангаж ручкой), м, оси планера — для внешней
## камеры (game.gd → camera.body_shift_fn, camera_rig.gd → cockpit.head_follow_body): карабин
## пилота больше не сдвигается (маятник вокруг HangPoint), это поле — замена прежнего сдвига.
var body_shift := Vector3.ZERO
var sail_material: ShaderMaterial  ## шейдер паруса (SailMaterial), null — исходный материал

var _cfg: Dictionary = {}  ## flight.json → visual
var _pcfg: Dictionary = {}  ## pilot.json → visual
var _hang := Vector3.ZERO  ## точка подвески в координатах обёртки
var _head: Node3D
var _pose := Transform3D.IDENTITY
## Модель сама встаёт анимацией stand (docs/models.md → «Пилот»); иначе (заглушка) — поворот.
var _animated_stand := false


## wing_cfg — конфиг крыла, pilot_cfg — конфиг пилота, vis_cfg — flight.json → visual.
func build(wing_cfg: Dictionary, pilot_cfg: Dictionary, vis_cfg: Dictionary) -> void:
	_cfg = vis_cfg
	_pcfg = pilot_cfg.visual
	for n in get_children():
		remove_child(n)
		n.queue_free()
	_hang = Vector3(0, float(vis_cfg.hang_height_m), 0)

	var wpath := String(wing_cfg.visual.get("visual_model", ""))
	wing = _load_model(wpath)
	if wing == null:
		wing = _fallback_wing(wing_cfg)
	wing.name = "Wing"
	add_child(wing)
	var hp := wing.find_child("HangPoint", true, false) as Node3D
	wing.position = _hang - (_relative_xform(wing, hp).origin if hp != null else Vector3.ZERO)
	sail_material = null
	var sail := wing.find_child("Sail", true, false) as MeshInstance3D
	if sail != null and wpath != "" and ResourceLoader.exists(wpath):
		sail_material = SailMaterial.apply(sail, wpath.get_file().get_basename())
	for mname in WING_MARKERS:
		if wing.find_child(mname, true, false) == null:
			push_warning("GliderVisual: в модели %s нет ноды %s" % [wpath, mname])

	pilot = Node3D.new()
	pilot.name = "Pilot"
	add_child(pilot)
	var ppath := String(_pcfg.get("visual_model", ""))
	var pm := _load_model(ppath)
	if pm == null:
		pm = _fallback_pilot()
	pm.name = "Model"
	pilot.add_child(pm)
	_head = pm.find_child("Head", true, false) as Node3D
	_animated_stand = false
	for ap: AnimationPlayer in pm.find_children("*", "AnimationPlayer", true, false):
		_animated_stand = _animated_stand or ap.has_animation("stand")
	if _head == null:
		push_warning("GliderVisual: в модели %s нет ноды Head" % ppath)
	head_marker = Marker3D.new()
	head_marker.name = "PilotHead"
	add_child(head_marker)
	_pose = _flight_pose(Vector3.ZERO)
	set_pose(0.0, 0.0, true, 1.0e6)


## Маркер по имени: HangPoint, BaseBar, InstrumentMount, WingTipL, WingTipR (крыло), PilotHead.
func get_marker(marker_name: String) -> Node3D:
	if marker_name == "PilotHead":
		return head_marker
	return wing.find_child(marker_name, true, false) as Node3D if wing != null else null


## Точка глаз пилота в координатах обёртки (для кабинной камеры).
func get_head_transform() -> Transform3D:
	return head_marker.transform if head_marker != null else Transform3D.IDENTITY


## Парус (шейдер): воздушная скорость, м/с; срыв 0..1; болтанка 0..1.
func set_flight(airspeed_ms: float, stall_amount: float, turbulence: float) -> void:
	SailMaterial.set_flight(sail_material, airspeed_ms, stall_amount, turbulence)


## Поза пилота: сдвиг по крену (roll ±1) и тангажу (pitch ±1), лёжа в полёте / стоя на земле.
func set_pose(roll: float, pitch: float, flying: bool, dt: float) -> void:
	if pilot == null:
		return
	var shift := Vector3(
		clampf(roll, -1.0, 1.0) * float(_cfg.pilot_shift_m),
		0.0,
		clampf(pitch, -1.0, 1.0) * float(_cfg.pilot_bar_m)
	)
	var target := _flight_pose(shift) if flying else _ground_pose(shift)
	var k := 1.0 - exp(-dt / float(_cfg.input_smoothing_s))
	_pose = Transform3D(
		_pose.basis.slerp(target.basis, k).orthonormalized(), _pose.origin.lerp(target.origin, k)
	)
	pilot.transform = _pose
	# Смещение центра масс (уже сглаженное вместе с поворотом) — для внешней камеры.
	var c := _body_center()
	body_shift = (_pose.basis * c - c) if flying else Vector3.ZERO
	if _head != null:
		head_marker.transform = _relative_xform(self, _head)
	else:
		head_marker.transform = _pose * Transform3D(Basis.IDENTITY, _head_local())


## В полёте: карабин остаётся в точке подвески (маятник), тело поворачивается вокруг неё так,
## что центр масс пилота смещается на shift (крен — вокруг продольной оси Z, тангаж — вокруг
## поперечной оси X); угол = asin(смещение / L), L — расстояние HangPoint → центр масс пилота.
func _flight_pose(shift: Vector3) -> Transform3D:
	var basis := Basis.IDENTITY
	var l := _body_center().length()
	if l > 0.0001:
		var roll_ang := asin(clampf(shift.x / l, -1.0, 1.0))
		var pitch_ang := -asin(clampf(shift.z / l, -1.0, 1.0))
		basis = Basis(Vector3(0, 0, 1), roll_ang) * Basis(Vector3(1, 0, 0), pitch_ang)
	return Transform3D(basis, _hang)


## На земле: стоит под крылом, ноги на земле. Модель со скелетом ставит тело вертикально сама
## (анимации stand/walk/run: подошвы на hang_height_m ниже карабина) — на 90° не поворачиваем,
## только сдвиг по крену и небольшой наклон назад вокруг хвата (GROUND_LEAN_BACK_DEG), ступни
## остаются на той же высоте. Заглушка без анимаций лежит — её поворачиваем вокруг центра тела.
func _ground_pose(shift: Vector3) -> Transform3D:
	if _animated_stand:
		var lean := Basis(Vector3.RIGHT, deg_to_rad(GROUND_LEAN_BACK_DEG))
		var o := GROUND_GRIP - lean * GROUND_GRIP  # хват на месте
		o.y += GROUND_FEET.y - (lean * GROUND_FEET + o).y  # ступни на прежней высоте
		return Transform3D(lean, _hang + o + Vector3(shift.x, 0.0, 0.0))
	var c := _body_center()
	var r := Basis(Vector3.RIGHT, PI * 0.5)
	var g := Vector3(shift.x, float(_pcfg.height_m) * 0.5, 0.0)
	return Transform3D(r, g - r * c)


## Центр тела относительно карабина.
func _body_center() -> Vector3:
	return Vector3(0, -float(_pcfg.body_below_hang_m), float(_pcfg.body_back_m))


func _head_local() -> Vector3:
	return _body_center() + Vector3(0, 0.12, -float(_pcfg.height_m) * 0.47 - 0.17)


func _load_model(path: String) -> Node3D:
	if path == "":
		return null
	if not ResourceLoader.exists(path):
		push_warning("GliderVisual: нет модели %s — заглушка из примитивов" % path)
		return null
	var ps := load(path) as PackedScene
	return ps.instantiate() as Node3D if ps != null else null


static func _relative_xform(root: Node, node: Node3D) -> Transform3D:
	var x := Transform3D.IDENTITY
	var n: Node = node
	while n != null and n != root:
		if n is Node3D:
			x = (n as Node3D).transform * x
		n = n.get_parent()
	return x


# ---------------------------------------------------------------- заглушки


## Крыло с трапецией; начало координат — HangPoint.
func _fallback_wing(wing_cfg: Dictionary) -> Node3D:
	var root := Node3D.new()
	var wv: Dictionary = wing_cfg.visual
	var half := float(wing_cfg.span_m) * 0.5
	var nose := Vector3(0, 0, -float(wv.root_chord_m) * 0.6)
	var tip_z := nose.z + float(wv.sweep_m)
	_add_marker(root, "HangPoint", Vector3.ZERO)
	_add_marker(root, "WingTipL", Vector3(-half, 0, tip_z))
	_add_marker(root, "WingTipR", Vector3(half, 0, tip_z))
	root.add_child(_fallback_sail(wing_cfg, nose, half))
	root.add_child(_fallback_frame())
	return root


func _fallback_sail(wing_cfg: Dictionary, nose: Vector3, half: float) -> MeshInstance3D:
	var wv: Dictionary = wing_cfg.visual
	var tail := nose + Vector3(0, 0, float(wv.root_chord_m))
	var tip_r := nose + Vector3(half, 0, float(wv.sweep_m))
	var tip_l := nose + Vector3(-half, 0, float(wv.sweep_m))
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	for tri: Array in [[nose, tip_r, tail], [nose, tail, tip_l]]:
		for p: Vector3 in tri:
			st.add_vertex(p)
	st.generate_normals()
	var mi := MeshInstance3D.new()
	mi.name = "Sail"
	mi.mesh = st.commit()
	var c: Array = wv.color
	mi.material_override = _mat(Color(float(c[0]), float(c[1]), float(c[2])), true)
	var tube := _mat(Color(0.7, 0.7, 0.75))
	_add_rod(mi, "Keel", nose, tail, tube)
	_add_rod(mi, "LeadingEdgeL", nose, tip_l, tube)
	_add_rod(mi, "LeadingEdgeR", nose, tip_r, tube)
	return mi


func _fallback_frame() -> Node3D:
	var frame := Node3D.new()
	frame.name = "ControlFrame"
	var hang_h := float(_cfg.hang_height_m)
	var bar := Vector3(0, float(_cfg.base_bar_height_m) - hang_h, -float(_cfg.base_bar_forward_m))
	var w := Vector3(float(_cfg.base_bar_width_m) * 0.5, 0, 0)
	var m := _mat(Color(0.7, 0.7, 0.75))
	_add_rod(frame, "DownTubeL", Vector3.ZERO, bar - w, m)
	_add_rod(frame, "DownTubeR", Vector3.ZERO, bar + w, m)
	_add_rod(frame, "BaseBarTube", bar - w, bar + w, m)
	_add_marker(frame, "BaseBar", bar)
	var mount := (bar + w).lerp(Vector3.ZERO, 0.2)
	var im := _add_marker(frame, "InstrumentMount", mount)
	# экран прибора (+Z маркера) смотрит на глаза пилота
	im.basis = Basis.looking_at(_head_local() - mount, Vector3.UP, true)
	return frame


## Пилот лёжа; начало координат — карабин, голова в −Z.
func _fallback_pilot() -> Node3D:
	var root := Node3D.new()
	var h := float(_pcfg.height_m)
	var c := _body_center()
	var body := MeshInstance3D.new()
	body.name = "Body"
	var cap := CapsuleMesh.new()
	cap.radius = h * 0.12
	cap.height = h * 1.05
	body.mesh = cap
	body.material_override = _mat(Color(0.15, 0.2, 0.3))
	body.transform = Transform3D(Basis(Vector3.RIGHT, -PI * 0.5), c + Vector3(0, 0, h * 0.1))
	root.add_child(body)
	var helmet := MeshInstance3D.new()
	helmet.name = "Helmet"
	var sph := SphereMesh.new()
	sph.radius = h * 0.075
	sph.height = h * 0.15
	helmet.mesh = sph
	helmet.material_override = _mat(Color(0.92, 0.92, 0.92))
	helmet.position = c + Vector3(0, 0.08, -h * 0.47)
	root.add_child(helmet)
	var strap := _mat(Color(0.85, 0.45, 0.05))
	_add_rod(root, "HangStrap", Vector3.ZERO, c + Vector3(0, h * 0.1, 0), strap)
	var head := Node3D.new()
	head.name = "Head"
	head.position = _head_local()
	root.add_child(head)
	return root


func _mat(c: Color, double_sided: bool = false) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = c
	if double_sided:
		m.cull_mode = BaseMaterial3D.CULL_DISABLED
	return m


static func _add_marker(parent: Node3D, n: String, pos: Vector3) -> Marker3D:
	var m := Marker3D.new()
	m.name = n
	m.position = pos
	parent.add_child(m)
	return m


static func _add_rod(
	parent: Node3D, rod_name: String, a: Vector3, b: Vector3, mat: Material
) -> void:
	var mi := MeshInstance3D.new()
	mi.name = rod_name
	var cyl := CylinderMesh.new()
	cyl.top_radius = 0.025
	cyl.bottom_radius = 0.025
	cyl.height = a.distance_to(b)
	mi.mesh = cyl
	mi.material_override = mat
	var y := (b - a).normalized()
	var hint := Vector3.FORWARD if absf(y.dot(Vector3.UP)) < 0.99 else Vector3.RIGHT
	var x := y.cross(hint).normalized()
	mi.transform = Transform3D(Basis(x, y, x.cross(y)), (a + b) * 0.5)
	parent.add_child(mi)
