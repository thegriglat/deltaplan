extends SceneTree
## Проверка контракта имён моделей (docs/guide/models.md) и ориентации осей.
## godot --headless --path . --script res://scenes/models_preview/check_models.gd
## Печатает найденные/отсутствующие ноды, число треугольников; код выхода 1 при ошибке.

const WING_NODES: Array[String] = ["Sail", "Frame", "ControlFrame", "HangPoint", "BaseBar",
	"InstrumentMount", "VarioMount", "WingTipL", "WingTipR", "UprightTopL", "UprightTopR",
	"UprightBottomL", "UprightBottomR", "WingCG"]
## Модели не крыльев; крылья — по одному glider_<id>.glb на каждый configs/wings/<id>.json.
const OTHER := {
	"res://assets/models/pilot.glb": ["Pilot", "PilotBody", "Helmet", "Head", "HandL", "HandR", "WristL", "WristR",
		"CockpitCamera"],
	"res://assets/models/instrument.glb": ["Body", "Screen"],
	"res://assets/models/vario_90s.glb": ["Body", "Screen"],
	"res://assets/models/watch.glb": ["Case", "Strap", "Dial", "Glass", "HourHand", "MinuteHand"],
	# PH-К4: наручный компас (PH-6)
	"res://assets/models/wrist_compass.glb": ["Case", "Strap", "Card", "Lubber"],
}
const TRI_BUDGET := {"glider": 30000, "wing": 14000, "instrument": 3000}

var _errors := 0


func _init() -> void:
	var pilot_tris := 0
	var contract := _wing_contract()
	contract.merge(OTHER)
	for path: String in contract:
		var ps := load(path) as PackedScene
		if ps == null:
			_fail("%s: не загружается" % path)
			continue
		var root := ps.instantiate() as Node3D
		var found: Array[String] = []
		var missing: Array[String] = []
		for n: String in contract[path]:
			if root.find_child(n, true, false) != null:
				found.append(n)
			else:
				missing.append(n)
		var tris := _count_tris(root)
		print("%s\n  найдены: %s\n  нет: %s\n  треугольников: %d" % [path, ", ".join(found),
			", ".join(missing) if missing else "—", tris])
		if missing:
			_fail("%s: нет нод %s" % [path, missing])
		if path.ends_with("pilot.glb"):
			pilot_tris = tris
		if path.contains("glider_"):
			_expect(path, "треугольников ≤ %d" % TRI_BUDGET.wing, tris <= TRI_BUDGET.wing)
		_check_axes(path, root)
		root.free()
	print("крыло + пилот: бюджет %d треугольников (пилот %d)" % [TRI_BUDGET.glider, pilot_tris])
	print("ИТОГ: %s" % ("OK" if _errors == 0 else "ОШИБОК: %d" % _errors))
	quit(1 if _errors else 0)


## Крылья из configs/wings/*.json: каждое → res://assets/models/glider_<id>.glb.
func _wing_contract() -> Dictionary:
	var out := {}
	var ids := Array(DirAccess.get_files_at("res://configs/wings"))
	ids.sort()
	for f: String in ids:
		if f.get_extension() == "json":
			out["res://assets/models/glider_%s.glb" % f.get_basename()] = WING_NODES
	if out.is_empty():
		_fail("configs/wings: нет конфигов крыльев")
	return out


func _check_axes(path: String, root: Node3D) -> void:
	if path.contains("glider_"):
		var tip_r := _pos(root, "WingTipR")
		var tip_l := _pos(root, "WingTipL")
		var bar := _pos(root, "BaseBar")
		var hang := _pos(root, "HangPoint")
		_expect(path, "WingTipR справа (+X)", tip_r.x > 4.0 and tip_l.x < -4.0)
		_expect(path, "HangPoint в начале координат", hang.length() < 0.01)
		_expect(path, "BaseBar впереди (−Z) и ниже (−Y)", bar.z < -0.1 and bar.y < -1.0)
		var cg := _pos(root, "WingCG")
		# подвеска по центру масс — на 1–2 см впереди (точно — tests/game/test_aframe_contracts.gd);
		# по паспорту (A1 v3) — где даёт производитель, расхождение с ЦМ до ±0,4 м
		_expect(path, "WingCG на киле рядом с подвеской (по ЦМ: на 1–2 см позади; по паспорту — до 0,4 м)",
			absf(cg.z) < 0.4 and absf(cg.x) < 0.001 and cg.y > 0.0)
		for side in ["L", "R"]:
			var top := _pos(root, "UprightTop" + side)
			var bot := _pos(root, "UprightBottom" + side)
			_expect(path, "стойка %s: низ впереди и ниже верха" % side, bot.z < top.z and bot.y < top.y)
		var im := _xform(root, "InstrumentMount")
		# A3.3 v9: приборы на хомуте нижней перекладины — маркер на оси штанги (ломаная
		# BarGripL–BaseBar–BarGripR, допуск 3 см на изгиб PV3) между хватами; экран (−Z) к глазам
		# (назад-вверх: −Z маркера = (0; sin30°; cos30°) при instrument_tilt_deg 60° к горизонту, как
		# в заглушке glider_visual.gd), верх экрана (+Y маркера) — вверх-вперёд
		var vm := _xform(root, "VarioMount")
		var gl := _pos(root, "BarGripL")
		var gr := _pos(root, "BarGripR")
		for pair in [["InstrumentMount", im], ["VarioMount", vm]]:
			var o: Vector3 = pair[1].origin
			var d := minf(_dist_seg(o, gl, bar), _dist_seg(o, bar, gr))
			_expect(path, "%s на оси штанги (%.3f м от оси)" % [pair[0], d], d < 0.03)
			_expect(path, "%s между хватами (|x| %.2f < %.2f)" % [pair[0], absf(o.x), absf(gl.x) - 0.04],
				absf(o.x) < absf(gl.x) - 0.04)
			_expect(path, "%s −Z смотрит назад-вверх на пилота" % pair[0],
				(-pair[1].basis.z).z > 0.7 and (-pair[1].basis.z).y > 0.3)
			_expect(path, "%s верх экрана вверх-вперёд" % pair[0],
				pair[1].basis.y.z < -0.3 and pair[1].basis.y.y > 0.5)
		_expect(path, "VarioMount слева от планшета", vm.origin.x < im.origin.x - 0.1)
		print("  InstrumentMount %s −Z %s" % [im.origin, -im.basis.z])
		print("  VarioMount %s −Z %s" % [vm.origin, -vm.basis.z])
		print("  WingTipL %s WingTipR %s BaseBar %s" % [tip_l, tip_r, bar])
	elif path.ends_with("pilot.glb"):
		var head := _pos(root, "Head")
		_expect(path, "Head впереди (−Z) и ниже подвеса (поза покоя — стоя)", head.y < -0.1)
		var ap := root.find_child("AnimationPlayer", true, false) as AnimationPlayer
		var need := ["stand", "walk", "run", "run_air", "climb_in", "prone", "climb_out",
			"flare"]
		var have: PackedStringArray = ap.get_animation_list() if ap else PackedStringArray()
		var miss := need.filter(func(a: String) -> bool: return not have.has(a))
		print("  анимации: %s" % ", ".join(have))
		_expect(path, "все анимации на месте (нет: %s)" % ", ".join(miss), miss.is_empty())
		_expect(path, "walk и run зациклены", ap != null
			and ap.get_animation("walk").loop_mode == Animation.LOOP_LINEAR
			and ap.get_animation("run").loop_mode == Animation.LOOP_LINEAR)
		print("  Head %s HandL %s HandR %s" % [head, _pos(root, "HandL"), _pos(root, "HandR")])
		for w: String in ["WristL", "WristR"]:
			_expect(path, "%s есть" % w, root.find_child(w, true, false) != null)
	elif path.ends_with("watch.glb"):
		# PH-К4: корпус Ø 40 ± 2 по Y, циферблат смотрит в −Z, стрелки — на оси, острие к +Y
		var cb := (root.find_child("Case", false, false) as MeshInstance3D).get_aabb()
		_expect(path, "корпус Ø %.1f мм (40 ± 2)" % (cb.size.y * 1000), absf(cb.size.y - 0.04) <= 0.002)
		_expect(path, "циферблат в −Z", (root.find_child("Dial", false, false) as MeshInstance3D).get_aabb().position.z < 0)
		for hn in ["HourHand", "MinuteHand"]:
			var hand := root.find_child(hn, false, false) as MeshInstance3D
			_expect(path, "%s: острие к +Y, начало на оси" % hn, hand.get_aabb().end.y > 0.008
				and absf(hand.position.x) < 1e-6 and absf(hand.position.y) < 1e-6)
	elif path.ends_with("instrument.glb") or path.ends_with("vario_90s.glb"):
		var scr := root.find_child("Screen", true, false) as MeshInstance3D
		if scr:
			var aabb := scr.get_aabb()
			_expect(path, "Screen — квад, смотрит в −Z", aabb.size.z < 0.001 and aabb.position.z < 0)
			print("  Screen AABB %s" % aabb)
		print("  бюджет прибора %d: %s" % [TRI_BUDGET.instrument,
			"ok" if _count_tris(root) <= TRI_BUDGET.instrument else "ПРЕВЫШЕН"])
	elif path.ends_with("wrist_compass.glb"):
		# PH-К4 (PH-6): диаметр корпуса, высота, картушка, подвижные части на оси циферблата
		var case_aabb := (root.find_child("Case", true, false) as MeshInstance3D).get_aabb()
		var card := root.find_child("Card", true, false) as MeshInstance3D
		_expect(path, "корпус Ø %.1f мм (46 ± 3)" % (case_aabb.size.x * 1000.0),
			absf(case_aabb.size.x * 1000.0 - 46.0) <= 3.0)
		_expect(path, "высота корпуса %.1f мм ≤ 16" % (-case_aabb.position.z * 1000.0),
			-case_aabb.position.z * 1000.0 <= 16.0)
		_expect(path, "картушка Ø %.1f мм ≥ 34" % (card.get_aabb().size.x * 1000.0),
			card.get_aabb().size.x * 1000.0 >= 34.0)
		_expect(path, "Card на оси циферблата (0, 0, z<0)", absf(card.position.x) < 1e-6
			and absf(card.position.y) < 1e-6 and card.position.z < 0.0)
		_expect(path, "треугольников %d ≤ 2500" % _count_tris(root), _count_tris(root) <= 2500)


func _pos(root: Node3D, n: String) -> Vector3:
	return _xform(root, n).origin


## Трансформ ноды относительно корня сцены (без добавления в дерево).
func _dist_seg(p: Vector3, a: Vector3, b: Vector3) -> float:
	var ab := b - a
	var t := clampf((p - a).dot(ab) / maxf(ab.length_squared(), 1e-9), 0.0, 1.0)
	return p.distance_to(a + ab * t)


func _xform(root: Node3D, n: String) -> Transform3D:
	var node := root.find_child(n, true, false) as Node3D
	if node == null:
		return Transform3D.IDENTITY
	var x := node.transform
	var p := node.get_parent()
	while p != null and p != root:
		x = (p as Node3D).transform * x
		p = p.get_parent()
	return x


func _count_tris(node: Node) -> int:
	var n := 0
	if node is MeshInstance3D and (node as MeshInstance3D).mesh:
		var mesh := (node as MeshInstance3D).mesh
		for s in mesh.get_surface_count():
			var arr := mesh.surface_get_arrays(s)
			var idx: PackedInt32Array = arr[Mesh.ARRAY_INDEX]
			var verts: PackedVector3Array = arr[Mesh.ARRAY_VERTEX]
			n += idx.size() / 3 if idx.size() > 0 else verts.size() / 3
	for c in node.get_children():
		n += _count_tris(c)
	return n


func _expect(path: String, what: String, ok: bool) -> void:
	print("  [%s] %s" % ["ok" if ok else "НЕТ", what])
	if not ok:
		_fail("%s: %s" % [path, what])


func _fail(msg: String) -> void:
	_errors += 1
	push_error(msg)
