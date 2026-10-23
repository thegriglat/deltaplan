extends TestCase
## Рыхлая оболочка облаков поля (CBS-1): параметры configs/atmosphere.json читаются и согласованы
## (метры, не доли порога; разброса оснований нет), слой передаёт их шейдерам. Профиль плотности
## (0 на границе → полная за field_shell_width_m) считается в шейдере cloud_common.gdshaderinc —
## здесь проверяется, что рамп берёт ширину из cf_shell_w, вид — кадрами (tools/shots/menu_art.py).


func _cfg() -> Dictionary:
	return Config.get_config("atmosphere").clouds


func test_params_read() -> void:
	var c := _cfg()
	for k in ["field_shell_width_m", "field_shell_out_m", "field_shell_density", "field_base_soft_m"]:
		check(c.has(k), "в конфиге есть " + k)
		check(c.has(k + "_doc"), "у " + k + " есть _doc")
	check(float(c.get("field_shell_width_m", 0.0)) >= 10.0, "ширина оболочки внутрь — метры, десятки и больше")
	check(float(c.get("field_shell_out_m", 0.0)) > 0.0, "клочья снаружи есть")
	var d := float(c.get("field_shell_density", -1.0))
	check(d > 0.0 and d <= 1.0, "плотность клочьев в (0, 1]: %s" % d)
	check(float(c.get("field_base_soft_m", 0.0)) >= 10.0, "низ тает не резче 10 м")
	check(not c.has("field_base_spread_m"), "разброса оснований в конфиге нет")


func test_shader_ramp_uses_width() -> void:
	var src := FileAccess.get_file_as_string("res://scripts/atmosphere/cloud_common.gdshaderinc")
	check(src.contains("shell_w = cf_shell_w"), "ширина рампа — от cf_shell_w (м)")
	check(src.contains("smoothstep(0.0, 1.0, (d_in"), "плотность растёт от 0 на границе: smoothstep по расстоянию")
	check(not src.contains("cf_spread"), "кода разброса оснований нет")
	check(not src.contains("cf_base_off"), "смещения основания нет")


func test_ubo_has_shell_floats() -> void:
	for n in ["cf_shell_w", "cf_shell_dens", "cf_shell_h", "cf_base_soft"]:
		check(n in CloudCompositorEffect.FIELD_FLOATS, n + " в UBO слоя поля")
	check(not ("cf_spread_hi" in CloudCompositorEffect.FIELD_FLOATS), "cf_spread удалён")
