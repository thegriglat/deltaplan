extends Node
## Поношенный вид приборов: на Body обоих приборов — шейдер износа, в моделях есть маска износа
## в цвете вершин (R рёбра, G грязь, B кнопки), у стекла — roughness-текстура при нетронутом
## albedo/эмиссии (читаемость экрана).

var failures: PackedStringArray = []


func check(cond: bool, msg: String = "") -> void:
	if not cond:
		failures.append("check failed: " + msg)


func _body_of(root: Node) -> MeshInstance3D:
	return root.find_child("Body", true, false) as MeshInstance3D


func _check_model(scene: String, screen_of: Callable, kinds: Array) -> void:
	var n: Node3D = load(scene).instantiate()
	add_child(n)
	var screen: MeshInstance3D = screen_of.call(n)
	check(screen != null, scene + ": экран найден")
	var body := _body_of(n)
	check(body != null, scene + ": Body найден")
	if body == null:
		n.free()
		return
	var shaders := 0
	for s in body.mesh.get_surface_count():
		var m := body.get_surface_override_material(s) as ShaderMaterial
		if m != null and m.shader != null:
			shaders += 1
	check(shaders == body.mesh.get_surface_count(), scene + ": все поверхности Body — шейдер износа")
	# маска в вершинах
	var rmax := 0.0
	var gmax := 0.0
	var bmax := 0.0
	var r_zero := 0
	var total := 0
	for s in body.mesh.get_surface_count():
		var arr := body.mesh.surface_get_arrays(s)
		var cols: PackedColorArray = arr[Mesh.ARRAY_COLOR]
		check(cols.size() > 0, scene + ": цвет вершин (маска износа) есть")
		for c in cols:
			rmax = maxf(rmax, c.r)
			gmax = maxf(gmax, c.g)
			bmax = maxf(bmax, c.b)
			total += 1
			if c.r < 0.01:
				r_zero += 1
	check(rmax > 0.5, scene + ": есть рёбра с износом (R max %.2f)" % rmax)
	check(gmax > 0.3, scene + ": есть впадины с грязью (G max %.2f)" % gmax)
	check(bmax > 0.99, scene + ": есть зона кнопок")
	check(total > 0 and float(r_zero) / total > 0.15, scene + ": плоскости без износа (%d/%d)" % [r_zero, total])
	# стекло: шероховатость текстурой, цвет/свечение не тронуты
	var mat := screen.material_override as StandardMaterial3D
	check(mat != null and mat.roughness_texture != null, scene + ": стекло с текстурой шероховатости")
	if mat != null:
		check(mat.albedo_color == Color.WHITE, scene + ": albedo экрана не затемнён")
	n.free()


func test_wear_applied_to_both_instruments() -> void:
	_check_model("res://scenes/instruments/vario_90s_3d.tscn",
		func(n): return (n as Vario90s3D).screen_mesh, [])
	_check_model("res://scenes/instruments/instrument_3d.tscn",
		func(n): return (n as Instrument3D).screen_mesh, [])


func test_kind_of() -> void:
	check(InstrumentWear.kind_of("InstrumentCase") == "plastic", "case")
	check(InstrumentWear.kind_of("VarioKey") == "rubber", "key")
	check(InstrumentWear.kind_of("InstrumentButton") == "rubber", "button")
	check(InstrumentWear.kind_of("VarioChrome") == "metal", "chrome")
	check(InstrumentWear.kind_of("InstrumentClamp") == "metal", "clamp")


func test_glass_texture_deterministic() -> void:
	var g := {"seed": 7, "scratch_count": 10}
	var a := InstrumentWear.glass_texture(0.5, g).get_image()
	var b := InstrumentWear.glass_texture(0.5, g).get_image()
	check(a.get_data() == b.get_data(), "текстура стекла детерминирована")
	# чистое стекло = исходная шероховатость: медиана около clean_level
	var px := a.get_data()
	var low := 0
	for i in px.size():
		if px[i] <= int(0.5 * 255.0) + 2:
			low += 1
	check(float(low) / px.size() > 0.5, "большая часть стекла — исходная шероховатость")
