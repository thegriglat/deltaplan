extends TestCase
## Контракт SC-K5 (docs/contracts/start-camp.md): ткань лагеря, шейдер и CampFabric.material.

const SHADER_PATH := "res://assets/shaders/camp/camp_fabric.gdshader"


func test_shader() -> void:
	var sh := load(SHADER_PATH) as Shader
	check(sh != null, "шейдер грузится")
	if sh == null:
		return
	check(sh.get_mode() == Shader.MODE_SPATIAL, "spatial")
	check(sh.code.contains("uniform bool use_color"), "uniform use_color")
	check(sh.code.contains("uniform float dirt_height_m"), "uniform dirt_height_m")
	check(not sh.code.contains("ALPHA"), "без прозрачности")
	check(sh.code.contains("instance uniform vec3 tint"), "tint — instance uniform")
	check(sh.code.contains("COLOR"), "тон берёт COLOR")


func test_helper() -> void:
	for p in ["tent", "tent_door", "bag", "fabric_dark", "sail", "cloth"]:
		var m := CampFabric.material(p)
		check(m != null and CampFabric.material(p) == m, "пресет %s: кэш" % p)
	check(CampFabric.material("fabric_dark").get_shader_parameter("use_color") == false, "fabric_dark без тона")
	check(CampFabric.material("tent").get_shader_parameter("use_color") != false, "tent берёт тон")
	check(CampFabric.material("tent_door") != CampFabric.material("tent"), "tent_door — отдельный")
