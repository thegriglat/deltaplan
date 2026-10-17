extends Node
## GPU (tools/gpu_tests.sh --filter=test_cloud_render): слой поля облачности (CLF-5) в
## compute-проходе облаков и в карте теней. Слой собирается (compute-шейдер, шейдер карты теней,
## боксовый шейдер без слоя); текстура поля (CLF-К2) доходит до эффекта и меняет картинку; пустое
## поле — слой не марширует (счётчик кадров пропуска); боксовый путь (Compatibility) не падает.
## Вид слоя проверяется кадрами (tools/shots/cloud_field/shots.sh): в SubViewport теста вывод
## эффекта в кадре теста не обнаружен (причина не выяснена), поэтому кадры здесь не сравниваются.

const FRAMES := 12

var failures: PackedStringArray = []


func needs_gpu() -> bool:
	return true


func check(cond: bool, msg: String = "") -> void:
	if not cond:
		failures.append("check failed: " + msg)


static func _flat(_x: float, _z: float) -> float:
	return 0.0


static func _sun(_x: float, _z: float) -> float:
	return 1.0


func _world(renderer: String = "compute") -> Atmosphere:
	var cfg := Config.get_config("atmosphere").duplicate(true)
	cfg.clouds.renderer = renderer
	var a := Atmosphere.new()
	a.visuals_enabled = false
	a.configure(cfg, Config.get_config("weather/medium"))
	a.turbulence_enabled = false
	a.set_ground(_flat, _sun)
	a.time_s = 13.0 * 3600.0
	a.set_focus(Vector3.ZERO)
	a.step(0.0)
	return a


## Поле задано руками (шаг поля отключён): квадрат 20 × 20 клеток по 400 м вокруг начала координат,
## покрытие cover, мощность depth; time — метка шага (по ней слой узнаёт новые данные).
static func _set_field(a: Atmosphere, cover: float, depth: float, time: float) -> void:
	var cp := a.cloud_phys
	cp.wait_field()
	cp.inputs_fn = Callable()
	var f := cp.field
	f.setup_grid(20, 20, 400.0, -4000.0, -4000.0)
	f.base_msl = 1500.0
	f.bg_cover = 0.0
	f.bg_depth = 0.0
	f.time = time
	for c in f.nx * f.ny:
		f.cover[c] = cover
		f.depth[c] = depth if cover > 0.0 else 0.0
		f.stage[c] = 0.0
		f.activity[c] = 0.3
	cp.mark_field_changed()


## Сцена: SubViewport с камерой под основанием, взгляд вверх-вперёд; слой облаков в ней.
func _scene(a: Atmosphere) -> Dictionary:
	var vp := SubViewport.new()
	vp.size = Vector2i(160, 120)
	vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	add_child(vp)
	var cam := Camera3D.new()
	cam.far = 60000.0
	vp.add_child(cam)
	cam.look_at_from_position(Vector3(0, 900, 2500), Vector3(0, 1700, -1500), Vector3.UP)
	cam.current = true
	var layer := CloudLayer.new()
	vp.add_child(layer)
	layer.setup(a)
	return {"vp": vp, "layer": layer}


func _frames(n: int) -> void:
	for i in n:
		await RenderingServer.frame_post_draw


func test_field_layer_draws_from_texture() -> void:
	var a := _world()
	_set_field(a, 0.0, 0.0, 1.0)
	var sc := _scene(a)
	var layer: CloudLayer = sc.layer
	await _frames(FRAMES)
	var eff: CloudCompositorEffect = layer._effect
	check(eff != null, "compute-путь: эффект есть")
	if eff == null:
		return
	check(not eff._failed and eff._march.is_valid(), "compute-шейдер со слоем поля собрался")
	check(float(layer.field_params.cf_on) == 0.0, "пустое поле: cf_on = 0")
	var skipped0 := eff.field_skipped
	check(skipped0 > 0 and eff.field_frames == 0, "пустое поле: слой пропущен (%d кадров, марш %d)" % [
		skipped0, eff.field_frames])
	# Поле со сплошным покрытием: новый шаг (time) — текстура обновлена и дошла до эффекта.
	_set_field(a, 1.0, 900.0, 2.0)
	await _frames(FRAMES)
	check(layer.field_uploads >= 2, "текстура поля обновлена по смене данных (%d)" % layer.field_uploads)
	check(float(layer.field_params.cf_on) == 1.0, "поле с облаками: cf_on = 1")
	check(eff.field_tex == layer.field_tex and eff.field_tex != null, "текстура К2 в эффекте")
	check(eff.field_max_tex == layer.field_max_tex and eff.field_max_tex != null, "грубая карта в эффекте")
	var img := layer.field_tex.get_image()
	check(img.get_size() == Vector2i(20, 20) and img.get_format() == Image.FORMAT_RGBA8,
		"текстура К2: RGBA8 nx × ny (%s)" % img.get_size())
	check(img.get_pixel(3, 3).r > 0.99, "R = покрытие")
	var rd := RenderingServer.texture_get_rd_texture(eff.field_tex.get_rid())
	check(rd.is_valid(), "RD-текстура поля для compute есть")
	check(eff.field_frames > 0, "слой поля марширован (%d кадров)" % eff.field_frames)
	# Параметры слоя в UBO эффекта — по К2: угол и обратные размеры сетки, основание и предел мощности.
	var r: Vector4 = eff.params.get("cf_rect", Vector4.ZERO)
	var bse: Vector4 = eff.params.get("cf_base", Vector4.ZERO)
	check(float(eff.params.get("cf_on", 0.0)) == 1.0, "cf_on = 1 в эффекте")
	check(r.is_equal_approx(Vector4(-4000.0, -4000.0, 1.0 / 8000.0, 1.0 / 8000.0)), "cf_rect по К2: %s" % r)
	check(is_equal_approx(bse.x, 1500.0) and bse.y > 0.0, "cf_base: основание и depth_max_m: %s" % bse)
	var misc: Vector4 = eff.params.get("cf_misc", Vector4.ZERO)
	check(misc.x > 900.0, "верх слоя над основанием не ниже мощности поля: %.0f м" % misc.x)
	# Без новых данных поля текстура не перегружается каждый кадр.
	var up := layer.field_uploads
	await _frames(6)
	check(layer.field_uploads == up, "без смены поля — без загрузок (%d → %d)" % [up, layer.field_uploads])
	(sc.vp as Node).queue_free()


func test_field_layer_shadow_quad() -> void:
	var a := _world()
	_set_field(a, 1.0, 900.0, 1.0)
	var sc := _scene(a)
	var layer: CloudLayer = sc.layer
	await _frames(FRAMES)
	var sm: CloudShadowMap = layer._shadow_map
	check(sm != null, "карта теней есть")
	if sm == null:
		return
	check(sm._field_mat.shader.get_shader_uniform_list().size() > 0, "шейдер карты теней со слоем собирается")
	check(sm._field_rect.visible, "квад слоя в карте теней виден при облаках в поле")
	var map: Image = sm._vp.get_texture().get_image()
	var c := map.get_pixel(map.get_width() / 2, map.get_height() / 2).r
	check(c < 0.5, "под сплошным слоем 900 м тень густая: пропускание %.3f" % c)
	# Пустое поле после скачка времени — без перехода от прошлого шага.
	layer._cf_t_upd = -1.0e9
	_set_field(a, 0.0, 0.0, 2.0)
	await _frames(FRAMES)
	check(not sm._field_rect.visible, "пустое поле — квад слоя скрыт")
	(sc.vp as Node).queue_free()


func test_boxes_path_compiles_and_runs() -> void:
	var a := _world("boxes")
	_set_field(a, 1.0, 900.0, 1.0)
	var sc := _scene(a)
	var layer: CloudLayer = sc.layer
	await _frames(FRAMES)
	check(layer._effect == null and layer._mmi != null, "боксовый путь выбран")
	var names: Array = []
	for u: Dictionary in layer._material.shader.get_shader_uniform_list():
		names.append(String(u.name))
	check(names.has("cloud_data") and names.has("noise_shape"), "боксовый шейдер собирается: %d uniform" % names.size())
	check(not names.has("cf_tex"), "в боксовом шейдере слоя поля нет (CLF-6)")
	(sc.vp as Node).queue_free()
