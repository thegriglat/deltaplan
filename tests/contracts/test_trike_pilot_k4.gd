extends TestCase
## Контракт TP-К4 (docs/contracts/trike-pilot.md): приборы дельталёта — тахометр и топливо, 3D и HUD.

const DOC := "res://docs/contracts/trike-pilot.md"
const SCENE := "res://scenes/instruments/trike_gauges_3d.tscn"


func test_version() -> void:
	var t := FileAccess.get_file_as_string(DOC)
	if t.is_empty():
		t = FileAccess.get_file_as_string(ProjectSettings.globalize_path(DOC))
	check(t.contains("## TP-К4 v2"), "TP-К4 v2 в документе")


func test_needle_angle() -> void:
	var f := GaugeDial.needle_angle_deg
	approx(f.call(0.0, 0.0, 8000.0, 135.0, -135.0), 135.0, 0.001, "начало")
	approx(f.call(8000.0, 0.0, 8000.0, 135.0, -135.0), -135.0, 0.001, "конец")
	approx(f.call(4000.0, 0.0, 8000.0, 135.0, -135.0), 0.0, 0.001, "середина")
	approx(f.call(-100.0, 0.0, 8000.0, 135.0, -135.0), 135.0, 0.001, "упор снизу")
	approx(f.call(9500.0, 0.0, 8000.0, 135.0, -135.0), -135.0, 0.001, "упор сверху")
	approx(TrikeGauges3D.needle_angle_deg(2000.0, 0.0, 8000.0, 135.0, -135.0), 67.5, 0.001, "обёртка 3D")


func test_config_and_locale() -> void:
	var sc := GaugeDial.scales()
	check(float(sc["rpm"]["max_rpm"]) >= float(sc["rpm"]["red_rpm"]), "red_rpm в шкале")
	check(float(sc["tank_l"]) > 0.0, "бак > 0")
	var ops: Dictionary = JSON.parse_string(FileAccess.get_file_as_string("res://configs/trike_pilot.json"))
	var tach: Dictionary = ops["tachometer"]
	approx(float(sc["rpm"]["max_rpm"]), float(tach["max_rpm"]), 0.001, "шкала тахометра = trike_pilot.json")
	approx(float(sc["rpm"]["red_rpm"]), float(tach["red_rpm"]), 0.001, "красная зона = trike_pilot.json")
	check(sc["rpm"]["green_rpm"] == tach["green_rpm"], "зелёная зона = trike_pilot.json")
	approx(float(sc["tank_l"]), float(ops["fuel"]["tank_l"]), 0.001, "бак = fuel.tank_l")
	var inst: Dictionary = JSON.parse_string(FileAccess.get_file_as_string("res://configs/instruments.json"))
	var tg: Dictionary = inst["trike_gauges"]
	check(not tg["tachometer"].has("max_rpm") and not tg["fuel"].has("tank_l_fallback"), "в instruments.json нет копий шкал")
	for k in ["trike_rpm", "trike_fuel"]:
		check(TranslationServer.translate(k) != k, "перевод " + k)


func _rel(n: Node3D, root: Node3D) -> Transform3D:
	var t := Transform3D.IDENTITY
	var c: Node3D = n
	while c != root:
		t = c.transform * t
		c = c.get_parent()
	return t


func _aabb(root: Node3D) -> AABB:
	var out := AABB()
	var first := true
	var stack: Array[Node] = [root]
	while not stack.is_empty():
		var c: Node = stack.pop_back()
		stack.append_array(c.get_children())
		if c is MeshInstance3D and (c as MeshInstance3D).mesh != null:
			var mi := c as MeshInstance3D
			var a := _rel(mi, root) * mi.mesh.get_aabb()
			out = a if first else out.merge(a)
			first = false
	return out


func test_3d() -> void:
	var ps: PackedScene = load(SCENE)
	check(ps != null, "сцена грузится")
	if ps == null:
		return
	var root := ps.instantiate() as Node3D
	check(root is TrikeGauges3D, "корень TrikeGauges3D")
	var rn := root.get_node_or_null("RpmNeedle") as Node3D
	var fn := root.get_node_or_null("FuelNeedle") as Node3D
	check(rn != null and fn != null, "RpmNeedle и FuelNeedle")
	if rn != null and fn != null:
		root.call("update_readout", 6800.0, 26.5, 53.0, true)
		var want := GaugeDial.needle_angle_deg(6800.0, 0.0, 8000.0, 135.0, -135.0)
		approx(rn.rotation_degrees.z, want, 0.5, "поворот RpmNeedle")
		approx(fn.rotation_degrees.z, 0.0, 0.5, "половина бака — стрелка вверх")
		root.call("update_readout", 0.0, 53.0, 53.0, false)
		approx(rn.rotation_degrees.z, 135.0, 0.5, "заглушён — 0 об/мин")
		var sz := _aabb(root).size
		var params: Dictionary = JSON.parse_string(FileAccess.get_file_as_string("res://tools/blender/trike_params.json"))
		var ps2: Array = params["panel"]["size"]
		check(sz.x > 0.1 and sz.x <= float(ps2[0]) + 0.01 and sz.y <= float(ps2[1]) + 0.01,
			"габарит %s ≤ panel.size %s" % [sz, ps2])
	root.free()


func test_hud() -> void:
	var sc := GaugeDial.scales()
	var hud: Dictionary = sc["hud"]
	var ov: Dictionary = Config.get_config("instruments").get("overlay", {})
	var scr: Dictionary = Config.get_config("instruments").get("screen", {})
	var ui: Dictionary = Config.get_config("ui").get("clock", {})
	for win: Vector2 in [Vector2(1280, 720), Vector2(1920, 1080), Vector2(2560, 1440)]:
		var r := TrikeGaugesHud.rect_px(win, hud, ov)
		check(Rect2(Vector2.ZERO, win).encloses(r), "%s: внутри окна %s" % [win, r])
		# рамка InstrumentOverlay (правый нижний угол)
		var bz := float(ov.get("bezel_px", 12))
		var h := win.y * float(ov.get("height_frac", 0.34))
		var w := h * float(scr.get("width_px", 720)) / float(scr.get("height_px", 960))
		var om := float(ov.get("margin_px", 18))
		var frame := Rect2(Vector2(win.x - om - w - 2.0 * bz, win.y - om - h - 2.0 * bz), Vector2(w + 2.0 * bz, h + 2.0 * bz))
		check(not frame.intersects(r), "%s: не пересекает рамку планшета" % win)
		# ClockLabel
		var br := ClockLabel.anchor_px(win, float(ui.get("margin_px", 18)), ov, float(ui.get("gap_px", 8)))
		var clock := Rect2(br - Vector2(win.x * 0.2, win.y * 0.06), Vector2(win.x * 0.2, win.y * 0.06))
		check(not clock.intersects(r), "%s: не пересекает часы" % win)
	var hd := TrikeGaugesHud.new()
	hd.update_readout(3000.0, 20.0, 53.0, true)
	check(not hd.is_shown(), "до set_active скрыт")
	hd.set_active(true)
	check(hd.is_shown(), "активен — виден")
	hd.free()
