extends Node
## Трава и порода рельефа на CPU (GR-25, G2 v2): GrassField.height_at — 0 на выходах породы купола и
## на скалах обрыва, на лугу у подножия — высота луга; DP_GRASS_DENSITY сильнее density_pct.

var failures: PackedStringArray = []


func check(cond: bool, msg: String = "") -> void:
	if not cond:
		failures.append("check failed: " + msg)


func test_grass_stone_height_at_zero_on_stone() -> void:
	var s := GrassStoneScene.build()
	var cfg: Dictionary = (Config.get_config("vegetation").grass as Dictionary).duplicate(true)
	cfg.enabled = true
	cfg.density_pct = 100
	cfg.mid.mode = "blades"
	var g := GrassField.new()
	var spots: Array[Vector4] = []
	g.setup(s.layer, s.height_tex, s.surface, s.surface_tex, s.look, cfg, spots)
	var full := 0
	var zero := 0
	var mid := 0
	var n := 0
	for z in range(-150, 151, 6):
		for x in range(-150, 151, 6):
			var k := g.grass_keep_at(x, z, SurfaceLayer.GRASS)
			var h := g.height_at(x, z)
			n += 1
			if k <= 0.0:
				zero += 1
				check(h == 0.0, "на породе травы нет: (%d, %d) h %.3f" % [x, z, h])
			elif k >= 1.0:
				full += 1
				check(h > 0.2, "на лугу трава: (%d, %d) h %.3f" % [x, z, h])
			else:
				mid += 1
	# скалы обрыва (уклон ~60°) — травы нет
	check(g.height_at(80.0, 0.0) == 0.0, "обрыв: %.3f" % g.height_at(80.0, 0.0))
	print("    grass_stone CPU: порода %d, луг %d, край %d из %d" % [zero, full, mid, n])
	check(zero > n / 20 and full > n / 5, "в сцене есть порода и луг: %d / %d" % [zero, full])
	g.free()


func test_grass_density_env_overrides_config() -> void:
	var cfg := {"enabled": true, "density_pct": 100}
	var old := OS.get_environment("DP_GRASS_DENSITY")
	OS.set_environment("DP_GRASS_DENSITY", "0")
	check(GrassField.density_k(cfg) == 0.0, "DP_GRASS_DENSITY=0 → 0")
	check(not GrassField.is_enabled(cfg), "DP_GRASS_DENSITY=0 → травы нет")
	OS.set_environment("DP_GRASS_DENSITY", "150")
	check(is_equal_approx(GrassField.density_k(cfg), 1.5), "DP_GRASS_DENSITY=150 → 1,5")
	OS.set_environment("DP_GRASS_DENSITY", "x")
	check(is_equal_approx(GrassField.density_k(cfg), 1.0), "нечисло — как конфиг")
	if old.is_empty():
		OS.unset_environment("DP_GRASS_DENSITY")
	else:
		OS.set_environment("DP_GRASS_DENSITY", old)
	check(is_equal_approx(GrassField.density_k(cfg), 1.0) or not old.is_empty(), "без переменной — конфиг")
