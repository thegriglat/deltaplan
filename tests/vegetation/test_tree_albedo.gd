extends TestCase
## SL-14: альбедо крон моделей, крестов LOD2 и билбордов-импостеров после множителя породы
## (configs/world.json → trees.albedo_gain) попадает в диапазон реального полога: хвойные 0,05–0,09,
## лиственные (и лиственница) 0,08–0,12. Яркость Y — линейная, по альфе, из самих текстур (без шейдера).

const LW := Vector3(0.2126, 0.7152, 0.0722)
const DIR := "res://assets/models/trees/"
const SPECIES := ["pine", "cedar", "larch", "birch", "spruce"]
const CONIFER := {"pine": true, "cedar": true, "spruce": true}


static func _img(path: String) -> Image:
	var im := Image.load_from_file(ProjectSettings.globalize_path(path))
	if im != null and im.is_compressed():
		im.decompress()
	return im


## Средняя Y по пикселям с альфой > thr (thr < 0 — взвешенно альфой), область r (в пикселях).
static func luma(im: Image, r: Rect2i, thr: float) -> float:
	var sum := 0.0
	var wsum := 0.0
	for y in range(r.position.y, r.end.y):
		for x in range(r.position.x, r.end.x):
			var c := im.get_pixel(x, y)
			var a := c.a
			var w := a if thr < 0.0 else (1.0 if a > thr else 0.0)
			if w <= 0.0:
				continue
			var l := c.srgb_to_linear()
			sum += w * (l.r * LW.x + l.g * LW.y + l.b * LW.z)
			wsum += w
	return sum / maxf(wsum, 1e-6)


## Базы: крона модели (лист, альфа > 0,5), крест LOD2 (среднее по 8 вариантам), билборд (ячейка атласа × brightness).
static func bases(sp: String, cfg: Dictionary) -> Array:
	var leaf := _img(DIR + "tree_%s_%s_leaf.png" % [sp, sp])
	var b_leaf := luma(leaf, Rect2i(Vector2i.ZERO, leaf.get_size()), 0.5)
	var acc := 0.0
	for k in 8:
		var im := _img(DIR + "tree_%s_tree_%s_v%d_impostor.png" % [sp, sp, k])
		acc += luma(im, Rect2i(Vector2i.ZERO, im.get_size()), -1.0)
	var atlas := _img(String(cfg.impostors.atlas))
	var cells: Array = cfg.impostors.atlas_cells
	var cw := atlas.get_width() / int(cells[0])
	var ch := atlas.get_height() / int(cells[1])
	var i := TreePlacer.SPECIES.find(sp)
	var cell := Rect2i((i % int(cells[0])) * cw, (i / int(cells[0])) * ch, cw, ch)
	var b_atlas := luma(atlas, cell, -1.0) * float(cfg.impostors.brightness)
	return [b_leaf, acc / 8.0, b_atlas]


func test_albedo_reaches_canopy_ranges() -> void:
	var w: Dictionary = Config.get_config("world")
	var cfg: Dictionary = w.trees
	check(bool(w.scene_look.get("tree_albedo_enabled", false)), "tree_albedo_enabled включён")
	var names := ["крона модели", "крест LOD2", "билборд"]
	print("         порода   вид            база    gain   после   цель")
	for sp in SPECIES:
		var conifer: bool = CONIFER.has(sp)
		var lo := 0.05 if conifer else 0.08
		var hi := 0.09 if conifer else 0.12
		var b := bases(sp, cfg)
		for k in 3:
			var g := TerrainTreeModels.albedo_gain_for(cfg, sp, k)
			var after: float = float(b[k]) * g
			print("         %-7s  %-12s  %.4f  %.2f  %.4f  %.2f–%.2f" % [sp, names[k], b[k], g, after, lo, hi])
			check(after >= lo - 0.005 and after <= hi, "%s / %s: альбедо %.4f в %.2f–%.2f" % [sp, names[k], after, lo, hi])


func test_shaders_and_sew() -> void:
	var inc := FileAccess.get_file_as_string("res://scripts/terrain/scene_look.gdshaderinc")
	check(inc.contains("uniform bool sl_tree_albedo_enabled"), "include: sl_tree_albedo_enabled")
	check(inc.contains("float sl_canopy_tone_w"), "include: тон полога без сшивки при включённом SL-14")
	var model := (load("res://scripts/terrain/tree_model.gdshader") as Shader).code
	check(model.contains("uniform float tree_gain") and model.contains("sl_tree_gain(tree_gain)"), "модель: множитель породы")
	# порядок: альбедо (до сезона) — множитель в базовом цвете раньше sl_tree_season
	check(model.find("sl_tree_gain(tree_gain)") < model.find("sl_tree_season(rgb"), "модель: альбедо раньше сезона")
	var imp := (load("res://scripts/terrain/forest_impostors.gdshader") as Shader).code
	check(imp.contains("sp_gain[5]") and imp.contains("v_sl_gain"), "импостеры: множитель породы")
	check(imp.find("* v_sl_gain") < imp.find("sl_tree_season(rgb"), "импостеры: альбедо раньше сезона")
	check(TerrainTreeModels.albedo_gain_for({}, "pine", 0) == 1.0, "нет записи — множитель 1")
