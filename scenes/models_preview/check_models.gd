extends SceneTree
## Проверка контракта имён моделей (docs/guide/models.md) и ориентации осей.
## godot --headless --path . --script res://scenes/models_preview/check_models.gd
## Печатает найденные/отсутствующие ноды, число треугольников; код выхода 1 при ошибке.

const WING_NODES: Array[String] = ["Sail", "Frame", "ControlFrame", "HangPoint", "BaseBar",
	"InstrumentMount", "VarioMount", "WingTipL", "WingTipR", "UprightTopL", "UprightTopR",
	"UprightBottomL", "UprightBottomR", "WingCG"]
## Модели не крыльев; крылья — по одному glider_<id>.glb на каждый configs/wings/<id>.json.
const OTHER := {
	"res://assets/models/pilot.glb": ["Pilot", "PilotBody", "Helmet", "Head", "HandL", "HandR",
		"CockpitCamera"],
	"res://assets/models/instrument.glb": ["Body", "Screen"],
	"res://assets/models/vario_90s.glb": ["Body", "Screen"],
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
		# A3.3 v4: прибор на выносе вперёд-вверх от штанги (0,4…0,8 м), по центру
		_expect(path, "InstrumentMount по центру, на выносе вперёд от штанги",
			absf(im.origin.x) < 0.01 and im.origin.distance_to(bar) > 0.4
			and im.origin.distance_to(bar) < 0.8 and im.origin.z < bar.z - 0.3)
		# база теперь под плечами (AF-1, A3.1), глаза пилота при лёжа чуть впереди неё: взгляд на
		# глаза — вверх (вперёд или назад — не проверяем)
		_expect(path, "InstrumentMount −Z смотрит вверх на пилота", (-im.basis.z).y > 0.6)
		var vm := _xform(root, "VarioMount")
		_expect(
			path,
			"VarioMount на таком же выносе слева от планшета (между ним и левой рукой)",
			vm.origin.x < -0.1 and vm.origin.x > -0.3 and absf(vm.origin.y - im.origin.y) < 0.05
			and absf(vm.origin.z - im.origin.z) < 0.05
		)
		_expect(path, "VarioMount −Z смотрит на пилота (вправо-вверх)",
			(-vm.basis.z).x > 0.25 and (-vm.basis.z).y > 0.6)
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
	elif path.ends_with("instrument.glb") or path.ends_with("vario_90s.glb"):
		var scr := root.find_child("Screen", true, false) as MeshInstance3D
		if scr:
			var aabb := scr.get_aabb()
			_expect(path, "Screen — квад, смотрит в −Z", aabb.size.z < 0.001 and aabb.position.z < 0)
			print("  Screen AABB %s" % aabb)
		print("  бюджет прибора %d: %s" % [TRI_BUDGET.instrument,
			"ok" if _count_tris(root) <= TRI_BUDGET.instrument else "ПРЕВЫШЕН"])


func _pos(root: Node3D, n: String) -> Vector3:
	return _xform(root, n).origin


## Трансформ ноды относительно корня сцены (без добавления в дерево).
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
