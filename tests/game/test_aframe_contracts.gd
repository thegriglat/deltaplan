extends Node
## Контракты геометрии трапеции и центровки (docs/contracts/aframe-geometry.md, A1–A3.1, A3.4):
## у всех крыльев параметры в glider_params.json в допусках, маркеры в .glb (UprightTop/Bottom L/R,
## WingCG) совпадают с параметрами, из flight.json убраны upright_top_m / upright_bottom_half_width_m,
## в полёте на балансировке середина BaseBar под серединой плеч (apogee ≤ 0,10 м по горизонтали,
## все крылья ≤ 0,15 м). Оси маркеров — Godot (+X вправо, +Y вверх, −Z вперёд) от HangPoint.

const PARAMS := "res://tools/blender/glider_params.json"
const FlightSim := preload("res://tests/flight/flight_sim.gd")
const MARKERS: Array[String] = [
	"HangPoint", "BaseBar", "UprightTopL", "UprightTopR", "UprightBottomL", "UprightBottomR", "WingCG"
]
const BASE_TOL_APOGEE := 0.10
const BASE_TOL_ALL := 0.15

var failures: PackedStringArray = []


func check(cond: bool, msg: String = "") -> void:
	if not cond:
		failures.append("check failed: " + msg)


func approx(actual: float, expected: float, tol: float, msg: String = "") -> void:
	if absf(actual - expected) > tol:
		failures.append("%s: ожидалось %.4f ± %.4f, получено %.4f" % [msg, expected, tol, actual])


func _params() -> Dictionary:
	var f := FileAccess.open(PARAMS, FileAccess.READ)
	return JSON.parse_string(f.get_as_text()) if f != null else {}


## Маркеры модели крыла в осях HangPoint: {имя: Vector3}; пусто — модели нет.
func _markers(out_name: String) -> Dictionary:
	var path := "res://assets/models/%s.glb" % out_name
	var ps := load(path) as PackedScene
	if ps == null:
		return {}
	var root := ps.instantiate() as Node3D
	var res := {}
	var hang := root.find_child("HangPoint", true, false) as Node3D
	if hang != null:
		var inv := GliderVisual._relative_xform(root, hang).affine_inverse()
		for m in MARKERS:
			var n := root.find_child(m, true, false) as Node3D
			if n != null:
				res[m] = inv * GliderVisual._relative_xform(root, n).origin
	root.free()
	return res


## Угол стойки к нормали киля в плоскости симметрии, град (низом вперёд — плюс).
static func _tilt_deg(top: Vector3, bottom: Vector3) -> float:
	var d := bottom - top
	return rad_to_deg(atan2(-d.z, -d.y))


func test_params_and_markers() -> void:
	var params := _params()
	var cf: Dictionary = params.control_frame
	for gone in ["apex_forward_m", "basebar_forward_m", "basebar_drop_m"]:
		check(not cf.has(gone), "control_frame без общей константы %s" % gone)
	var arms: Dictionary = Config.get_config("flight").visual.arms
	check(not arms.has("upright_top_m"), "flight.json: нет visual.arms.upright_top_m")
	check(
		not arms.has("upright_bottom_half_width_m"),
		"flight.json: нет visual.arms.upright_bottom_half_width_m"
	)
	check(cf.has("mass_model") and cf.has("sail_mass_kg"), "control_frame: mass_model, sail_mass_kg")
	for wid: String in params.wings:
		var p: Dictionary = params.wings[wid]
		for k in ["cg_from_nose_m", "nose_forward_m", "upright_tilt_deg", "upright_len_m"]:
			check(p.has(k), "%s: есть %s" % [wid, k])
		if not (p.has("cg_from_nose_m") and p.has("upright_tilt_deg") and p.has("upright_len_m")):
			continue
		var tilt := float(p.upright_tilt_deg)
		var length := float(p.upright_len_m)
		var off := float(p.get("hang_cg_offset_m", cf.hang_cg_offset_m))
		var hfa: float = (
			float(p.hang_from_apex_m)
			if p.has("hang_from_apex_m")
			else float(cf.hang_from_apex_m["double" if p.double_surface else "single"])
		)
		check(tilt >= 4.0 and tilt <= 13.0, "%s: наклон %.1f в 4…13" % [wid, tilt])
		check(length >= 1.6 and length <= 1.75, "%s: длина стоек %.3f в 1,6…1,75" % [wid, length])
		check(off >= 0.01 and off <= 0.02, "%s: подвеска впереди ЦМ на %.3f в 0,01…0,02" % [wid, off])
		check(hfa >= -0.2 and hfa <= 0.2, "%s: hang_from_apex %.2f в −0,20…+0,20" % [wid, hfa])
		approx(
			float(p.nose_forward_m), float(p.cg_from_nose_m) - off, 0.0015,
			"%s: nose_forward_m = cg_from_nose_m − hang_cg_offset_m" % wid
		)
		var mk := _markers(String(p.out))
		check(mk.size() == MARKERS.size(), "%s: в модели есть все маркеры A2 (%d из %d)" % [wid, mk.size(), MARKERS.size()])
		if mk.size() != MARKERS.size():
			continue
		for side in ["L", "R"]:
			var top: Vector3 = mk["UprightTop" + side]
			var bot: Vector3 = mk["UprightBottom" + side]
			approx(_tilt_deg(top, bot), tilt, 0.5, "%s %s: наклон стойки в модели" % [wid, side])
			approx(top.distance_to(bot), length, 0.01, "%s %s: длина стойки в модели" % [wid, side])
			approx(top.z, hfa, 0.01, "%s %s: вершина относительно подвески (hang_from_apex_m)" % [wid, side])
		approx(
			(mk["WingCG"] as Vector3).z, off, 0.002,
			"%s: HangPoint впереди WingCG на hang_cg_offset_m" % wid
		)
		check((mk["WingCG"] as Vector3).y > 0.0, "%s: WingCG на киле выше подвески" % wid)


## Полёт на балансировке: середина BaseBar от середины плеч по горизонтали в осях мира (киль под
## тангажем трима). Плечи — по пилоту в позе prone (не зависят от крыла).
func test_base_bar_under_shoulders() -> void:
	var v := GliderVisual.new()
	add_child(v)
	v.build(
		Config.get_config("wings/apogee"),
		Config.get_config("pilot"),
		Config.get_config("flight").visual
	)
	var ap: AnimationPlayer = v.find_children("*", "AnimationPlayer", true, false)[0]
	ap.play("prone", 0.0)
	ap.advance(0.5)
	v.set_pose(0.0, 0.0, true, 1.0e6)
	for i in 3:
		await get_tree().process_frame
	var hang := Vector3(0, float(Config.get_config("flight").visual.hang_height_m), 0)
	var sh := ((v.shoulder(-1) + v.shoulder(1)) * 0.5) - hang
	v.free()
	var worst := 0.0
	var worst_id := ""
	var params: Dictionary = _params().wings
	for wid: String in params:
		var p: Dictionary = params[wid]
		var mk := _markers(String(p.out))
		if not mk.has("BaseBar"):
			check(false, "%s: нет BaseBar" % wid)
			continue
		var m := FlightSim.make(String(p.config))
		m.reset_in_air(Vector3(0, 3000, 0), 0.0)
		var th := m.theta
		var bb: Vector3 = mk["BaseBar"]
		var f := -bb.z - (-sh.z)  # вперёд в осях крыла
		var u := bb.y - sh.y
		var horiz := f * cos(th) - u * sin(th)
		var vert := f * sin(th) + u * cos(th)
		if wid == "apogee":
			check(
				absf(horiz) <= BASE_TOL_APOGEE,
				"apogee: база от плеч по горизонтали %+.3f (≤ %.2f)" % [horiz, BASE_TOL_APOGEE]
			)
			print("         apogee: база от плеч: по горизонтали %+.3f, по вертикали %+.3f м" % [horiz, vert])
		if absf(horiz) > absf(worst):
			worst = horiz
			worst_id = wid
		check(absf(horiz) <= BASE_TOL_ALL, "%s: база от плеч %+.3f м (≤ %.2f)" % [wid, horiz, BASE_TOL_ALL])
	print("         по всем крыльям худшее: %s, %+.3f м" % [worst_id, worst])
