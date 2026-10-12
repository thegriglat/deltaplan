extends TestCase
## Тень от неба на траве (PH-8, PH-К7): шейдер травы принимает декали (освещаемый spatial без
## unshaded, цвет через ALBEDO), слой травы входит в cull_mask декали, объём декали накрывает траву.

const GRASS_SHADER := "res://scripts/terrain/grass.gdshader"


func test_sky_shade_grass_shader_receives_decals() -> void:
	var code := FileAccess.get_file_as_string(GRASS_SHADER)
	check(not code.is_empty(), "шейдер травы читается")
	var rm := code.substr(code.find("render_mode"), 140)
	check(not rm.contains("unshaded"), "трава не unshaded — декали Forward+ применяются к ALBEDO")
	check(code.contains("ALBEDO ="), "цвет травы пишется в ALBEDO (декаль умножает его до света)")
	check(not code.contains("discard"), "трава не отбрасывает фрагменты в пятне")


func test_sky_shade_grass_layer_and_volume() -> void:
	var g := GrassField.new()
	var vis_cfg: Dictionary = Config.get_config("flight").visual.sky_shade
	var decal := Decal.new()
	decal.cull_mask = 0xFFFFF
	check((g.layers & decal.cull_mask) != 0, "декаль проецируется на слой травы (%d)" % g.layers)
	var gcfg: Dictionary = Config.get_config("vegetation").grass
	var tallest := maxf(float(gcfg.crop_height_m[1]), float(gcfg.blade_height_m[1]))
	var top := float(vis_cfg.vertical_m) * (1.0 - float(vis_cfg.vertical_lift))
	var bottom := float(vis_cfg.vertical_m) * float(vis_cfg.vertical_lift) - float(vis_cfg.vertical_m) * 0.5
	check(top >= tallest, "объём декали выше самой высокой травы: %.2f >= %.2f" % [top, tallest])
	check(bottom <= 0.0 and -bottom >= 0.1, "объём декали ниже земли на запас рельефа: %.2f" % bottom)
	# трава не прячет пятно: затемнение в центре у земли заметно (альфа ≥ 5 %)
	var c := {"gain": vis_cfg.gain, "sky_share": 0.2, "h_max_m": vis_cfg.h_max_m}
	check(SkyShade.darkening(0.0, 3.0, 13.5, c) > 0.05, "пятно на траве заметно")
	decal.free()
	g.free()
