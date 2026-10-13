extends TestCase
## SL-7: просвет крон моделей деревьев — лиственные больше хвойных (configs/world.json → trees.backlight).


func test_broadleaf_backlight_exceeds_conifer() -> void:
	var cfg: Dictionary = Config.get_config("world").get("trees", {})
	var birch := TerrainTreeModels.backlight_for(cfg, "birch")
	var larch := TerrainTreeModels.backlight_for(cfg, "larch")
	for sp in ["pine", "cedar", "spruce"]:
		var c := TerrainTreeModels.backlight_for(cfg, sp)
		check(c > 0.0 and c < birch, "%s (хвойное) просвечивает меньше берёзы: %.2f < %.2f" % [sp, c, birch])
		check(c <= larch, "%s не больше лиственницы" % sp)
	check(birch <= 1.0, "просвет не выше 1")
	check(TerrainTreeModels.backlight_for({}, "birch") == 0.0, "нет раздела — просвета нет")
	var code := (load("res://scripts/terrain/tree_model.gdshader") as Shader).code
	check(code.contains("uniform float backlight"), "шейдер крон принимает backlight")
