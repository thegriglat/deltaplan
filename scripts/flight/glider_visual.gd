class_name GliderVisual
extends Node3D
## Визуал дельтаплана: крыло + пилот (docs/guide/flight.md → «Визуал и контракт моделей»).
##
## Крыло: wings/<id>.json → visual.visual_model. Начало координат модели — HangPoint;
## ноды Sail, ControlFrame, маркеры HangPoint, BaseBar, InstrumentMount, WingTipL, WingTipR.
## Пилот: pilot.json → visual.visual_model. Начало — карабин (вешается в HangPoint), лёжа,
## голова в −Z, пустышка Head — глаза. Пилот висит под нодой Pilot, которая сдвигается
## по крену и тангажу. Маркер PilotHead этой обёртки следует за Head (кабинная камера).
## Нет файла — заглушка из примитивов с теми же именами.
## Руки пилота со скелетом держат трапецию (PilotArmIK, flight.json → visual.arms): в полёте —
## базовую штангу, на земле и при выравнивании — стойки. Крыло с трапецией слегка трясётся
## относительно пилота от перегрузки и болтанки (visual.buzz, поле buzz — для кабинной камеры).
## Нода стоит в начале координат Glider (ноги пилота), 1 ед. = 1 м, вперёд −Z, вверх +Y.

const WING_MARKERS: Array[String] = [
	"HangPoint", "BaseBar", "InstrumentMount", "WingTipL", "WingTipR"
]
## Маркеры трапеции (контракт A2, docs/contracts/aframe-geometry.md): оси стоек и центр масс крыла.
## Нет маркера — ошибка в журнал, без запасного числа.
const FRAME_MARKERS: Array[String] = [
	"UprightTopL", "UprightTopR", "UprightBottomL", "UprightBottomR", "WingCG"
]
## Заглушка крыла: верх стоек относительно HangPoint (правая; левая — зеркально по X), м.
## Заглушка: вынос середины базовой штанги вперёд (PV3, среднее по классам), м.
const FALLBACK_BAR_BOW := 0.08
const FALLBACK_UPRIGHT_TOP := Vector3(0.055, -0.02, -0.25)
## Стоя (stand/walk/run из pilot.glb) ступни на ~0,3 м позади таза, ноги наклонены ~19°, глаза
## на ~0,7 м впереди ступней: взгляд вниз не достаёт до ног. Модель на земле чуть отклоняется
## назад вокруг хвата рук на стойках (руки остаются на стойках, ступни выходят под корпус).
## Откидывание корпуса назад на земле и наклон на разбеге — pilot.json → visual.run_anim.
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
## Тряска крыла относительно пилота сейчас (visual.buzz), м, оси визуала; 0 — в спокойном воздухе.
var buzz := Vector3.ZERO
## Руки пилота (null — у модели нет скелета с костями рук).
var arm_ik: PilotArmIK
## Доля «руки на штанге» (0 — на стойках, 1 — на базовой штанге) и «выравнивание» (руки выше).
var arm_bar := 0.0
var arm_flare := 0.0
## Ленточки на тросах трапеции (Telltale, instruments.json → telltale); шагает Glider.step.
var telltales: Array[Telltale] = []
## Рисуется ли жёсткая стропа модели пилота (на земле скрыта, вместо неё гибкая лента — A3.7).
var strap_rigid_visible := true

var _cfg: Dictionary = {}  ## flight.json → visual
var _pcfg: Dictionary = {}  ## pilot.json → visual
var _hang := Vector3.ZERO  ## точка подвески в координатах обёртки
var _head: Node3D
var _pose := Transform3D.IDENTITY
## Модель сама встаёт анимацией stand (docs/guide/models.md → «Пилот»); иначе (заглушка) — поворот.
var _run_blend := 0.0  ## 0..1: доля наклона разбега (run_anim.run_lean_back_deg), плавно по времени
var _animated_stand := false
var _anim: AnimationPlayer
var _skeleton: Skeleton3D
var _shoulders: Array[int] = []  ## кости UpperArm.L/R (высота хвата на стойках)
var _wing_base := Vector3.ZERO  ## положение крыла без тряски
var _turbulence := 0.0
var _buzz_time := 0.0
var _buzz_amp := 0.0
var _buzz_kick := 0.0
var _arms_snap := true
## Стропа пилота на земле (A3.7): жёсткая стропа модели скрыта, вместо неё гибкая лента от HangPoint
## крыла до точки подвесной системы на груди пилота (растягивается, провисает при слабине).
var _strap_mesh: MeshInstance3D  ## PilotBody
var _strap_surface := -1  ## поверхность материала Strap в PilotBody
var _strap_ribbon: MeshInstance3D  ## лента (ImmediateMesh) в осях визуала
var _strap_hidden_mat: ShaderMaterial
var _strap_anchor_bone := -1  ## кость, к которой привязана нижняя точка стропы
var _strap_anchor_local := Vector3.ZERO  ## нижняя точка стропы в осях этой кости
var hang_drop_m := 0.0  ## на сколько пилот в полёте ниже карабина-на-HangPoint: зазор до штанги у этого крыла (A3.5 v8)
var _strap_rest_len := 0.9  ## длина стропы модели (карабин → подвесная система), м


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
	_wing_base = wing.position
	buzz = Vector3.ZERO
	_buzz_amp = 0.0
	_buzz_kick = 0.0
	sail_material = null
	var sail := wing.find_child("Sail", true, false) as MeshInstance3D
	if sail != null and wpath != "" and ResourceLoader.exists(wpath):
		sail_material = SailMaterial.apply(sail, wpath.get_file().get_basename())
	for mname in WING_MARKERS:
		if wing.find_child(mname, true, false) == null:
			push_warning("GliderVisual: в модели %s нет ноды %s" % [wpath, mname])
	for mname in FRAME_MARKERS:
		if wing.find_child(mname, true, false) == null:
			push_error("GliderVisual: в модели %s нет маркера трапеции %s (A2)" % [wpath, mname])
	telltales = Telltale.build_on(wing)

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
	hang_drop_m = float(wing_cfg.visual.get("hang_drop_m", _compute_hang_drop()))
	_animated_stand = false
	_anim = null
	for ap: AnimationPlayer in pm.find_children("*", "AnimationPlayer", true, false):
		_animated_stand = _animated_stand or ap.has_animation("stand")
		_anim = ap
	_build_arms(pm)
	_build_strap(pm)
	if _head == null:
		push_warning("GliderVisual: в модели %s нет ноды Head" % ppath)
	head_marker = Marker3D.new()
	head_marker.name = "PilotHead"
	add_child(head_marker)
	_pose = _flight_pose(Vector3.ZERO)
	set_pose(0.0, 0.0, true, 1.0e6)


## Стропа пилота: поверхность Strap в PilotBody (прячется на земле), нижняя точка подвесной
## системы (центр самых нижних вершин стропы) в осях кости, лента на земле — вместо жёсткой.
func _build_strap(pm: Node3D) -> void:
	_strap_mesh = null
	_strap_surface = -1
	_strap_anchor_bone = -1
	_strap_ribbon = null
	strap_rigid_visible = true
	var mi := pm.find_child("PilotBody", true, false) as MeshInstance3D
	if mi == null or mi.mesh == null or _skeleton == null:
		return
	for i in mi.mesh.get_surface_count():
		var m := mi.mesh.surface_get_material(i)
		if m != null and m.resource_name == "Strap":
			_strap_surface = i
	if _strap_surface < 0:
		return
	_strap_mesh = mi
	var verts: PackedVector3Array = mi.mesh.surface_get_arrays(_strap_surface)[Mesh.ARRAY_VERTEX]
	var low := INF
	for v in verts:
		low = minf(low, v.y)
	var sum := Vector3.ZERO
	var n := 0
	for v in verts:
		if v.y < low + 0.05:
			sum += v
			n += 1
	var bottom := sum / maxf(n, 1)
	_strap_rest_len = absf(bottom.y)
	var ci := _skeleton.find_bone("Chest")
	if ci < 0:
		return
	_strap_anchor_bone = ci
	# вершины меша — в покое скелета (осях меша); кость Chest в покое → локальная точка
	var to_sk := _relative_xform(_skeleton, mi)
	_strap_anchor_local = _skeleton.get_bone_global_rest(ci).affine_inverse() * (to_sk * bottom)
	_strap_hidden_mat = ShaderMaterial.new()
	var sh := Shader.new()
	sh.code = "shader_type spatial;\nvoid fragment() { discard; }\n"
	_strap_hidden_mat.shader = sh
	_strap_ribbon = MeshInstance3D.new()
	_strap_ribbon.name = "GroundStrap"
	_strap_ribbon.mesh = ImmediateMesh.new()
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.12, 0.12, 0.14)
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	_strap_ribbon.material_override = mat
	_strap_ribbon.visible = false
	add_child(_strap_ribbon)


## Нижняя точка стропы пилота (подвесная система) в осях визуала по текущей позе.
func strap_bottom() -> Vector3:
	if _strap_anchor_bone < 0 or pilot == null:
		return _hang
	var bp := _skeleton.get_bone_global_pose(_strap_anchor_bone)
	return pilot.transform * (_relative_xform(pilot, _skeleton) * (bp * _strap_anchor_local))


## Верх гибкой стропы на земле — всегда HangPoint крыла (A3.7), оси визуала.
func strap_top() -> Vector3:
	return _marker_pos("HangPoint")


## На земле рисуем гибкую стропу от HangPoint до подвесной системы, жёсткую скрываем; когда
## карабин пилота вернулся на HangPoint (полёт), показываем жёсткую (без скачка).
func _update_strap() -> void:
	if _strap_mesh == null or _strap_ribbon == null:
		return
	var top := strap_top()
	var rigid := pilot.transform.origin.distance_to(top) < 0.03
	if rigid != strap_rigid_visible:
		strap_rigid_visible = rigid
		_strap_mesh.set_surface_override_material(
			_strap_surface, null if rigid else _strap_hidden_mat
		)
	_strap_ribbon.visible = not rigid
	if rigid:
		return
	var bottom := strap_bottom()
	var chord := top.distance_to(bottom)
	var sag := 0.5 * sqrt(maxf(_strap_rest_len * _strap_rest_len - chord * chord, 0.0))
	var im := _strap_ribbon.mesh as ImmediateMesh
	im.clear_surfaces()
	# две перекрёстные ленты (из любой камеры видна)
	for half: Vector3 in [Vector3(0.012, 0.0, 0.0), Vector3(0.0, 0.0, 0.012)]:
		im.surface_begin(Mesh.PRIMITIVE_TRIANGLE_STRIP)
		for i in 9:
			var t := i / 8.0
			var pt := top.lerp(bottom, t) + Vector3.DOWN * (sag * 4.0 * t * (1.0 - t))
			im.surface_add_vertex(pt - half)
			im.surface_add_vertex(pt + half)
		im.surface_end()


## Руки: модификатор PilotArmIK на скелете пилота (кости UpperArm/Forearm/Hand, пустышки хвата).
func _build_arms(pm: Node3D) -> void:
	arm_ik = null
	_skeleton = null
	_shoulders.clear()
	_arms_snap = true
	var arms: Dictionary = _cfg.get("arms", {})
	if not bool(arms.get("enabled", true)):
		return
	var sks := pm.find_children("*", "Skeleton3D", true, false)
	if sks.is_empty():
		return
	_skeleton = sks[0] as Skeleton3D
	var ik := PilotArmIK.new()
	ik.name = "ArmIK"
	_skeleton.add_child(ik)
	ik.frame_node = self
	var grip_l := pm.find_child("HandL", true, false) as Node3D
	var grip_r := pm.find_child("HandR", true, false) as Node3D
	if not ik.setup(grip_l, grip_r):
		push_warning("GliderVisual: у скелета пилота нет костей рук — без IK")
		_skeleton.remove_child(ik)
		ik.free()
		_skeleton = null
		return
	ik.shoulder_reach = float(arms.get("shoulder_reach_m", 0.07))
	arm_ik = ik
	for n: String in ["UpperArm.L", "UpperArm.R"]:
		_shoulders.append(_skeleton.find_bone(n))


## Маркер по имени: HangPoint, BaseBar, InstrumentMount, WingTipL, WingTipR (крыло), PilotHead.
func get_marker(marker_name: String) -> Node3D:
	if marker_name == "PilotHead":
		return head_marker
	return wing.find_child(marker_name, true, false) as Node3D if wing != null else null


## Точка глаз пилота в координатах обёртки (для кабинной камеры).
func get_head_transform() -> Transform3D:
	return head_marker.transform if head_marker != null else Transform3D.IDENTITY


## Шаг физики ленточек: ориентация планера на прошлом шаге (prev) и сейчас (cur), скорость
## начала планера, air_fn(pos) → ветер. Нода визуала — в начале координат Glider.
func step_telltales(
	dt: float, prev: Basis, cur: Transform3D, velocity: Vector3, air_fn: Callable
) -> void:
	for t in telltales:
		t.step(dt, transform * _relative_xform(self, t).origin, prev, cur, velocity, air_fn)


## Парус (шейдер): воздушная скорость, м/с; срыв 0..1; болтанка 0..1.
func set_flight(airspeed_ms: float, stall_amount: float, turbulence: float) -> void:
	_turbulence = turbulence
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
	if flying:
		shift *= lerpf(1.0, _reach_scale(shift), arm_bar)
	_update_run_lean(flying, dt)
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
	_update_buzz(flying, dt)
	_update_arms(flying, dt)
	_update_strap()


# ---------------------------------------------------------------- руки


## Цели рук: точки хвата на штанге / стойках по текущей анимации (flight.json → visual.arms).
func _update_arms(flying: bool, dt: float) -> void:
	if arm_ik == null or wing == null:
		return
	var a: Dictionary = _cfg.get("arms", {})
	var goal := _arm_goal(a, flying)
	var bs := float(a.get("blend_s", 0.2))
	var k := 1.0 if _arms_snap or bs <= 0.0 else 1.0 - exp(-dt / bs)
	_arms_snap = false
	arm_bar = lerpf(arm_bar, goal.x, k)
	arm_flare = lerpf(arm_flare, goal.y, k)
	var bar_l := bar_grip(-1)
	var bar_r := bar_grip(1)
	var up_l := upright_grip(-1)
	var up_r := upright_grip(1)
	var pole := _vec3(a.get("elbow_pole", [1.0, -1.0, 0.3])).lerp(
		_vec3(a.get("elbow_pole_bar", [1.0, -0.3, 0.6])), arm_bar
	)
	var bb := _relative_xform(self, get_marker("BaseBar"))
	arm_ik.set_targets(
		up_l.lerp(bar_l, arm_bar),
		up_r.lerp(bar_r, arm_bar),
		bb.basis * Vector3(-pole.x, pole.y, pole.z),
		bb.basis * pole
	)


## Точка хвата на базовой штанге: маркер BaseBar ± полуширина хвата (side −1 — левая, +1 — правая),
## оси визуала.
func bar_grip(side: int) -> Vector3:
	var a: Dictionary = _cfg.get("arms", {})
	var bb := _relative_xform(self, get_marker("BaseBar"))
	var off := _vec3(a.get("bar_grip_offset_m", [0.0, 0.0, 0.0]))
	# PV3: штанга изогнута вперёд — хват на её оси (маркеры BarGripL/R на |x| = полуширине хвата)
	var gm := get_marker("BarGripL" if side < 0 else "BarGripR")
	if gm != null:
		return _relative_xform(self, gm).origin + bb.basis * off
	return bb * (Vector3(side * float(a.get("bar_grip_half_width_m", 0.33)), 0.0, 0.0) + off)


## Точка хвата на стойке трапеции выше плеча по вертикали мира (+ arms.upright_above_shoulder_m,
## при выравнивании — flare_above_shoulder_m): на отрезке «верх стойки → конец базовой штанги».
func upright_grip(side: int) -> Vector3:
	return _upright_point(side, shoulder(side))


## Точка на оси стойки, поднятая над плечом sh (оси визуала) на заданное arms-конфигом число метров
## по вертикали мира: визуал наклонён на тангаж крыла, поэтому высоту считаем не по его Y.
func _upright_point(side: int, sh: Vector3) -> Vector3:
	var a: Dictionary = _cfg.get("arms", {})
	var apex := _marker_pos("UprightTopL" if side < 0 else "UprightTopR")
	var end := _marker_pos("UprightBottomL" if side < 0 else "UprightBottomR")
	var above := lerpf(
		float(a.get("upright_above_shoulder_m", 0.1)),
		float(a.get("flare_above_shoulder_m", 0.25)),
		arm_flare
	)
	var th := _frame_pitch()
	var c := cos(th)
	var sn := sin(th)
	var y_apex := apex.y * c - apex.z * sn
	var y_end := end.y * c - end.z * sn
	var y := sh.y * c - sh.z * sn + above
	var t := (
		clampf(inverse_lerp(y_apex, y_end, y), 0.05, 0.95) if absf(y_apex - y_end) > 1e-3 else 0.5
	)
	return apex.lerp(end, t)


## Положение маркера крыла в осях визуала (нет маркера — ошибка, Vector3.ZERO).
func _marker_pos(marker_name: String) -> Vector3:
	var m := get_marker(marker_name)
	if m == null:
		push_error("GliderVisual: нет маркера %s" % marker_name)
		return Vector3.ZERO
	return _relative_xform(self, m).origin


## Плечо (начало кости UpperArm) в осях визуала.
func shoulder(side: int) -> Vector3:
	return pilot.transform * _shoulder_local(side) if pilot != null else _hang


## Плечо в осях ноды Pilot по текущей анимации (без правок IK: родитель Chest × покой UpperArm).
func _shoulder_local(side: int) -> Vector3:
	var i := _shoulders[0 if side < 0 else 1] if _shoulders.size() == 2 else -1
	if _skeleton == null or i < 0:
		return Vector3.ZERO
	var parent := _skeleton.get_bone_parent(i)
	var o := _skeleton.get_bone_rest(i).origin
	if parent >= 0:
		o = _skeleton.get_bone_global_pose(parent) * o
	return _relative_xform(pilot, _skeleton) * o


## Руки на штанге не дают телу уйти дальше вытянутых рук: во сколько раз уменьшить сдвиг тела
## (1 — не надо), чтобы обе точки хвата остались в досягаемости (PilotArmIK.max_reach).
func _reach_scale(shift: Vector3) -> float:
	if arm_ik == null or not arm_ik.active or shift.is_zero_approx():
		return 1.0
	var limit := arm_ik.max_reach() - float(_cfg.get("arms", {}).get("reach_margin_m", 0.01))
	var grips := [bar_grip(-1) - buzz, bar_grip(1) - buzz]
	var sl := _shoulder_local(-1)
	var sr := _shoulder_local(1)
	var fits := func(k: float) -> bool:
		var x := _flight_pose(shift * k)
		return (x * sl).distance_to(grips[0]) <= limit and (x * sr).distance_to(grips[1]) <= limit
	if fits.call(1.0):
		return 1.0
	var lo := 0.0
	var hi := 1.0
	for _i in 10:
		var mid := (lo + hi) * 0.5
		if fits.call(mid):
			lo = mid
		else:
			hi = mid
	return lo


## (доля «на штанге», доля «выравнивание») по анимации: prone — штанга; climb_in/climb_out —
## руки переходят со стоек на штангу и обратно в окне arms.climb_window; flare — стойки выше плеч;
## stand/walk/run/run_air — стойки.
func _arm_goal(a: Dictionary, flying: bool) -> Vector2:
	var anim := String(_anim.assigned_animation) if _anim != null else ""
	# без анимации модель в позе покоя (руки вниз) — руки не трогаем
	arm_ik.active = anim != ""
	if anim == "":
		return Vector2(1.0 if flying else 0.0, 0.0)
	var length := _anim.get_animation(anim).length
	var p := _anim.current_animation_position / length if length > 0.0 else 1.0
	var win: Array = a.get("climb_window", [0.2, 0.8])
	var s := smoothstep(float(win[0]), float(win[1]), p)
	if anim in a.get("bar_animations", ["prone"]):
		return Vector2(1.0, 0.0)
	if anim == "climb_in":
		return Vector2(s, 0.0)
	if anim == "climb_out":
		return Vector2(1.0 - s, 0.0)
	if anim == "flare":
		return Vector2(0.0, 1.0)
	return Vector2.ZERO


# ---------------------------------------------------------------- тряска


## Тряска крыла с трапецией относительно пилота (flight.json → visual.buzz): амплитуда от болтанки
## (turbulence из set_flight) и отклонения перегрузки от 1 g, плюс толчок от мгновенной
## перегрузки; сумма синусов 2–8 Гц. На прямой в спокойном воздухе — ноль.
func _update_buzz(flying: bool, dt: float) -> void:
	if wing == null:
		return
	var b: Dictionary = _cfg.get("buzz", {})
	var want := 0.0
	var kick := 0.0
	var lm := _load_meter()
	if flying and not b.is_empty():
		want = float(b.turbulence_m) * clampf(_turbulence, 0.0, 1.0)
		if lm != null:
			var excess := absf(lm.load_factor - 1.0) - float(b.load_deadzone_g)
			want += float(b.load_m_per_g) * maxf(excess, 0.0)
			kick = float(b.kick_m_per_g) * (lm.load_raw - lm.load_factor)
	var mx := float(b.get("max_m", 0.03))
	var sm := float(b.get("smoothing_s", 0.3))
	var dtc := minf(dt, 1.0)
	var k := 1.0 if sm <= 0.0 or dt > 10.0 else 1.0 - exp(-dtc / sm)
	_buzz_amp = lerpf(_buzz_amp, minf(want, mx), k)
	var kt := float(b.get("kick_filter_s", 0.03))
	var kk := 1.0 if kt <= 0.0 or dt > 10.0 else 1.0 - exp(-dtc / kt)
	_buzz_kick = lerpf(_buzz_kick, clampf(kick, -mx, mx), kk)
	_buzz_time = fmod(_buzz_time + dtc, 1000.0)
	buzz = Vector3.ZERO
	if _buzz_amp > 1e-5:
		var w := _vec3(b.get("axis_weights", [0.4, 1.0, 0.3]))
		var n := Vector3(_buzz_wave(b, 0.0), _buzz_wave(b, 1.7), _buzz_wave(b, 3.1))
		buzz = n * w * _buzz_amp
	buzz.y += _buzz_kick
	buzz = buzz.limit_length(mx)
	var rot := deg_to_rad(float(b.get("rotation_deg_per_cm", 0.1))) * 100.0
	var basis := Basis(Vector3.BACK, buzz.x * rot) * Basis(Vector3.RIGHT, -buzz.z * rot)
	wing.transform = Transform3D(basis, _wing_base + buzz)


## Сумма синусов на частотах buzz.freqs_hz (фазы сдвинуты на phase), нормирована к ±1.
func _buzz_wave(b: Dictionary, phase: float) -> float:
	var freqs: Array = b.get("freqs_hz", [2.3, 3.7, 5.3, 7.4])
	if freqs.is_empty():
		return 0.0
	var s := 0.0
	var i := 0
	for f: Variant in freqs:
		s += sin(TAU * float(f) * _buzz_time + phase * (i + 1) + i * 1.3)
		i += 1
	return s / sqrt(float(freqs.size()) * 0.5)


## Перегрузка планера (FlightModel.load), если визуал висит под Glider.
func _load_meter() -> LoadMeter:
	var g := get_parent() as Glider
	return g.model.load if g != null and g.model != null else null


static func _vec3(v: Variant) -> Vector3:
	var arr: Array = v
	return Vector3(float(arr[0]), float(arr[1]), float(arr[2]))


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
	return Transform3D(basis, _hang + basis * Vector3(0, -hang_drop_m, 0))


## Подгонка длины подвески под крыло (A3.5 v8): низ торса на pilot.json → visual.bar_gap_m над
## верхом базовой штанги. Модель пилота запечена с длиной hang_length_m; недостающее — вниз.
func _compute_hang_drop() -> float:
	if wing == null or get_marker("BaseBar") == null:
		return 0.0
	var depth := _hang.y - _marker_pos("BaseBar").y  # карабин (HangPoint) — ось штанги
	var top := depth - float(_pcfg.get("bar_radius_m", 0.015))
	return top - float(_pcfg.get("bar_gap_m", 0.06)) - float(_pcfg.hang_length_m)


## На земле: стоит под крылом, ноги на земле. Модель со скелетом ставит тело вертикально сама
## (анимации stand/walk/run: подошвы на hang_height_m ниже карабина) — на 90° не поворачиваем,
## только сдвиг по крену и небольшой наклон назад вокруг хвата (pilot.json → visual.run_anim.lean_back_deg), ступни
## остаются на той же высоте. Заглушка без анимаций лежит — её поворачиваем вокруг центра тела.
## Тело стоит вертикально к горизонту, а не к крылу: тангаж крыла (киль задран на угол атаки,
## 16–37°) снимается поворотом вокруг ступней — иначе пилот «сидит», отклонившись назад вместе с
## крылом. Руки остаются тянуться к стойкам (IK). Telemetry.basis и точка поворота не меняются (К4).
func _ground_pose(shift: Vector3) -> Transform3D:
	var pose: Transform3D
	var feet: Vector3
	if _animated_stand:
		var ra: Dictionary = _pcfg.get("run_anim", {})
		var back := lerpf(
			float(ra.get("lean_back_deg", 15.0)),
			float(ra.get("run_lean_back_deg", 15.0)),
			_run_blend
		)
		var lean := Basis(Vector3.RIGHT, deg_to_rad(back))
		var o := GROUND_GRIP - lean * GROUND_GRIP  # хват на месте
		o.y += GROUND_FEET.y - (lean * GROUND_FEET + o).y  # ступни на прежней высоте
		pose = Transform3D(lean, _hang + o)
		feet = pose * GROUND_FEET
	else:
		var c := _body_center()
		var r := Basis(Vector3.RIGHT, PI * 0.5)
		var g := Vector3(shift.x, float(_pcfg.height_m) * 0.5, 0.0)
		pose = Transform3D(r, g - r * c)
		feet = Vector3(shift.x, 0.0, 0.0)
	var level := Basis(Vector3.RIGHT, -_frame_pitch())
	var out := Transform3D(level, feet - level * feet) * pose
	if _animated_stand and arm_ik != null and wing != null:
		out.origin += _ground_slide(out, feet)
	return out


## Доля наклона разбега: растёт, пока играет анимация run на земле, и спадает при любой другой
## (отрыв, остановка); экспонента с run_anim.lean_smooth_s, dt большой — сразу.
func _update_run_lean(flying: bool, dt: float) -> void:
	var anim := String(_anim.assigned_animation) if _anim != null else ""
	var want := 1.0 if anim == "run" and not flying else 0.0
	var tau := float(_pcfg.get("run_anim", {}).get("lean_smooth_s", 0.6))
	var k := 1.0 if tau <= 0.0 or dt > 10.0 else 1.0 - exp(-minf(dt, 1.0) / tau)
	_run_blend = lerpf(_run_blend, want, k)


## Горизонталь мира «вперёд вдоль курса крыла» в осях визуала (визуал наклонён на тангаж).
func _ground_fwd() -> Vector3:
	var th := _frame_pitch()
	return Vector3(0.0, -sin(th), -cos(th))


## На сколько сдвинуть стоящего пилота вдоль горизонтали вперёд (м), чтобы стойки были впереди его
## плеч на arms.upright_ahead_of_shoulder_m. Тангаж крыла поворачивается вокруг ступней (К4), а
## HangPoint в 1,9 м над ними — при тангаже 16° он уходит на ~0,5 м назад, стойки вместе с ним:
## если ставить пилота по ступням, стойки оказываются позади плеч, руки тянутся назад, плечи
## «выламываются». Пилот держит крыло за стойки и стоит под ним. Вбок ноги остаются на месте
## (крыло качается у него в руках), по высоте ступни на земле. Физика и точка поворота К4 не
## меняются — сдвигается только визуал пилота (его карабин при этом не на HangPoint: в позе stand
## модели плечи на ~0,35 м впереди карабина, а стойки на высоте плеч — под HangPoint).
func _ground_slide(pose: Transform3D, feet: Vector3) -> Vector3:
	if _skeleton == null:
		return Vector3.ZERO
	var ahead := float(_cfg.get("arms", {}).get("upright_ahead_of_shoulder_m", 0.3))
	var fv := _ground_fwd()
	var th := _frame_pitch()
	var upv := Vector3(0.0, cos(th), -sin(th))  # вертикаль мира в осях визуала
	var d := 0.0
	var dy := 0.0
	for i in 3:
		var diff := 0.0
		for side in [-1, 1]:
			var sh: Vector3 = pose * _shoulder_local(side) + fv * d + upv * dy
			diff += (_upright_point(side, sh) - sh).dot(fv) * 0.5
		d += diff - ahead
		dy = _feet_sink(feet + fv * d)
	return fv * clampf(d, -1.5, 1.5) + upv * dy


## На сколько поднять стопы (м, по вертикали мира), чтобы они стояли на земле под собой, а не на
## плоскости через ступни планера: сдвинутый назад пилот на склоне 20° иначе уходит в землю.
## Нет земли (ground_fn) — 0. feet_vis — точка ступней в осях визуала до подъёма.
func _feet_sink(feet_vis: Vector3) -> float:
	var g := get_parent() as Glider
	if g == null or not g.ground_fn.is_valid() or not is_inside_tree():
		return 0.0
	var w := global_transform * feet_vis
	var h := float(g.ground_fn.call(w.x, w.z))
	return clampf(h - w.y, -0.5, 0.5)


## Тангаж обёртки (крыла) к горизонту, рад: + нос вверх (Telemetry.basis = from_euler(θ, …)).
func _frame_pitch() -> float:
	var b := global_transform.basis if is_inside_tree() else transform.basis
	var fwd := b.orthonormalized() * Vector3.FORWARD
	return asin(clampf(fwd.y, -1.0, 1.0))


## Вид из кабины с камерой позади тела (A3.3 v8, camera.json → cockpit.eye_mode back_*): тело пилота
## не рисуется для кабинной камеры. "full" — как есть; "arms" — только руки (копия PilotBody на слое
## «только кабина», фрагменты дальше ARM_MASK_R_M от костей рук отброшены); "none" — и руки скрыты.
## Для внешних камер тело всегда видно (слой 20 не рисует только кабинная камера).
const BODY_HIDDEN_LAYER := 1 << 19
const COCKPIT_ONLY_LAYER := 1 << 18
const ARM_MASK_R_M := 0.1
const ARM_MASK_SHADER := """
shader_type spatial;
uniform vec4 albedo : source_color = vec4(0.3, 0.3, 0.3, 1.0);
uniform float rough = 0.7;
uniform float radius = 0.1;
uniform vec3 pts[6];
varying vec3 wpos;
float seg(vec3 p, vec3 a, vec3 b) {
	vec3 pa = p - a;
	vec3 ba = b - a;
	float h = clamp(dot(pa, ba) / max(dot(ba, ba), 0.0001), 0.0, 1.0);
	return length(pa - ba * h);
}
void vertex() { wpos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz; }
void fragment() {
	float d = min(min(seg(wpos, pts[0], pts[1]), seg(wpos, pts[1], pts[2])),
		min(seg(wpos, pts[3], pts[4]), seg(wpos, pts[4], pts[5])));
	if (d > radius) { discard; }
	ALBEDO = albedo.rgb;
	ROUGHNESS = rough;
}
"""
var _body_mode := "full"
var _body_mi: MeshInstance3D
var _arms_mi: MeshInstance3D
var _arm_mats: Array[ShaderMaterial] = []


func set_cockpit_body(mode: String) -> void:
	if mode == _body_mode and (_body_mi != null or mode == "full"):
		return
	if _body_mi == null:
		_body_mi = find_child("PilotBody", true, false) as MeshInstance3D
	if _body_mi == null:
		return
	_body_mode = mode
	_body_mi.layers = 1 if mode == "full" else BODY_HIDDEN_LAYER
	if mode == "arms" and _arms_mi == null and _body_mi.mesh != null and _skeleton != null:
		_arms_mi = MeshInstance3D.new()
		_arms_mi.name = "CockpitArms"
		_arms_mi.mesh = _body_mi.mesh
		_arms_mi.skin = _body_mi.skin
		_arms_mi.layers = COCKPIT_ONLY_LAYER
		_arms_mi.transform = _body_mi.transform
		_body_mi.get_parent().add_child(_arms_mi)
		_arms_mi.skeleton = _arms_mi.get_path_to(_skeleton)
		for i in _body_mi.mesh.get_surface_count():
			var m := ShaderMaterial.new()
			m.shader = Shader.new()
			m.shader.code = ARM_MASK_SHADER
			var src := _body_mi.mesh.surface_get_material(i) as BaseMaterial3D
			if src != null:
				m.set_shader_parameter("albedo", src.albedo_color)
				m.set_shader_parameter("rough", src.roughness)
			m.set_shader_parameter("radius", ARM_MASK_R_M)
			_arms_mi.set_surface_override_material(i, m)
			_arm_mats.append(m)
	if _arms_mi != null:
		_arms_mi.visible = mode == "arms"


## Положения плечо–локоть–кисть (мир) для маски рук; зовёт кабинная камера каждый кадр.
func update_arm_mask() -> void:
	if _body_mode != "arms" or _skeleton == null or _arm_mats.is_empty():
		return
	var pts := PackedVector3Array()
	for side in ["L", "R"]:
		for b in ["UpperArm.", "Forearm.", "Hand."]:
			var bi := _skeleton.find_bone(b + side)
			pts.append(_skeleton.to_global(_skeleton.get_bone_global_pose(bi).origin) if bi >= 0 else Vector3.ZERO)
	for m in _arm_mats:
		m.set_shader_parameter("pts", pts)


## Центр тела относительно карабина.
func _body_center() -> Vector3:
	return Vector3(0, -float(_pcfg.body_below_hang_m) - hang_drop_m, float(_pcfg.body_back_m))


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
	_add_marker(root, "WingCG", Vector3(0, 0, 0.015))
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
	var top_r := FALLBACK_UPRIGHT_TOP
	var top_l := Vector3(-top_r.x, top_r.y, top_r.z)
	_add_rod(frame, "DownTubeL", top_l, bar - w, m)
	_add_rod(frame, "DownTubeR", top_r, bar + w, m)
	_add_marker(frame, "UprightTopL", top_l)
	_add_marker(frame, "UprightTopR", top_r)
	_add_marker(frame, "UprightBottomL", bar - w)
	_add_marker(frame, "UprightBottomR", bar + w)
	# PV3: ось штанги изогнута вперёд (cos²) на FALLBACK_BAR_BOW в центре
	var pts: Array[Vector3] = []
	for i in 17:
		var u := -1.0 + 2.0 * i / 16.0
		pts.append(bar + w * u + Vector3(0, 0, -FALLBACK_BAR_BOW * pow(cos(PI * u * 0.5), 2)))
	for i in 16:
		_add_rod(frame, "BaseBarTube%d" % i, pts[i], pts[i + 1], m)
	_add_marker(frame, "BaseBar", bar + Vector3(0, 0, -FALLBACK_BAR_BOW))
	var gu := float(_cfg.get("arms", {}).get("bar_grip_half_width_m", 0.33)) / w.x
	for side in [-1, 1]:
		_add_marker(frame, "BarGripL" if side < 0 else "BarGripR",
			bar + w * (side * gu) + Vector3(0, 0, -FALLBACK_BAR_BOW * pow(cos(PI * gu * 0.5), 2)))
	# приборы на хомуте левой стойки, как в build_gliders.py (instrument_upright_t 0,3 /
	# vario_upright_t 0,42 от штанги к вершине, instrument_inward_m 0,1, instrument_forward_m 0,3); экран (+Z маркера) к глазам
	for spec in [["InstrumentMount", 0.3], ["VarioMount", 0.42]]:
		var mount := (bar - w).lerp(top_l, float(spec[1])) + Vector3(0.1, 0, -0.3)
		var im := _add_marker(frame, String(spec[0]), mount)
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
