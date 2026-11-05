extends TestCase
## CVW-К3: CloudLayer.visible_density_at — плотность по облакам, которые рисуются (записи и слой
## поля), а не по грубому полю. В центре облака ≥ 0,5; вне облаков и в просвете слоя 0; ничего не
## рисуется — −1. Шум для CPU-выборки — срезы атласа PNG (без рендерера).

const Rig := preload("res://tests/atmosphere/air_rig.gd")
const TEX := "res://assets/textures/clouds/cloud_shape.png"
const SHADER := "res://scripts/atmosphere/cloud_common.gdshaderinc"
const BASE := 2000.0


func _slices() -> Array[Image]:
	var atlas := Image.load_from_file(ProjectSettings.globalize_path(TEX))
	var out: Array[Image] = []
	if atlas == null:
		return out
	atlas.convert(Image.FORMAT_RGB8)
	for z in 128:
		out.append(atlas.get_region(Rect2i((z % 16) * 128, (z / 16) * 128, 128, 128)))
	return out


func _layer() -> CloudLayer:
	var a := Rig.make({"advance": 0.0})
	var l := CloudLayer.new()
	l.setup(a, Config.get_config("atmosphere"))
	l._nz_slices = _slices()
	return l


func _add(l: CloudLayer, rec: PackedFloat32Array) -> void:
	var s := l._add_slot()
	l._slot_obj[s] = RefCounted.new()
	l._rec[s] = rec


func _cu(vis: float) -> PackedFloat32Array:
	return CloudLayer.make_record(
		Vector2(0, 0), Vector3.RIGHT, BASE, 1200.0, 800.0, 800.0,
		Vector4(1.0, 0.0, 0.0, 7.0), Vector4(0.0, 0.0, 0.0, 0.0), 0.0, 10.0, vis
	)


func test_not_drawn_is_minus_one() -> void:
	var l := _layer()
	approx(l.visible_density_at(Vector3(0, BASE + 400.0, 0)), -1.0, 1e-6, "записей нет, поля нет")
	_add(l, _cu(0.0))
	approx(l.visible_density_at(Vector3(0, BASE + 400.0, 0)), -1.0, 1e-6, "видимость 0 — не рисуется")


func test_center_and_outside() -> void:
	var l := _layer()
	_add(l, _cu(1.0))
	var c := l.visible_density_at(Vector3(0, BASE + 360.0, 0))
	check(c >= 0.5, "центр рисуемого облака ≥ 0,5: %.3f" % c)
	approx(l.visible_density_at(Vector3(6000, BASE + 360.0, 0)), 0.0, 1e-6, "вне облака 0")
	approx(l.visible_density_at(Vector3(0, BASE - 300.0, 0)), 0.0, 1e-6, "под основанием 0")
	approx(l.visible_density_at(Vector3(0, BASE + 3000.0, 0)), 0.0, 1e-6, "над верхом 0")
	# уходящее облако тает (vis³)
	_add(l, _cu(0.5))
	check(l.visible_density_at(Vector3(0, BASE + 360.0, 0)) <= 1.0, "не больше 1")


func test_field_gaps() -> void:
	var l := _layer()
	# поле 4 × 4 ячейки по 1 км: покрытие 0,25 всюду (грубая плотность > 0 везде), мощность полная
	var raw := PackedByteArray()
	for i in 16:
		raw.append_array(PackedByteArray([64, 255, 128, 0]))
	l._cf_img = Image.create_from_data(4, 4, false, Image.FORMAT_RGBA8, raw)
	l._cf_prev_img = l._cf_img
	l._cf_quant = CloudLayer.slice_quantiles(l._nz_slices)
	l.field_params = {
		"cf_on": 1.0, "cf_rect": Vector4(-2000, -2000, 1.0 / 4000.0, 1.0 / 4000.0),
		"cf_base": Vector4(BASE, 2500.0, 0.25, 0.0), "cf_edge": 2000.0,
		"cf_misc": Vector4(3000.0, 20000.0, 8000.0, 1.0), "cf_shell_w": 40.0,
		"cf_shell_dens": 0.25, "cf_shell_h": 25.0,
	}
	var n := 0
	var zero := 0
	var mx := 0.0
	for ix in 40:
		for iz in 40:
			var d := l.visible_density_at(Vector3(-1900 + ix * 95.0, BASE + 300.0, -1900 + iz * 95.0))
			check(d >= 0.0 and d <= 1.0, "в [0, 1]")
			n += 1
			zero += 1 if d == 0.0 else 0
			mx = maxf(mx, d)
	check(mx >= 0.5, "в теле облака поля ≥ 0,5: %.3f" % mx)
	check(float(zero) / n > 0.5, "между облаками поля 0, хотя грубое поле > 0: доля нулей %.2f" % (float(zero) / n))
	l.field_params["cf_on"] = 0.0
	approx(l.visible_density_at(Vector3(0, BASE + 300.0, 0)), -1.0, 1e-6, "поле выключено — −1")


func test_shader_constants_match() -> void:
	var src := FileAccess.get_file_as_string(SHADER)
	var pairs := {
		"FADE_H0": CloudLayer.V_FADE_H0, "FADE_H1": CloudLayer.V_FADE_H1, "FADE_R1": CloudLayer.V_FADE_R1,
		"CF_DOME_E": CloudLayer.V_CF_DOME_E, "CF_ASPECT": CloudLayer.V_CF_ASPECT,
		"CF_D_REF": CloudLayer.V_CF_D_REF, "CF_W_MIN": CloudLayer.V_CF_W_MIN, "CF_W_MAX": CloudLayer.V_CF_W_MAX,
		"CF_XI_MU": CloudLayer.V_CF_XI_MU, "CF_XI_SD": CloudLayer.V_CF_XI_SD, "CF_XI_LO": CloudLayer.V_CF_XI_LO,
		"CF_XI_HI": CloudLayer.V_CF_XI_HI, "CF_MASK_K": CloudLayer.V_CF_MASK_K, "CF_EDGE_E": CloudLayer.V_CF_EDGE_E,
	}
	for k: String in pairs:
		var m := RegEx.create_from_string("const float %s = ([-0-9.]+);" % k).search(src)
		check(m != null and absf(float(m.get_string(1)) - float(pairs[k])) < 1e-6, "константа " + k)
