extends Node
## Контракт PV3 (docs/contracts/pilot-view.md): изгиб базовой штанги. У каждого крыла
## wings.<id>.basebar задан (straight ⇒ bow_m = 0, curved ⇒ 0,03…0,25); в .glb середина оси штанги
## (BaseBar) вынесена вперёд от хорды UprightBottomL–R на bow_m ±0,005 (у безмачтовых к выносу
## добавляется провис спидбара speedbar_dip_m вниз); хваты рук (BarGripL/R) лежат на оси изогнутой
## штанги (±0,01 м): на хорде плюс вынос по тому же закону дуги.

const PARAMS := "res://tools/blender/glider_params.json"
const NAMES: Array[String] = ["HangPoint", "BaseBar", "UprightBottomL", "UprightBottomR", "BarGripL", "BarGripR"]

var failures: PackedStringArray = []


func check(cond: bool, msg: String = "") -> void:
	if not cond:
		failures.append("check failed: " + msg)


func approx(actual: float, expected: float, tol: float, msg: String = "") -> void:
	if absf(actual - expected) > tol:
		failures.append("%s: ожидалось %.4f ± %.4f, получено %.4f" % [msg, expected, tol, actual])


func _markers(out_name: String) -> Dictionary:
	var ps := load("res://assets/models/%s.glb" % out_name) as PackedScene
	if ps == null:
		return {}
	var root := ps.instantiate() as Node3D
	var res := {}
	var hang := root.find_child("HangPoint", true, false) as Node3D
	if hang != null:
		var inv := GliderVisual._relative_xform(root, hang).affine_inverse()
		for m in NAMES:
			var n := root.find_child(m, true, false) as Node3D
			if n != null:
				res[m] = inv * GliderVisual._relative_xform(root, n).origin
	root.free()
	return res


## Вынос оси вперёд в точке x: тот же закон, что aframe_geom.bow_at.
static func _bow_at(x: float, w: float, bow: float, straight_len: float) -> float:
	var half := w - straight_len
	if bow <= 0.0 or absf(x) >= half:
		return 0.0
	return bow * pow(cos(PI * absf(x) / (2.0 * half)), 2)


func test_basebar_curve() -> void:
	var f := FileAccess.open(PARAMS, FileAccess.READ)
	var params: Dictionary = JSON.parse_string(f.get_as_text())
	var cf: Dictionary = params.control_frame
	check(cf.has("basebar_default") and cf.basebar_default.shape == "curved", "basebar_default задан")
	var grip_x := float(Config.get_config("flight").visual.arms.bar_grip_half_width_m)
	approx(float(cf.bar_grip_hand_x_m), grip_x, 1e-6, "bar_grip_hand_x_m = arms.bar_grip_half_width_m")
	var n_curved := 0
	for wid: String in params.wings:
		var p: Dictionary = params.wings[wid]
		check(p.has("basebar") and p.basebar.has("shape"), "%s: basebar.shape задан" % wid)
		if not p.has("basebar"):
			continue
		var bb: Dictionary = p.basebar
		var bow := float(bb.get("bow_m", -1.0))
		if bb.shape == "straight":
			check(bow == 0.0, "%s: straight ⇒ bow_m = 0" % wid)
		else:
			n_curved += 1
			check(bb.shape == "curved" and bow >= 0.03 and bow <= 0.25, "%s: curved ⇒ bow_m %.3f в 0,03…0,25" % [wid, bow])
		var mk := _markers(String(p.out))
		check(mk.size() == NAMES.size(), "%s: в модели есть BaseBar и BarGripL/R (%d из %d)" % [wid, mk.size(), NAMES.size()])
		if mk.size() != NAMES.size():
			continue
		var l: Vector3 = mk["UprightBottomL"]
		var r: Vector3 = mk["UprightBottomR"]
		var mid := (l + r) * 0.5
		var b: Vector3 = mk["BaseBar"]
		var dip := float(cf.speedbar_dip_m) if p.faired_uprights else 0.0
		# вперёд по ходу = −Z Godot; вниз — −Y
		approx(mid.z - b.z, bow, 0.005, "%s: вынос BaseBar вперёд от хорды" % wid)
		approx(mid.y - b.y, dip, 0.005, "%s: провис спидбара" % wid)
		approx(b.x, 0.0, 0.005, "%s: BaseBar по центру" % wid)
		var w := (r.x - l.x) * 0.5
		var sl := float(bb.get("straight_len_m", 0.0)) if bb.shape == "curved" else 0.0
		for side in [-1, 1]:
			var g: Vector3 = mk["BarGripL" if side < 0 else "BarGripR"]
			approx(absf(g.x), grip_x, 0.01, "%s: хват по x" % wid)
			approx(mid.z - g.z, _bow_at(g.x, w, bow, sl), 0.01, "%s: хват %d на оси изогнутой штанги" % [wid, side])
	check(n_curved > 0, "есть изогнутые штанги")
