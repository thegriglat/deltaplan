extends TestCase
## Проба «Здесь море» — в выбранной точке, а не в центре места (узле сетки 0,05°).
## Запуск: godot --headless --path . res://tests/run_tests.tscn -- --filter=sea


func test_sea_probe_at_picked_point() -> void:
	# 5×5 узлов по 100 м, центр (0, 0) — вода/океан 0 м; суша 40 м в стороне, на (+200, 0)
	var hs := PackedFloat32Array()
	var cl := PackedByteArray()
	hs.resize(25)
	cl.resize(25)
	hs.fill(0.0)
	cl.fill(SurfaceLayer.WATER)
	for j in 5:
		for i in 3:
			hs[j * 5 + 3 + i - (1 if i == 2 else 0)] = 40.0
			cl[j * 5 + 3 + i - (1 if i == 2 else 0)] = SurfaceLayer.GRASS
	var detail := HeightLayer.from_heights("detail", 5, 5, 100.0, -200.0, -200.0, hs)
	var surf := SurfaceLayer.from_classes("detail", 5, 5, 100.0, -200.0, -200.0, cl)
	check(Terrain.is_sea(detail, surf, -450.0), "центр места — вода: море")
	check(Terrain.is_sea(detail, surf, -450.0, 0.0, 0.0), "проба в центре — море")
	check(not Terrain.is_sea(detail, surf, -450.0, 200.0, 0.0), "выбранная точка на суше — не море")
	check(Terrain.is_sea(detail, surf, -450.0, -200.0, 100.0), "выбранная точка в воде — море")
