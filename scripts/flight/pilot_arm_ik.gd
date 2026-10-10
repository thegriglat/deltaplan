class_name PilotArmIK
extends SkeletonModifier3D
## Руки пилота держат трапецию: двухзвенная обратная кинематика (плечо → локоть → точка хвата)
## поверх анимации pilot.glb (docs/guide/models.md → «Пилот»). Работает как SkeletonModifier3D —
## после AnimationPlayer в том же обновлении скелета, поэтому пустышки HandL/HandR
## (BoneAttachment3D) уже видят исправленную позу.
##
## Кисть с предплечьем — одно жёсткое звено (запястье не гнётся, как в анимации): звено 1 —
## UpperArm (плечо → локоть), звено 2 — Forearm (локоть → пустышка хвата HandL/HandR).
## Цели задаёт GliderVisual (set_targets) в координатах своей ноды; полюс локтя — в тех же осях.
## Нет нужных костей — модификатор ничего не делает.

## Кости: [плечо, предплечье, кисть] для левой и правой руки (в Godot точки в именах сохраняются;
## на всякий случай ищем и вариант с «_»).
const ARM_BONES := {
	"L": ["UpperArm.L", "Forearm.L", "Hand.L"],
	"R": ["UpperArm.R", "Forearm.R", "Hand.R"],
}

## Нода, в осях которой заданы цели (визуал планера).
var frame_node: Node3D
## Точки хвата левой/правой кисти в осях frame_node.
var target_l := Vector3.ZERO
var target_r := Vector3.ZERO
## Куда смотрит локоть (направление в осях frame_node) для левой/правой руки.
var pole_l := Vector3(-1, -1, 0)
var pole_r := Vector3(1, -1, 0)
## Плечо может выдвинуться к цели (лопатка) не больше чем на столько, м.
var shoulder_reach := 0.07

var _arms: Array[Dictionary] = []  ## {upper, fore, grip: Vector3 (хват в осях кисти)}


## skeleton — скелет пилота; grip_l/grip_r — пустышки хвата (дети BoneAttachment3D кисти).
func setup(grip_l: Node3D, grip_r: Node3D) -> bool:
	_arms.clear()
	var sk := get_skeleton()
	if sk == null:
		return false
	for side: String in ["L", "R"]:
		var names: Array = ARM_BONES[side]
		var idx: Array[int] = []
		for n: String in names:
			var i := sk.find_bone(n)
			if i < 0:
				i = sk.find_bone(n.replace(".", "_"))
			idx.append(i)
		if idx.has(-1):
			_arms.clear()
			return false
		var grip_node := grip_l if side == "L" else grip_r
		var grip := Vector3.ZERO
		if grip_node != null:
			grip = grip_node.transform.origin  # пустышка в осях BoneAttachment3D = осях кисти
		_arms.append({"upper": idx[0], "fore": idx[1], "hand": idx[2], "grip": grip})
	return true


func set_targets(l: Vector3, r: Vector3, p_l: Vector3, p_r: Vector3) -> void:
	target_l = l
	target_r = r
	pole_l = p_l
	pole_r = p_r


## Дальше всего от плеча до точки хвата, м: плечо + предплечье с кистью + выдвижение плеча.
func max_reach() -> float:
	var sk := get_skeleton()
	if sk == null or _arms.is_empty():
		return 0.0
	var a: Dictionary = _arms[0]
	var la := sk.get_bone_rest(a.fore).origin.length()
	var lb := (sk.get_bone_rest(a.hand) * (a.grip as Vector3)).length()
	return la + lb + shoulder_reach


## Длины звеньев: x — плечо (плечевой сустав → локоть), y — от локтя до точки хвата
## (предплечье + кисть до центра ладони), м.
func arm_lengths() -> Vector2:
	var sk := get_skeleton()
	if sk == null or _arms.is_empty():
		return Vector2.ZERO
	var a: Dictionary = _arms[0]
	return Vector2(
		sk.get_bone_rest(a.fore).origin.length(),
		(sk.get_bone_rest(a.hand) * (a.grip as Vector3)).length()
	)


## Есть ли кости рук (setup прошёл).
func ready_to_solve() -> bool:
	return _arms.size() == 2


func _process_modification_with_delta(_delta: float) -> void:
	var sk := get_skeleton()
	if sk == null or _arms.size() != 2 or frame_node == null or not frame_node.is_inside_tree():
		return
	# цели: оси визуала → оси скелета
	var to_sk := sk.global_transform.affine_inverse() * frame_node.global_transform
	var reach := shoulder_reach
	_solve(sk, _arms[0], to_sk * target_l, (to_sk.basis * pole_l).normalized(), reach)
	_solve(sk, _arms[1], to_sk * target_r, (to_sk.basis * pole_r).normalized(), reach)


## Плечо и локоть, посчитанные IK в последнем кадре, в осях скелета: [плечо, локоть]
## (Skeleton3D.get_bone_global_pose отдаёт позу анимации, без правок модификатора — для тестов).
func solved_joints(side: int) -> Array[Vector3]:
	if side >= _arms.size() or not _arms[side].has("solved"):
		return [Vector3.ZERO, Vector3.ZERO]
	return _arms[side].solved


## Точка хвата руки в осях скелета при текущей позе (для тестов и отладки).
func grip_point(side: int) -> Vector3:
	var sk := get_skeleton()
	if sk == null or side >= _arms.size():
		return Vector3.ZERO
	var a: Dictionary = _arms[side]
	return sk.get_bone_global_pose(a.hand) * (a.grip as Vector3)


static func _solve(
	sk: Skeleton3D, a: Dictionary, target: Vector3, pole: Vector3, reach: float
) -> void:
	var up_i: int = a.upper
	var fo_i: int = a.fore
	var u := sk.get_bone_global_pose(up_i)
	var f := sk.get_bone_global_pose(fo_i)
	var h := sk.get_bone_global_pose(a.hand)
	var s := u.origin  # плечо
	var e := f.origin  # локоть
	var g := h * (a.grip as Vector3)  # хват сейчас
	var la := s.distance_to(e)
	var lb := e.distance_to(g)
	if la < 1e-4 or lb < 1e-4:
		return
	# не достаёт — плечо (лопатка) выдвигается к цели
	var over := s.distance_to(target) - (la + lb - 1e-3)
	if over > 0.0:
		var sh := (target - s).normalized() * minf(over, reach)
		s += sh
		e += sh
		g += sh
		u.origin = s
		f.origin = e
	var to_t := target - s
	var d := clampf(to_t.length(), absf(la - lb) + 1e-3, la + lb - 1e-4)
	var n := to_t.normalized() if to_t.length() > 1e-5 else (g - s).normalized()
	# локоть: на окружности вокруг оси плечо→цель, в сторону полюса
	var x := (la * la - lb * lb + d * d) / (2.0 * d)
	var r := sqrt(maxf(la * la - x * x, 0.0))
	var p := pole - n * pole.dot(n)
	if p.length() < 1e-4:
		p = (e - s) - n * (e - s).dot(n)  # полюс вдоль оси — как в анимации
	if p.length() < 1e-4:
		p = n.cross(Vector3.RIGHT)
	var e2 := s + n * x + p.normalized() * r
	# плечо: повернуть так, чтобы локоть встал в e2
	var q1 := _arc(e - s, e2 - s)
	var u2 := Transform3D(q1 * u.basis, s)
	var f1 := u2 * u.affine_inverse() * f  # предплечье едет за плечом
	var g1 := f1 * f.affine_inverse() * g
	# предплечье: повернуть вокруг локтя, чтобы хват встал в цель
	var q2 := _arc(g1 - f1.origin, s + n * d - f1.origin)
	var f2 := Transform3D(q2 * f1.basis, f1.origin)
	a.solved = [s, e2] as Array[Vector3]
	sk.set_bone_global_pose(up_i, u2)
	sk.set_bone_global_pose(fo_i, f2)


## Кратчайший поворот от a к b.
static func _arc(a: Vector3, b: Vector3) -> Basis:
	var an := a.normalized()
	var bn := b.normalized()
	var c := an.cross(bn)
	var dot := clampf(an.dot(bn), -1.0, 1.0)
	if c.length() < 1e-6:
		if dot > 0.0:
			return Basis.IDENTITY
		var ortho := an.cross(Vector3.RIGHT)
		if ortho.length() < 1e-3:
			ortho = an.cross(Vector3.UP)
		return Basis(ortho.normalized(), PI)
	return Basis(c.normalized(), atan2(c.length(), dot))
