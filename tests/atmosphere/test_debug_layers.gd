extends TestCase
## RW-P2: отладочные слои F3–F7 получают от фасада W2 / крейта непустые конечные данные и рисуются.
## Воздух — не запечённое место из массивов (рельеф с холмом, 9,6 км при шаге 25 м, как требует
## крейт), прогноз, поле Пикара считает крейт (детерминированный режим, малая область поля);
## дальше каждый слой проходит свой путь целиком, кроме окна: F3 (WindFieldDebug: стрелки и
## подпись), F4 (карта фаз: растр, картинка, точка пилота), F5 (DebugOverlays: линии стрелок),
## F6 (термики: формы, столбы и подписи), F7 (поток тепла: растр и сетка на рельефе). Рисует
## сцена, а проверяется то, что она рисует (вершины, экземпляры, текстура), картинками — нет.
## godot --headless --path . res://tests/run_tests.tscn -- --filter=debug_layers

const Rig := preload("res://tests/atmosphere/air_rig.gd")

const N := 385  # узлов места: 9600 м при шаге 25 м
const HALF := 4800.0
const GROUND := 600.0
const LOC := {
	"id": "dbg_layers",
	"center_lat": 51.5,
	"center_lon": 86.5,
	"utc_offset_h": 6.0,
	"month": 7,
	"day": 15,
}
const SKIP_NO_EXT := "нет расширения DpAir (tools/build_rust.sh tune linux)"

var _a: Atmosphere
var _host: Node


class StubTerrain:
	extends Node

	func height_at(x: float, z: float) -> float:
		return DebugLayersHill.ground(x, z)


class DebugLayersHill:
	## Рельеф места: ровная земля и холм 400 м (центр 1200, −1500; радиус 1,5 км).
	static func ground(x: float, z: float) -> float:
		var dx := x - 1200.0
		var dz := z + 1500.0
		var r2 := (dx * dx + dz * dz) / (1500.0 * 1500.0)
		return GROUND + (400.0 * exp(-r2) if r2 < 9.0 else 0.0)


func skip_reason(_method: String) -> String:
	return "" if ClassDB.class_exists("DpAir") else SKIP_NO_EXT


static func _place() -> AirPlaceData:
	var n := N * N
	var h := PackedFloat32Array()
	h.resize(n)
	for j in N:
		for i in N:
			h[j * N + i] = DebugLayersHill.ground(-HALF + 25.0 * i, -HALF + 25.0 * j)
	var water := PackedByteArray()
	water.resize(n)
	var cls := PackedByteArray()
	cls.resize(n)
	cls.fill(SurfaceLayer.GRASS)
	var moist := PackedFloat32Array()
	moist.resize(n)
	moist.fill(0.4)
	var grid := {"origin_x": -HALF, "origin_z": -HALF, "spacing": 25.0, "width": N, "height": N}
	var p := AirPlaceData.from_arrays(
		AirPlaceData.make_header(LOC.duplicate(), grid, []), h, water, cls, moist
	)
	p.fill_crate_inputs()
	return p


## Атмосфера в READY с полем Пикара, один раз на весь файл. Сцена-хозяин: Air, Glider, Terrain —
## по именам, как в game.tscn (WindFieldDebug берёт их оттуда).
func _air() -> Atmosphere:
	if _a != null:
		return _a
	_host = Node.new()
	_host.name = "Host"
	var tree_root := (Engine.get_main_loop() as SceneTree).root
	tree_root.get_child(tree_root.get_child_count() - 1).add_child(_host)  # сцена раннера
	_a = Atmosphere.new()
	_a.name = "Air"
	_a.visuals_enabled = false
	_a.deterministic = true
	var cfg: Dictionary = Config.get_config("atmosphere").duplicate(true)
	cfg.air.domain_l_m = 7200.0  # малая область поля: секунды, а не минуты
	cfg.air.threads = 4
	cfg.air.tol_scale = 5.0
	cfg.air_model.edge_blend_cells = 1.0
	cfg.air_model.window_levels_m = []
	_a.cfg_override = cfg
	_host.add_child(_a)
	_a.configure(cfg)
	_a.configure(7)
	var cond := {
		"forecast":
		{"temperature_c": 28.0, "wind_speed_kmh": 21.6, "wind_from_deg": 270.0, "sky": "clear"},
		"start_hour": 13.0,
		"speed": 1.0,
		"quantum_h": 0.5,
	}
	_a.set_conditions(cond)
	_a.set_static_thermals(PackedFloat32Array([0.0, 0.0, 4.0, 130.0]), 0)
	_a.set_focuses(PackedVector3Array([Vector3(0.0, 900.0, 0.0)]), PackedFloat32Array([1.0]))
	_a.load_place(_place())
	_a.start_at(0.0)
	Rig.wait_ready(_a, 300000)
	_a.advance_to(1.0)
	return _a


func _glider() -> Node3D:
	var g := _host.get_node_or_null("Glider") as Node3D
	if g == null:
		g = Node3D.new()
		g.name = "Glider"
		_host.add_child(g)
		g.global_position = Vector3(0.0, 900.0, 0.0)
	return g


func _terrain() -> Node:
	var t := _host.get_node_or_null("Terrain")
	if t == null:
		t = StubTerrain.new()
		t.name = "Terrain"
		_host.add_child(t)
	return t


static func _finite_v3(v: Vector3) -> bool:
	return is_finite(v.x) and is_finite(v.y) and is_finite(v.z)


static func _all_finite(arr: PackedFloat32Array) -> bool:
	for x in arr:
		if not is_finite(x):
			return false
	return true


## Растр отладки: размеры сходятся с данными, значения конечны.
func _check_raster(r: Dictionary, what: String) -> bool:
	check(not r.is_empty(), "%s: растр непуст" % what)
	if r.is_empty():
		return false
	var data: PackedFloat32Array = r.data
	check(int(r.nx) > 1 and int(r.ny) > 1, "%s: размеры %s×%s" % [what, r.nx, r.ny])
	check(data.size() == int(r.nx) * int(r.ny), "%s: nx·ny = len(data) (%d)" % [what, data.size()])
	check(float(r.dx) > 0.0 and is_finite(float(r.x0)) and is_finite(float(r.z0)), "%s: сетка" % what)
	check(_all_finite(data), "%s: данные конечны" % what)
	return true


func test_air_ready_with_field() -> void:
	var a := _air()
	check(a.is_ready(), "READY (%s)" % a.status())
	check(a.is_air_field_on(), "поле Пикара включено и готово")
	var st := a.status()
	check(String(st.stage) == "", "этапа подготовки нет после READY")
	var nonzero := 0
	var total := 0
	for ix in range(-5, 6):
		for iz in range(-5, 6):
			var p := Vector3(ix * 200.0, GROUND + 300.0, iz * 200.0)
			var v := a.air_velocity_at(p)
			var m := a.sample(p, Atmosphere.SAMPLE_MEAN)
			check(_finite_v3(v) and is_finite(m.x + m.y + m.z + m.w), "ответ конечен в %s" % p)
			total += 1
			if Vector2(v.x, v.z).length() > 0.5:
				nonzero += 1
	check(nonzero > total / 2, "ветер ≠ 0 в большинстве точек (%d из %d)" % [nonzero, total])


func test_f3_wind_field_arrows() -> void:
	var a := _air()
	_glider()
	_terrain()
	var wfd := WindFieldDebug.new()
	_host.add_child(wfd)
	check(not wfd.is_processing(), "выключено — _process не крутится")
	wfd._toggle()
	check(wfd._active, "F3 включился (ссылки Air/Glider/Terrain найдены)")
	if wfd._active:
		var n := maxi(1, int(round(wfd.radius_m / wfd.spacing_m)))
		var count := (2 * n + 1) * (2 * n + 1) * wfd.levels_agl.size()
		check(wfd._mm.multimesh.instance_count == count, "экземпляров стрелок %d из %d" % [wfd._mm.multimesh.instance_count, count])
		var arrows := wfd.arrows_at(_glider().global_position)
		check(arrows.size() == count, "стрелок в сетке %d из %d" % [arrows.size(), count])
		var okk := 0
		var moving := 0
		var rising := 0
		var sinking := 0
		for ar in arrows:
			var xf: Transform3D = ar.xf
			var v: Vector3 = ar.v
			var col: Color = ar.col
			# длина стрелки по ветру: не короче 15 % полной, не длиннее полной; толщина — задана
			var l := xf.basis.z.length()
			if (
				_finite_v3(xf.origin)
				and _finite_v3(v)
				and l >= 0.149 * wfd.arrow_len_m
				and l <= 1.001 * wfd.arrow_len_m
				and is_equal_approx(xf.basis.x.length(), wfd.arrow_thick_m)
			):
				okk += 1
			if Vector2(v.x, v.z).length() > 0.5:
				moving += 1
			rising += 1 if col.r > col.b + 0.01 else 0
			sinking += 1 if col.b > col.r + 0.01 else 0
		check(okk == count, "все стрелки конечны, нужной длины и толщины (%d из %d)" % [okk, count])
		check(moving > count / 2, "ветер ≠ 0 у большинства стрелок (%d из %d)" % [moving, count])
		check(rising + sinking > 0, "цвет по вертикали не одноцветный (подъём %d, спуск %d)" % [rising, sinking])
		check(wfd._label.text == "F3 — ветер: поле", "подпись режима: «%s»" % wfd._label.text)
		wfd._toggle()
		check(not wfd._mm.visible, "повторное F3 прячет стрелки")
	wfd.free()
	_a.set_focuses(PackedVector3Array([Vector3(0.0, 900.0, 0.0)]), PackedFloat32Array([1.0]))


func test_f4_phase_map() -> void:
	var a := _air()
	var pm := WindFieldDebug.fetch_raster(a, "phase_main")
	if not _check_raster(pm, "phase_main"):
		return
	var data: PackedFloat32Array = pm.data
	var kinds := {}
	for x in data:
		check(x >= 0.0 and x < 7.0 and x == floorf(x), "индекс фазы целый в 0…6 (%s)" % x)
		kinds[int(x)] = true
	check(kinds.size() >= 1, "есть хотя бы одна фаза")
	var img := WindFieldDebug.phase_image(pm)
	check(img.get_width() == int(pm.nx) and img.get_height() == int(pm.ny), "картинка nx×ny")
	var lit := 0
	for j in img.get_height():
		for i in img.get_width():
			if img.get_pixel(i, j) != Color.BLACK:
				lit += 1
	check(lit == img.get_width() * img.get_height(), "каждая клетка закрашена цветом фазы")
	# карта накрывает область вокруг начала координат, где пилот
	var span := float(pm.dx) * float(pm.nx)
	check(float(pm.x0) < 0.0 and float(pm.x0) + span > 0.0, "карта накрывает x=0")
	check(float(pm.z0) < 0.0 and float(pm.z0) + float(pm.dx) * float(pm.ny) > 0.0, "карта накрывает z=0")
	# слой целиком
	_glider()
	_terrain()
	var wfd := WindFieldDebug.new()
	_host.add_child(wfd)
	wfd._toggle_phase()
	check(wfd._phase_on, "F4 включился")
	check(wfd._phase_rect.texture != null, "текстура карты фаз задана")
	check(wfd._phase_dot.visible, "точка пилота на карте")
	check(wfd._phase_label.text.begins_with("F4 — карта фаз: A B C D F G H"), "легенда: «%s»" % wfd._phase_label.text)
	var ver: Variant = wfd._phase_src
	wfd._update_phase()
	check(wfd._phase_src == ver, "текстура не перестраивается без новой карты")
	wfd._toggle_phase()
	check(not wfd._phase_canvas.visible, "повторное F4 прячет карту")
	wfd.free()


func _overlays() -> DebugOverlays:
	_air()
	var dbg := DebugOverlays.new()
	_host.add_child(dbg)
	var pilot := _glider()
	dbg.setup(_air(), pilot, DebugLayersHill.ground)
	dbg.camera = pilot
	return dbg


func test_f5_wind_arrows() -> void:
	var dbg := _overlays()
	dbg.toggle_wind()
	check(dbg.wind_on, "F5 включился")
	var v := dbg.mean_air_at(Vector3(0.0, GROUND + 100.0, 0.0))
	check(_finite_v3(v) and Vector2(v.x, v.z).length() > 1.0, "средний ветер в точке ≠ 0 (%s)" % v)
	var grid := dbg._wind_grid()
	check(grid.size() > 100, "в сетке F5 есть точки (%d)" % grid.size())
	for _i in 60:
		dbg._process(0.1)
		if dbg._wind_mesh != null and dbg._wind_pilot != null:
			break
	check(dbg._wind_mesh != null, "сетка стрелок построена")
	if dbg._wind_mesh != null:
		var mesh: ArrayMesh = dbg._wind_mesh.mesh
		check(mesh.get_surface_count() == 1, "у сетки стрелок одна поверхность")
		var verts: PackedVector3Array = mesh.surface_get_arrays(0)[Mesh.ARRAY_VERTEX]
		check(verts.size() > 100, "вершин в стрелках: %d" % verts.size())
		var bad := 0
		for p in verts:
			if not _finite_v3(p):
				bad += 1
		check(bad == 0, "вершины стрелок конечны (%d плохих)" % bad)
	check(dbg._wind_pilot != null, "крупная стрелка над пилотом построена")
	dbg.toggle_wind()
	check(not dbg.wind_on and not dbg.is_processing(), "повторное F5 выключает")
	dbg.free()


func test_f6_thermals() -> void:
	var dbg := _overlays()
	var shapes := dbg.thermal_shapes()
	check(shapes.size() >= 1, "термики в слое F6 (%d)" % shapes.size())
	for s in shapes:
		var ok: bool = (
			float(s.strength) > 0.0
			and float(s.r) > 0.0
			and float(s.y1) > float(s.y0)
			and _finite_v3(s.src)
		)
		check(ok, "форма термика конечна и не пуста: %s" % [s])
		check(dbg.core_radius(s, float(s.y1)) > 10.0, "радиус у верха > 10 м")
	dbg.toggle_thermals()
	dbg._process(1.0)
	check(dbg._th_mesh != null and dbg._th_mesh.mesh != null, "столбы термиков построены")
	if dbg._th_mesh != null and dbg._th_mesh.mesh != null:
		check((dbg._th_mesh.mesh as ArrayMesh).get_surface_count() == 2, "заливка и контуры")
	var shown := 0
	for l in dbg._th_labels:
		if l.visible:
			shown += 1
	check(shown == shapes.size(), "подписей столько же, сколько форм (%d)" % shown)
	dbg.toggle_thermals()
	dbg.free()


func test_f7_heat_flux() -> void:
	var a := _air()
	check("heat_flux" in a.debug_raster_names(), "heat_flux в debug_raster_names")
	var r := a.debug_raster("heat_flux")
	if not _check_raster(r, "heat_flux"):
		return
	var data: PackedFloat32Array = r.data
	var lo := INF
	var hi := -INF
	for x in data:
		lo = minf(lo, x)
		hi = maxf(hi, x)
	check(hi > 50.0, "дневной поток тепла над землёй (макс %.1f Вт/м²)" % hi)
	check(lo >= -50.0, "поток тепла не уходит в большие минусы (мин %.1f)" % lo)
	check(float(r.x0) < 0.0 and float(r.x0) + float(r.dx) * float(r.nx) > 0.0, "карта накрывает x=0")
	var dbg := _overlays()
	dbg.toggle_heat()
	check(dbg.heat_on, "F7 включился")
	dbg._process(2.0)
	check(dbg._heat_mesh != null and dbg._heat_mesh.mesh != null, "сетка потока тепла построена")
	if dbg._heat_mesh != null and dbg._heat_mesh.mesh != null:
		var arr: Array = (dbg._heat_mesh.mesh as ArrayMesh).surface_get_arrays(0)
		var verts: PackedVector3Array = arr[Mesh.ARRAY_VERTEX]
		var cols: PackedColorArray = arr[Mesh.ARRAY_COLOR]
		check(verts.size() > 100 and verts.size() == cols.size(), "вершин %d, цветов %d" % [verts.size(), cols.size()])
		var warm := 0
		for c in cols:
			if c.a > 0.2:
				warm += 1
		check(warm > 0, "есть тёплые клетки (цвет теплее фона)")
	dbg.toggle_heat()
	check(dbg._heat_mesh == null, "повторное F7 убирает сетку")
	dbg.free()


func test_z_release() -> void:
	if _a != null:
		_a.free()
		_a = null
	if _host != null:
		_host.free()
		_host = null
